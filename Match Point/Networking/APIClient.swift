//
//  APIClient.swift
//  Match Point
//
//  Created by Ana Luisa Bittencourt on 26/03/26.
//

import Foundation

struct APIError: Error, LocalizedError, UserPresentableError {
    let message: String
    var errorDescription: String? { message }

    var userFacing: UserFacingSyncFeedback {
        // Treat missing credentials/service as a configuration problem internally,
        // but keep the user-facing copy product-level.
        let normalized = message.lowercased()
        if normalized.contains("api key") || normalized.contains("missing api") || normalized.contains("backend proxy") {
            return UserFacingSyncFeedback(
                kind: .configuration,
                title: "Sincronização indisponível",
                message: "O serviço de dados do Match Point não está disponível no momento.",
                recoverySuggestion: "Tente novamente em instantes."
            )
        }
        return UserFacingSyncFeedback(
            kind: .generic,
            title: "Falha de sincronização",
            message: message,
            recoverySuggestion: "Tente novamente em instantes."
        )
    }
}

struct APIHTTPError: Error, LocalizedError, UserPresentableError {
    let statusCode: Int
    let body: String

    var errorDescription: String? {
        let cleanBody = body
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleanBody.isEmpty ? "HTTP \(statusCode)" : "HTTP \(statusCode): \(String(cleanBody.prefix(120)))"
    }

    var shouldRetry: Bool {
        statusCode == 500 || statusCode == 502 || statusCode == 503 || statusCode == 504
    }

    var userFacing: UserFacingSyncFeedback {
        switch statusCode {
        case 401, 403:
            return UserFacingSyncFeedback(
                kind: .configuration,
                title: "Acesso negado",
                message: "O serviço recusou a requisição (HTTP \(statusCode)).",
                recoverySuggestion: "Tente novamente em instantes."
            )
        case 429:
            return UserFacingSyncFeedback(
                kind: .rateLimited,
                title: "Muitas tentativas",
                message: "Plano ou quota atingida (HTTP 429).",
                recoverySuggestion: "Aguarde alguns minutos antes de tentar novamente."
            )
        case 500...599:
            return UserFacingSyncFeedback(
                kind: .generic,
                title: "Serviço instável",
                message: errorDescription ?? "HTTP \(statusCode)",
                recoverySuggestion: "Tente de novo em instantes."
            )
        default:
            return UserFacingSyncFeedback(
                kind: .generic,
                title: "Falha HTTP",
                message: errorDescription ?? "HTTP \(statusCode)",
                recoverySuggestion: "Tente novamente em instantes."
            )
        }
    }
}

struct APIClient {
    /// Closure resolved on every request so a runtime config change (e.g. user
    /// pasting a new backend proxy URL in Diagnostics) takes effect on the
    /// next call instead of being captured at construction time and silently
    /// stuck for the lifetime of any cached `DataSyncService` instance.
    var baseURLProvider: () -> URL
    var session: URLSession = .shared

    /// Convenience for tests / call sites that want a hard-coded URL.
    init(baseURL: URL, session: URLSession = .shared) {
        self.baseURLProvider = { baseURL }
        self.session = session
    }

    init(baseURLProvider: @escaping () -> URL, session: URLSession = .shared) {
        self.baseURLProvider = baseURLProvider
        self.session = session
    }

    func get<T: Decodable>(
        path: String? = nil,
        query: [String: String] = [:],
        headers: [String: String] = [:],
        as type: T.Type = T.self
    ) async throws -> T {
        let baseURL = baseURLProvider()
        let targetURL: URL
        if let path, !path.isEmpty {
            targetURL = baseURL.appending(path: path)
        } else {
            targetURL = baseURL
        }

        guard var comps = URLComponents(url: targetURL, resolvingAgainstBaseURL: false) else {
            throw APIError(message: "Invalid URL components")
        }
        if !query.isEmpty {
            comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = comps.url else { throw APIError(message: "Invalid URL") }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        headers.forEach { req.setValue($0.value, forHTTPHeaderField: $0.key) }

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<no body>"
            throw APIHTTPError(statusCode: (resp as? HTTPURLResponse)?.statusCode ?? -1, body: body)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
    }
}
