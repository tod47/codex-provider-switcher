import CryptoKit
import Foundation
import XCTest

@testable import CodexProviderSwitcher

final class SnapshotStoreTests: XCTestCase {
    private var temporaryDirectory: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("provider-switcher-tests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? fileManager.removeItem(at: temporaryDirectory)
        }
        try super.tearDownWithError()
    }

    func testCaptureWritesTimestampedSnapshotAndSHA256() throws {
        let configURL = try makeConfig(contents: "model_provider = \"custom\"\n")
        let rootURL = temporaryDirectory.appendingPathComponent("snapshots", isDirectory: true)
        let store = SnapshotStore(rootURL: rootURL)

        let snapshot = try store.capture(
            configURL: configURL,
            targetMode: .deepSeek,
            now: Date(timeIntervalSince1970: 1_754_678_400)
        )

        XCTAssertTrue(fileManager.fileExists(atPath: snapshot.configURL.path))
        XCTAssertTrue(snapshot.configURL.path.contains("before-deepseek") == false)
        XCTAssertEqual(snapshot.sha256, sha256(Data("model_provider = \"custom\"\n".utf8)))
        XCTAssertTrue(snapshot.configURL.path.contains("snapshots"))
    }

    func testAtomicReplaceLeavesNoTemporaryFile() throws {
        let configURL = try makeConfig(contents: "model = \"gpt\"\n")
        let store = SnapshotStore(rootURL: temporaryDirectory.appendingPathComponent("snapshots"))

        try store.atomicallyReplace(configURL: configURL, with: "model = \"deepseek\"\n")

        XCTAssertEqual(try String(contentsOf: configURL), "model = \"deepseek\"\n")
        let siblings = try fileManager.contentsOfDirectory(
            at: configURL.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        )
        XCTAssertFalse(siblings.contains { $0.lastPathComponent.contains(".tmp-") })
    }

    func testSnapshotReadReturnsTheExactOriginalConfig() throws {
        let original = "model = \"gpt\"\r\nmodel_provider = \"custom\"\r\n"
        let configURL = try makeConfig(contents: original)
        let store = SnapshotStore(rootURL: temporaryDirectory.appendingPathComponent("snapshots"))

        let snapshot = try store.capture(configURL: configURL, targetMode: .deepSeek, now: Date())

        XCTAssertEqual(try store.read(snapshot), original)
    }

    func testManifestRoundTripsAndUses0600Permissions() throws {
        let manifestURL = temporaryDirectory.appendingPathComponent("manifest.json")
        let store = ManifestStore(url: manifestURL)
        let manifest = SwitchManifest(
            activeMode: .deepSeek,
            lastGPTSnapshot: nil,
            lastVerification: nil,
            transactionID: "transaction-1",
            transactionPhase: "launched"
        )

        try store.save(manifest)

        XCTAssertEqual(try store.load(), manifest)
        let attributes = try fileManager.attributesOfItem(atPath: manifestURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testSnapshotStoreDoesNotTouchASeparateStateDatabase() throws {
        let configURL = try makeConfig(contents: "model_provider = \"custom\"\n")
        let stateURL = temporaryDirectory.appendingPathComponent("state_5.sqlite")
        let sentinel = Data("history sentinel".utf8)
        try sentinel.write(to: stateURL)
        let store = SnapshotStore(rootURL: temporaryDirectory.appendingPathComponent("snapshots"))

        _ = try store.capture(configURL: configURL, targetMode: .deepSeek, now: Date())
        try store.atomicallyReplace(configURL: configURL, with: "model_provider = \"custom\"\n")

        XCTAssertEqual(try Data(contentsOf: stateURL), sentinel)
    }

    private func makeConfig(contents: String) throws -> URL {
        let url = temporaryDirectory.appendingPathComponent("config.toml")
        try Data(contents.utf8).write(to: url)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
