import Foundation
import XCTest
@testable import GPTSwitch

final class CodexConfigEditorTests: XCTestCase {
    func testEnableAndRestoreOnlyChangesProviderBaseURL() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = directory.appendingPathComponent("config.toml")
        let original = """
        model = "gpt-5.5"
        model_provider = "relay"

        [model_providers.relay]
        name = "Relay"
        base_url = "https://relay.example/api"
        experimental_bearer_token = "secret"

        [features]
        image_generation = true
        """
        try original.write(to: configURL, atomically: true, encoding: .utf8)

        let editor = CodexConfigEditor()
        let configuration = try editor.enable(at: configURL, port: 17891, bridgeModel: nil)

        XCTAssertEqual(configuration.bridgeModel, "gpt-5.5")
        XCTAssertEqual(configuration.localBaseURL, "http://127.0.0.1:17891/api")
        let enabled = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(enabled.contains("base_url = \"http://127.0.0.1:17891/api\""))
        XCTAssertTrue(enabled.contains("experimental_bearer_token = \"secret\""))

        try editor.restore(configuration)
        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), original)
    }

    func testRestoreRefusesUnexpectedConfigurationChange() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = directory.appendingPathComponent("config.toml")
        try "model = \"gpt-5\"\nmodel_provider = \"relay\"\n[model_providers.relay]\nbase_url = \"https://relay.example/api\""
            .write(to: configURL, atomically: true, encoding: .utf8)
        let editor = CodexConfigEditor()
        let configuration = try editor.enable(at: configURL, port: 17891, bridgeModel: nil)
        try "model = \"gpt-5\"\nmodel_provider = \"relay\"\n[model_providers.relay]\nbase_url = \"https://other.example/api\""
            .write(to: configURL, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try editor.restore(configuration))
    }
}
