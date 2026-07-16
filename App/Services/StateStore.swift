import Foundation

struct StateStore: Sendable {
    func load() throws -> ProxyConfiguration? {
        guard FileManager.default.fileExists(atPath: AppPaths.state.path) else {
            return nil
        }
        let data = try Data(contentsOf: AppPaths.state)
        return try JSONDecoder().decode(ProxyConfiguration.self, from: data)
    }

    func save(_ configuration: ProxyConfiguration) throws {
        try FileManager.default.createDirectory(at: AppPaths.applicationSupport, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(configuration)
        try data.write(to: AppPaths.state, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: AppPaths.state.path)
    }

    func delete() throws {
        if FileManager.default.fileExists(atPath: AppPaths.state.path) {
            try FileManager.default.removeItem(at: AppPaths.state)
        }
    }
}
