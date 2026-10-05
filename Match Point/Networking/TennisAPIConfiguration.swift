import Foundation
import Security

enum TennisAPIConfiguration {
    private static let providerDefaults = UserDefaults.standard
    private static let apiTennisKeyStorage = "tennis_api_key_api_tennis"
    private static let apiTennisKeyAccount = "tennis_api_key_api_tennis"
    private static let keychain = KeychainSecretStore(service: "com.matchpoint.apikeys")
    private static let backendProxyURLStorage = "match_point_backend_proxy_url"
    private static let backendWebSocketURLStorage = "match_point_backend_websocket_url"

    enum Provider: String, CaseIterable, Codable {
        case apiTennis

        var displayName: String {
            switch self {
            case .apiTennis:
                return "API Tennis"
            }
        }
    }

    struct ProviderReadiness {
        let provider: Provider
        let hasBackendProxy: Bool
        let usesBackendProxy: Bool
        let notes: String

        var isReadyForSync: Bool {
            hasBackendProxy
        }

        var statusLabel: String {
            if isReadyForSync { return "Ready" }
            return "Missing Backend Proxy"
        }
    }

    // The app is wired to use API Tennis through the Match Point backend proxy.
    // Provider credentials are server-side only; the client stores backend URLs,
    // never third-party API keys.
    static var selectedProvider: Provider { .apiTennis }

    // The app must never fall back to provider-hosted API Tennis URLs in
    // production. These placeholders keep URL construction non-optional while
    // `APITennisProvider.request` and `LiveMatchWebSocketService` fail fast
    // until a backend proxy is configured.
    static let backendRequiredRestBaseURL = staticURL("https://backend-required.invalid/tennis")
    static let backendRequiredWebSocketBaseURL = staticURL("wss://backend-required.invalid/live")

    private static func staticURL(_ string: StaticString) -> URL {
        guard let url = URL(string: "\(string)") else {
            preconditionFailure("Invalid static URL literal: \(string)")
        }
        return url
    }
    nonisolated static let timeZone = "America/New_York"

    /// Shared locale used for all API date parsing — `en_US_POSIX` guarantees
    /// stable behavior regardless of user locale (e.g. avoids 12h/24h drift).
    nonisolated static let posixLocale = Locale(identifier: "en_US_POSIX")

    /// Returns a fresh `DateFormatter` pre-configured with the POSIX locale and
    /// the API's expected time zone. Callers set `.dateFormat` themselves.
    /// Returns a new instance each call to avoid sharing mutable state across
    /// threads — `DateFormatter` is not safe to mutate concurrently.
    nonisolated static func makePOSIXDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = posixLocale
        formatter.timeZone = TimeZone(identifier: timeZone)
        return formatter
    }

    /// Tries each `format` in order against `raw` using the POSIX/API timezone
    /// formatter. Returns the first match, or `nil` if none parse. Centralizes
    /// the multi-format fallback previously duplicated across providers.
    nonisolated static func parseAPIDate(_ raw: String?, formats: [String]) -> Date? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let formatter = makePOSIXDateFormatter()
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) {
                return date
            }
        }
        return nil
    }

    static var restBaseURL: URL {
        backendProxyBaseURL ?? backendRequiredRestBaseURL
    }

    static var webSocketBaseURL: URL {
        backendWebSocketBaseURL ?? backendRequiredWebSocketBaseURL
    }

    static var usesBackendProxy: Bool {
        return true
    }

    static var hasBackendProxy: Bool {
        backendProxyBaseURL != nil
    }

    static var backendServiceBaseURL: URL? {
        guard var components = backendProxyBaseURL.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) else {
            return nil
        }
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }

    static var selectedProviderHasConfiguredKey: Bool {
        hasBackendProxy
    }

    static func purgeLegacyAPIKey() {
        keychain.delete(account: apiTennisKeyAccount)
        providerDefaults.removeObject(forKey: apiTennisKeyStorage)
    }

    static var backendProxyBaseURL: URL? {
        urlFromKeychainOrEnvironment(
            account: backendProxyURLStorage,
            environmentKey: "MATCH_POINT_BACKEND_PROXY_URL",
            allowedSchemes: ["https"],
            debugLocalhostSchemes: ["http"]
        )
    }

    static var backendWebSocketBaseURL: URL? {
        urlFromKeychainOrEnvironment(
            account: backendWebSocketURLStorage,
            environmentKey: "MATCH_POINT_BACKEND_WEBSOCKET_URL",
            allowedSchemes: ["wss"],
            debugLocalhostSchemes: ["ws"]
        )
    }

    static func setBackendProxyURL(_ value: String) {
        writeBackendURL(value, account: backendProxyURLStorage)
    }

    static func setBackendWebSocketURL(_ value: String) {
        writeBackendURL(value, account: backendWebSocketURLStorage)
    }

    private static func writeBackendURL(_ value: String, account: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            keychain.delete(account: account)
        } else {
            keychain.write(trimmed, account: account)
        }
        // Defensive: drop any stale plaintext copy from earlier builds that
        // persisted these URLs in UserDefaults.
        providerDefaults.removeObject(forKey: account)
    }

    static var selectedProviderDisplayName: String {
        selectedProvider.displayName
    }

    static var apiRequestTimeout: TimeInterval {
        let environment = ProcessInfo.processInfo.environment
        if let raw = environment["MATCH_POINT_API_TIMEOUT_SECONDS"],
           let value = TimeInterval(raw),
           value > 0 {
            return value
        }
        let stored = providerDefaults.double(forKey: "match_point_api_timeout_seconds")
        return stored > 0 ? stored : 15
    }

    static func setAPIRequestTimeout(_ value: TimeInterval) {
        providerDefaults.set(max(1, value), forKey: "match_point_api_timeout_seconds")
    }

    static func makeProviderURLSession(for provider: Provider = selectedProvider) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = apiRequestTimeout
        configuration.timeoutIntervalForResource = max(apiRequestTimeout * 2, 30)
        configuration.waitsForConnectivity = true
        configuration.httpAdditionalHeaders = [
            "Accept": "application/json",
            "User-Agent": "MatchPoint/\(provider.rawValue)"
        ]
        return URLSession(configuration: configuration)
    }

    static func providerReadiness(for provider: Provider) -> ProviderReadiness {
        let proxyURL = backendProxyBaseURL
        return ProviderReadiness(
            provider: provider,
            hasBackendProxy: proxyURL != nil,
            usesBackendProxy: usesBackendProxy,
            notes: "O app usa apenas backend proxy; a chave da API Tennis fica no servidor."
        )
    }

    nonisolated static func validatedBackendProxyURL(_ raw: String) -> URL? {
        validatedBackendURL(raw, allowedSchemes: ["https"], debugLocalhostSchemes: ["http"])
    }

    nonisolated static func validatedBackendWebSocketURL(_ raw: String) -> URL? {
        validatedBackendURL(raw, allowedSchemes: ["wss"], debugLocalhostSchemes: ["ws"])
    }

    private static func urlFromKeychainOrEnvironment(
        account: String,
        environmentKey: String,
        allowedSchemes: Set<String>,
        debugLocalhostSchemes: Set<String>
    ) -> URL? {
        if let secret = keychain.read(account: account)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !secret.isEmpty {
            return validatedBackendURL(secret, allowedSchemes: allowedSchemes, debugLocalhostSchemes: debugLocalhostSchemes)
        }

        // One-time migration: older builds wrote these URLs to UserDefaults in
        // plaintext. Promote into Keychain on first read and wipe the legacy copy.
        let legacy = providerDefaults.string(forKey: account)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !legacy.isEmpty {
            keychain.write(legacy, account: account)
            providerDefaults.removeObject(forKey: account)
            return validatedBackendURL(legacy, allowedSchemes: allowedSchemes, debugLocalhostSchemes: debugLocalhostSchemes)
        }

        let environment = ProcessInfo.processInfo.environment
        let value = environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : validatedBackendURL(value, allowedSchemes: allowedSchemes, debugLocalhostSchemes: debugLocalhostSchemes)
    }

    private nonisolated static func validatedBackendURL(
        _ raw: String,
        allowedSchemes: Set<String>,
        debugLocalhostSchemes: Set<String>
    ) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(),
              !host.isEmpty else {
            return nil
        }

        if allowedSchemes.contains(scheme) {
            return url
        }

        #if DEBUG
        let localhostHosts: Set<String> = ["localhost", "127.0.0.1", "::1"]
        if debugLocalhostSchemes.contains(scheme), localhostHosts.contains(host) {
            return url
        }
        #endif

        return nil
    }

}
