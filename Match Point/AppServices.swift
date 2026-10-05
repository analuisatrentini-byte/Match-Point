import Foundation
import SwiftData
import SwiftUI

// MARK: - Service protocols
//
// These protocols expose only the APIs actually exercised by callers today.
// Production code keeps using `*.shared` and gets the live singleton via the
// `.live` factory below; tests inject mocks through `.environment(\.appServices, ...)`
// without subclassing the (final) production types.

@MainActor
protocol AlertNotificationsServicing {
    func refreshScheduledNotifications(in context: ModelContext, force: Bool) async
    func snapshotForStoredMatch(_ match: TennisMatch) -> MatchAlertSnapshot?
    func processMatchUpdate(_ match: TennisMatch, previous: MatchAlertSnapshot?) async
}

extension AlertNotificationsServicing {
    // Convenience overload — mirrors the default-argument call sites that still
    // write `refreshScheduledNotifications(in: context)` without specifying force.
    func refreshScheduledNotifications(in context: ModelContext) async {
        await refreshScheduledNotifications(in: context, force: false)
    }
}

@MainActor
protocol LiveActivityServicing {
    func handle(match: TennisMatch, rankings: [RankingEntry])
    func endStaleActivities(keepingKeys liveMatchKeys: Set<String>)
}

@MainActor
protocol WidgetSnapshotServicing {
    func update(match: TennisMatch, rankings: [RankingEntry])
    func replaceLiveMatches(_ matches: [TennisMatch], rankings: [RankingEntry])
    func replaceRelevantMatches(_ matches: [TennisMatch], rankings: [RankingEntry])
    func replaceTopRankingPlayers(_ rankings: [RankingEntry])
}

extension WidgetSnapshotServicing {
    func replaceRelevantMatches(_ matches: [TennisMatch], rankings: [RankingEntry]) {
        replaceLiveMatches(matches.filter(\.isLive), rankings: rankings)
    }

    func replaceTopRankingPlayers(_ rankings: [RankingEntry]) {}
}

extension AlertEventEngine: AlertNotificationsServicing {}
extension LiveActivityController: LiveActivityServicing {}
extension MatchWidgetSnapshotStore: WidgetSnapshotServicing {}

// MARK: - Container

@MainActor
struct AppServices {
    var alerts: any AlertNotificationsServicing
    var liveActivity: any LiveActivityServicing
    var widgetSnapshots: any WidgetSnapshotServicing

    static let live = AppServices(
        alerts: AlertEventEngine.shared,
        liveActivity: LiveActivityController.shared,
        widgetSnapshots: MatchWidgetSnapshotStore.shared
    )
}

// MARK: - Environment plumbing

private struct AppServicesKey: @preconcurrency EnvironmentKey {
    @MainActor static let defaultValue: AppServices = .live
}

extension EnvironmentValues {
    var appServices: AppServices {
        get { self[AppServicesKey.self] }
        set { self[AppServicesKey.self] = newValue }
    }
}

extension URL {
    func queryValue(for name: String) -> String? {
        URLComponents(url: self, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name == name }?
            .value
    }
}

/// Shared rolling-window constants for `@Query` predicates across views.
/// Each value is intentional — changing one here changes all consumers.
enum MatchQueryWindow {
    /// Feed and social views: recent enough to be conversational (30 days).
    static func feed(from now: Date = .now) -> Date {
        Calendar.current.date(byAdding: .day, value: -30, to: now) ?? .distantPast
    }
    /// Match list views: wide enough to include recent completed results (60 days).
    static func matchList(from now: Date = .now) -> Date {
        Calendar.current.date(byAdding: .day, value: -60, to: now) ?? .distantPast
    }
}

extension Notification.Name {
    static let openBetWizard = Notification.Name("match-point.open-bet-wizard")
    /// Fired the moment any entity goes from unfavorited → favorited.
    /// ContentView catches this to show a notification permission prompt in context.
    static let didFirstFavorite = Notification.Name("match-point.did-first-favorite")
    static let didToggleFavorite = Notification.Name("match-point.did-toggle-favorite")

    /// Empty states across the app raise this so ContentView can switch to
    /// the players directory tab in a single tap. Keeps the empty state
    /// button decoupled from ContentView (which owns tab selection state)
    /// without introducing a global router.
    static let navigateToPlayersDirectory = Notification.Name("match-point.navigate-to-players")
    static let openDeepLink = Notification.Name("match-point.open-deep-link")
}
