import Foundation
import XCTest

@testable import CodexProviderSwitcher

final class EnvFileImporterTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-switcher-env-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        try super.tearDownWithError()
    }

    func testEnvImporterReadsQuotedAndUnquotedDeepSeekKey() throws {
        let importer = EnvFileImporter()
        let url = try makeEnvFile(
            "DEEPSEEK_API_KEY=plain-value\nOTHER=value\nQUOTED=\"quoted-value\"\n"
        )

        XCTAssertEqual(try importer.readValue(named: "DEEPSEEK_API_KEY", from: url), "plain-value")
        XCTAssertEqual(try importer.readValue(named: "QUOTED", from: url), "quoted-value")
    }

    func testEnvImporterIgnoresCommentsAndOtherVariables() throws {
        let importer = EnvFileImporter()
        let url = try makeEnvFile(
            "# DEEPSEEK_API_KEY=wrong\nOTHER=value # comment\nDEEPSEEK_API_KEY=correct\n"
        )

        XCTAssertEqual(try importer.readValue(named: "DEEPSEEK_API_KEY", from: url), "correct")
    }

    func testEnvImporterReturnsNilForMissingKey() throws {
        let importer = EnvFileImporter()
        let url = try makeEnvFile("OTHER=value\n")

        XCTAssertNil(try importer.readValue(named: "DEEPSEEK_API_KEY", from: url))
    }

    func testSecretStoreErrorDescriptionDoesNotExposeSecrets() {
        let error = KeychainSecretStoreError.operationFailed(operation: "read", status: -25300)

        XCTAssertFalse(String(describing: error).contains("DEEPSEEK"))
        XCTAssertFalse(String(describing: error).contains("secret"))
    }

    private func makeEnvFile(_ contents: String) throws -> URL {
        let url = temporaryDirectory.appendingPathComponent("test.env")
        try Data(contents.utf8).write(to: url)
        return url
    }
}
