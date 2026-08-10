import Foundation

struct SwitchManifest: Codable, Equatable, Sendable {
    var activeMode: ProviderMode
    var lastGPTSnapshot: ConfigSnapshot?
    var lastVerification: ProviderVerification?
    var transactionID: String?
    var transactionPhase: String?

    static let initial = SwitchManifest(
        activeMode: .unknown,
        lastGPTSnapshot: nil,
        lastVerification: nil,
        transactionID: nil,
        transactionPhase: nil
    )
}

enum ManifestStoreError: Error, Equatable {
    case invalidData(URL)
    case writeFailed(String)
}

final class ManifestStore {
    private let url: URL
    private let fileManager: FileManager

    init(url: URL, fileManager: FileManager = .default) {
        self.url = url
        self.fileManager = fileManager
    }

    func load() throws -> SwitchManifest {
        guard fileManager.fileExists(atPath: url.path) else {
            return .initial
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(SwitchManifest.self, from: data)
        } catch {
            throw ManifestStoreError.invalidData(url)
        }
    }

    func save(_ manifest: SwitchManifest) throws {
        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let data = try JSONEncoder().encode(manifest)
            let temporaryURL = url
                .deletingLastPathComponent()
                .appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
            defer {
                if fileManager.fileExists(atPath: temporaryURL.path) {
                    try? fileManager.removeItem(at: temporaryURL)
                }
            }

            try data.write(to: temporaryURL, options: .withoutOverwriting)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporaryURL.path)

            if fileManager.fileExists(atPath: url.path) {
                _ = try fileManager.replaceItemAt(
                    url,
                    withItemAt: temporaryURL,
                    backupItemName: nil,
                    options: .usingNewMetadataOnly
                )
            } else {
                try fileManager.moveItem(at: temporaryURL, to: url)
            }
        } catch let error as ManifestStoreError {
            throw error
        } catch {
            throw ManifestStoreError.writeFailed(String(describing: error))
        }
    }
}
