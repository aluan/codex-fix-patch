import Foundation
import Network

final class NativeProxyServer: @unchecked Sendable {
    private let installConfiguration: ProxyConfiguration
    private let providerRouter: ActiveProviderRouter
    private let queue = DispatchQueue(label: "com.aluan.CodexImageGenProxy.server", qos: .userInitiated)
    private let eventHandler: @Sendable (RequestMetric) -> Void
    private let stateHandler: @Sendable (Result<Void, Error>) -> Void
    private var listener: NWListener?

    init(
        configuration: ProxyConfiguration,
        providerRouter: ActiveProviderRouter,
        eventHandler: @escaping @Sendable (RequestMetric) -> Void,
        stateHandler: @escaping @Sendable (Result<Void, Error>) -> Void
    ) {
        installConfiguration = configuration
        self.providerRouter = providerRouter
        self.eventHandler = eventHandler
        self.stateHandler = stateHandler
    }

    func start() throws {
        guard let port = NWEndpoint.Port(rawValue: installConfiguration.port) else {
            throw URLError(.badURL)
        }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
        let listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.stateHandler(.success(()))
                AppLog.info("Native proxy listening on 127.0.0.1:\(port.rawValue)")
            case .failed(let error):
                self?.stateHandler(.failure(error))
                AppLog.error("Proxy listener failed: \(error.localizedDescription)")
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            ClientConnectionHandler(
                connection: connection,
                queue: self.queue,
                requestHandler: { [weak self] request, connection in
                    self?.handle(request, connection: connection)
                }
            ).start()
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        AppLog.info("Native proxy stopped")
    }

    private func handle(_ request: IncomingHTTPRequest, connection: NWConnection) {
        let provider = providerRouter.snapshot()
        if request.path == "/_codex_imagegen_patch/health" {
            HTTPResponseWriter.sendJSON(
                status: 200,
                object: [
                    "ok": true,
                    "tool_version": ProxyConfiguration.currentToolVersion,
                    "bridge_model": provider.bridgeModel,
                    "provider": provider.profile.displayName,
                ],
                to: connection
            )
            return
        }
        let normalizedPath = request.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if normalizedPath.hasSuffix("images/generations") {
            bridge(request, provider: provider, edit: false, connection: connection)
        } else if normalizedPath.hasSuffix("images/edits") {
            bridge(request, provider: provider, edit: true, connection: connection)
        } else {
            forward(request, provider: provider, connection: connection)
        }
    }

    private func bridge(
        _ request: IncomingHTTPRequest,
        provider: ActiveProviderSnapshot,
        edit: Bool,
        connection: NWConnection
    ) {
        let startedAt = Date()
        let requestMetadata = UsageExtractor.requestMetadata(from: request.body)
        Task {
            var upstreamStatus: Int?
            do {
                let bridge = ResponsesBridge()
                let upstreamRequest = try bridge.makeResponsesRequest(
                    from: request,
                    provider: provider,
                    edit: edit
                )
                let (data, response) = try await URLSession.shared.data(for: upstreamRequest)
                guard let response = response as? HTTPURLResponse else {
                    throw ResponsesBridgeError.invalidUpstreamResponse
                }
                upstreamStatus = response.statusCode
                guard (200..<300).contains(response.statusCode) else {
                    throw ResponsesBridgeError.upstreamFailure(response.statusCode, "上游请求失败")
                }
                let result = try bridge.parseImageResult(
                    data: data,
                    contentType: response.value(forHTTPHeaderField: "Content-Type")
                )
                let output = try bridge.makeImagesResponse(imageResult: result, originalBody: request.body)
                HTTPResponseWriter.send(
                    status: 200,
                    contentType: "application/json; charset=utf-8",
                    body: output,
                    to: connection
                )
                eventHandler(makeMetric(
                    startedAt: startedAt,
                    provider: provider,
                    endpoint: edit ? .imageEdit : .imageGeneration,
                    requestMetadata: requestMetadata,
                    observation: result.observation,
                    statusCode: response.statusCode,
                    imageCount: 1,
                    errorCategory: nil
                ))
            } catch {
                HTTPResponseWriter.error(status: 502, message: error.localizedDescription, to: connection)
                eventHandler(makeMetric(
                    startedAt: startedAt,
                    provider: provider,
                    endpoint: edit ? .imageEdit : .imageGeneration,
                    requestMetadata: requestMetadata,
                    observation: ResponseUsageObservation(),
                    statusCode: upstreamStatus,
                    imageCount: 0,
                    errorCategory: errorCategory(for: error, statusCode: upstreamStatus)
                ))
                AppLog.error("Image bridge failed: \(error.localizedDescription)")
            }
        }
    }

    private func forward(
        _ request: IncomingHTTPRequest,
        provider: ActiveProviderSnapshot,
        connection: NWConnection
    ) {
        let startedAt = Date()
        let metadata = UsageExtractor.requestMetadata(from: request.body)
        let endpoint = requestEndpoint(for: request.path)
        do {
            let upstreamRequest = try makeForwardRequest(request, provider: provider)
            let delegate = StreamingForwardDelegate(
                connection: connection,
                provider: provider,
                endpoint: endpoint,
                requestMetadata: metadata,
                startedAt: startedAt
            ) { [eventHandler] metric in
                eventHandler(metric)
            }
            delegate.start(request: upstreamRequest)
        } catch {
            HTTPResponseWriter.error(status: 502, message: error.localizedDescription, to: connection)
            eventHandler(makeMetric(
                startedAt: startedAt,
                provider: provider,
                endpoint: endpoint,
                requestMetadata: metadata,
                observation: ResponseUsageObservation(),
                statusCode: nil,
                imageCount: 0,
                errorCategory: errorCategory(for: error, statusCode: nil)
            ))
        }
    }

    private func makeForwardRequest(
        _ request: IncomingHTTPRequest,
        provider: ActiveProviderSnapshot
    ) throws -> URLRequest {
        guard let upstream = URL(string: provider.upstreamBaseURL),
              var components = URLComponents(url: upstream, resolvingAgainstBaseURL: false),
              let incoming = URLComponents(string: request.target) else {
            throw URLError(.badURL)
        }
        let localBasePath = URL(string: installConfiguration.localBaseURL)?.path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        var suffix = incoming.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !localBasePath.isEmpty {
            if suffix == localBasePath {
                suffix = ""
            } else if suffix.hasPrefix("\(localBasePath)/") {
                suffix.removeFirst(localBasePath.count + 1)
            }
        }
        let upstreamBasePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = [upstreamBasePath, suffix]
            .filter { !$0.isEmpty }
            .joined(separator: "/")
        if !components.path.isEmpty { components.path = "/\(components.path)" }
        components.query = incoming.query
        guard let url = components.url else {
            throw URLError(.badURL)
        }
        var output = URLRequest(url: url)
        output.httpMethod = request.method
        output.httpBody = request.body.isEmpty ? nil : request.body
        let excluded = Set([
            "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
            "proxy-connection", "te", "trailer", "transfer-encoding", "upgrade",
            "host", "content-length",
        ])
        for (name, value) in request.headers where !excluded.contains(name.lowercased()) {
            output.setValue(value, forHTTPHeaderField: name)
        }
        ProviderRequestAuthorizer.apply(provider, to: &output)
        return output
    }

    private func requestEndpoint(for path: String) -> RequestEndpoint {
        let normalized = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if normalized.hasSuffix("/responses") || normalized == "responses" { return .responses }
        if normalized.hasSuffix("/models") || normalized == "models" { return .models }
        return .other
    }

    private func makeMetric(
        startedAt: Date,
        provider: ActiveProviderSnapshot,
        endpoint: RequestEndpoint,
        requestMetadata: RequestMetadata,
        observation: ResponseUsageObservation,
        statusCode: Int?,
        imageCount: Int,
        errorCategory: String?
    ) -> RequestMetric {
        let completedAt = Date()
        return RequestMetric(
            startedAt: startedAt,
            completedAt: completedAt,
            providerID: provider.id,
            providerName: provider.profile.displayName,
            endpoint: endpoint,
            requestedModel: requestMetadata.model,
            responseModel: observation.model ?? (endpoint == .imageGeneration || endpoint == .imageEdit ? provider.bridgeModel : nil),
            statusCode: statusCode,
            isStreaming: requestMetadata.isStreaming,
            durationMilliseconds: Int(completedAt.timeIntervalSince(startedAt) * 1_000),
            usage: observation.usage,
            imageCount: imageCount,
            errorCategory: errorCategory
        )
    }

    private func errorCategory(for error: Error, statusCode: Int?) -> String {
        if let statusCode { return "http_\(statusCode)" }
        if error is URLError { return "network_error" }
        if error is ResponsesBridgeError { return "bridge_error" }
        return "proxy_error"
    }
}

private final class ClientConnectionHandler: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let requestHandler: @Sendable (IncomingHTTPRequest, NWConnection) -> Void
    private var buffer = Data()
    private var expectedLength: Int?

    init(
        connection: NWConnection,
        queue: DispatchQueue,
        requestHandler: @escaping @Sendable (IncomingHTTPRequest, NWConnection) -> Void
    ) {
        self.connection = connection
        self.queue = queue
        self.requestHandler = requestHandler
    }

    func start() {
        connection.start(queue: queue)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, isComplete, error in
            if let data {
                buffer.append(data)
            }
            do {
                if expectedLength == nil {
                    expectedLength = try HTTPRequestParser.expectedRequestLength(in: buffer)
                }
                if let expectedLength, buffer.count >= expectedLength {
                    let request = try HTTPRequestParser.parse(Data(buffer.prefix(expectedLength)))
                    requestHandler(request, connection)
                    return
                }
            } catch {
                HTTPResponseWriter.error(status: 400, message: error.localizedDescription, to: connection)
                return
            }
            if let error {
                AppLog.error("Client connection failed: \(error.localizedDescription)")
                connection.cancel()
            } else if isComplete {
                connection.cancel()
            } else {
                receive()
            }
        }
    }
}

private final class StreamingForwardDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let connection: NWConnection
    private let provider: ActiveProviderSnapshot
    private let endpoint: RequestEndpoint
    private let requestMetadata: RequestMetadata
    private let startedAt: Date
    private let completion: @Sendable (RequestMetric) -> Void
    private let usageParser = StreamingUsageParser()
    private var session: URLSession?
    private var responseStarted = false
    private var statusCode: Int?
    private var firstByteAt: Date?

    init(
        connection: NWConnection,
        provider: ActiveProviderSnapshot,
        endpoint: RequestEndpoint,
        requestMetadata: RequestMetadata,
        startedAt: Date,
        completion: @escaping @Sendable (RequestMetric) -> Void
    ) {
        self.connection = connection
        self.provider = provider
        self.endpoint = endpoint
        self.requestMetadata = requestMetadata
        self.startedAt = startedAt
        self.completion = completion
    }

    func start(request: URLRequest) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 600
        configuration.timeoutIntervalForResource = 3_600
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        session.dataTask(with: request).resume()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }
        statusCode = response.statusCode
        usageParser.begin(contentType: response.value(forHTTPHeaderField: "Content-Type"))
        var header = "HTTP/1.1 \(response.statusCode) \(HTTPResponseWriter.reasonPhrase(response.statusCode))\r\n"
        let excluded = Set(["content-length", "transfer-encoding", "connection", "keep-alive"])
        for (rawName, rawValue) in response.allHeaderFields {
            let name = String(describing: rawName)
            guard !excluded.contains(name.lowercased()) else { continue }
            header += "\(name): \(rawValue)\r\n"
        }
        header += "Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
        responseStarted = true
        connection.send(content: Data(header.utf8), completion: .contentProcessed { error in
            completionHandler(error == nil ? .allow : .cancel)
        })
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !data.isEmpty else { return }
        if firstByteAt == nil { firstByteAt = Date() }
        usageParser.consume(data)
        var chunk = Data(String(data.count, radix: 16).utf8)
        chunk.append(Data("\r\n".utf8))
        chunk.append(data)
        chunk.append(Data("\r\n".utf8))
        connection.send(content: chunk, completion: .idempotent)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer {
            session.finishTasksAndInvalidate()
            self.session = nil
        }
        if let error {
            if responseStarted {
                connection.cancel()
            } else {
                HTTPResponseWriter.error(status: 502, message: error.localizedDescription, to: connection)
            }
            completion(makeMetric(errorCategory: "network_error"))
            return
        }
        connection.send(content: Data("0\r\n\r\n".utf8), contentContext: .defaultMessage, isComplete: true, completion: .contentProcessed { [completion] error in
            self.connection.cancel()
            completion(self.makeMetric(errorCategory: error == nil ? nil : "downstream_error"))
        })
    }

    private func makeMetric(errorCategory: String?) -> RequestMetric {
        let completedAt = Date()
        let observation = usageParser.finish()
        return RequestMetric(
            startedAt: startedAt,
            completedAt: completedAt,
            providerID: provider.id,
            providerName: provider.profile.displayName,
            endpoint: endpoint,
            requestedModel: requestMetadata.model,
            responseModel: observation.model,
            statusCode: statusCode,
            isStreaming: requestMetadata.isStreaming,
            durationMilliseconds: Int(completedAt.timeIntervalSince(startedAt) * 1_000),
            timeToFirstByteMilliseconds: firstByteAt.map { Int($0.timeIntervalSince(startedAt) * 1_000) },
            usage: observation.usage,
            errorCategory: errorCategory ?? statusCode.flatMap { (200..<300).contains($0) ? nil : "http_\($0)" }
        )
    }
}
