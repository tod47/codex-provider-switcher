import Foundation

struct EndpointPreflightReport: Equatable, Sendable {
    let reachable: Bool
    let responsesDeclared: Bool
    let messages: [String]
}

protocol HTTPProbe: Sendable {
    func head(_ url: URL, timeout: Duration) async throws -> Int
}

struct URLSessionHTTPProbe: HTTPProbe {
    func head(_ url: URL, timeout: Duration) async throws -> Int {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = timeout.timeInterval
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw EndpointPreflightError.nonHTTPResponse
        }
        return httpResponse.statusCode
    }
}

enum EndpointPreflightError: Error, Equatable {
    case nonHTTPResponse
}

struct EndpointPreflight {
    let probe: any HTTPProbe

    func check(settings: DeepSeekSettings, secretAvailable: Bool) async -> EndpointPreflightReport {
        var messages: [String] = []
        let responsesDeclared = settings.wireAPI == "responses"
        let scheme = settings.baseURL.scheme?.lowercased()
        let validScheme = scheme == "http" || scheme == "https"
        let hasHost = settings.baseURL.host != nil

        if !responsesDeclared {
            messages.append("provider wire_api must be responses")
        }
        if !validScheme || !hasHost {
            messages.append("endpoint URL must use http or https")
        }
        if !secretAvailable {
            messages.append("DeepSeek API Key is missing")
        }

        guard responsesDeclared, validScheme, hasHost, secretAvailable else {
            return EndpointPreflightReport(
                reachable: false,
                responsesDeclared: responsesDeclared,
                messages: messages
            )
        }

        do {
            let status = try await probe.head(settings.baseURL, timeout: .seconds(3))
            if (200..<500).contains(status) {
                messages.append("endpoint reachable (HTTP \(status))")
                return EndpointPreflightReport(
                    reachable: true,
                    responsesDeclared: true,
                    messages: messages
                )
            }
            messages.append("endpoint returned HTTP \(status)")
        } catch {
            messages.append("endpoint probe failed")
        }

        return EndpointPreflightReport(
            reachable: false,
            responsesDeclared: responsesDeclared,
            messages: messages
        )
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let components = self.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
