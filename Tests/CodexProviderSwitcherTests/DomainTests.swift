import XCTest

@testable import CodexProviderSwitcher

final class DomainTests: XCTestCase {
    func testPackageTargetIsLoadable() {
        XCTAssertTrue(true)
    }

    func testProviderModeRoundTripsThroughCodable() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for mode in [ProviderMode.gpt, .deepSeek, .unknown] {
            let data = try encoder.encode(mode)
            XCTAssertEqual(try decoder.decode(ProviderMode.self, from: data), mode)
        }
    }

    func testDefaultSettingsPointToInjectedHomeAndChatGPTBundle() throws {
        let home = URL(fileURLWithPath: "/tmp/provider-switcher-test-home", isDirectory: true)
        let app = URL(fileURLWithPath: "/tmp/ChatGPT.app", isDirectory: true)

        let settings = try SwitchSettings.defaultSettings(
            homeDirectory: home,
            chatGPTApplicationURL: app,
            keychainAccount: "test-user"
        )

        XCTAssertEqual(settings.codexHome, home.appendingPathComponent(".codex"))
        XCTAssertEqual(settings.codexConfigURL, home.appendingPathComponent(".codex/config.toml"))
        XCTAssertEqual(settings.chatGPTApplicationURL, app)
        XCTAssertEqual(settings.keychainAccount, "test-user")
    }

    func testDeepSeekSettingsRequireResponsesWireAPI() throws {
        XCTAssertThrowsError(
            try DeepSeekSettings(
                model: "deepseek-test",
                baseURL: URL(string: "https://example.test/v1")!,
                wireAPI: "chat_completions"
            )
        ) { error in
            XCTAssertEqual(error as? SwitchSettingsError, .invalidWireAPI("chat_completions"))
        }
    }

    func testDeepSeekSettingsRejectInvalidValues() {
        XCTAssertThrowsError(
            try DeepSeekSettings(model: "", baseURL: URL(string: "https://example.test")!)
        )
        XCTAssertThrowsError(
            try DeepSeekSettings(model: "model", baseURL: URL(string: "file:///tmp/model")!)
        )
        XCTAssertThrowsError(
            try DeepSeekSettings(
                model: "model",
                baseURL: URL(string: "https://example.test")!,
                environmentKey: " "
            )
        )
    }
}
