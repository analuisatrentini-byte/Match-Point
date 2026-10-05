import SwiftUI
import SwiftData
import OSLog

// MARK: - Timeline Models

nonisolated struct MatchTimelineEvent: Codable, Identifiable, Equatable {
    let timestamp: Date
    let title: String
    let detail: String
    let pointWinnerName: String?
    let serverName: String?
    let pointScore: String?
    let gameScore: String?

    var id: String {
        "\(timestamp.timeIntervalSince1970)-\(title)-\(detail)"
    }

    init(
        timestamp: Date,
        title: String,
        detail: String,
        pointWinnerName: String? = nil,
        serverName: String? = nil,
        pointScore: String? = nil,
        gameScore: String? = nil
    ) {
        self.timestamp = timestamp
        self.title = title
        self.detail = detail
        self.pointWinnerName = pointWinnerName
        self.serverName = serverName
        self.pointScore = pointScore
        self.gameScore = gameScore
    }
}

nonisolated struct MatchTimelinePayload: Codable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let events: [MatchTimelineEvent]
    let advancedStats: AdvancedMatchStatsSnapshot?
    let orderOfPlay: MatchOrderOfPlaySnapshot?

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        events: [MatchTimelineEvent],
        advancedStats: AdvancedMatchStatsSnapshot? = nil,
        orderOfPlay: MatchOrderOfPlaySnapshot? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.events = events
        self.advancedStats = advancedStats
        self.orderOfPlay = orderOfPlay
    }
}

nonisolated struct MatchOrderOfPlaySnapshot: Codable, Equatable {
    let courtName: String
    let order: Int?
    let source: String
    let capturedAt: Date

    var isUsable: Bool {
        courtName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
}

struct LiveMatchInsights {
    struct MomentumSegment: Identifiable {
        let id: Int
        let label: String
        let weight: Double
        let color: Color
    }

    let status: String
    let currentSetLabel: String
    let currentGameLabel: String
    let serverLabel: String
    let pointLabel: String
    let breakPointLabel: String
    let timeline: [MatchTimelineEvent]
    let momentumSegments: [MomentumSegment]

    init(match: TennisMatch, scoreboard: MatchScoreboardData) {
        let player1Name = match.player1?.name ?? "Player 1"
        let player2Name = match.player2?.name ?? "Player 2"
        let normalizedPoints = Self.parseScorePair(match.pointScore)
        let currentLeader = Self.currentLeader(from: normalizedPoints, serverName: match.serverName, player1Name: player1Name, player2Name: player2Name)
        let player1Momentum = Self.momentumScore(for: player1Name, in: match.timelineEvents)
        let player2Momentum = Self.momentumScore(for: player2Name, in: match.timelineEvents)

        self.status = match.status.isEmpty ? "Live" : match.status
        self.currentSetLabel = Self.currentSetLabel(from: match, scoreboard: scoreboard)
        self.currentGameLabel = match.gameScore.isEmpty ? "Aguardando game atual" : match.gameScore
        self.serverLabel = match.serverName.isEmpty ? "Saque indefinido" : match.serverName
        self.pointLabel = match.pointScore.isEmpty ? "Sem pontuação do rally" : match.pointScore
        self.breakPointLabel = Self.breakPointLabel(
            normalizedPoints: normalizedPoints,
            serverName: match.serverName,
            player1Name: player1Name,
            player2Name: player2Name
        )
        self.timeline = Array(match.timelineEvents.sorted { $0.timestamp > $1.timestamp }.prefix(8))
        self.momentumSegments = [
            MomentumSegment(
                id: 0,
                label: Self.shortName(player1Name),
                weight: max(0.15, player1Momentum + (currentLeader == player1Name ? 0.35 : 0)),
                color: .blue
            ),
            MomentumSegment(
                id: 1,
                label: Self.shortName(player2Name),
                weight: max(0.15, player2Momentum + (currentLeader == player2Name ? 0.35 : 0)),
                color: .orange
            )
        ]
    }

    private static func currentSetLabel(from match: TennisMatch, scoreboard: MatchScoreboardData) -> String {
        let index = scoreboard.hasSets ? scoreboard.sets.count + (match.isLive ? 1 : 0) : 1
        return "Set \(index)"
    }

    private static func parseScorePair(_ value: String) -> (String, String)? {
        let parts = value
            .split(separator: "-")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard parts.count == 2 else { return nil }
        return (parts[0], parts[1])
    }

    private static func breakPointLabel(
        normalizedPoints: (String, String)?,
        serverName: String,
        player1Name: String,
        player2Name: String
    ) -> String {
        guard let normalizedPoints else {
            return "Sem break point"
        }

        let values = normalizedPoints
        let server = serverName.trimmingCharacters(in: .whitespacesAndNewlines)

        if server == player1Name, isBreakPoint(receiverPoint: values.1, serverPoint: values.0) {
            return "Break point para \(player2Name)"
        }

        if server == player2Name, isBreakPoint(receiverPoint: values.0, serverPoint: values.1) {
            return "Break point para \(player1Name)"
        }

        return "Sem break point"
    }

    private static func isBreakPoint(receiverPoint: String, serverPoint: String) -> Bool {
        let orderedPoints = ["0", "15", "30", "40", "A", "AD"]
        guard
            let receiverIndex = orderedPoints.firstIndex(of: receiverPoint.uppercased()),
            let serverIndex = orderedPoints.firstIndex(of: serverPoint.uppercased())
        else {
            return receiverPoint.uppercased().contains("A") && !serverPoint.uppercased().contains("A")
        }

        return receiverIndex >= 3 && receiverIndex > serverIndex
    }

    private static func currentLeader(
        from points: (String, String)?,
        serverName: String,
        player1Name: String,
        player2Name: String
    ) -> String? {
        guard let points else {
            return serverName.isEmpty ? nil : serverName
        }

        let values = ["0": 0, "15": 1, "30": 2, "40": 3, "A": 4, "AD": 4]
        let first = values[points.0.uppercased()] ?? 0
        let second = values[points.1.uppercased()] ?? 0

        if first == second {
            return serverName.isEmpty ? nil : serverName
        }

        return first > second ? player1Name : player2Name
    }

    private static func momentumScore(for playerName: String, in timeline: [MatchTimelineEvent]) -> Double {
        let relevant = timeline.suffix(6)
        guard !relevant.isEmpty else { return 0.5 }

        let hits = relevant.reduce(0.0) { partial, event in
            let title = event.title.lowercased()
            let detail = event.detail.lowercased()
            let player = playerName.lowercased()
            if title.contains(player) || detail.contains(player) {
                return partial + 1
            }
            return partial
        }

        return max(0.2, hits / Double(relevant.count))
    }

    private static func shortName(_ name: String) -> String {
        name.split(separator: " ").last.map(String.init) ?? name
    }
}

struct MatchScoreboardData {
    struct SetScore: Identifiable {
        let id: Int
        let player1Games: String
        let player2Games: String
        /// Tiebreak score of the loser when the set went to a tiebreak.
        /// Providers report it as "7-6(4)" → loserTieBreak = "4".
        let loserTieBreak: String?
    }

    let sets: [SetScore]

    init(score: String) {
        let tokens = score.split(separator: " ").map(String.init)
        self.sets = tokens.enumerated().compactMap { index, token in
            Self.parseSet(token: token, index: index)
        }
    }

    private static func parseSet(token: String, index: Int) -> SetScore? {
        // Extract the parenthesized tiebreak score before stripping the punctuation.
        var loserTieBreak: String?
        if let openParen = token.firstIndex(of: "("),
           let closeParen = token.firstIndex(of: ")"),
           openParen < closeParen {
            let inside = token[token.index(after: openParen)..<closeParen]
            loserTieBreak = inside.isEmpty ? nil : String(inside)
        }

        let stripped = token
            .replacingOccurrences(of: "(", with: "-")
            .replacingOccurrences(of: ")", with: "")
        let parts = stripped.split(separator: "-").map(String.init)
        guard parts.count >= 2 else { return nil }
        return SetScore(
            id: index,
            player1Games: parts[0],
            player2Games: parts[1],
            loserTieBreak: loserTieBreak
        )
    }

    var hasSets: Bool {
        !sets.isEmpty
    }

    struct PlayerPair {
        let player1: Int
        let player2: Int
    }

    struct BestSet {
        let setIndex: Int
        let player1Games: Int
        let player2Games: Int
    }

    private func gamesPair(_ set: SetScore) -> (Int, Int)? {
        guard let p1 = Int(set.player1Games), let p2 = Int(set.player2Games) else { return nil }
        return (p1, p2)
    }

    var setsWonByPlayer: PlayerPair {
        var p1 = 0
        var p2 = 0
        for set in sets {
            guard let pair = gamesPair(set) else { continue }
            if pair.0 > pair.1 { p1 += 1 }
            else if pair.1 > pair.0 { p2 += 1 }
        }
        return PlayerPair(player1: p1, player2: p2)
    }

    var totalGames: PlayerPair {
        var p1 = 0
        var p2 = 0
        for set in sets {
            guard let pair = gamesPair(set) else { continue }
            p1 += pair.0
            p2 += pair.1
        }
        return PlayerPair(player1: p1, player2: p2)
    }

    // Returns the set where player 1 had the largest margin (only when they
    // actually won it). nil when player 1 did not win any decoded set.
    var bestSetForPlayer1: BestSet? {
        var best: BestSet?
        var bestMargin = Int.min
        for set in sets {
            guard let pair = gamesPair(set) else { continue }
            let margin = pair.0 - pair.1
            if margin > 0, margin > bestMargin {
                bestMargin = margin
                best = BestSet(setIndex: set.id, player1Games: pair.0, player2Games: pair.1)
            }
        }
        return best
    }
}

extension TennisMatch {
    var orderOfPlaySnapshot: MatchOrderOfPlaySnapshot? {
        guard let data = liveTimelinePayload.data(using: .utf8) else {
            return nil
        }

        return try? JSONDecoder().decode(MatchTimelinePayload.self, from: data).orderOfPlay
    }

    var advancedStatsSnapshot: AdvancedMatchStatsSnapshot? {
        guard let data = liveTimelinePayload.data(using: .utf8) else {
            return nil
        }

        return try? JSONDecoder().decode(MatchTimelinePayload.self, from: data).advancedStats
    }

    var timelineEvents: [MatchTimelineEvent] {
        guard let data = liveTimelinePayload.data(using: .utf8) else {
            return []
        }

        let decoder = JSONDecoder()
        if let payload = try? decoder.decode(MatchTimelinePayload.self, from: data) {
            return payload.events
        }

        // Backward compatibility with pre-versioned payloads stored as a bare array.
        return (try? decoder.decode([MatchTimelineEvent].self, from: data)) ?? []
    }

    func registerLiveTimelineEvent(
        title overrideTitle: String? = nil,
        detail overrideDetail: String? = nil,
        pointWinnerName: String? = nil
    ) {
        let event = MatchTimelineEvent(
            timestamp: lastUpdatedAt ?? .now,
            title: overrideTitle ?? liveTimelineTitle,
            detail: overrideDetail ?? liveTimelineDetail,
            pointWinnerName: pointWinnerName,
            serverName: serverName.isEmpty ? nil : serverName,
            pointScore: pointScore.isEmpty ? nil : pointScore,
            gameScore: gameScore.isEmpty ? nil : gameScore
        )

        var events = timelineEvents

        if events.last == event {
            return
        }

        events.append(event)
        if events.count > 24 {
            events.removeFirst(events.count - 24)
        }

        saveTimelineEvents(events)
    }

    func registerLiveTimelineEvents(_ points: [LivePointDTO]) {
        guard !points.isEmpty else { return }
        var events = timelineEvents
        let existingIDs = Set(events.map(\.id))

        for point in points {
            let event = MatchTimelineEvent(
                timestamp: point.timestamp,
                title: point.title,
                detail: point.detail,
                pointWinnerName: point.pointWinnerName,
                serverName: point.serverName,
                pointScore: point.pointScore,
                gameScore: point.gameScore
            )

            if existingIDs.contains(event.id) == false {
                events.append(event)
            }
        }

        events.sort { $0.timestamp < $1.timestamp }
        if events.count > 24 {
            events.removeFirst(events.count - 24)
        }

        saveTimelineEvents(events)
    }

    func updateAdvancedStatsSnapshot(_ snapshot: AdvancedMatchStatsSnapshot?) {
        guard let snapshot, snapshot.hasAnyValue else { return }
        saveTimelineEvents(timelineEvents, advancedStats: snapshot)
    }

    func updateOrderOfPlaySnapshot(_ snapshot: MatchOrderOfPlaySnapshot?) {
        guard let snapshot, snapshot.isUsable else { return }
        saveTimelineEvents(timelineEvents, orderOfPlay: snapshot)
    }

    private func saveTimelineEvents(
        _ events: [MatchTimelineEvent],
        advancedStats: AdvancedMatchStatsSnapshot? = nil,
        orderOfPlay: MatchOrderOfPlaySnapshot? = nil
    ) {
        // Belt-and-suspenders cap: callers already trim to 24 events in memory,
        // but any direct mutation or future code path that bypasses
        // registerLiveTimelineEvent could still grow the persisted JSON
        // unboundedly. Enforce both an event count and a byte budget here so
        // a single TennisMatch row never blows past ~32KB on disk.
        var bounded = events
        if bounded.count > Self.maxPersistedTimelineEvents {
            bounded.removeFirst(bounded.count - Self.maxPersistedTimelineEvents)
        }

        do {
            let encoder = JSONEncoder()
            let currentStats = advancedStats ?? advancedStatsSnapshot
            let currentOrderOfPlay = orderOfPlay ?? orderOfPlaySnapshot
            var data = try encoder.encode(MatchTimelinePayload(events: bounded, advancedStats: currentStats, orderOfPlay: currentOrderOfPlay))
            // If the encoded payload still exceeds the byte budget (long titles
            // or rich detail strings), drop the oldest events until it fits.
            while data.count > Self.maxPersistedTimelineBytes, bounded.count > 1 {
                bounded.removeFirst()
                data = try encoder.encode(MatchTimelinePayload(events: bounded, advancedStats: currentStats, orderOfPlay: currentOrderOfPlay))
            }
            liveTimelinePayload = String(data: data, encoding: .utf8) ?? liveTimelinePayload
        } catch {
            AppLogger.persistence.error("Failed to encode versioned timeline payload: \(AppLogger.message(for: error), privacy: .private)")
            AppLogger.recordFailure(category: "persistence", operation: "encodeTimelinePayload", error: error)
        }
    }

    private static let maxPersistedTimelineEvents = 24
    private static let maxPersistedTimelineBytes = 32_000

    private var liveTimelineTitle: String {
        if !pointScore.isEmpty {
            return "Ponto em disputa"
        }

        if !gameScore.isEmpty {
            return "Game atualizado"
        }

        if isLive {
            return status.isEmpty ? "Partida ao vivo" : status
        }

        return "Status atualizado"
    }

    private var liveTimelineDetail: String {
        var fragments: [String] = []

        if !serverName.isEmpty {
            fragments.append("Saque: \(serverName)")
        }
        if !pointScore.isEmpty {
            fragments.append("Pontos: \(pointScore)")
        }
        if !gameScore.isEmpty {
            fragments.append("Games: \(gameScore)")
        }
        if !score.isEmpty {
            fragments.append("Sets: \(score)")
        }
        if fragments.isEmpty {
            fragments.append(status.isEmpty ? "Atualização recebida" : status)
        }

        return fragments.joined(separator: " • ")
    }

    var isUpcoming: Bool {
        date >= .now && !isCompleted && !isCancelled
    }

    /// True when the current game is a tie-break — used to swap the scoreboard
    /// for `TiebreakCounter` in the live tracker. Reads both `gameScore`
    /// (some providers report "6-6" or "6/6") and `status`.
    var isInTiebreak: Bool {
        let normalizedGame = gameScore.replacingOccurrences(of: "/", with: "-")
        if normalizedGame.contains("6-6") { return true }
        let normalized = TennisMatch.normalizedStatus(status)
        return normalized.contains("tiebreak") || normalized.contains("tie-break") || normalized.contains("tie break")
    }

    var isCompleted: Bool {
        // Cancelled matches never played; they're not "completed".
        // Walkover and retirement are terminal states with a winner, so they are.
        if isCancelled { return false }
        if isWalkover || isRetirement { return true }
        let normalized = TennisMatch.normalizedStatus(status)
        return normalized.contains("final")
            || normalized.contains("finished")
            || normalized.contains("ended")
            || normalized.contains("completed")
    }

    var isCancelled: Bool {
        let normalized = TennisMatch.normalizedStatus(status)
        return normalized.contains("cancel") || normalized.contains("postponed")
    }

    var isWalkover: Bool {
        let normalized = TennisMatch.normalizedStatus(status)
        return normalized == "w/o"
            || normalized == "wo"
            || normalized.contains("walkover")
            || normalized.contains("walk-over")
            || normalized.contains("walk over")
    }

    var isRetirement: Bool {
        let normalized = TennisMatch.normalizedStatus(status)
        return normalized == "ret"
            || normalized.contains("retired")
            || normalized.contains("retirement")
            || normalized.contains("abandon")
    }

    /// Did the match end in some way other than playing it out normally? Useful
    /// for UI ("Por W.O.") and for settlement rules that treat these as edge cases.
    var endedIrregularly: Bool {
        isCancelled || isWalkover || isRetirement
    }

    var endedIrregularlyLabel: String? {
        if isCancelled { return "Cancelada" }
        if isWalkover { return "W.O." }
        if isRetirement { return "Abandono" }
        return nil
    }

    private static func normalizedStatus(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func involves(player: Player) -> Bool {
        player1?.id == player.id
            || player2?.id == player.id
            || player1Partner?.id == player.id
            || player2Partner?.id == player.id
    }

    var isDoubles: Bool {
        player1Partner != nil
            || player2Partner != nil
            || Self.looksLikeDoublesTeam(player1?.name)
            || Self.looksLikeDoublesTeam(player2?.name)
    }

    var player1TeamName: String {
        Self.teamName(primary: player1, partner: player1Partner)
    }

    var player2TeamName: String {
        Self.teamName(primary: player2, partner: player2Partner)
    }

    private static func teamName(primary: Player?, partner: Player?) -> String {
        let primaryName = primary?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let partnerName = partner?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch (primaryName.isEmpty, partnerName.isEmpty) {
        case (false, false):
            return "\(primaryName) / \(partnerName)"
        case (false, true):
            return primaryName
        case (true, false):
            return partnerName
        case (true, true):
            return "TBD"
        }
    }

    private static func looksLikeDoublesTeam(_ value: String?) -> Bool {
        guard let value else { return false }
        return value.contains("/") || value.contains("&") || value.localizedCaseInsensitiveContains(" / ")
    }

    func opponent(for player: Player) -> Player? {
        if player1?.id == player.id { return player2 }
        if player2?.id == player.id { return player1 }
        return nil
    }

    func didPlayerWin(_ player: Player) -> Bool? {
        guard isCompleted else { return nil }

        let scoreboard = MatchScoreboardData(score: score)
        guard scoreboard.hasSets else { return nil }

        let player1SetWins = scoreboard.sets.reduce(into: 0) { partial, set in
            if (Int(set.player1Games) ?? 0) > (Int(set.player2Games) ?? 0) {
                partial += 1
            }
        }
        let player2SetWins = scoreboard.sets.count - player1SetWins

        guard player1SetWins != player2SetWins else { return nil }

        if player1?.id == player.id {
            return player1SetWins > player2SetWins
        }
        if player2?.id == player.id {
            return player2SetWins > player1SetWins
        }

        return nil
    }
}

struct MatchScoreboardView: View {
    let player1Name: String
    let player2Name: String
    let scoreboard: MatchScoreboardData
    var highlightLive: Bool = false
    var hidesScores: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Players")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(Color.readableSecondary)

                ForEach(scoreboard.sets) { set in
                    Text("S\(set.id + 1)")
                        .frame(width: 34)
                        .foregroundStyle(Color.readableSecondary)
                }
            }
            .font(.caption.weight(.semibold))
            .padding(.bottom, 8)
            .accessibilityHidden(true)

            scoreboardRow(name: player1Name, setValues: displayValues(scoreboard.sets.map(\.player1Games)), isHighlighted: highlightLive)
            Divider().padding(.vertical, 8)
            scoreboardRow(name: player2Name, setValues: displayValues(scoreboard.sets.map(\.player2Games)), isHighlighted: false)
        }
        .accessibilityIdentifier("match-scoreboard")
    }

    private func displayValues(_ values: [String]) -> [String] {
        hidesScores ? values.map { _ in "–" } : values
    }

    @ViewBuilder
    private func scoreboardRow(name: String, setValues: [String], isHighlighted: Bool) -> some View {
        HStack(spacing: 12) {
            Text(name)
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(isHighlighted ? .primary : .primary)

            ForEach(Array(setValues.enumerated()), id: \.offset) { _, value in
                Text(value)
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .frame(width: 34)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.rowAccessibilityLabel(name: name, setValues: setValues))
    }

    /// VoiceOver label for a scoreboard row.
    ///
    /// Without grouping, VoiceOver reads the name and every set cell as a
    /// separate element — "Alcaraz", "6", "3", "6" — with no indication that
    /// the digits belong to the same player or which set each one represents.
    /// Combine the row so the reader hears one linear phrase like
    /// "Alcaraz. Set 1: 6 games. Set 2: 3 games. Set 3: 6 games."
    static func rowAccessibilityLabel(name: String, setValues: [String]) -> String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmedName.isEmpty ? "Jogador" : trimmedName
        guard !setValues.isEmpty else {
            return "\(base). Sem sets registrados"
        }
        let setPhrases = setValues.enumerated().map { index, value in
            let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let readable = cleaned.isEmpty ? "sem placar" : "\(cleaned) games"
            return "set \(index + 1): \(readable)"
        }
        return "\(base). " + setPhrases.joined(separator: ". ")
    }
}
