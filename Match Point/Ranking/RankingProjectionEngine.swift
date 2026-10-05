import Foundation

enum RankingProjectionEngine {
    @MainActor
    static func projectionText(
        for match: TennisMatch,
        rankings: [RankingEntry],
        officialSnapshot: OfficialRankingProjectionSnapshot?
    ) -> String? {
        if let officialText = officialProjectionText(for: match, snapshot: officialSnapshot) {
            return officialText
        }
        return projectionText(for: match, rankings: rankings)
    }

    @MainActor
    static func projectionText(
        for player: Player,
        in match: TennisMatch,
        rankings: [RankingEntry],
        officialSnapshot: OfficialRankingProjectionSnapshot?
    ) -> String? {
        if let officialText = officialProjectionText(for: player, in: match, snapshot: officialSnapshot) {
            return officialText
        }
        return projectionText(for: player, in: match, rankings: rankings)
    }

    static func projectionText(for match: TennisMatch, rankings: [RankingEntry]) -> String? {
        guard let candidate = projectedCandidate(for: match, rankings: rankings) else { return nil }
        return projectionText(for: candidate.player, candidate: candidate, match: match, rankings: rankings)
    }

    static func projectionText(for player: Player, in match: TennisMatch, rankings: [RankingEntry]) -> String? {
        guard match.involves(player: player),
              let entry = rankings.first(where: { $0.player?.id == player.id })
        else {
            return nil
        }

        return projectionText(for: player, candidate: (player, entry), match: match, rankings: rankings)
    }

    private static func projectionText(
        for player: Player,
        candidate: (player: Player, entry: RankingEntry),
        match: TennisMatch,
        rankings: [RankingEntry]
    ) -> String {
        let basePoints = rankingPoints(for: match).winnerPoints
        // Walkovers typically award fewer ranking points. ATP/WTA award the same
        // points as a normal match win in most cases, but some tournaments apply a
        // 50% reduction for walkover victories in early rounds. We apply a
        // conservative 50% reduction here to avoid overestimating gains.
        let bonus = match.isWalkover ? max(1, basePoints / 2) : basePoints
        let projectedPoints = candidate.entry.points + bonus
        let projectedRank = projectedRank(for: candidate.player, projectedPoints: projectedPoints, rankings: rankings, currentRank: candidate.entry.rank)
        let confidence = rankingProjectionConfidence(for: match)

        if projectedRank < candidate.entry.rank {
            return "\(confidence): se vencer, \(player.name) pode subir de #\(candidate.entry.rank) para #\(projectedRank) (+\(bonus) pts de campeão estimados)."
        }
        return "\(confidence): vitória renderia até +\(bonus) pts para \(player.name), mantendo pressão no #\(candidate.entry.rank)."
    }

    private static func projectedCandidate(for match: TennisMatch, rankings: [RankingEntry]) -> (player: Player, entry: RankingEntry)? {
        [match.player1, match.player2]
            .compactMap { player -> (Player, RankingEntry)? in
                guard let player, let entry = rankings.first(where: { $0.player?.id == player.id }) else { return nil }
                return (player, entry)
            }
            .min { lhs, rhs in lhs.entry.rank < rhs.entry.rank }
    }

    private static func projectedRank(for player: Player, projectedPoints: Int, rankings: [RankingEntry], currentRank: Int) -> Int {
        let sorted = rankings.sorted { lhs, rhs in
            let lhsPoints = lhs.player?.id == player.id ? projectedPoints : lhs.points
            let rhsPoints = rhs.player?.id == player.id ? projectedPoints : rhs.points
            return lhsPoints > rhsPoints
        }
        // Player may be absent from the snapshot we received (e.g. WTA ranking
        // missing a wildcard entry). Falling back to position 0 would falsely
        // promote them to #1 — preserve the known current rank instead.
        guard let idx = sorted.firstIndex(where: { $0.player?.id == player.id }) else {
            return currentRank
        }
        return idx + 1
    }

    private static func rankingProjectionConfidence(for match: TennisMatch) -> String {
        if tournamentCategory(for: match).isOfficialTable {
            return "Projeção por tabela ATP/WTA"
        }
        return "Projeção local sem pontos defendidos oficiais"
    }

    @MainActor
    private static func officialProjectionText(
        for match: TennisMatch,
        snapshot: OfficialRankingProjectionSnapshot?
    ) -> String? {
        guard let snapshot else { return nil }
        return [match.player1, match.player2]
            .compactMap { player -> (Player, OfficialRankingProjectionSnapshot.Entry)? in
                guard let player, let entry = snapshot.entry(for: player) else { return nil }
                return (player, entry)
            }
            .min { lhs, rhs in lhs.1.currentRank < rhs.1.currentRank }
            .flatMap { officialProjectionText(for: $0.0, in: match, snapshot: snapshot) }
    }

    @MainActor
    private static func officialProjectionText(
        for player: Player,
        in match: TennisMatch,
        snapshot: OfficialRankingProjectionSnapshot?
    ) -> String? {
        guard
            match.involves(player: player),
            let snapshot,
            let entry = snapshot.entry(for: player),
            let earnedPoints = snapshot.pointsForWin(from: match)
        else {
            return nil
        }

        let basePoints = entry.livePoints ?? entry.currentPoints
        let projectedPoints = max(0, basePoints - entry.defendingPoints + earnedPoints)
        let projectedRank = snapshot.projectedRank(for: entry, projectedPoints: projectedPoints)
        let currentRank = entry.liveRank ?? entry.currentRank
        let net = earnedPoints - entry.defendingPoints
        let movement = projectedRank < currentRank
            ? "sobe de #\(currentRank) para #\(projectedRank)"
            : "fica projetado em #\(projectedRank)"
        let netText = net >= 0 ? "+\(net)" : "\(net)"
        let raceText = entry.raceRank.map { " Race: #\($0)." } ?? ""

        return "Projeção oficial \(snapshot.source): se vencer, \(player.name) \(movement) com \(projectedPoints) pts live (\(netText) líquidos; defende \(entry.defendingPoints), ganha \(earnedPoints)).\(raceText)"
    }

    private static func rankingPoints(for match: TennisMatch) -> (winnerPoints: Int, reachedRoundPoints: Int) {
        let tournamentMatches = match.tournament?.matches ?? []
        let round = MatchRoundResolver.roundLabel(for: match, allMatches: tournamentMatches.isEmpty ? [match] : tournamentMatches)
        let table = tournamentCategory(for: match).pointsTable
        switch round {
        case "Final":
            return (table.winner, table.finalist)
        case "Semi-final":
            return (table.finalist, table.semiFinalist)
        case "Quarter-final":
            return (table.semiFinalist, table.quarterFinalist)
        case "Round of 16":
            return (table.quarterFinalist, table.roundOf16)
        default:
            return (table.roundOf16, table.earlyRound)
        }
    }

    private static func tournamentCategory(for match: TennisMatch) -> RankingPointCategory {
        tournamentCategory(
            name: match.tournament?.name ?? "",
            externalKey: match.tournament?.externalKey,
            isMajor: match.tournament?.isMajor == true
        )
    }

    fileprivate static func tournamentCategory(
        name: String,
        externalKey: String?,
        isMajor: Bool
    ) -> RankingPointCategory {
        if isMajor { return .grandSlam }
        let nameLower = name.lowercased()
        let keyLower = externalKey?.lowercased() ?? ""

        // ATP/WTA Finals are the year-end championships — prefer exact externalKey
        // match first, then fall back to conservative name substrings. Avoid
        // name.contains("wta finals") alone since regional events like "WTA Finals
        // Guadalajara" would also match and receive 1500 points incorrectly.
        let isTourFinalsKey = keyLower == "atp_finals"
            || keyLower == "wta_finals"
            || keyLower == "nitto_atp_finals"
        let isTourFinalsName = nameLower.contains("nitto atp")
            || nameLower.contains("year-end championships")
            || nameLower.contains("year end championships")
            || (keyLower.isEmpty && (nameLower == "atp finals" || nameLower == "wta finals"))
        if isTourFinalsKey || isTourFinalsName {
            return .tourFinals
        }
        if nameLower.contains("masters") || nameLower.contains("1000") || nameLower.contains("wta 1000") {
            return .thousand
        }
        if nameLower.contains("500") {
            return .fiveHundred
        }
        if nameLower.contains("250") {
            return .twoFifty
        }
        return .estimatedTwoFifty
    }

    fileprivate static func pointsForRound(_ round: String, category: RankingPointCategory) -> Int {
        let table = category.pointsTable
        switch round {
        case "Final":
            return table.winner
        case "Semi-final":
            return table.finalist
        case "Quarter-final":
            return table.semiFinalist
        case "Round of 16":
            return table.quarterFinalist
        case "Round of 32", "Round of 64", "Round of 128":
            return table.roundOf16
        default:
            return table.earlyRound
        }
    }
}

// MARK: - What-if scenario projection

/// A single assumption in a ranking "what if?" scenario. Decoupled from
/// `TennisMatch` so the projection can be tested and rendered without a live
/// SwiftData context — callers pre-extract the round label and tournament
/// context when building the scenario.
struct RankingScenarioAssumption: Identifiable, Hashable {
    /// Match identifier the assumption is anchored to.
    let id: UUID
    let round: String
    let winnerID: UUID
    let winnerName: String
    let loserID: UUID?
    let loserName: String
    let tournamentName: String
    let tournamentExternalKey: String?
    let tournamentIsMajor: Bool
}

/// A projected delta for a single player after applying all scenario
/// assumptions. Only players whose rank OR points changed are returned.
struct RankingScenarioProjection: Identifiable, Hashable {
    /// Player identifier — mirrors `Player.id`.
    let id: UUID
    let playerName: String
    let currentRank: Int
    let currentPoints: Int
    let projectedRank: Int
    let projectedPoints: Int

    /// Positive when the player climbs (currentRank > projectedRank).
    var rankDelta: Int { currentRank - projectedRank }
    var pointsDelta: Int { projectedPoints - currentPoints }
}

extension RankingProjectionEngine {
    /// Applies a sequence of hypothetical match results to a snapshot of the
    /// current ranking and returns the players whose position or points would
    /// change. Assumptions are processed in the order provided; callers should
    /// pre-sort chronologically so earlier-round wins compound into later
    /// rounds correctly.
    static func projectScenario(
        assumptions: [RankingScenarioAssumption],
        rankings: [RankingEntry]
    ) -> [RankingScenarioProjection] {
        guard !assumptions.isEmpty else { return [] }

        struct WorkingEntry {
            let playerID: UUID
            let playerName: String
            let currentRank: Int
            let currentPoints: Int
            var projectedPoints: Int
        }

        var working: [UUID: WorkingEntry] = [:]
        for entry in rankings {
            guard let player = entry.player else { continue }
            working[player.id] = WorkingEntry(
                playerID: player.id,
                playerName: player.name,
                currentRank: entry.rank,
                currentPoints: entry.points,
                projectedPoints: entry.points
            )
        }

        for assumption in assumptions {
            let category = tournamentCategory(
                name: assumption.tournamentName,
                externalKey: assumption.tournamentExternalKey,
                isMajor: assumption.tournamentIsMajor
            )
            let award = pointsForRound(assumption.round, category: category)
            if var entry = working[assumption.winnerID] {
                entry.projectedPoints += award
                working[assumption.winnerID] = entry
            }
        }

        let sorted = working.values.sorted { lhs, rhs in
            if lhs.projectedPoints != rhs.projectedPoints {
                return lhs.projectedPoints > rhs.projectedPoints
            }
            return lhs.currentRank < rhs.currentRank
        }

        var projectedRankByPlayer: [UUID: Int] = [:]
        for (index, entry) in sorted.enumerated() {
            projectedRankByPlayer[entry.playerID] = index + 1
        }

        return sorted.compactMap { entry -> RankingScenarioProjection? in
            let projectedRank = projectedRankByPlayer[entry.playerID] ?? entry.currentRank
            let changed = projectedRank != entry.currentRank || entry.projectedPoints != entry.currentPoints
            guard changed else { return nil }
            return RankingScenarioProjection(
                id: entry.playerID,
                playerName: entry.playerName,
                currentRank: entry.currentRank,
                currentPoints: entry.currentPoints,
                projectedRank: projectedRank,
                projectedPoints: entry.projectedPoints
            )
        }
        .sorted { lhs, rhs in
            if abs(lhs.rankDelta) != abs(rhs.rankDelta) {
                return abs(lhs.rankDelta) > abs(rhs.rankDelta)
            }
            if lhs.projectedRank != rhs.projectedRank {
                return lhs.projectedRank < rhs.projectedRank
            }
            return lhs.playerName < rhs.playerName
        }
    }
}

nonisolated struct OfficialRankingProjectionSnapshot: Codable, Equatable {
    struct Entry: Codable, Equatable, Identifiable {
        var id: String { playerExternalKey }
        let playerExternalKey: String
        let playerName: String
        let tourRaw: String
        let currentRank: Int
        let currentPoints: Int
        let liveRank: Int?
        let livePoints: Int?
        let raceRank: Int?
        let racePoints: Int?
        let defendingPoints: Int
        let earnedPoints: Int

        var comparablePoints: Int {
            livePoints ?? max(0, currentPoints - defendingPoints + earnedPoints)
        }
    }

    struct RoundPoints: Codable, Equatable {
        let winner: Int
        let finalist: Int
        let semiFinalist: Int
        let quarterFinalist: Int
        let roundOf16: Int
        let earlyRound: Int
    }

    struct TournamentContext: Codable, Equatable {
        let tournamentExternalKey: String?
        let tournamentName: String
        let pointsByRound: RoundPoints
    }

    let source: String
    let generatedAt: Date
    let entries: [Entry]
    let tournament: TournamentContext?

    func entry(for player: Player) -> Entry? {
        if let externalKey = player.externalKey, !externalKey.isEmpty {
            return entries.first { $0.playerExternalKey == externalKey }
        }
        return entries.first { entry in
            entry.playerName.localizedCaseInsensitiveCompare(player.name) == .orderedSame
        }
    }

    @MainActor
    func pointsForWin(from match: TennisMatch) -> Int? {
        guard let tournament else { return nil }
        if let expectedKey = tournament.tournamentExternalKey, !expectedKey.isEmpty {
            guard match.tournament?.externalKey == expectedKey else { return nil }
        } else if tournament.tournamentName.localizedCaseInsensitiveCompare(match.tournament?.name ?? "") != .orderedSame {
            return nil
        }

        let tournamentMatches = match.tournament?.matches ?? []
        let round = MatchRoundResolver.roundLabel(for: match, allMatches: tournamentMatches.isEmpty ? [match] : tournamentMatches)
        switch round {
        case "Final":
            return tournament.pointsByRound.winner
        case "Semi-final":
            return tournament.pointsByRound.finalist
        case "Quarter-final":
            return tournament.pointsByRound.semiFinalist
        case "Round of 16":
            return tournament.pointsByRound.quarterFinalist
        default:
            return tournament.pointsByRound.roundOf16
        }
    }

    func projectedRank(for entry: Entry, projectedPoints: Int) -> Int {
        let sorted = entries.sorted { lhs, rhs in
            let lhsPoints = lhs.playerExternalKey == entry.playerExternalKey ? projectedPoints : lhs.comparablePoints
            let rhsPoints = rhs.playerExternalKey == entry.playerExternalKey ? projectedPoints : rhs.comparablePoints
            if lhsPoints != rhsPoints {
                return lhsPoints > rhsPoints
            }
            return lhs.currentRank < rhs.currentRank
        }
        guard let index = sorted.firstIndex(where: { $0.playerExternalKey == entry.playerExternalKey }) else {
            return entry.liveRank ?? entry.currentRank
        }
        return index + 1
    }
}

private enum RankingPointCategory {
    case grandSlam
    case tourFinals
    case thousand
    case fiveHundred
    case twoFifty
    case estimatedTwoFifty

    var isOfficialTable: Bool {
        self != .estimatedTwoFifty
    }

    var pointsTable: RankingPointsTable {
        switch self {
        case .grandSlam:
            return RankingPointsTable(winner: 2_000, finalist: 1_300, semiFinalist: 800, quarterFinalist: 400, roundOf16: 200, earlyRound: 100)
        case .tourFinals:
            return RankingPointsTable(winner: 1_500, finalist: 1_000, semiFinalist: 600, quarterFinalist: 400, roundOf16: 200, earlyRound: 100)
        case .thousand:
            return RankingPointsTable(winner: 1_000, finalist: 650, semiFinalist: 400, quarterFinalist: 200, roundOf16: 100, earlyRound: 50)
        case .fiveHundred:
            return RankingPointsTable(winner: 500, finalist: 330, semiFinalist: 200, quarterFinalist: 100, roundOf16: 50, earlyRound: 25)
        case .twoFifty, .estimatedTwoFifty:
            return RankingPointsTable(winner: 250, finalist: 165, semiFinalist: 100, quarterFinalist: 50, roundOf16: 25, earlyRound: 13)
        }
    }
}

private struct RankingPointsTable {
    let winner: Int
    let finalist: Int
    let semiFinalist: Int
    let quarterFinalist: Int
    let roundOf16: Int
    let earlyRound: Int
}
