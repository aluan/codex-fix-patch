import Foundation
import Network

final class NativeProxyServer: @unchecked Sendable {
    private let configuration: ProxyConfiguration
    private let queue = DispatchQueue(label: "com.aluan.CodexImageGenProxy.server", qos: .userInitiated)
    private let eventHandler: @Sendable (ProxyEvent) -> Void
    private let stateHandler: @Sendable (Result<Void, Error>) -> Void
    private var listener: NWListener?

    init(
        configuration: ProxyConfiguration,
        eventHandler: @escaping @Sendable (ProxyEvent) -> Void,
        stateHandler: @escaping @Sendable (Result<Void, Error>) -> Void
    ) {
        self.configuration = configuration
        self.eventHandler = eventHandler
        self.stateHandler = stateHandler
    }

    func start() throws {
        guard let port = NWEndpoint.Port(rawValue: configuration.port) else {
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
                requestHandler: self.handle
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
        if request.path == "/_codex_imagegen_patch/health" {
            HTTPResponseWriter.sendJSON(
                status: 200,
                object: [
                    "ok": true,
                    "tool_version": ProxyConfiguration.currentToolVersion,
                    "bridge_model": configuration.bridgeModel,
                ],
                to: connection
            )
            return
        }
        let normalizedPath = request.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if normalizedPath.hasSuffix("images/generations") {
            bridge(request, edit: false, connection: connection)
        } else if normalizedPath.hasSuffix("images/edits") {
            bridge(request, edit: true, connection: connection)
        } else {
            forward(request, connection: connection)
        }
    }

    private func bridge(_ request: IncomingHTTPRequest, edit: Bool, connection: NWConnection) {
        Task {
            do {
                let bridge = ResponsesBridge()
                let upstreamRequest = try bridge.makeResponsesRequest(
                    from: request,
                    configuration: configuration,
                    edit: edit
                )
                let (data, response) = try await URLSession.shared.data(for: upstreamRequest)
                guard let response = response as? HTTPURLResponse else {
                    throw ResponsesBridgeError.invalidUpstreamResponse
                }
                guard (200..<300).contains(response.statusCode) else {
                    let message = String(data: data.prefix(2_000), encoding: .utf8) ?? "未知上游错误"
                    throw ResponsesBridgeError.upstreamFailure(response.statusCode, message)
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
                eventHandler(.imageBridged)
            } catch {
                HTTPResponseWriter.error(status: 502, message: error.localizedDescription, to: connection)
                eventHandler(.failed(error.localizedDescription))
                AppLog.error("Image bridge failed: \(error.localizedDescription)")
            }
        }
    }

    private func forward(_ request: IncomingHTTPRequest, connection: NWConnection) {
        do {
            let upstreamRequest = try makeForwardRequest(request)
            let delegate = StreamingForwardDelegate(connection: connection) { [eventHandler] result in
                switch result {
                case .success:
                    eventHandler(.forwarded)
                case .failure(let error):
                    eventHandler(.failed(error.localizedDescription))
                }
            }
            delegate.start(request: upstreamRequest)
        } catch {
            HTTPResponseWriter.error(status: 502, message: error.localizedDescription, to: connection)
            eventHandler(.failed(error.localizedDescription))
        }
    }

    private func makeForwardRequest(_ request: IncomingHTTPRequest) throws -> URLRequest {
        guard let upstream = URL(string: configuration.upstreamBaseURL),
              var components = URLComponents(url: upstream, resolvingAgainstBaseURL: false),
              let incoming = URLComponents(string: request.target) else {
            throw URLError(.badURL)
        }
        components.path = incoming.path
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
        return output
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
    private let completion: @Sendable (Result<Void, Error>) -> Void
    private var session: URLSession?
    private var responseStarted = false

    init(connection: NWConnection, completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        self.connection = connection
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
            completion(.failure(error))
            return
        }
        connection.send(content: Data("0\r\n\r\n".utf8), contentContext: .defaultMessage, isComplete: true, completion: .contentProcessed { [completion] error in
            self.connection.cancel()
            if let error {
                completion(.failure(error))
            } else {
                completion(.success(()))
            }
        })
    }
}
