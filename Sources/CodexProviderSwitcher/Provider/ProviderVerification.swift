import Foundation

enum ProviderVerificationState: String, Codable, Equatable, Sendable {
    case configurationAndProcessVerified
    case modelAvailable
    case actualResponseVerified
    case failed

    var displayName: String {
        switch self {
        case .configurationAndProcessVerified:
            return "配置和 Codex 进程已验证"
        case .modelAvailable:
            return "模型目录已验证"
        case .actualResponseVerified:
            return "实际响应模型已验证"
        case .failed:
            return "验证失败"
        }
    }
}

struct ProviderVerification: Codable, Equatable, Sendable {
    let state: ProviderVerificationState
    let verifiedModel: String?
    let verifiedEndpoint: String?
    let actualResponseModel: String?
    let messages: [String]

    init(
        state: ProviderVerificationState,
        verifiedModel: String?,
        verifiedEndpoint: String? = nil,
        actualResponseModel: String? = nil,
        messages: [String]
    ) {
        self.state = state
        self.verifiedModel = verifiedModel
        self.verifiedEndpoint = verifiedEndpoint
        self.actualResponseModel = actualResponseModel
        self.messages = messages
    }

    enum CodingKeys: String, CodingKey {
        case state
        case verifiedModel
        case verifiedEndpoint
        case actualResponseModel
        case messages
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.state = try container.decode(ProviderVerificationState.self, forKey: .state)
        self.verifiedModel = try container.decodeIfPresent(String.self, forKey: .verifiedModel)
        self.verifiedEndpoint = try container.decodeIfPresent(String.self, forKey: .verifiedEndpoint)
        self.actualResponseModel = try container.decodeIfPresent(String.self, forKey: .actualResponseModel)
        self.messages = try container.decodeIfPresent([String].self, forKey: .messages) ?? []
    }
}

struct ProviderStatus: Equatable, Sendable {
    let mode: ProviderMode
    let configuredModel: String?
    let endpoint: String?
    let processRunning: Bool
    let verification: ProviderVerification?

    static func unverified(
        mode: ProviderMode,
        configuredModel: String? = nil,
        endpoint: String? = nil,
        processRunning: Bool = false
    ) -> ProviderStatus {
        ProviderStatus(
            mode: mode,
            configuredModel: configuredModel,
            endpoint: endpoint,
            processRunning: processRunning,
            verification: nil
        )
    }
}

protocol DeepSeekModelCatalogChecking: Sendable {
    func listModels(baseURL: URL, apiKey: String, timeout: Duration) async throws -> [String]
}

protocol DeepSeekModelResponseTesting: Sendable {
    func sendMinimalTest(baseURL: URL, model: String, apiKey: String, timeout: Duration) async throws -> String
}

enum DeepSeekModelCatalogError: Error, Equatable {
    case nonHTTPResponse
    case unexpectedStatus(Int)
    case invalidPayload
}

struct URLSessionDeepSeekModelCatalogChecker: DeepSeekModelCatalogChecking {
    func listModels(baseURL: URL, apiKey: String, timeout: Duration) async throws -> [String] {
        let modelsURL = baseURL.appendingPathComponent("models")
        var request = URLRequest(url: modelsURL)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout.timeInterval
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DeepSeekModelCatalogError.nonHTTPResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw DeepSeekModelCatalogError.unexpectedStatus(httpResponse.statusCode)
        }

        do {
            return try JSONDecoder().decode(ModelListResponse.self, from: data).data.map(\.id)
        } catch {
            throw DeepSeekModelCatalogError.invalidPayload
        }
    }
}

enum DeepSeekResponseTestError: Error, Equatable {
    case nonHTTPResponse
    case unexpectedStatus(Int)
    case invalidPayload
}

struct URLSessionDeepSeekModelResponseTester: DeepSeekModelResponseTesting {
    func sendMinimalTest(
        baseURL: URL,
        model: String,
        apiKey: String,
        timeout: Duration
    ) async throws -> String {
        let responseURL = baseURL.appendingPathComponent("responses")
        var request = URLRequest(url: responseURL)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout.timeInterval
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(MinimalResponseRequest(model: model))

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DeepSeekResponseTestError.nonHTTPResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw DeepSeekResponseTestError.unexpectedStatus(httpResponse.statusCode)
        }

        do {
            return try JSONDecoder().decode(ResponsePayload.self, from: data).model
        } catch {
            throw DeepSeekResponseTestError.invalidPayload
        }
    }
}

private struct MinimalResponseRequest: Encodable {
    let model: String
    let input = "Reply with OK."
    let maxOutputTokens = 1
    let reasoning = Reasoning(effort: "none")
    let store = false

    enum CodingKeys: String, CodingKey {
        case model
        case input
        case maxOutputTokens = "max_output_tokens"
        case reasoning
        case store
    }

    struct Reasoning: Encodable {
        let effort: String
    }
}

private struct ResponsePayload: Decodable {
    let model: String
}

private struct ModelListResponse: Decodable {
    let data: [Model]

    struct Model: Decodable {
        let id: String
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let components = self.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
