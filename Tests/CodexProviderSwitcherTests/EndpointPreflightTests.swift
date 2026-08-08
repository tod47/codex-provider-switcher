import Foundation
import XCTest

@testable import CodexProviderSwitcher

final class EndpointPreflightTests: XCTestCase {
    func testPreflightRejectsMissingSecret() async throws {
        let probe = RecordingHTTPProbe(status: 200)
        let preflight = EndpointPreflight(probe: probe)
        let settings = try DeepSeekSettings(
            model: "deepseek-test",
            baseURL: URL(string: "https://example.test/v1")!
        )

        let report = await preflight.check(settings: settings, secretAvailable: false)

        XCTAssertFalse(report.reachable)
        XCTAssertTrue(report.messages.contains("DeepSeek API Key is missing"))
        XCTAssertEqual(probe.callCount, 0)
    }

    func testPreflightRejectsNonResponsesWireAPI() async throws {
        let probe = RecordingHTTPProbe(status: 200)
        let preflight = EndpointPreflight(probe: probe)
        let settings = try decodeSettings(wireAPI: "chat_completions")

        let report = await preflight.check(settings: settings, secretAvailable: true)

        XCTAssertFalse(report.responsesDeclared)
        XCTAssertTrue(report.messages.contains("provider wire_api must be responses"))
        XCTAssertEqual(probe.callCount, 0)
    }

    func testPreflightTreats401AsReachableButReportsResponsesDeclaration() async throws {
        let probe = RecordingHTTPProbe(status: 401)
        let preflight = EndpointPreflight(probe: probe)
        let settings = try DeepSeekSettings(
            model: "deepseek-test",
            baseURL: URL(string: "https://example.test/v1")!
        )

        let report = await preflight.check(settings: settings, secretAvailable: true)

        XCTAssertTrue(report.reachable)
        XCTAssertTrue(report.responsesDeclared)
        XCTAssertEqual(probe.callCount, 1)
    }

    func testPreflightRejectsMalformedURLOrUnsupportedScheme() async throws {
        let probe = RecordingHTTPProbe(status: 200)
        let preflight = EndpointPreflight(probe: probe)
        let settings = try decodeSettings(baseURL: "file:///tmp/deepseek")

        let report = await preflight.check(settings: settings, secretAvailable: true)

        XCTAssertFalse(report.reachable)
        XCTAssertTrue(report.messages.contains("endpoint URL must use http or https"))
        XCTAssertEqual(probe.callCount, 0)
    }

    private func decodeSettings(
        baseURL: String = "https://example.test/v1",
        wireAPI: String = "responses"
    ) throws -> DeepSeekSettings {
        let json = """
        {
          "model": "deepseek-test",
          "baseURL": "\(baseURL)",
          "environmentKey": "DEEPSEEK_API_KEY",
          "wireAPI": "\(wireAPI)"
        }
        """
        return try JSONDecoder().decode(DeepSeekSettings.self, from: Data(json.utf8))
    }
}

private final class RecordingHTTPProbe: HTTPProbe, @unchecked Sendable {
    let status: Int
    private(set) var callCount = 0

    init(status: Int) {
        self.status = status
    }

    func head(_ url: URL, timeout: Duration) async throws -> Int {
        callCount += 1
        return status
    }
}
