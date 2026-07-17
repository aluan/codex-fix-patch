import Foundation

final class ActiveProviderRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ActiveProviderSnapshot

    init(snapshot: ActiveProviderSnapshot) {
        value = snapshot
    }

    func snapshot() -> ActiveProviderSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func update(_ snapshot: ActiveProviderSnapshot) {
        lock.lock()
        value = snapshot
        lock.unlock()
    }
}

enum ProviderRequestAuthorizer {
    static func apply(_ provider: ActiveProviderSnapshot, to request: inout URLRequest) {
        guard provider.profile.credentialMode == .keychainBearer,
              let token = provider.bearerToken, !token.isEmpty else { return }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(nil, forHTTPHeaderField: "api-key")
    }
}
