import XCTest

@testable import CodexProviderSwitcher

final class CodexConfigTransformerTests: XCTestCase {
    private let fixture = """
    model_provider = "custom"
    model = "gpt-5.6-luna"
    model_reasoning_effort = "xhigh"

    [model_providers.custom]
    name = "OpenAI"
    base_url = "https://chatgpt.com/backend-api/codex"
    wire_api = "responses"
    requires_openai_auth = true
    supports_websockets = false

    [features]
    js_repl = false
    """

    private var deepSeekSettings: DeepSeekSettings {
        try! DeepSeekSettings(
            model: "deepseek-v4-flash",
            baseURL: URL(string: "http://127.0.0.1:4000/v1")!
        )
    }

    func testDeepSeekTransformPreservesUnrelatedConfigAndCustomProviderID() throws {
        let transformer = CodexConfigTransformer()
        let output = try transformer.makeDeepSeekConfig(from: fixture, settings: deepSeekSettings)

        XCTAssertTrue(output.contains("model_provider = \"custom\""))
        XCTAssertTrue(output.contains("model_reasoning_effort = \"xhigh\""))
        XCTAssertTrue(output.contains("supports_websockets = false"))
        XCTAssertTrue(output.contains("[features]"))
        XCTAssertTrue(output.contains("js_repl = false"))
    }

    func testDeepSeekTransformSetsResponsesAndEnvironmentKey() throws {
        let transformer = CodexConfigTransformer()
        let output = try transformer.makeDeepSeekConfig(from: fixture, settings: deepSeekSettings)

        XCTAssertTrue(output.contains("model = \"deepseek-v4-flash\""))
        XCTAssertTrue(output.contains("name = \"DeepSeek (experimental)\""))
        XCTAssertTrue(output.contains("base_url = \"http://127.0.0.1:4000/v1\""))
        XCTAssertTrue(output.contains("wire_api = \"responses\""))
        XCTAssertTrue(output.contains("env_key = \"DEEPSEEK_API_KEY\""))
        XCTAssertTrue(output.contains("requires_openai_auth = false"))
    }

    func testModeDetectionDistinguishesGPTDeepSeekAndUnknown() throws {
        let transformer = CodexConfigTransformer()
        let deepSeek = try transformer.makeDeepSeekConfig(from: fixture, settings: deepSeekSettings)

        XCTAssertEqual(transformer.detectMode(in: fixture, settings: deepSeekSettings), .gpt)
        XCTAssertEqual(transformer.detectMode(in: deepSeek, settings: deepSeekSettings), .deepSeek)
        XCTAssertEqual(
            transformer.detectMode(in: fixture.replacingOccurrences(of: "model_provider = \"custom\"", with: "model_provider = \"other\""), settings: deepSeekSettings),
            .unknown
        )
    }

    func testModeDetectionRecognizesDeepSeekWhenChatGPTChangedOnlyTheModel() throws {
        let transformer = CodexConfigTransformer()
        let deepSeek = try transformer.makeDeepSeekConfig(from: fixture, settings: deepSeekSettings)
        let editedByChatGPT = deepSeek.replacingOccurrences(
            of: "model = \"deepseek-v4-flash\"",
            with: "model = \"gpt-5.6-terra\""
        )

        XCTAssertEqual(
            transformer.detectMode(in: editedByChatGPT, settings: deepSeekSettings),
            .deepSeek
        )
    }

    func testModeDetectionAcceptsLegacyDeepSeekV1BaseURL() throws {
        let transformer = CodexConfigTransformer()
        let currentSettings = try DeepSeekSettings(
            model: "deepseek-v4-flash",
            baseURL: URL(string: "https://api.deepseek.com")!
        )
        let legacyConfig = try transformer.makeDeepSeekConfig(from: fixture, settings: currentSettings)
            .replacingOccurrences(
                of: "base_url = \"https://api.deepseek.com\"",
                with: "base_url = \"https://api.deepseek.com/v1\""
            )

        XCTAssertEqual(
            transformer.detectMode(in: legacyConfig, settings: currentSettings),
            .deepSeek
        )
    }

    func testTransformerRejectsMissingCustomProviderTable() {
        let transformer = CodexConfigTransformer()
        let invalid = fixture.replacingOccurrences(of: "[model_providers.custom]", with: "[model_providers.other]")

        XCTAssertThrowsError(try transformer.makeDeepSeekConfig(from: invalid, settings: deepSeekSettings)) { error in
            XCTAssertEqual(error as? ConfigTransformError, .missingProviderTable("model_providers.custom"))
        }
    }

    func testTransformerNeverEmitsAnAPIKeyValue() throws {
        let transformer = CodexConfigTransformer()
        let output = try transformer.makeDeepSeekConfig(from: fixture, settings: deepSeekSettings)

        XCTAssertFalse(output.contains("sk-"))
        XCTAssertFalse(output.contains("DEEPSEEK_API_KEY="))
        XCTAssertTrue(output.contains("env_key = \"DEEPSEEK_API_KEY\""))
    }
}
