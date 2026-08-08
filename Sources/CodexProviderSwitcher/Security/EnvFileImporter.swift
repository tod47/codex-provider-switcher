import Foundation

enum EnvFileImportError: Error, Equatable {
    case unreadable(URL)
    case malformedLine(Int)
    case unterminatedQuote(Int)
}

struct EnvFileImporter {
    func readValue(named name: String, from url: URL) throws -> String? {
        let contents: String
        do {
            contents = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw EnvFileImportError.unreadable(url)
        }

        var result: String?
        for (lineNumber, rawLine) in contents.components(separatedBy: .newlines).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else {
                continue
            }
            guard let equalsIndex = line.firstIndex(of: "=") else {
                throw EnvFileImportError.malformedLine(lineNumber + 1)
            }

            let key = String(line[..<equalsIndex]).trimmingCharacters(in: .whitespaces)
            guard key == name else {
                continue
            }

            let rawValue = String(line[line.index(after: equalsIndex)...])
                .trimmingCharacters(in: .whitespaces)
            result = try normalize(rawValue, lineNumber: lineNumber + 1)
        }
        return result
    }

    private func normalize(_ rawValue: String, lineNumber: Int) throws -> String {
        guard let first = rawValue.first else {
            return ""
        }
        if first == "\"" || first == "'" {
            guard rawValue.last == first, rawValue.count >= 2 else {
                throw EnvFileImportError.unterminatedQuote(lineNumber)
            }
            return String(rawValue.dropFirst().dropLast())
        }

        return rawValue
            .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            .trimmingCharacters(in: .whitespaces)
    }
}
