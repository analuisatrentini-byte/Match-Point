import Foundation

struct AccountAuthSession: Decodable {
    struct User: Decodable {
        let id: String
        let provider: String
        let email: String
        let username: String
        let displayName: String
        let externalKey: String
    }

    let token: String
    let expiresAt: String
    let user: User
}

struct AccountAuthService {
    private enum DefaultsKey {
        static let backendURL = "match-point.social.moderation-backend-url"
        static let sessionToken = "match-point.account.session-token"
        static let sessionExpiresAt = "match-point.account.session-expires-at"
    }

    private struct Envelope: Decodable {
        let ok: Bool
        let result: AccountAuthSession
    }

    private struct RecoveryEnvelope: Decodable {
        struct RecoveryResult: Decodable {
            let message: String?
        }
        let ok: Bool
        let result: RecoveryResult
    }

    private struct DeletionEnvelope: Decodable {
        struct DeletionResult: Decodable {
            let deleted: Bool
            let provider: String?
            let appleTokenRevoked: Bool?
        }
        let ok: Bool
        let result: DeletionResult
    }

    private let urlSession: URLSession

    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    static var isBackendConfigured: Bool {
        baseURL() != nil
    }

    func signInWithApple(appleUserID: String, email: String?, displayName: String, authorizationCode: String?) async throws -> AccountAuthSession {
        try await postSession(
            path: "/auth/apple",
            payload: [
                "appleUserID": appleUserID,
                "email": email ?? "",
                "displayName": displayName,
                "authorizationCode": authorizationCode ?? ""
            ]
        )
    }

    func signUpWithEmail(email: String, username: String, password: String) async throws -> AccountAuthSession {
        try await postSession(
            path: "/auth/email/signup",
            payload: [
                "email": email,
                "username": username,
                "password": password,
                "displayName": username
            ]
        )
    }

    func loginWithEmail(identifier: String, password: String) async throws -> AccountAuthSession {
        try await postSession(
            path: "/auth/email/login",
            payload: [
                "identifier": identifier,
                "password": password
            ]
        )
    }

    func requestRecovery(identifier: String) async throws -> String {
        guard let url = Self.endpoint(path: "/auth/email/recovery/request") else {
            throw AuthServiceError.backendNotConfigured
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["identifier": identifier])
        let (data, response) = try await urlSession.data(for: request)
        try Self.validate(response: response, data: data)
        let envelope = try JSONDecoder().decode(RecoveryEnvelope.self, from: data)
        return envelope.result.message ?? "Se a conta existir, enviaremos um código de recuperação."
    }

    func resetPassword(identifier: String, code: String, newPassword: String) async throws -> AccountAuthSession {
        try await postSession(
            path: "/auth/email/recovery/reset",
            payload: [
                "identifier": identifier,
                "code": code,
                "newPassword": newPassword
            ]
        )
    }

    func deleteRemoteAccountIfAuthenticated() async throws -> Bool {
        guard let token = Self.sessionToken else { return false }
        guard let url = Self.endpoint(path: "/auth/delete") else {
            throw AuthServiceError.backendNotConfigured
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        request.httpBody = Data("{}".utf8)
        let (data, response) = try await urlSession.data(for: request)
        try Self.validate(response: response, data: data)
        _ = try JSONDecoder().decode(DeletionEnvelope.self, from: data)
        Self.clearSession()
        return true
    }

    private func postSession(path: String, payload: [String: String]) async throws -> AccountAuthSession {
        guard let url = Self.endpoint(path: path) else {
            throw AuthServiceError.backendNotConfigured
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await urlSession.data(for: request)
        try Self.validate(response: response, data: data)
        let session = try JSONDecoder().decode(Envelope.self, from: data).result
        Self.saveSession(session)
        return session
    }

    private static func endpoint(path: String) -> URL? {
        guard let baseURL = baseURL() else { return nil }
        return baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }

    private static func baseURL() -> URL? {
        let raw = UserDefaults.standard.string(forKey: DefaultsKey.backendURL)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard var components = URLComponents(string: raw), components.scheme == "https", components.host?.isEmpty == false else {
            return nil
        }
        components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return components.url
    }

    private static func saveSession(_ session: AccountAuthSession) {
        let defaults = UserDefaults.standard
        defaults.set(session.token, forKey: DefaultsKey.sessionToken)
        defaults.set(session.expiresAt, forKey: DefaultsKey.sessionExpiresAt)
    }

    static var sessionToken: String? {
        UserDefaults.standard.string(forKey: DefaultsKey.sessionToken)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    static func clearSession() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: DefaultsKey.sessionToken)
        defaults.removeObject(forKey: DefaultsKey.sessionExpiresAt)
    }

    private static func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw AuthServiceError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw AuthServiceError.server(message ?? "Falha de autenticação.")
        }
    }
}

enum AuthServiceError: LocalizedError {
    case backendNotConfigured
    case invalidResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .backendNotConfigured:
            return "Serviço de conta indisponível no momento."
        case .invalidResponse:
            return "Resposta inválida do servidor."
        case .server(let message):
            return message
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
