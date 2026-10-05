import Combine
import Foundation
import OSLog
import SwiftUI

#if canImport(WidgetKit)
import WidgetKit
#endif

nonisolated struct ProductAnalyticsEvent: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    let name: String
    let occurredAt: Date
    let properties: [String: String]

    init(id: UUID = UUID(), name: String, occurredAt: Date = .now, properties: [String: String] = [:]) {
        self.id = id
        self.name = name
        self.occurredAt = occurredAt
        self.properties = properties
    }
}

nonisolated struct ProductAnalyticsSnapshot: Codable, Equatable, Hashable {
    var firstSeenAt: Date
    var lastSeenAt: Date
    var launchDays: Set<String>
    var events: [ProductAnalyticsEvent]
    var counters: [String: Int]

    init(
        firstSeenAt: Date = .now,
        lastSeenAt: Date = .now,
        launchDays: Set<String> = [],
        events: [ProductAnalyticsEvent] = [],
        counters: [String: Int] = [:]
    ) {
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
        self.launchDays = launchDays
        self.events = events
        self.counters = counters
    }

    var signature: Int {
        var hasher = Hasher()
        hasher.combine(firstSeenAt)
        hasher.combine(lastSeenAt)
        hasher.combine(launchDays)
        hasher.combine(events)
        hasher.combine(counters)
        return hasher.finalize()
    }

    var completedOnboarding: Bool { counters[ProductAnalyticsEventName.onboardingCompleted] ?? 0 > 0 }
    var pickedFavoritePlayer: Bool { counters[ProductAnalyticsEventName.favoritePlayerChosen] ?? 0 > 0 }
    var acceptedAlerts: Bool { counters[ProductAnalyticsEventName.alertPermissionAccepted] ?? 0 > 0 }
    var startedLiveActivity: Bool { counters[ProductAnalyticsEventName.liveActivityStarted] ?? 0 > 0 }
    var installedWidget: Bool { counters[ProductAnalyticsEventName.widgetInstalled] ?? 0 > 0 }
    var openedMatchFromPush: Bool { counters[ProductAnalyticsEventName.matchOpenedFromPush] ?? 0 > 0 }
    var openedAppFromWidget: Bool { counters[ProductAnalyticsEventName.appOpenedFromWidget] ?? 0 > 0 }
    var openedAppFromAlert: Bool { counters[ProductAnalyticsEventName.appOpenedFromAlert] ?? 0 > 0 }
    var openedPlayerHome: Bool { counters[ProductAnalyticsEventName.playerHomeViewed] ?? 0 > 0 }
    var sawPlayerStory: Bool { counters[ProductAnalyticsEventName.playerStoryShown] ?? 0 > 0 }
    var openedCalendar: Bool { counters[ProductAnalyticsEventName.favoriteCalendarViewed] ?? 0 > 0 }
    var openedMatchBrain: Bool { counters[ProductAnalyticsEventName.matchBrainViewed] ?? 0 > 0 }
    var retainedD1: Bool { counters[ProductAnalyticsEventName.retentionD1] ?? 0 > 0 }
    var retainedD7: Bool { counters[ProductAnalyticsEventName.retentionD7] ?? 0 > 0 }
    var retainedD30: Bool { counters[ProductAnalyticsEventName.retentionD30] ?? 0 > 0 }

    var sessionCount: Int { counters[ProductAnalyticsEventName.sessionStarted] ?? 0 }
    var widgetReturnCount: Int { counters[ProductAnalyticsEventName.appOpenedFromWidget] ?? 0 }
    var alertReturnCount: Int { counters[ProductAnalyticsEventName.appOpenedFromAlert] ?? 0 }
    var calendarOpenCount: Int { counters[ProductAnalyticsEventName.favoriteCalendarViewed] ?? 0 }
    var calendarMatchOpenCount: Int { counters[ProductAnalyticsEventName.favoriteCalendarMatchOpened] ?? 0 }
    var matchBrainOpenCount: Int { counters[ProductAnalyticsEventName.matchBrainViewed] ?? 0 }
    var matchBrainMatchOpenCount: Int { counters[ProductAnalyticsEventName.matchBrainMatchOpened] ?? 0 }

    var funnelCompletionCount: Int {
        [completedOnboarding, pickedFavoritePlayer, acceptedAlerts, startedLiveActivity, installedWidget, openedMatchFromPush, openedPlayerHome].filter { $0 }.count
    }

    var funnelStepCount: Int { 7 }

    mutating func trim(maxEvents: Int = 160) {
        if events.count > maxEvents {
            events = Array(events.sorted { $0.occurredAt > $1.occurredAt }.prefix(maxEvents))
        }
    }
}

nonisolated enum ProductAnalyticsEventName {
    static let appLaunched = "app_launched"
    static let sessionStarted = "session_started"
    static let onboardingCompleted = "onboarding_completed"
    static let favoritePlayerChosen = "favorite_player_chosen"
    static let favoriteMatchChosen = "favorite_match_chosen"
    static let favoriteTournamentChosen = "favorite_tournament_chosen"
    static let alertPermissionAccepted = "alert_permission_accepted"
    static let alertPermissionDeclined = "alert_permission_declined"
    static let widgetInstalled = "widget_installed"
    static let widgetNotInstalled = "widget_not_installed"
    static let appOpenedFromWidget = "app_opened_from_widget"
    static let appOpenedFromAlert = "app_opened_from_alert"
    static let liveActivityStarted = "live_activity_started"
    static let matchOpened = "match_opened"
    static let matchOpenedFromPush = "match_opened_from_push"
    static let matchOpenedFromPlayerHome = "match_opened_from_player_home"
    static let favoriteCalendarViewed = "favorite_calendar_viewed"
    static let favoriteCalendarCTASelected = "favorite_calendar_cta_selected"
    static let favoriteCalendarMatchOpened = "favorite_calendar_match_opened"
    static let matchBrainViewed = "match_brain_viewed"
    static let matchBrainMatchOpened = "match_brain_match_opened"
    static let playerOpened = "player_opened"
    static let playerHomeViewed = "player_home_viewed"
    static let playerStoryShown = "player_story_shown"
    static let tournamentOpened = "tournament_opened"
    static let retentionD1 = "retention_d1"
    static let retentionD7 = "retention_d7"
    static let retentionD30 = "retention_d30"
}

@MainActor
final class ProductAnalyticsStore: ObservableObject {
    static let shared = ProductAnalyticsStore()

    @Published private(set) var snapshot: ProductAnalyticsSnapshot

    private let defaults: UserDefaults
    private let storageKey: String

    init(defaults: UserDefaults = .standard, storageKey: String = "match-point.product-analytics") {
        self.defaults = defaults
        self.storageKey = storageKey
        self.snapshot = Self.load(from: defaults, key: storageKey)
    }

    func recordAppLaunch(now: Date = .now) {
        record(ProductAnalyticsEventName.appLaunched, now: now)
        let dayKey = Self.dayKey(for: now)
        mutate { draft in
            draft.launchDays.insert(dayKey)
            draft.lastSeenAt = now
        }
        recordRetentionMilestones(now: now)
    }

    /// Record a foreground session distinct from cold launch. `recordAppLaunch`
    /// fires on cold + `scenePhase == .active`, so this method is called from
    /// the same hook — it separates "app launched N times" from "user resumed
    /// N sessions" (they diverge when someone leaves the app open in memory).
    func recordSessionStarted(now: Date = .now) {
        record(ProductAnalyticsEventName.sessionStarted, now: now)
    }

    func record(_ name: String, properties: [String: String] = [:], now: Date = .now) {
        mutate { draft in
            draft.events.append(ProductAnalyticsEvent(name: name, occurredAt: now, properties: properties))
            draft.counters[name, default: 0] += 1
            draft.lastSeenAt = now
            draft.trim()
        }
        AppLogger.product.info("Product analytics event: \(name, privacy: .public)")
    }

    func refreshWidgetInstallState() async {
        #if canImport(WidgetKit)
        guard #available(iOS 14.0, macOS 11.0, *) else { return }
        do {
            let installed = try await currentWidgetConfigurations().isEmpty == false
            record(installed ? ProductAnalyticsEventName.widgetInstalled : ProductAnalyticsEventName.widgetNotInstalled)
        } catch {
            AppLogger.recordFailure(category: "analytics", operation: "widgetConfigurationState", error: error)
        }
        #endif
    }

    func reset() {
        snapshot = ProductAnalyticsSnapshot()
        defaults.removeObject(forKey: storageKey)
    }

    private func recordRetentionMilestones(now: Date) {
        let days = Calendar.current.dateComponents([.day], from: snapshot.firstSeenAt, to: now).day ?? 0
        if days >= 1, snapshot.counters[ProductAnalyticsEventName.retentionD1] == nil {
            record(ProductAnalyticsEventName.retentionD1, now: now)
        }
        if days >= 7, snapshot.counters[ProductAnalyticsEventName.retentionD7] == nil {
            record(ProductAnalyticsEventName.retentionD7, now: now)
        }
        if days >= 30, snapshot.counters[ProductAnalyticsEventName.retentionD30] == nil {
            record(ProductAnalyticsEventName.retentionD30, now: now)
        }
    }

    private func mutate(_ update: (inout ProductAnalyticsSnapshot) -> Void) {
        var draft = snapshot
        update(&draft)
        snapshot = draft
        persist(draft)
    }

    private func persist(_ snapshot: ProductAnalyticsSnapshot) {
        do {
            let data = try JSONEncoder().encode(snapshot)
            defaults.set(data, forKey: storageKey)
        } catch {
            AppLogger.persistence.error("Failed to persist product analytics: \(AppLogger.message(for: error), privacy: .private)")
        }
    }

    private static func load(from defaults: UserDefaults, key: String) -> ProductAnalyticsSnapshot {
        guard let data = defaults.data(forKey: key) else { return ProductAnalyticsSnapshot() }
        do {
            return try JSONDecoder().decode(ProductAnalyticsSnapshot.self, from: data)
        } catch {
            AppLogger.persistence.error("Failed to decode product analytics: \(AppLogger.message(for: error), privacy: .private)")
            return ProductAnalyticsSnapshot()
        }
    }

    private static func dayKey(for date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return "\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0)"
    }

    #if canImport(WidgetKit)
    @available(iOS 14.0, macOS 11.0, *)
    private func currentWidgetConfigurations() async throws -> [WidgetInfo] {
        try await withCheckedThrowingContinuation { continuation in
            WidgetCenter.shared.getCurrentConfigurations { result in
                continuation.resume(with: result)
            }
        }
    }
    #endif
}
