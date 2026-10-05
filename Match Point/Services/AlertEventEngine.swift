import Foundation
import OSLog
import SwiftData
import UserNotifications

nonisolated struct MatchAlertSnapshot: Codable, Equatable {
    let isLive: Bool
    let status: String
    let serverName: String
    let pointScore: String
    let gameScore: String
    let score: String
    let matchDate: Date
    let courtName: String
    let snapshotAt: Date

    init(
        isLive: Bool,
        status: String,
        serverName: String = "",
        pointScore: String = "",
        gameScore: String = "",
        score: String = "",
        matchDate: Date = .distantPast,
        courtName: String = "",
        snapshotAt: Date = .now
    ) {
        self.isLive = isLive
        self.status = status
        self.serverName = serverName
        self.pointScore = pointScore
        self.gameScore = gameScore
        self.score = score
        self.matchDate = matchDate
        self.courtName = courtName
        self.snapshotAt = snapshotAt
    }

    private enum CodingKeys: String, CodingKey {
        case isLive, status, serverName, pointScore, gameScore, score, matchDate, courtName, snapshotAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isLive = try container.decode(Bool.self, forKey: .isLive)
        status = try container.decode(String.self, forKey: .status)
        serverName = try container.decodeIfPresent(String.self, forKey: .serverName) ?? ""
        pointScore = try container.decodeIfPresent(String.self, forKey: .pointScore) ?? ""
        gameScore = try container.decodeIfPresent(String.self, forKey: .gameScore) ?? ""
        score = try container.decodeIfPresent(String.self, forKey: .score) ?? ""
        matchDate = try container.decodeIfPresent(Date.self, forKey: .matchDate) ?? .distantPast
        courtName = try container.decodeIfPresent(String.self, forKey: .courtName) ?? ""
        snapshotAt = try container.decodeIfPresent(Date.self, forKey: .snapshotAt) ?? .now
    }
}

nonisolated enum MatchNotificationLevel: String, Codable {
    case silentWidget
    case importantBanner
    case urgent
}

private enum MatchSide {
    case player1
    case player2
}

protocol NotificationCenterScheduling {
    func add(_ request: UNNotificationRequest) async throws
    func pendingRequests() async -> [UNNotificationRequest]
    func removePendingNotificationRequests(withIdentifiers identifiers: [String])
    func removeDeliveredNotifications(withIdentifiers identifiers: [String])
}

extension UNUserNotificationCenter: NotificationCenterScheduling {
    func pendingRequests() async -> [UNNotificationRequest] {
        await withCheckedContinuation { continuation in
            getPendingNotificationRequests { requests in
                continuation.resume(returning: requests)
            }
        }
    }
}

@MainActor
final class AlertEventEngine {
    static let shared = AlertEventEngine()

    private let center: any NotificationCenterScheduling
    private let defaults: UserDefaults
    private let upcomingPrefix = "match-point.alert.upcoming."
    private let eventPrefix = "match-point.alert.event."
    private let breakPointPrefix = "match-point.alert.event.breakPoint."
    private let breakServePrefix = "match-point.alert.event.breakServe."
    private let walkOnPrefix = "match-point.alert.event.walkOn."
    private let scheduleChangePrefix = "match-point.alert.event.scheduleChange."
    private let courtChangePrefix = "match-point.alert.event.courtChange."
    private let snapshotPrefix = "match-point.alert.snapshot."
    private let refreshThrottleInterval: TimeInterval
    private var lastScheduledRefreshAt: Date = .distantPast

    init(
        center: any NotificationCenterScheduling = UNUserNotificationCenter.current(),
        defaults: UserDefaults = .standard,
        refreshThrottleInterval: TimeInterval = 60
    ) {
        self.center = center
        self.defaults = defaults
        self.refreshThrottleInterval = refreshThrottleInterval
    }

    func refreshScheduledNotifications(in context: ModelContext, force: Bool = false) async {
        let now = Date()
        guard force || now.timeIntervalSince(lastScheduledRefreshAt) >= refreshThrottleInterval else {
            return
        }
        lastScheduledRefreshAt = now

        let preferences = AlertPreferencesStore.shared.preferences

        await removePendingRequests(withPrefix: upcomingPrefix)

        guard preferences.notificationsEnabled, AlertPreferencesStore.shared.authorizationStatus == .authorized else {
            return
        }

        guard preferences.notifyBeforeMatch else {
            return
        }

        // Only fetch upcoming matches within a 7-day window — no point loading
        // historical matches that can never fire a notification.
        let windowStart = Date()
        let windowEnd = Calendar.current.date(byAdding: .day, value: 7, to: windowStart) ?? windowStart
        let descriptor = FetchDescriptor<TennisMatch>(
            predicate: #Predicate { $0.date >= windowStart && $0.date <= windowEnd },
            sortBy: [SortDescriptor(\.date, order: .forward)]
        )
        let matches: [TennisMatch]
        do {
            matches = try context.fetch(descriptor)
        } catch {
            AppLogger.notifications.error("Failed to fetch matches for notification refresh: \(AppLogger.message(for: error), privacy: .private)")
            AppLogger.recordFailure(category: "notifications", operation: "refreshScheduledNotifications.fetchMatches", error: error)
            return
        }

        for match in matches where shouldScheduleUpcomingAlert(for: match, preferences: preferences) {
            await scheduleUpcomingNotification(for: match, leadTimeMinutes: preferences.leadTimeMinutes)
        }
    }

    func processMatchUpdate(_ match: TennisMatch, previous: MatchAlertSnapshot?) async {
        let preferences = AlertPreferencesStore.shared.preferences
        let authorized = AlertPreferencesStore.shared.authorizationStatus == .authorized

        // A cancellation pulls the rug out from under any scheduled "upcoming",
        // "started" or "finished" alert — fire none of them and clear the slate.
        if match.isCancelled {
            await cancelUpcomingNotifications(for: match)
            persistSnapshot(for: match)
            return
        }

        guard preferences.notificationsEnabled, authorized, matchMatchesPreferences(match, preferences: preferences) else {
            persistSnapshot(for: match)
            return
        }

        let current = snapshot(for: match)

        if let scheduleAlert = scheduleChangeAlert(for: match, previous: previous, current: current) {
            await scheduleEventNotification(
                identifier: "\(scheduleChangePrefix)\(matchNotificationID(for: match)).\(Int(current.matchDate.timeIntervalSince1970 / 60))",
                match: match,
                title: scheduleAlert.title,
                body: scheduleAlert.body,
                level: .importantBanner
            )
        }

        if let courtAlert = courtChangeAlert(for: match, previous: previous, current: current) {
            await scheduleEventNotification(
                identifier: "\(courtChangePrefix)\(matchNotificationID(for: match)).\(normalizedNotificationToken(current.courtName))",
                match: match,
                title: courtAlert.title,
                body: courtAlert.body,
                level: .importantBanner
            )
        }

        // Walk-on fires BEFORE the live transition — the provider has told us
        // the players are warming up / on court but isLive hasn't flipped true
        // yet. This is the "your player just walked on" signal a Flashscore user
        // is used to; the existing "Partida começou" alert fires later when the
        // first ball lands.
        if shouldNotifyWalkOn(previous: previous, current: current, preferences: preferences) {
            await scheduleEventNotification(
                identifier: "\(walkOnPrefix)\(matchNotificationID(for: match))",
                match: match,
                title: "Entrou em quadra",
                body: walkOnBody(for: match),
                level: .importantBanner
            )
        }

        if let breakPointAlert = breakPointOpportunityAlert(for: match, previous: previous, current: current) {
            await scheduleEventNotification(
                identifier: "\(breakPointPrefix)\(matchNotificationID(for: match)).\(normalizedNotificationToken(current.gameScore)).\(normalizedNotificationToken(current.pointScore))",
                match: match,
                title: breakPointAlert.title,
                body: breakPointAlert.body,
                level: breakPointAlert.level
            )
        }

        if let breakServeAlert = breakServeAlert(for: match, previous: previous, current: current) {
            await scheduleEventNotification(
                identifier: "\(breakServePrefix)\(matchNotificationID(for: match)).\(current.gameScore)",
                match: match,
                title: breakServeAlert.title,
                body: breakServeAlert.body,
                level: breakServeAlert.level
            )
        }

        if shouldNotifyMatchStarted(previous: previous, current: current, preferences: preferences) {
            await scheduleEventNotification(
                identifier: "\(eventPrefix)start.\(matchNotificationID(for: match))",
                match: match,
                title: "Partida começou",
                body: matchStartedBody(for: match),
                level: matchStartedLevel(for: match)
            )
        } else if shouldNotifyMatchFinished(previous: previous, current: current, preferences: preferences) {
            let result = spoilerFreeModeEnabled ? "Resultado oculto pelo modo spoiler-free." : (match.score.isEmpty ? current.status : match.score)
            let bodySuffix = spoilerFreeModeEnabled ? "" : (match.endedIrregularlyLabel.map { " (\($0))" } ?? "")
            await scheduleEventNotification(
                identifier: "\(eventPrefix)finish.\(matchNotificationID(for: match))",
                match: match,
                title: "Partida encerrada",
                body: "\(matchTitle(for: match)) terminou. \(result)\(bodySuffix)",
                level: .importantBanner
            )
        }

        persistSnapshot(for: match)
    }

    private func cancelUpcomingNotifications(for match: TennisMatch) async {
        let id = matchNotificationID(for: match)
        // Cancel all plausible upcoming-reminder IDs regardless of the current
        // lead-time setting. If the user changed their lead time since the
        // notification was scheduled, the ID embedded the old lead time, so
        // cancelling only the current setting leaves orphan notifications.
        let identifiers = allUpcomingIdentifiers(forMatchID: id) + [
            "\(walkOnPrefix)\(id)",
            "\(breakPointPrefix)\(id)",
            "\(breakServePrefix)\(id)",
            "\(scheduleChangePrefix)\(id)",
            "\(courtChangePrefix)\(id)",
            "\(eventPrefix)start.\(id)",
            "\(eventPrefix)finish.\(id)"
        ]
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    func cleanupNotifications(forDeletedMatchID id: String) async {
        let identifiers = allUpcomingIdentifiers(forMatchID: id) + [
            "\(walkOnPrefix)\(id)",
            "\(breakPointPrefix)\(id)",
            "\(breakServePrefix)\(id)",
            "\(scheduleChangePrefix)\(id)",
            "\(courtChangePrefix)\(id)",
            "\(eventPrefix)start.\(id)",
            "\(eventPrefix)finish.\(id)"
        ]
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        defaults.removeObject(forKey: "\(snapshotPrefix)\(id)")
    }

    /// Builds upcoming-reminder identifiers for all lead times the app has ever
    /// supported. This ensures cancellations find the right notification even
    /// when the user changed their lead-time preference after scheduling.
    private func allUpcomingIdentifiers(forMatchID id: String) -> [String] {
        let allLeadTimes = [5, 10, 15, 20, 30, 45, 60, 90, 120]
        return allLeadTimes.map { "\(upcomingPrefix)\(id).\($0)" }
    }

    func snapshotForStoredMatch(_ match: TennisMatch) -> MatchAlertSnapshot? {
        let key = "\(snapshotPrefix)\(matchNotificationID(for: match))"
        guard let data = defaults.data(forKey: key) else {
            return nil
        }
        do {
            return try JSONDecoder().decode(MatchAlertSnapshot.self, from: data)
        } catch {
            AppLogger.notifications.error("Failed to decode alert snapshot for \(key, privacy: .public): \(AppLogger.message(for: error), privacy: .private)")
            AppLogger.recordFailure(category: "notifications", operation: "decodeAlertSnapshot", error: error)
            // Corrupted snapshots used to fall through to nil here, which made
            // processMatchUpdate treat the next frame as a fresh transition
            // and re-fire `matchStarted`/`matchFinished` notifications the
            // user already received. Instead, persist a fresh snapshot mirroring
            // the match's current state and return it as `previous` — that way
            // processMatchUpdate sees no transition (previous == current) and
            // skips the duplicate notification. We lose at most one legitimate
            // transition notification for this match, vs. spamming the user
            // with dupes on every refresh until the next state change.
            defaults.removeObject(forKey: key)
            let healed = snapshot(for: match)
            persistSnapshot(for: match)
            return healed
        }
    }

    private func shouldScheduleUpcomingAlert(for match: TennisMatch, preferences: AlertPreferences) -> Bool {
        guard matchMatchesPreferences(match, preferences: preferences) else {
            return false
        }

        guard match.date > .now else {
            return false
        }

        let triggerDate = match.date.addingTimeInterval(TimeInterval(-preferences.leadTimeMinutes * 60))
        return triggerDate > .now
    }

    private func shouldNotifyMatchStarted(
        previous: MatchAlertSnapshot?,
        current: MatchAlertSnapshot,
        preferences: AlertPreferences
    ) -> Bool {
        guard preferences.notifyMatchStarted else {
            return false
        }

        return current.isLive && previous?.isLive != true
    }

    /// Walk-on transition: the provider status now contains warm-up / on-court
    /// phrasing but didn't on the previous snapshot, and the match isn't already
    /// flagged live (otherwise `matchStarted` covers it). Guard on the previous
    /// status so flicker between "on court" / "warming" doesn't re-fire the alert.
    private func shouldNotifyWalkOn(
        previous: MatchAlertSnapshot?,
        current: MatchAlertSnapshot,
        preferences: AlertPreferences
    ) -> Bool {
        guard preferences.notifyMatchWalkOn else {
            return false
        }
        guard !current.isLive else {
            return false
        }
        guard Self.statusLooksLikeWalkOn(current.status) else {
            return false
        }
        if let previous, Self.statusLooksLikeWalkOn(previous.status) || previous.isLive {
            return false
        }
        return true
    }

    private func shouldNotifyMatchFinished(
        previous: MatchAlertSnapshot?,
        current: MatchAlertSnapshot,
        preferences: AlertPreferences
    ) -> Bool {
        guard preferences.notifyMatchFinished else {
            return false
        }

        let wasLive = previous?.isLive == true
        return wasLive && !current.isLive && statusLooksFinished(current.status)
    }

    private func breakServeAlert(
        for match: TennisMatch,
        previous: MatchAlertSnapshot?,
        current: MatchAlertSnapshot
    ) -> (title: String, body: String, level: MatchNotificationLevel)? {
        guard match.isLive,
              let previous,
              previous.isLive,
              !previous.serverName.isEmpty,
              previous.gameScore != current.gameScore,
              let previousGames = parseGameScore(previous.gameScore),
              let currentGames = parseGameScore(current.gameScore),
              let previousServerSide = side(forServerName: previous.serverName, in: match)
        else {
            return nil
        }

        let player1Delta = currentGames.0 - previousGames.0
        let player2Delta = currentGames.1 - previousGames.1
        guard (player1Delta == 1 && player2Delta == 0) || (player1Delta == 0 && player2Delta == 1) else {
            return nil
        }

        let scoringSide: MatchSide = player1Delta == 1 ? .player1 : .player2
        guard scoringSide != previousServerSide else {
            return nil
        }

        let breaker = player(for: scoringSide, in: match)
        let broken = player(for: previousServerSide, in: match)
        let setNumber = currentSetNumber(for: current)
        let level: MatchNotificationLevel = setNumber >= 5 ? .urgent : .importantBanner
        let setLabel = ordinalSetLabel(setNumber)
        let body = spoilerFreeModeEnabled
            ? "Momento importante em \(matchTitle(for: match)). Abra quando quiser acompanhar sem revelar placar aqui."
            : "\(breaker) acabou de quebrar o saque de \(broken) no \(setLabel). Games: \(current.gameScore)."
        return ("Quebra de saque", body, level)
    }

    private func breakPointOpportunityAlert(
        for match: TennisMatch,
        previous: MatchAlertSnapshot?,
        current: MatchAlertSnapshot
    ) -> (title: String, body: String, level: MatchNotificationLevel)? {
        guard match.isLive,
              let previous,
              previous.isLive,
              previous.pointScore != current.pointScore
        else {
            return nil
        }

        let label = MatchIntelligence.breakPointLabel(for: match)
        guard label != "Sem break point" else {
            return nil
        }

        if previous.pointScore == current.pointScore || previous.gameScore != current.gameScore {
            return nil
        }

        let favorite = favoriteContextLabel(for: match)
        let body: String
        if let favorite, label.localizedCaseInsensitiveContains(favorite) {
            body = "\(favorite) tem break point agora. Este é um dos momentos para abrir a partida."
        } else if let favorite {
            body = "\(favorite) está num game crítico: \(label.lowercased())."
        } else {
            body = "\(matchTitle(for: match)): \(label)."
        }
        return ("Break point ativo", body, .urgent)
    }

    private func scheduleChangeAlert(
        for match: TennisMatch,
        previous: MatchAlertSnapshot?,
        current: MatchAlertSnapshot
    ) -> (title: String, body: String)? {
        guard let previous,
              !match.isLive,
              !match.isCompleted,
              previous.matchDate != .distantPast,
              current.matchDate != .distantPast
        else {
            return nil
        }

        let delta = current.matchDate.timeIntervalSince(previous.matchDate)
        guard abs(delta) >= 10 * 60 else {
            return nil
        }

        let title = delta > 0 ? "Partida atrasada" : "Partida antecipada"
        let oldTime = previous.matchDate.formatted(date: .omitted, time: .shortened)
        let newTime = current.matchDate.formatted(date: .omitted, time: .shortened)
        let favorite = favoriteContextLabel(for: match) ?? "seu favorito"
        let body = "\(favorite) teve o horário atualizado: \(oldTime) → \(newTime)."
        return (title, body)
    }

    private func courtChangeAlert(
        for match: TennisMatch,
        previous: MatchAlertSnapshot?,
        current: MatchAlertSnapshot
    ) -> (title: String, body: String)? {
        guard let previous,
              !match.isCompleted,
              !previous.courtName.isEmpty,
              !current.courtName.isEmpty,
              normalizedName(previous.courtName) != normalizedName(current.courtName)
        else {
            return nil
        }

        let favorite = favoriteContextLabel(for: match) ?? "seu jogo favorito"
        let body = "\(favorite) mudou de quadra: \(previous.courtName) → \(current.courtName)."
        return ("Jogo movido de quadra", body)
    }

    private func scheduleUpcomingNotification(for match: TennisMatch, leadTimeMinutes: Int) async {
        let identifier = "\(upcomingPrefix)\(matchNotificationID(for: match)).\(leadTimeMinutes)"
        let content = UNMutableNotificationContent()
        let favorite = favoriteContextLabel(for: match)
        content.title = favorite.map { "\($0) em \(leadTimeMinutes) min" } ?? "Partida em \(leadTimeMinutes) min"
        content.body = upcomingBody(for: match, leadTimeMinutes: leadTimeMinutes)
        content.threadIdentifier = "match-point.\(matchNotificationID(for: match))"
        content.userInfo = notificationUserInfo(for: match, level: .silentWidget)
        applyNotificationLevel(.silentWidget, to: content)

        let triggerDate = match.date.addingTimeInterval(TimeInterval(-leadTimeMinutes * 60))
        let interval = triggerDate.timeIntervalSinceNow

        guard interval > 1 else {
            return
        }

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        )

        do {
            try await center.add(request)
        } catch {
            AppLogger.notifications.error("Failed to schedule upcoming notification \(identifier, privacy: .public): \(AppLogger.message(for: error), privacy: .private)")
            AppLogger.recordFailure(category: "notifications", operation: "scheduleUpcomingNotification", error: error)
        }
    }

    private func scheduleEventNotification(identifier: String, match: TennisMatch, title: String, body: String, level: MatchNotificationLevel) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.threadIdentifier = "match-point.\(matchNotificationID(for: match))"
        content.userInfo = notificationUserInfo(for: match, level: level)
        applyNotificationLevel(level, to: content)

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )

        do {
            try await center.add(request)
        } catch {
            AppLogger.notifications.error("Failed to schedule event notification \(identifier, privacy: .public): \(AppLogger.message(for: error), privacy: .private)")
            AppLogger.recordFailure(category: "notifications", operation: "scheduleEventNotification", error: error)
        }
    }

    private func notificationUserInfo(for match: TennisMatch, level: MatchNotificationLevel) -> [AnyHashable: Any] {
        let id = matchNotificationID(for: match)
        return [
            "matchPointNotificationLevel": level.rawValue,
            "matchPointDeepLink": matchDeepLink(for: match),
            "matchPointMatchID": id
        ]
    }

    private func matchDeepLink(for match: TennisMatch) -> String {
        let id = matchNotificationID(for: match)
        let encodedID = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        return "matchpoint://matches/\(encodedID)"
    }

    private func removePendingRequests(withPrefix prefix: String) async {
        let requests = await center.pendingRequests()
        let identifiers = requests.map(\.identifier).filter { $0.hasPrefix(prefix) }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    private func applyNotificationLevel(_ level: MatchNotificationLevel, to content: UNMutableNotificationContent) {
        switch level {
        case .silentWidget:
            content.sound = nil
            content.relevanceScore = 0.2
            if #available(iOS 15.0, macOS 12.0, *) {
                content.interruptionLevel = .passive
            }
        case .importantBanner:
            content.sound = nil
            content.relevanceScore = 0.7
            if #available(iOS 15.0, macOS 12.0, *) {
                content.interruptionLevel = .active
            }
        case .urgent:
            content.sound = .default
            content.relevanceScore = 1.0
            if #available(iOS 15.0, macOS 12.0, *) {
                content.interruptionLevel = .timeSensitive
            }
        }
    }

    private func matchMatchesPreferences(_ match: TennisMatch, preferences: AlertPreferences) -> Bool {
        let favoriteMatch = preferences.followFavoriteMatches && match.isFavorite
        let favoritePlayer = preferences.followFavoritePlayers && ((match.player1?.isFavorite == true) || (match.player2?.isFavorite == true))
        let favoriteTournament = preferences.followFavoriteTournaments && (match.tournament?.isFavorite == true)
        return favoriteMatch || favoritePlayer || favoriteTournament
    }

    private func matchTitle(for match: TennisMatch) -> String {
        "\(match.player1?.name ?? "TBD") vs \(match.player2?.name ?? "TBD")"
    }

    private func favoriteContextLabel(for match: TennisMatch) -> String? {
        let favoritePlayers = [match.player1, match.player2]
            .compactMap { $0 }
            .filter(\.isFavorite)
            .map(\.name)
        if let first = favoritePlayers.first {
            return first
        }
        if match.isFavorite {
            return matchTitle(for: match)
        }
        if match.tournament?.isFavorite == true {
            return match.tournament?.name
        }
        return nil
    }

    private func upcomingBody(for match: TennisMatch, leadTimeMinutes: Int) -> String {
        var parts: [String] = []
        parts.append("\(matchTitle(for: match)) começa às \(match.date.formatted(date: .omitted, time: .shortened)).")
        if let court = match.orderOfPlaySnapshot?.courtName, !court.isEmpty {
            parts.append("Quadra: \(court).")
        }
        if favoriteContextLabel(for: match) != nil {
            parts.append("Vale preparar o radar agora.")
        }
        return parts.joined(separator: " ")
    }

    private func matchStartedBody(for match: TennisMatch) -> String {
        let title = matchTitle(for: match)
        let tournament = match.tournament?.name ?? "torneio favorito"
        if let favorite = favoriteContextLabel(for: match) {
            return "\(favorite) entrou em quadra. \(title) está ao vivo em \(tournament) — vale abrir agora."
        }
        return "\(title) está ao vivo em \(tournament)."
    }

    private func matchStartedLevel(for match: TennisMatch) -> MatchNotificationLevel {
        favoriteContextLabel(for: match) == nil ? .silentWidget : .importantBanner
    }

    private var spoilerFreeModeEnabled: Bool {
        UserDefaults.standard.data(forKey: "match-point.experience-preferences")
            .flatMap { try? JSONDecoder().decode(ExperiencePreferences.self, from: $0) }?
            .spoilerFreeMode == true
    }

    private func parseGameScore(_ value: String) -> (Int, Int)? {
        let normalized = value.replacingOccurrences(of: "/", with: "-")
        let parts = normalized.split(separator: "-").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard parts.count == 2,
              let first = Int(parts[0]),
              let second = Int(parts[1])
        else {
            return nil
        }
        return (first, second)
    }

    private func side(forServerName serverName: String, in match: TennisMatch) -> MatchSide? {
        let normalizedServer = normalizedName(serverName)
        if normalizedName(match.player1?.name ?? "") == normalizedServer { return .player1 }
        if normalizedName(match.player2?.name ?? "") == normalizedServer { return .player2 }
        return nil
    }

    private func player(for side: MatchSide, in match: TennisMatch) -> String {
        switch side {
        case .player1:
            return match.player1?.name ?? "Player 1"
        case .player2:
            return match.player2?.name ?? "Player 2"
        }
    }

    private func normalizedName(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func normalizedNotificationToken(_ value: String) -> String {
        normalizedName(value)
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
    }

    private func currentSetNumber(for snapshot: MatchAlertSnapshot) -> Int {
        MatchScoreboardData(score: snapshot.score).sets.count + 1
    }

    private func ordinalSetLabel(_ setNumber: Int) -> String {
        switch setNumber {
        case 1: return "1º set"
        case 2: return "2º set"
        case 3: return "3º set"
        case 4: return "4º set"
        default: return "\(setNumber)º set"
        }
    }

    /// Internal so tests can construct the snapshot UserDefaults key. Not
    /// public because external callers should go through the higher-level
    /// `snapshotForStoredMatch` / `processMatchUpdate` API.
    func matchNotificationID(for match: TennisMatch) -> String {
        if let externalID = match.externalID, !externalID.isEmpty {
            return externalID
        }

        return match.id.uuidString
    }

    private func snapshot(for match: TennisMatch) -> MatchAlertSnapshot {
        MatchAlertSnapshot(
            isLive: match.isLive,
            status: match.status,
            serverName: match.serverName,
            pointScore: match.pointScore,
            gameScore: match.gameScore,
            score: match.score,
            matchDate: match.date,
            courtName: match.orderOfPlaySnapshot?.courtName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        )
    }

    private func persistSnapshot(for match: TennisMatch) {
        let key = "\(snapshotPrefix)\(matchNotificationID(for: match))"
        do {
            let data = try JSONEncoder().encode(snapshot(for: match))
            defaults.set(data, forKey: key)
        } catch {
            AppLogger.notifications.error("Failed to encode alert snapshot for \(key, privacy: .public): \(AppLogger.message(for: error), privacy: .private)")
            AppLogger.recordFailure(category: "notifications", operation: "saveAlertSnapshot", error: error)
        }
    }

    private func statusLooksFinished(_ status: String) -> Bool {
        let normalized = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.contains("final") || normalized.contains("finished") || normalized.contains("ended") || normalized.contains("completed")
    }

    /// Phrases the live data providers use when players are warming up / walking
    /// onto court but the match itself hasn't started ticking points yet. Pulled
    /// from real status strings observed across api-tennis, Sofascore, Flashscore
    /// and the Brazilian (`em quadra`, `aquecimento`) localizations. Case- and
    /// punctuation-insensitive: the comparator strips whitespace and lowercases.
    static func statusLooksLikeWalkOn(_ status: String) -> Bool {
        let normalized = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        let needles = [
            "warm up", "warm-up", "warming",
            "on court", "oncourt", "walk on", "walkon",
            "to start", "first ball", "first serve",
            "court call", "ready to start",
            "em quadra", "aquecimento", "vai começar", "vai comecar", "prestes a começar", "prestes a comecar"
        ]
        return needles.contains(where: normalized.contains)
    }

    /// Builds the push body for the walk-on alert with ETA derived from the
    /// scheduled `match.date`. When the scheduled time is past (delayed match
    /// that finally warmed up), drop the minutes part instead of showing a
    /// negative ETA.
    private func walkOnBody(for match: TennisMatch) -> String {
        let title = matchTitle(for: match)
        let interval = match.date.timeIntervalSinceNow
        if interval > 90 {
            let minutes = Int((interval / 60).rounded())
            return "\(title) entrou em quadra — primeira bola em ~\(minutes) min."
        }
        return "\(title) entrou em quadra — primeira bola iminente."
    }
}
