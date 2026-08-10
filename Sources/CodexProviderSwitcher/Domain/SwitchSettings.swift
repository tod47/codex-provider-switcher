import Foundation

enum SwitchSettingsError: Error, Equatable {
    case emptyModel
    case unsupportedURLScheme(String)
    case emptyEnvironmentKey
    case invalidWireAPI(String)
    case invalidTimeout
}

struct DeepSeekSettings: Codable, Equatable, Sendable {
    let model: String
    let baseURL: URL
    let environmentKey: String
    let wireAPI: String

    init(
        model: String,
        baseURL: URL,
        environmentKey: String = "DEEPSEEK_API_KEY",
        wireAPI: String = "responses"
    ) throws {
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SwitchSettingsError.emptyModel
        }
        guard let scheme = baseURL.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw SwitchSettingsError.unsupportedURLScheme(baseURL.absoluteString)
        }
        guard !environmentKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SwitchSettingsError.emptyEnvironmentKey
        }
        guard wireAPI == "responses" else {
            throw SwitchSettingsError.invalidWireAPI(wireAPI)
        }

        self.model = model
        self.baseURL = baseURL
        self.environmentKey = environmentKey
        self.wireAPI = wireAPI
    }
}

struct SwitchSettings: Codable, Equatable, Sendable {
    let codexHome: URL
    let codexConfigURL: URL
    let chatGPTApplicationURL: URL
    let deepSeek: DeepSeekSettings
    let keychainService: String
    let keychainAccount: String
    let quitTimeoutSeconds: Double
    let launchTimeoutSeconds: Double

    init(
        codexHome: URL,
        chatGPTApplicationURL: URL,
        deepSeek: DeepSeekSettings,
        keychainService: String = "Codex Provider Switcher",
        keychainAccount: String,
        quitTimeoutSeconds: Double = 20,
        launchTimeoutSeconds: Double = 20
    ) throws {
        guard quitTimeoutSeconds > 0, launchTimeoutSeconds > 0 else {
            throw SwitchSettingsError.invalidTimeout
        }

        self.codexHome = codexHome
        self.codexConfigURL = codexHome.appendingPathComponent("config.toml")
        self.chatGPTApplicationURL = chatGPTApplicationURL
        self.deepSeek = deepSeek
        self.keychainService = keychainService
        self.keychainAccount = keychainAccount
        self.quitTimeoutSeconds = quitTimeoutSeconds
        self.launchTimeoutSeconds = launchTimeoutSeconds
    }

    static func defaultSettings(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        chatGPTApplicationURL: URL = URL(fileURLWithPath: "/Applications/ChatGPT.app"),
        keychainAccount: String = NSUserName()
    ) throws -> SwitchSettings {
        let deepSeek = try DeepSeekSettings(
            model: "deepseek-v4-flash",
            baseURL: URL(string: "https://api.deepseek.com")!
        )
        return try SwitchSettings(
            codexHome: homeDirectory.appendingPathComponent(".codex"),
            chatGPTApplicationURL: chatGPTApplicationURL,
            deepSeek: deepSeek,
            keychainAccount: keychainAccount
        )
    }
}
