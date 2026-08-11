import Foundation

enum ConfigTransformError: Error, Equatable {
    case missingRootKey(String)
    case missingProviderTable(String)
    case duplicateKey(String)
    case invalidExistingConfig(String)
}

struct ProviderConfiguration: Equatable, Sendable {
    let mode: ProviderMode
    let model: String
    let endpoint: String
}

struct CodexConfigTransformer {
    private let gptBaseURL: String

    init(gptBaseURL: String = "https://chatgpt.com/backend-api/codex") {
        self.gptBaseURL = gptBaseURL
    }

    func validateBaseConfig(_ text: String) throws {
        let parsed = try ParsedConfig(text: text)
        try validate(parsed)
    }

    func detectMode(in text: String, settings: DeepSeekSettings) -> ProviderMode {
        guard let parsed = try? ParsedConfig(text: text),
              let rootProvider = parsed.singleValue(table: nil, key: "model_provider"),
              rootProvider == "custom",
              parsed.tableHeaderIndexes["model_providers.custom"]?.count == 1,
              let baseURL = parsed.singleValue(table: "model_providers.custom", key: "base_url"),
              let wireAPI = parsed.singleValue(table: "model_providers.custom", key: "wire_api"),
              let requiresAuth = parsed.singleValue(table: "model_providers.custom", key: "requires_openai_auth")
        else {
            return .unknown
        }

        if baseURL == gptBaseURL, requiresAuth == "true" {
            return .gpt
        }

        let isDeepSeek = deepSeekBaseURLMatches(baseURL, settings: settings)
            && wireAPI == settings.wireAPI
            && parsed.singleValue(table: "model_providers.custom", key: "env_key") == settings.environmentKey
            && requiresAuth == "false"

        return isDeepSeek ? .deepSeek : .unknown
    }

    private func deepSeekBaseURLMatches(_ candidate: String, settings: DeepSeekSettings) -> Bool {
        normalizedProviderBaseURL(candidate) == normalizedProviderBaseURL(settings.baseURL.absoluteString)
    }

    private func normalizedProviderBaseURL(_ value: String) -> String {
        var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        if normalized.hasSuffix("/v1") {
            normalized.removeLast(3)
        }
        return normalized
    }

    func configuration(in text: String, settings: DeepSeekSettings) -> ProviderConfiguration? {
        guard let parsed = try? ParsedConfig(text: text),
              let model = parsed.singleValue(table: nil, key: "model"),
              let baseURL = parsed.singleValue(table: "model_providers.custom", key: "base_url")
        else {
            return nil
        }

        return ProviderConfiguration(
            mode: detectMode(in: text, settings: settings),
            model: model,
            endpoint: baseURL
        )
    }

    func repairDeepSeekModel(
        in text: String,
        settings: DeepSeekSettings
    ) throws -> String? {
        var parsed = try ParsedConfig(text: text)
        guard detectMode(in: text, settings: settings) == .deepSeek,
              let modelAssignment = parsed.singleAssignment(table: nil, key: "model"),
              modelAssignment.value != settings.model
        else {
            return nil
        }

        parsed.lines[modelAssignment.lineIndex] = assignmentLine(
            key: "model",
            value: settings.model,
            originalLine: parsed.lines[modelAssignment.lineIndex]
        )
        return parsed.rendered()
    }

    func makeDeepSeekConfig(from gptConfig: String, settings: DeepSeekSettings) throws -> String {
        var parsed = try ParsedConfig(text: gptConfig)
        try validate(parsed)

        guard let modelAssignment = parsed.singleAssignment(table: nil, key: "model") else {
            throw ConfigTransformError.missingRootKey("model")
        }
        parsed.lines[modelAssignment.lineIndex] = assignmentLine(
            key: "model",
            value: settings.model,
            originalLine: parsed.lines[modelAssignment.lineIndex]
        )

        guard let providerHeader = parsed.tableHeaderIndexes["model_providers.custom"]?.first else {
            throw ConfigTransformError.missingProviderTable("model_providers.custom")
        }

        let fields: [(String, String)] = [
            ("name", "DeepSeek (experimental)"),
            ("base_url", settings.baseURL.absoluteString),
            ("wire_api", settings.wireAPI),
            ("env_key", settings.environmentKey),
            ("requires_openai_auth", "false")
        ]

        let providerEnd = parsed.endOfTable(named: "model_providers.custom", startingAt: providerHeader)
        var missingFields: [(String, String)] = []

        for (key, value) in fields {
            let assignments = parsed.assignments(table: "model_providers.custom", key: key)
            if assignments.count > 1 {
                throw ConfigTransformError.duplicateKey("model_providers.custom.\(key)")
            }
            if let assignment = assignments.first {
                parsed.lines[assignment.lineIndex] = assignmentLine(
                    key: key,
                    value: value,
                    originalLine: parsed.lines[assignment.lineIndex]
                )
            } else {
                missingFields.append((key, value))
            }
        }

        if !missingFields.isEmpty {
            let insertionLines = missingFields.map { key, value in
                assignmentLine(key: key, value: value, originalLine: "")
            }
            parsed.lines.insert(contentsOf: insertionLines, at: providerEnd)
        }

        return parsed.rendered()
    }

    private func validate(_ parsed: ParsedConfig) throws {
        let rootModel = parsed.assignments(table: nil, key: "model")
        guard !rootModel.isEmpty else {
            throw ConfigTransformError.missingRootKey("model")
        }
        guard rootModel.count == 1 else {
            throw ConfigTransformError.duplicateKey("model")
        }

        let rootProvider = parsed.assignments(table: nil, key: "model_provider")
        guard !rootProvider.isEmpty else {
            throw ConfigTransformError.missingRootKey("model_provider")
        }
        guard rootProvider.count == 1 else {
            throw ConfigTransformError.duplicateKey("model_provider")
        }
        guard rootProvider[0].value == "custom" else {
            throw ConfigTransformError.invalidExistingConfig("model_provider must be custom")
        }

        guard parsed.tableHeaderIndexes["model_providers.custom"]?.count == 1 else {
            if parsed.tableHeaderIndexes["model_providers.custom"] == nil {
                throw ConfigTransformError.missingProviderTable("model_providers.custom")
            }
            throw ConfigTransformError.duplicateKey("model_providers.custom")
        }

        for key in ["name", "base_url", "wire_api", "env_key", "requires_openai_auth"] {
            let assignments = parsed.assignments(table: "model_providers.custom", key: key)
            guard assignments.count <= 1 else {
                throw ConfigTransformError.duplicateKey("model_providers.custom.\(key)")
            }
        }
    }

    private func assignmentLine(key: String, value: String, originalLine: String) -> String {
        let indentation = String(originalLine.prefix { $0 == " " || $0 == "\t" })
        let renderedValue: String
        if value == "true" || value == "false" {
            renderedValue = value
        } else {
            renderedValue = "\"\(escapeTOMLBasicString(value))\""
        }
        return "\(indentation)\(key) = \(renderedValue)"
    }

    private func escapeTOMLBasicString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }
}

private struct ConfigAssignment {
    let table: String?
    let key: String
    let value: String
    let lineIndex: Int
}

private struct ParsedConfig {
    var lines: [String]
    let lineEnding: String
    let hasTrailingLineEnding: Bool
    var assignmentsByTableAndKey: [String: [ConfigAssignment]] = [:]
    var tableHeaderIndexes: [String: [Int]] = [:]

    init(text: String) throws {
        self.lineEnding = text.contains("\r\n") ? "\r\n" : "\n"
        let components = text.components(separatedBy: lineEnding)
        self.hasTrailingLineEnding = components.last == ""
        self.lines = hasTrailingLineEnding ? Array(components.dropLast()) : components
        try parseLines()
    }

    func assignments(table: String?, key: String) -> [ConfigAssignment] {
        assignmentsByTableAndKey[assignmentBucket(table: table, key: key)] ?? []
    }

    func singleAssignment(table: String?, key: String) -> ConfigAssignment? {
        assignments(table: table, key: key).count == 1 ? assignments(table: table, key: key)[0] : nil
    }

    func singleValue(table: String?, key: String) -> String? {
        singleAssignment(table: table, key: key)?.value
    }

    func endOfTable(named table: String, startingAt headerIndex: Int) -> Int {
        let nextHeader = tableHeaderIndexes.values
            .flatMap { $0 }
            .filter { $0 > headerIndex }
            .min()
        return nextHeader ?? lines.count
    }

    func rendered() -> String {
        let body = lines.joined(separator: lineEnding)
        return hasTrailingLineEnding ? body + lineEnding : body
    }

    private mutating func parseLines() throws {
        var currentTable: String?

        for (lineIndex, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else {
                continue
            }

            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                guard !trimmed.hasPrefix("[[") else {
                    continue
                }
                let tableName = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                guard !tableName.isEmpty else {
                    throw ConfigTransformError.invalidExistingConfig("empty table header")
                }
                currentTable = tableName
                tableHeaderIndexes[tableName, default: []].append(lineIndex)
                continue
            }

            guard let equalsIndex = trimmed.firstIndex(of: "=") else {
                continue
            }
            let key = String(trimmed[..<equalsIndex]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else {
                continue
            }
            let rawValue = String(trimmed[trimmed.index(after: equalsIndex)...]).trimmingCharacters(in: .whitespaces)
            let value = try parseValue(rawValue)
            let assignment = ConfigAssignment(table: currentTable, key: key, value: value, lineIndex: lineIndex)
            assignmentsByTableAndKey[assignmentBucket(table: currentTable, key: key), default: []].append(assignment)
        }
    }

    private func parseValue(_ rawValue: String) throws -> String {
        guard rawValue.hasPrefix("\"") else {
            return rawValue.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .trimmingCharacters(in: .whitespaces)
        }

        var escaped = false
        var endIndex: String.Index?
        for index in rawValue.indices.dropFirst() {
            let character = rawValue[index]
            if escaped {
                escaped = false
                continue
            }
            if character == "\\" {
                escaped = true
            } else if character == "\"" {
                endIndex = index
                break
            }
        }

        guard let endIndex else {
            throw ConfigTransformError.invalidExistingConfig("unterminated string value")
        }

        let remainder = rawValue[rawValue.index(after: endIndex)...].trimmingCharacters(in: .whitespaces)
        guard remainder.isEmpty || remainder.hasPrefix("#") else {
            throw ConfigTransformError.invalidExistingConfig("unexpected text after string value")
        }

        let content = rawValue[rawValue.index(after: rawValue.startIndex)..<endIndex]
        return decodeTOMLBasicString(String(content))
    }

    private func decodeTOMLBasicString(_ value: String) -> String {
        var result = ""
        var escaped = false
        for character in value {
            if escaped {
                switch character {
                case "n": result.append("\n")
                case "r": result.append("\r")
                case "t": result.append("\t")
                default: result.append(character)
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                result.append(character)
            }
        }
        if escaped {
            result.append("\\")
        }
        return result
    }

    private func assignmentBucket(table: String?, key: String) -> String {
        "\(table ?? "<root>").\(key)"
    }
}
