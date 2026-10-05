import Foundation
import Combine
import OSLog
import SwiftData
import UserNotifications

#if canImport(UIKit)
import UIKit
#if canImport(CarPlay)
import CarPlay
#endif

@MainActor
final class RemotePushManager: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate, ObservableObject {
    private enum DefaultsKey {
        // Legacy plaintext URL location. Kept only so we can read+migrate then wipe.
        static let backendEndpointURL = "match-point.remote-push.backend-endpoint-url"
        static let backendSyncEnabled = "match-point.remote-push.backend-sync-enabled"
    }

    private enum KeychainAccount {
        static let backendEndpointURL = "remote-push.backend-endpoint-url"
    }

    private enum SubscriptionPayloadError: LocalizedError {
        case localFavoritesUnavailable

        var errorDescription: String? {
            "Não foi possível ler favoritos locais para sincronizar push remoto."
        }
    }

    private static let keychain = KeychainSecretStore(service: "com.matchpoint.remote-push")

    enum RegistrationState: Equatable {
        case idle
        case registering
        case registered
        case failed(String)

        var label: String {
            switch self {
            case .idle:
                return "Idle"
            case .registering:
                return "Registrando"
            case .registered:
                return "Registrado"
            case .failed(let message):
                return message
            }
        }
    }

    enum BackendSyncState: Equatable {
        case idle
        case disabled
        case syncing
        case synced(Date)
        case failed(String)

        var label: String {
            switch self {
            case .idle:
                return "Não sincronizado"
            case .disabled:
                return "Desativado"
            case .syncing:
                return "Enviando"
            case .synced(let date):
                return "Enviado \(date.formatted(date: .omitted, time: .shortened))"
            case .failed(let message):
                return message
            }
        }
    }

    @Published private(set) var registrationState: RegistrationState = .idle
    @Published private(set) var backendSyncState: BackendSyncState = .idle
    @Published private(set) var deviceToken: String = ""
    @Published private(set) var isRegisteredForRemoteNotifications = false
    @Published private(set) var backendSyncEnabled: Bool
    @Published private(set) var backendEndpointURL: String

    private let defaults: UserDefaults
    private let session: URLSession

    override convenience init() {
        self.init(defaults: .standard, session: .shared)
    }

    init(defaults: UserDefaults, session: URLSession) {
        let enabled = defaults.bool(forKey: DefaultsKey.backendSyncEnabled)
        self.defaults = defaults
        self.session = session
        self.backendSyncEnabled = enabled
        // Prefer the Keychain copy; if absent, fall back to the legacy
        // plaintext UserDefaults value and migrate it into the Keychain so the
        // next launch reads from the secure store only.
        if let secret = Self.keychain.read(account: KeychainAccount.backendEndpointURL), !secret.isEmpty {
            self.backendEndpointURL = secret
        } else if let legacy = defaults.string(forKey: DefaultsKey.backendEndpointURL), !legacy.isEmpty {
            self.backendEndpointURL = legacy
            let wrote = Self.keychain.write(legacy, account: KeychainAccount.backendEndpointURL)
            // Only clear the plaintext copy after confirming Keychain accepted it.
            if wrote { defaults.removeObject(forKey: DefaultsKey.backendEndpointURL) }
        } else {
            self.backendEndpointURL = ""
        }
        self.backendSyncState = enabled ? .idle : .disabled
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func refreshSystemState() {
        isRegisteredForRemoteNotifications = UIApplication.shared.isRegisteredForRemoteNotifications
    }

    func registerForRemoteNotifications() {
        registrationState = .registering
        UIApplication.shared.registerForRemoteNotifications()
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        self.deviceToken = deviceToken.map { String(format: "%02x", $0) }.joined()
        isRegisteredForRemoteNotifications = true
        registrationState = .registered
        Task {
            await syncDeviceTokenWithBackend(reason: "apns-token-registered")
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        isRegisteredForRemoteNotifications = false
        registrationState = .failed(error.localizedDescription)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        if let url = Self.deepLinkURL(from: response.notification.request) {
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .openDeepLink,
                    object: nil,
                    userInfo: ["url": url]
                )
            }
        }
        ProductAnalyticsStore.shared.record(
            ProductAnalyticsEventName.appOpenedFromAlert,
            properties: Self.analyticsProperties(from: response.notification.request)
        )
        ProductAnalyticsStore.shared.record(
            ProductAnalyticsEventName.matchOpenedFromPush,
            properties: Self.analyticsProperties(from: response.notification.request)
        )
    }

    func updateBackendEndpointURL(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        backendEndpointURL = trimmed
        if trimmed.isEmpty {
            Self.keychain.delete(account: KeychainAccount.backendEndpointURL)
        } else {
            Self.keychain.write(trimmed, account: KeychainAccount.backendEndpointURL)
        }
        // Defensive: clear any plaintext copy from older builds.
        defaults.removeObject(forKey: DefaultsKey.backendEndpointURL)
        if backendSyncEnabled {
            Task {
                await syncDeviceTokenWithBackend(reason: "backend-url-updated")
            }
        }
    }

    func setBackendSyncEnabled(_ enabled: Bool) {
        backendSyncEnabled = enabled
        defaults.set(enabled, forKey: DefaultsKey.backendSyncEnabled)

        if enabled {
            backendSyncState = .idle
            if deviceToken.isEmpty {
                registerForRemoteNotifications()
            } else {
                Task {
                    await syncDeviceTokenWithBackend(reason: "user-enabled")
                }
            }
        } else {
            Task {
                await unregisterDeviceTokenFromBackend()
            }
        }
    }

    func syncDeviceTokenWithBackend(reason: String = "manual") async {
        guard backendSyncEnabled else {
            backendSyncState = .disabled
            return
        }
        guard !deviceToken.isEmpty else {
            backendSyncState = .failed("Token APNs indisponível")
            return
        }
        guard let url = Self.validatedBackendURL(backendEndpointURL) else {
            backendSyncState = .failed("Alertas remotos indisponíveis")
            return
        }

        backendSyncState = .syncing
        do {
            try await sendTokenPayload(to: url, action: "register", reason: reason, subscription: nil)
            backendSyncState = .synced(.now)
        } catch {
            backendSyncState = .failed(AppLogger.message(for: error))
            AppLogger.notifications.error("Remote push backend sync failed: \(AppLogger.message(for: error), privacy: .private)")
            AppLogger.recordFailure(category: "remotePush", operation: "syncDeviceTokenWithBackend", error: error)
        }
    }

    private func unregisterDeviceTokenFromBackend() async {
        guard !deviceToken.isEmpty, let url = Self.validatedBackendURL(backendEndpointURL) else {
            backendSyncState = .disabled
            return
        }

        backendSyncState = .syncing
        do {
            try await sendTokenPayload(to: url, action: "unregister", reason: "user-disabled", subscription: nil)
            backendSyncState = .disabled
        } catch {
            backendSyncState = .failed(AppLogger.message(for: error))
            AppLogger.notifications.error("Remote push backend unregister failed: \(AppLogger.message(for: error), privacy: .private)")
            AppLogger.recordFailure(category: "remotePush", operation: "unregisterDeviceTokenFromBackend", error: error)
        }
    }

    /// Accepts only well-formed HTTPS URLs with a host; rejects http, file, data, etc.
    /// The device token must never leave the device over an untrusted channel.
    nonisolated static func validatedBackendURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty,
              // Reject loopback hosts — device tokens must not be sent to local servers.
              !["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased())
        else {
            return nil
        }
        return url
    }

    private static func analyticsProperties(from request: UNNotificationRequest) -> [String: String] {
        var properties: [String: String] = ["notificationID": request.identifier]
        if let level = request.content.userInfo["matchPointNotificationLevel"] as? String {
            properties["level"] = level
        }
        if request.identifier.contains("upcoming") {
            properties["source"] = "upcoming"
        } else if request.identifier.contains("event") {
            properties["source"] = "event"
        } else {
            properties["source"] = "remote"
        }
        if let deepLink = deepLinkURL(from: request)?.absoluteString {
            properties["deeplink"] = deepLink
        }
        return properties
    }

    private static func deepLinkURL(from request: UNNotificationRequest) -> URL? {
        let userInfo = request.content.userInfo
        let raw = userInfo["matchPointDeepLink"] as? String
            ?? userInfo["deeplink"] as? String
            ?? userInfo["url"] as? String
        guard let raw,
              let url = URL(string: raw),
              url.scheme == "matchpoint" else {
            return nil
        }
        return url
    }

    func syncNotificationSubscriptions(in context: ModelContext, reason: String = "subscription-sync") async {
        await syncNotificationSubscriptions(
            in: context,
            preferences: AlertPreferencesStore.shared.preferences,
            reason: reason
        )
    }

    func syncNotificationSubscriptions(
        in context: ModelContext,
        preferences: AlertPreferences,
        reason: String = "subscription-sync"
    ) async {
        guard backendSyncEnabled else {
            backendSyncState = .disabled
            return
        }
        guard !deviceToken.isEmpty else {
            backendSyncState = .failed("Token APNs indisponível")
            return
        }
        guard let url = Self.validatedBackendURL(backendEndpointURL) else {
            backendSyncState = .failed("Alertas remotos indisponíveis")
            return
        }

        do {
            let subscription = try Self.makeSubscriptionPayload(in: context, preferences: preferences)
            backendSyncState = .syncing
            try await sendTokenPayload(to: url, action: "register", reason: reason, subscription: subscription)
            backendSyncState = .synced(.now)
        } catch {
            backendSyncState = .failed(AppLogger.message(for: error))
            AppLogger.notifications.error("Remote push subscription sync failed: \(AppLogger.message(for: error), privacy: .private)")
            AppLogger.recordFailure(category: "remotePush", operation: "syncNotificationSubscriptions", error: error)
        }
    }

    private func sendTokenPayload(
        to url: URL,
        action: String,
        reason: String,
        subscription: RemotePushSubscriptionPayload?
    ) async throws {
        let request = try Self.makeTokenRequest(
            to: url,
            action: action,
            reason: reason,
            deviceToken: deviceToken,
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "",
            environment: Self.apnsEnvironment,
            registeredForRemoteNotifications: isRegisteredForRemoteNotifications,
            subscription: subscription
        )

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIHTTPError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? -1, body: "")
        }
    }

    @MainActor
    static func makeSubscriptionPayload(in context: ModelContext, preferences: AlertPreferences) throws -> RemotePushSubscriptionPayload {
        let players = try fetchLocalFavorites(FetchDescriptor<Player>(), in: context, modelName: "Player")
        let matches = try fetchLocalFavorites(FetchDescriptor<TennisMatch>(), in: context, modelName: "TennisMatch")
        let tournaments = try fetchLocalFavorites(FetchDescriptor<Tournament>(), in: context, modelName: "Tournament")

        let favoritePlayers = players
            .filter(\.isFavorite)
            .compactMap { favorite(id: $0.externalKey, fallback: $0.id.uuidString, name: $0.name, kind: .player) }

        let favoriteMatches = matches
            .filter(\.isFavorite)
            .compactMap { favorite(id: $0.externalID, fallback: $0.id.uuidString, name: matchTitle($0), kind: .match) }

        let favoriteTournaments = tournaments
            .filter(\.isFavorite)
            .compactMap { favorite(id: $0.externalKey, fallback: $0.id.uuidString, name: $0.name, kind: .tournament) }

        return RemotePushSubscriptionPayload(
            preferences: .init(from: preferences),
            favorites: .init(
                players: favoritePlayers,
                matches: favoriteMatches,
                tournaments: favoriteTournaments
            ),
            eventRules: RemotePushEventRule.defaults(for: preferences),
            backendDataPlane: .continuousTennisIngestion
        )
    }

    nonisolated static func makeTokenRequest(
        to url: URL,
        action: String,
        reason: String,
        deviceToken: String,
        bundleIdentifier: String,
        environment: String,
        registeredForRemoteNotifications: Bool,
        subscription: RemotePushSubscriptionPayload? = nil
    ) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let payload = RemotePushTokenPayload(
            action: action,
            reason: reason,
            deviceToken: deviceToken,
            platform: "ios",
            bundleIdentifier: bundleIdentifier,
            environment: environment,
            registeredForRemoteNotifications: registeredForRemoteNotifications,
            subscription: subscription
        )
        request.httpBody = try JSONEncoder().encode(payload)
        return request
    }

    private static var apnsEnvironment: String {
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }

}

nonisolated struct RemotePushTokenPayload: Codable, Equatable {
    var action: String
    var reason: String
    var deviceToken: String
    var platform: String
    var bundleIdentifier: String
    var environment: String
    var registeredForRemoteNotifications: Bool
    var subscription: RemotePushSubscriptionPayload?
}

nonisolated struct RemotePushSubscriptionPayload: Codable, Equatable {
    nonisolated struct Preferences: Codable, Equatable {
        var notificationsEnabled: Bool
        var leadTimeMinutes: Int
        var followFavoriteMatches: Bool
        var followFavoritePlayers: Bool
        var followFavoriteTournaments: Bool

        init(from preferences: AlertPreferences) {
            self.notificationsEnabled = preferences.notificationsEnabled
            self.leadTimeMinutes = preferences.leadTimeMinutes
            self.followFavoriteMatches = preferences.followFavoriteMatches
            self.followFavoritePlayers = preferences.followFavoritePlayers
            self.followFavoriteTournaments = preferences.followFavoriteTournaments
        }
    }

    nonisolated struct Favorites: Codable, Equatable {
        var players: [RemotePushFavorite]
        var matches: [RemotePushFavorite]
        var tournaments: [RemotePushFavorite]
    }

    var schemaVersion: Int = 1
    var preferences: Preferences
    var favorites: Favorites
    var eventRules: [RemotePushEventRule]
    var backendDataPlane: BackendDataPlaneContract = .continuousTennisIngestion
}

nonisolated struct RemotePushFavorite: Codable, Equatable {
    nonisolated enum Kind: String, Codable {
        case player
        case match
        case tournament
    }

    var id: String
    var name: String
    var kind: Kind
}

nonisolated struct RemotePushEventRule: Codable, Equatable {
    nonisolated enum Event: String, Codable {
        case upcoming = "match.upcoming"
        case walkOn = "match.walk-on"
        case started = "match.started"
        case finished = "match.finished"
        case breakServe = "match.break-serve"
        case finalSetBreakServe = "match.break-serve.final-set"
        case setPoint = "match.set-point"
        case matchPoint = "match.match-point"
        case tiebreak = "match.tiebreak"
        case delayed = "match.delayed"
        case interrupted = "match.interrupted"
        case courtChanged = "match.court-changed"
    }

    var event: Event
    var level: MatchNotificationLevel
    var enabled: Bool
    var minimumFavoriteScope: String

    static func defaults(for preferences: AlertPreferences) -> [RemotePushEventRule] {
        [
            .init(event: .upcoming, level: .silentWidget, enabled: preferences.notifyBeforeMatch, minimumFavoriteScope: "match-or-player-or-tournament"),
            .init(event: .walkOn, level: .importantBanner, enabled: preferences.notifyMatchWalkOn, minimumFavoriteScope: "match-or-player-or-tournament"),
            .init(event: .started, level: .silentWidget, enabled: preferences.notifyMatchStarted, minimumFavoriteScope: "match-or-player-or-tournament"),
            .init(event: .finished, level: .importantBanner, enabled: preferences.notifyMatchFinished, minimumFavoriteScope: "match-or-player-or-tournament"),
            .init(event: .breakServe, level: .importantBanner, enabled: true, minimumFavoriteScope: "match-or-player"),
            .init(event: .finalSetBreakServe, level: .urgent, enabled: true, minimumFavoriteScope: "match-or-player"),
            .init(event: .setPoint, level: .importantBanner, enabled: true, minimumFavoriteScope: "match-or-player"),
            .init(event: .matchPoint, level: .urgent, enabled: true, minimumFavoriteScope: "match-or-player"),
            .init(event: .tiebreak, level: .importantBanner, enabled: true, minimumFavoriteScope: "match-or-player"),
            .init(event: .delayed, level: .importantBanner, enabled: true, minimumFavoriteScope: "match-or-player-or-tournament"),
            .init(event: .interrupted, level: .importantBanner, enabled: true, minimumFavoriteScope: "match-or-player-or-tournament"),
            .init(event: .courtChanged, level: .silentWidget, enabled: true, minimumFavoriteScope: "match-or-player-or-tournament")
        ]
    }
}

private extension RemotePushManager {
    @MainActor
    static func fetchLocalFavorites<Model: PersistentModel>(
        _ descriptor: FetchDescriptor<Model>,
        in context: ModelContext,
        modelName: String
    ) throws -> [Model] {
        do {
            return try context.fetch(descriptor)
        } catch {
            AppLogger.persistence.error("Remote push favorite fetch failed for \(modelName, privacy: .public): \(AppLogger.message(for: error), privacy: .private)")
            AppLogger.recordFailure(category: "remotePush", operation: "makeSubscriptionPayload.fetch.\(modelName)", error: error)
            throw SubscriptionPayloadError.localFavoritesUnavailable
        }
    }

    static func favorite(id: String?, fallback: String, name: String, kind: RemotePushFavorite.Kind) -> RemotePushFavorite? {
        let candidate: String
        if let id, !id.isEmpty {
            candidate = id
        } else {
            candidate = fallback
        }
        let resolvedID = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolvedID.isEmpty else { return nil }
        return RemotePushFavorite(id: resolvedID, name: name, kind: kind)
    }

    static func matchTitle(_ match: TennisMatch) -> String {
        "\(match.player1?.name ?? "TBD") vs \(match.player2?.name ?? "TBD")"
    }
}

#else

@MainActor
final class RemotePushManager: ObservableObject {
    enum BackendSyncState: Equatable {
        case idle
        case disabled
        case syncing
        case synced(Date)
        case failed(String)

        var label: String {
            switch self {
            case .idle:
                return "Unavailable"
            case .disabled:
                return "Unavailable"
            case .syncing:
                return "Unavailable"
            case .synced:
                return "Unavailable"
            case .failed(let message):
                return message
            }
        }
    }

    enum RegistrationState: Equatable {
        case idle
        case registering
        case registered
        case failed(String)

        var label: String {
            switch self {
            case .idle:
                return "Unavailable"
            case .registering:
                return "Registrando"
            case .registered:
                return "Registrado"
            case .failed(let message):
                return message
            }
        }
    }

    @Published private(set) var registrationState: RegistrationState = .idle
    @Published private(set) var backendSyncState: BackendSyncState = .disabled
    @Published private(set) var deviceToken: String = ""
    @Published private(set) var isRegisteredForRemoteNotifications = false
    @Published private(set) var backendSyncEnabled = false
    @Published private(set) var backendEndpointURL = ""

    func refreshSystemState() {}
    func registerForRemoteNotifications() {}
    func updateBackendEndpointURL(_ value: String) {}
    func setBackendSyncEnabled(_ enabled: Bool) {}
    func syncDeviceTokenWithBackend(reason: String = "manual") async {}
}

#endif
