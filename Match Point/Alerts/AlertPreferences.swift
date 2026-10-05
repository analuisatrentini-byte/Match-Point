import Combine
import Foundation
import OSLog
import UserNotifications

nonisolated struct AlertPreferences: Codable, Equatable {
    var notificationsEnabled: Bool = false
    var notifyBeforeMatch: Bool = true
    var notifyMatchStarted: Bool = true
    var notifyMatchFinished: Bool = true
    /// Fires when the live feed reports the players are warming up / on court —
    /// the "your player walked on court, first ball in ~N min" alert. Distinct
    /// from `notifyMatchStarted` (which waits for `isLive = true`).
    var notifyMatchWalkOn: Bool = true
    var followFavoriteMatches: Bool = true
    var followFavoritePlayers: Bool = true
    var followFavoriteTournaments: Bool = true
    var leadTimeMinutes: Int = 15

    init(
        notificationsEnabled: Bool = false,
        notifyBeforeMatch: Bool = true,
        notifyMatchStarted: Bool = true,
        notifyMatchFinished: Bool = true,
        notifyMatchWalkOn: Bool = true,
        followFavoriteMatches: Bool = true,
        followFavoritePlayers: Bool = true,
        followFavoriteTournaments: Bool = true,
        leadTimeMinutes: Int = 15
    ) {
        self.notificationsEnabled = notificationsEnabled
        self.notifyBeforeMatch = notifyBeforeMatch
        self.notifyMatchStarted = notifyMatchStarted
        self.notifyMatchFinished = notifyMatchFinished
        self.notifyMatchWalkOn = notifyMatchWalkOn
        self.followFavoriteMatches = followFavoriteMatches
        self.followFavoritePlayers = followFavoritePlayers
        self.followFavoriteTournaments = followFavoriteTournaments
        self.leadTimeMinutes = leadTimeMinutes
    }

    private enum CodingKeys: String, CodingKey {
        case notificationsEnabled, notifyBeforeMatch, notifyMatchStarted, notifyMatchFinished, notifyMatchWalkOn
        case followFavoriteMatches, followFavoritePlayers, followFavoriteTournaments
        case leadTimeMinutes
    }

    // Custom decoder so existing users — whose persisted JSON lacks `notifyMatchWalkOn` —
    // upgrade without losing other preferences (default decoder would fail on the
    // missing key and reset everything).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        notificationsEnabled = try container.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? false
        notifyBeforeMatch = try container.decodeIfPresent(Bool.self, forKey: .notifyBeforeMatch) ?? true
        notifyMatchStarted = try container.decodeIfPresent(Bool.self, forKey: .notifyMatchStarted) ?? true
        notifyMatchFinished = try container.decodeIfPresent(Bool.self, forKey: .notifyMatchFinished) ?? true
        notifyMatchWalkOn = try container.decodeIfPresent(Bool.self, forKey: .notifyMatchWalkOn) ?? true
        followFavoriteMatches = try container.decodeIfPresent(Bool.self, forKey: .followFavoriteMatches) ?? true
        followFavoritePlayers = try container.decodeIfPresent(Bool.self, forKey: .followFavoritePlayers) ?? true
        followFavoriteTournaments = try container.decodeIfPresent(Bool.self, forKey: .followFavoriteTournaments) ?? true
        leadTimeMinutes = try container.decodeIfPresent(Int.self, forKey: .leadTimeMinutes) ?? 15
    }
}

@MainActor
final class AlertPreferencesStore: ObservableObject {
    static let shared = AlertPreferencesStore()

    @Published private(set) var preferences: AlertPreferences
    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    private let defaults: UserDefaults
    private let preferencesKey = "match-point.alert-preferences"

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if let data = defaults.data(forKey: preferencesKey) {
            do {
                self.preferences = try JSONDecoder().decode(AlertPreferences.self, from: data)
            } catch {
                AppLogger.notifications.error("Failed to decode AlertPreferences; using defaults: \(AppLogger.message(for: error), privacy: .private)")
                AppLogger.recordFailure(category: "preferences", operation: "AlertPreferences.decode", error: error)
                self.preferences = AlertPreferences()
            }
        } else {
            self.preferences = AlertPreferences()
        }
    }

    func refreshAuthorizationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorizationStatus = settings.authorizationStatus

        if settings.authorizationStatus != .authorized, preferences.notificationsEnabled {
            update {
                $0.notificationsEnabled = false
            }
        }
    }

    func requestAuthorization() async -> Bool {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
            await refreshAuthorizationStatus()

            if granted {
                update {
                    $0.notificationsEnabled = true
                }
            }

            return granted
        } catch {
            await refreshAuthorizationStatus()
            return false
        }
    }

    func update(_ mutate: (inout AlertPreferences) -> Void) {
        var updated = preferences
        mutate(&updated)
        preferences = updated

        do {
            let encoded = try JSONEncoder().encode(updated)
            defaults.set(encoded, forKey: preferencesKey)
        } catch {
            AppLogger.notifications.error("Failed to persist AlertPreferences: \(AppLogger.message(for: error), privacy: .private)")
            AppLogger.recordFailure(category: "preferences", operation: "AlertPreferences.encode", error: error)
        }
    }

    func setAuthorizationStatusForTesting(_ status: UNAuthorizationStatus) {
        authorizationStatus = status
    }
}
