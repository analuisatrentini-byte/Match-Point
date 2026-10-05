import Combine
import Foundation
import OSLog
import SwiftUI
import UserNotifications

nonisolated struct BehaviorAffinity: Codable, Equatable, Hashable {
    var count: Int
    var lastSeenAt: Date
}

nonisolated struct BehaviorPersonalizationSnapshot: Codable, Equatable, Hashable {
    var playerViews: [String: BehaviorAffinity] = [:]
    var tournamentViews: [String: BehaviorAffinity] = [:]
    var matchViews: [String: BehaviorAffinity] = [:]
    var activeHours: [Int: Int] = [:]
    var ignoredAlertEvents: [String: Int] = [:]
    var processedIgnoredAlertIDs: [String: Date] = [:]
    var recommendationOpenCount: Int = 0
    var usefulRecommendationOpenCount: Int = 0
    var lastRecommendationSummary: String?
    var favoriteSignalCount: Int = 0
    var lastUpdatedAt: Date?

    var signature: Int {
        var hasher = Hasher()
        hasher.combine(playerViews)
        hasher.combine(tournamentViews)
        hasher.combine(matchViews)
        hasher.combine(activeHours)
        hasher.combine(ignoredAlertEvents)
        hasher.combine(processedIgnoredAlertIDs)
        hasher.combine(recommendationOpenCount)
        hasher.combine(usefulRecommendationOpenCount)
        hasher.combine(lastRecommendationSummary)
        hasher.combine(favoriteSignalCount)
        hasher.combine(lastUpdatedAt)
        return hasher.finalize()
    }

    var recommendationAccuracyRate: Double? {
        guard recommendationOpenCount > 0 else { return nil }
        return Double(usefulRecommendationOpenCount) / Double(recommendationOpenCount)
    }

    mutating func trim(maxItems: Int = 80) {
        playerViews = Self.trimmed(playerViews, maxItems: maxItems)
        tournamentViews = Self.trimmed(tournamentViews, maxItems: maxItems)
        matchViews = Self.trimmed(matchViews, maxItems: maxItems)
        ignoredAlertEvents = Dictionary(
            uniqueKeysWithValues: ignoredAlertEvents
                .sorted { $0.value > $1.value }
                .prefix(maxItems)
                .map { ($0.key, $0.value) }
        )
        processedIgnoredAlertIDs = Dictionary(
            uniqueKeysWithValues: processedIgnoredAlertIDs
                .sorted { $0.value > $1.value }
                .prefix(maxItems)
                .map { ($0.key, $0.value) }
        )
    }

    private static func trimmed(_ values: [String: BehaviorAffinity], maxItems: Int) -> [String: BehaviorAffinity] {
        Dictionary(
            uniqueKeysWithValues: values.sorted { lhs, rhs in
                if lhs.value.count != rhs.value.count { return lhs.value.count > rhs.value.count }
                return lhs.value.lastSeenAt > rhs.value.lastSeenAt
            }
            .prefix(maxItems)
            .map { ($0.key, $0.value) }
        )
    }
}

enum BehaviorPersonalizationScorer {
    static func boost(for match: TennisMatch, snapshot: BehaviorPersonalizationSnapshot, now: Date = .now) -> Int {
        min(45, relevanceReasons(for: match, snapshot: snapshot, now: now).reduce(0) { $0 + $1.points })
    }

    static func relevanceReasons(
        for match: TennisMatch,
        snapshot: BehaviorPersonalizationSnapshot,
        now: Date = .now
    ) -> [MatchRelevanceReason] {
        var reasons: [MatchRelevanceReason] = []

        if let affinity = snapshot.matchViews[match.behaviorKey] {
            reasons.append(MatchRelevanceReason(
                symbol: "arrow.counterclockwise.circle.fill",
                label: "Você voltou nesta partida",
                points: min(18, 10 + affinity.count * 2)
            ))
        }

        let playerSignals = [match.player1, match.player2]
            .compactMap { player -> (name: String, affinity: BehaviorAffinity)? in
                guard let player, let affinity = snapshot.playerViews[player.behaviorKey] else { return nil }
                return (player.name, affinity)
            }
            .sorted { $0.affinity.count > $1.affinity.count }

        if let signal = playerSignals.first {
            reasons.append(MatchRelevanceReason(
                symbol: "person.crop.circle.badge.clock",
                label: "Você acompanha \(signal.name)",
                points: min(20, 8 + signal.affinity.count * 3)
            ))
        }

        if let tournament = match.tournament,
           let affinity = snapshot.tournamentViews[tournament.behaviorKey] {
            reasons.append(MatchRelevanceReason(
                symbol: "trophy.circle.fill",
                label: "Torneio recorrente para você",
                points: min(14, 6 + affinity.count * 2)
            ))
        }

        let hour = Calendar.current.component(.hour, from: now)
        if let count = snapshot.activeHours[hour], count >= 2, match.isLive || match.isUpcoming {
            reasons.append(MatchRelevanceReason(
                symbol: "clock.arrow.circlepath",
                label: "No seu horário de uso",
                points: min(8, 3 + count)
            ))
        }

        return reasons.sorted { $0.points > $1.points }
    }

    static func preferenceReasons(
        for match: TennisMatch,
        preferences: ExperiencePreferences,
        snapshot: BehaviorPersonalizationSnapshot?,
        rankByPlayerID: [UUID: Int],
        now: Date = .now
    ) -> [MatchRelevanceReason] {
        var reasons: [MatchRelevanceReason] = []

        switch preferences.matchBrainStyle {
        case .balanced:
            break
        case .pressureMoments:
            if match.isLive, MatchIntelligence.breakPointLabel(for: match) != "Sem break point" || match.isInTiebreak || match.pointScore.contains("40-40") {
                reasons.append(MatchRelevanceReason(symbol: "flame.fill", label: String(localized: "Seu estilo: pressão"), points: 14))
            }
        case .starPower:
            let hasStar = [match.player1, match.player2].contains { player in
                guard let id = player?.id, let rank = rankByPlayerID[id] else { return false }
                return rank <= 20
            }
            if hasStar {
                reasons.append(MatchRelevanceReason(symbol: "crown.fill", label: String(localized: "Seu estilo: grandes nomes"), points: 12))
            }
        case .underdogStories:
            let ranks = [match.player1, match.player2].compactMap { player -> Int? in
                guard let id = player?.id else { return nil }
                return rankByPlayerID[id]
            }
            if ranks.count == 2, let best = ranks.min(), let worst = ranks.max(), worst - best >= 25 {
                reasons.append(MatchRelevanceReason(symbol: "arrow.up.forward.circle.fill", label: String(localized: "Seu estilo: zebra possível"), points: 12))
            }
        }

        if preferences.matchBrainViewingWindow == .quickCheck, match.isLive || match.date.timeIntervalSince(now) <= 30 * 60 {
            reasons.append(MatchRelevanceReason(symbol: "timer", label: String(localized: "Cabe numa olhada rápida"), points: 15))
        }

        let hour = Calendar.current.component(.hour, from: match.date)
        if preferences.matchBrainViewingWindow != .anytime,
           preferences.matchBrainViewingWindow != .quickCheck,
           preferences.matchBrainViewingWindow.contains(hour: hour, activeHours: snapshot?.activeHours ?? [:]) {
            reasons.append(MatchRelevanceReason(symbol: "clock.fill", label: String(localized: "No horário que você prefere"), points: 9))
        }

        return reasons
    }
}

@MainActor
final class BehaviorPersonalizationStore: ObservableObject {
    static let shared = BehaviorPersonalizationStore()

    @Published private(set) var snapshot: BehaviorPersonalizationSnapshot

    private let defaults: UserDefaults
    private let storageKey: String

    init(defaults: UserDefaults = .standard, storageKey: String = "match-point.behavior-personalization") {
        self.defaults = defaults
        self.storageKey = storageKey
        self.snapshot = Self.load(from: defaults, key: storageKey)
    }

    func recordMatchOpen(
        _ match: TennisMatch,
        peers: [TennisMatch] = [],
        rankings: [RankingEntry] = [],
        now: Date = .now
    ) {
        mutate(now: now) { draft in
            Self.bump(key: match.behaviorKey, in: &draft.matchViews, now: now)
            if let player = match.player1 {
                Self.bump(key: player.behaviorKey, in: &draft.playerViews, now: now)
            }
            if let player = match.player2 {
                Self.bump(key: player.behaviorKey, in: &draft.playerViews, now: now)
            }
            if let tournament = match.tournament {
                Self.bump(key: tournament.behaviorKey, in: &draft.tournamentViews, now: now)
            }
            draft.activeHours[Calendar.current.component(.hour, from: now), default: 0] += 1
        }

        // Feed the on-device ranker with one positive (the opened match) and up
        // to three unopened peers as negatives. Using the *pre-mutation*
        // snapshot for peers would slightly bias against the just-opened match,
        // so we take the current one after the mutate — new counts only affect
        // *future* opens' features, not the labels being applied here.
        let rankLookup = Self.rankLookup(for: rankings)
        let positiveFeatures = FeedRankerFeatureExtractor.features(
            for: match,
            rankByPlayerID: rankLookup,
            behavior: snapshot,
            now: now
        )
        var samples: [(features: FeedRankerFeatures, label: Double)] = [(positiveFeatures, 1.0)]

        let negatives = peers
            .filter { $0.id != match.id }
            .shuffled()
            .prefix(3)
        for peer in negatives {
            let features = FeedRankerFeatureExtractor.features(
                for: peer,
                rankByPlayerID: rankLookup,
                behavior: snapshot,
                now: now
            )
            samples.append((features, 0.0))
        }

        FeedRankerModel.shared.train(samples: samples)
    }

    func recordRecommendationOpen(
        _ match: TennisMatch,
        relevanceScore: Int,
        reasons: [MatchRelevanceReason],
        now: Date = .now
    ) {
        mutate(now: now) { draft in
            draft.recommendationOpenCount = min(draft.recommendationOpenCount + 1, 9_999)
            if Self.wasUsefulRecommendation(match: match, relevanceScore: relevanceScore, reasons: reasons) {
                draft.usefulRecommendationOpenCount = min(draft.usefulRecommendationOpenCount + 1, 9_999)
            }
            let leadReason = reasons.first?.label ?? String(localized: "contexto geral")
            let matchup = "\(match.player1TeamName) vs \(match.player2TeamName)"
            draft.lastRecommendationSummary = String(format: String(localized: "%@: %@"), matchup, leadReason)
        }
    }

    private static func rankLookup(for rankings: [RankingEntry]) -> [UUID: Int] {
        var map: [UUID: Int] = [:]
        map.reserveCapacity(rankings.count)
        for entry in rankings {
            guard let playerID = entry.player?.id else { continue }
            if map[playerID] == nil { map[playerID] = entry.rank }
        }
        return map
    }

    func recordPlayerView(_ player: Player, now: Date = .now) {
        mutate(now: now) { draft in
            Self.bump(key: player.behaviorKey, in: &draft.playerViews, now: now)
            draft.activeHours[Calendar.current.component(.hour, from: now), default: 0] += 1
        }
    }

    func recordTournamentView(_ tournament: Tournament, now: Date = .now) {
        mutate(now: now) { draft in
            Self.bump(key: tournament.behaviorKey, in: &draft.tournamentViews, now: now)
            draft.activeHours[Calendar.current.component(.hour, from: now), default: 0] += 1
        }
    }

    func recordAlertIgnored(event: String) {
        mutate(now: .now) { draft in
            draft.ignoredAlertEvents[event, default: 0] += 1
        }
    }

    func recordDeliveredNotificationsAsIgnored(now: Date = .now) async {
        let notifications = await deliveredNotifications()
        let matchPointNotifications = notifications.filter {
            $0.request.identifier.hasPrefix("match-point.alert.")
        }
        guard !matchPointNotifications.isEmpty else { return }

        mutate(now: now) { draft in
            for notification in matchPointNotifications where draft.processedIgnoredAlertIDs[notification.request.identifier] == nil {
                let event = Self.ignoredEventKey(for: notification)
                draft.ignoredAlertEvents[event, default: 0] += 1
                draft.processedIgnoredAlertIDs[notification.request.identifier] = now
            }
        }
    }

    func recordFavoriteSignal(now: Date = .now) {
        mutate(now: now) { draft in
            draft.favoriteSignalCount += 1
        }
    }

    func reset() {
        snapshot = BehaviorPersonalizationSnapshot()
        defaults.removeObject(forKey: storageKey)
    }

    private func mutate(now: Date, _ update: (inout BehaviorPersonalizationSnapshot) -> Void) {
        var draft = snapshot
        update(&draft)
        draft.lastUpdatedAt = now
        draft.trim()
        snapshot = draft
        persist(draft)
    }

    private func persist(_ snapshot: BehaviorPersonalizationSnapshot) {
        do {
            let data = try JSONEncoder().encode(snapshot)
            defaults.set(data, forKey: storageKey)
        } catch {
            AppLogger.sync.warning("Failed to persist behavior personalization snapshot: \(error.localizedDescription, privacy: .private)")
        }
    }

    private func deliveredNotifications() async -> [UNNotification] {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getDeliveredNotifications { notifications in
                continuation.resume(returning: notifications)
            }
        }
    }

    private static func ignoredEventKey(for notification: UNNotification) -> String {
        if let level = notification.request.content.userInfo["matchPointNotificationLevel"] as? String {
            return "delivered.\(level)"
        }
        if notification.request.identifier.contains("upcoming") {
            return "delivered.upcoming"
        }
        return "delivered.event"
    }

    private static func load(from defaults: UserDefaults, key: String) -> BehaviorPersonalizationSnapshot {
        guard let data = defaults.data(forKey: key) else { return BehaviorPersonalizationSnapshot() }
        do {
            return try JSONDecoder().decode(BehaviorPersonalizationSnapshot.self, from: data)
        } catch {
            AppLogger.sync.warning("Failed to decode behavior personalization snapshot: \(error.localizedDescription, privacy: .private)")
            return BehaviorPersonalizationSnapshot()
        }
    }

    private static func bump(key: String, in values: inout [String: BehaviorAffinity], now: Date) {
        let current = values[key]
        values[key] = BehaviorAffinity(count: min((current?.count ?? 0) + 1, 99), lastSeenAt: now)
    }

    private static func wasUsefulRecommendation(match: TennisMatch, relevanceScore: Int, reasons: [MatchRelevanceReason]) -> Bool {
        if relevanceScore >= 65 { return true }
        if match.isLive { return true }
        return reasons.contains { reason in
            reason.symbol == "star.fill" ||
                reason.symbol == "person.crop.circle.badge.checkmark" ||
                reason.symbol == "flame.fill" ||
                reason.symbol == "clock.fill"
        }
    }
}

extension Player {
    var behaviorKey: String { externalKey ?? id.uuidString }
}

extension Tournament {
    var behaviorKey: String { externalKey ?? id.uuidString }
}

extension TennisMatch {
    var behaviorKey: String { externalKey ?? id.uuidString }
}
