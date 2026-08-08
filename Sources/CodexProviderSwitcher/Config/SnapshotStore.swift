import CryptoKit
import Foundation

struct ConfigSnapshot: Codable, Equatable, Sendable {
    let id: String
    let createdAt: Date
    let targetMode: ProviderMode
    let configURL: URL
    let sha256: String
}

enum SnapshotStoreError: Error, Equatable {
    case missingConfig(URL)
    case unreadableConfig(URL)
    case replacementFailed(String)
}

final class SnapshotStore {
    private let rootURL: URL
    private let fileManager: FileManager

    init(rootURL: URL, fileManager: FileManager = .default) {
        self.rootURL = rootURL
        self.fileManager = fileManager
    }

    func capture(configURL: URL, targetMode: ProviderMode, now: Date) throws -> ConfigSnapshot {
        guard fileManager.fileExists(atPath: configURL.path) else {
            throw SnapshotStoreError.missingConfig(configURL)
        }
        guard let data = try? Data(contentsOf: configURL) else {
            throw SnapshotStoreError.unreadableConfig(configURL)
        }

        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let id = "\(timestamp(for: now))-\(targetMode.rawValue)-\(UUID().uuidString.lowercased())"
        let snapshotDirectory = rootURL.appendingPathComponent(id, isDirectory: true)
        try fileManager.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true)

        let snapshotURL = snapshotDirectory.appendingPathComponent("config.toml")
        try data.write(to: snapshotURL, options: .atomic)
        try copyPermissions(from: configURL, to: snapshotURL)

        return ConfigSnapshot(
            id: id,
            createdAt: now,
            targetMode: targetMode,
            configURL: snapshotURL,
            sha256: digest(data)
        )
    }

    func read(_ snapshot: ConfigSnapshot) throws -> String {
        let data = try Data(contentsOf: snapshot.configURL)
        guard digest(data) == snapshot.sha256 else {
            throw SnapshotStoreError.unreadableConfig(snapshot.configURL)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw SnapshotStoreError.unreadableConfig(snapshot.configURL)
        }
        return text
    }

    func atomicallyReplace(configURL: URL, with text: String) throws {
        guard fileManager.fileExists(atPath: configURL.path) else {
            throw SnapshotStoreError.missingConfig(configURL)
        }

        let originalAttributes = try fileManager.attributesOfItem(atPath: configURL.path)
        let temporaryURL = configURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(configURL.lastPathComponent).tmp-\(UUID().uuidString)")

        defer {
            if fileManager.fileExists(atPath: temporaryURL.path) {
                try? fileManager.removeItem(at: temporaryURL)
            }
        }

        do {
            try Data(text.utf8).write(to: temporaryURL, options: .withoutOverwriting)
            if let permissions = originalAttributes[.posixPermissions] {
                try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: temporaryURL.path)
            }
            _ = try fileManager.replaceItemAt(
                configURL,
                withItemAt: temporaryURL,
                backupItemName: nil,
                options: .usingNewMetadataOnly
            )
        } catch {
            throw SnapshotStoreError.replacementFailed(String(describing: error))
        }
    }

    private func copyPermissions(from source: URL, to destination: URL) throws {
        let attributes = try fileManager.attributesOfItem(atPath: source.path)
        guard let permissions = attributes[.posixPermissions] else {
            return
        }
        try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: destination.path)
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func timestamp(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmssSSS"
        return formatter.string(from: date)
    }
}
