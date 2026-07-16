import Foundation
import OSLog

enum AppLog {
    private static let logger = Logger(subsystem: "com.aluan.CodexImageGenProxy", category: "app")
    private static let queue = DispatchQueue(label: "com.aluan.CodexImageGenProxy.log")
    private static let maximumBytes = 1_000_000

    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        append("INFO", message)
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        append("ERROR", message)
    }

    private static func append(_ level: String, _ message: String) {
        queue.async {
            do {
                try FileManager.default.createDirectory(at: AppPaths.logs, withIntermediateDirectories: true)
                if let attributes = try? FileManager.default.attributesOfItem(atPath: AppPaths.logFile.path),
                   let size = attributes[.size] as? NSNumber,
                   size.intValue > maximumBytes {
                    let rotated = AppPaths.logs.appendingPathComponent("app.log.1")
                    try? FileManager.default.removeItem(at: rotated)
                    try FileManager.default.moveItem(at: AppPaths.logFile, to: rotated)
                }
                let formatter = ISO8601DateFormatter()
                let line = "\(formatter.string(from: Date())) [\(level)] \(message)\n"
                if !FileManager.default.fileExists(atPath: AppPaths.logFile.path) {
                    try line.write(to: AppPaths.logFile, atomically: true, encoding: .utf8)
                } else {
                    let handle = try FileHandle(forWritingTo: AppPaths.logFile)
                    try handle.seekToEnd()
                    try handle.write(contentsOf: Data(line.utf8))
                    try handle.close()
                }
            } catch {
                logger.error("Failed to persist log: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
