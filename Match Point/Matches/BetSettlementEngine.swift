import Foundation

enum BetSettlementEngine {
    static func status(for bet: PointBet) -> BetStatus? {
        guard let match = bet.match else {
            return .void
        }

        // Cancelled matches: return stakes unless the bet was already deterministically
        // settled before the cancellation (e.g. a straight-set win confirmed before a
        // mid-match abandonment). We attempt a full settlement pass first; if it
        // produces a concrete won/lost outcome we honour it. Only pure-cancelled
        // matches with no resolvable outcome fall back to void.
        if match.isCancelled {
            let preSettlement = settlementIgnoringCancellation(for: bet, match: match)
            return preSettlement ?? .void
        }

        switch bet.kind {
        case .matchWinner:
            guard let player = bet.player else { return .void }
            guard let didWin = match.didPlayerWin(player) else { return nil }
            return didWin ? .won : .lost

        case .setWinner:
            guard let player = bet.player else { return .void }
            return setWinnerStatus(for: bet, match: match, player: player)

        case .finalScore:
            guard match.isCompleted, !bet.predictedScore.isEmpty else { return nil }
            return normalizedScore(match.score) == normalizedScore(bet.predictedScore) ? .won : .lost

        case .playerPerformance:
            guard let player = bet.player else { return .void }
            guard match.isCompleted else { return nil }
            return performanceStatus(for: bet, match: match, player: player)

        case .tieBreakPlayed:
            guard match.isCompleted else { return nil }
            let predicted = normalizedBoolean(bet.predictedScore)
            return didMatchHaveTieBreak(match) == predicted ? .won : .lost

        case .totalSets:
            guard match.isCompleted, let predicted = Int(bet.predictedScore) else { return nil }
            return MatchScoreboardData(score: match.score).sets.count == predicted ? .won : .lost

        case .holdServe:
            guard let player = bet.player else { return .void }
            return nextGameStatus(for: bet, match: match, player: player, mode: .holdServe)

        case .firstBreak:
            guard let player = bet.player else { return .void }
            return nextGameStatus(for: bet, match: match, player: player, mode: .firstBreak)

        case .nextGameWinner:
            guard let player = bet.player else { return .void }
            return nextGameStatus(for: bet, match: match, player: player, mode: .nextGameWinner)
        }
    }

    static func targetSetIndex(for match: TennisMatch) -> Int {
        let completedSets = MatchScoreboardData(score: match.score).sets.count
        return max(0, completedSets)
    }

    static func defaultPredictedScore(for match: TennisMatch, player: Player?) -> String {
        guard let player else { return "6-4 6-4" }
        let isBestOfFive = match.tournament?.isMajor == true
        let playerIsFirst = match.player1?.id == player.id
        if isBestOfFive {
            return playerIsFirst ? "6-4 6-4 6-4" : "4-6 4-6 4-6"
        }
        return playerIsFirst ? "6-4 6-4" : "4-6 4-6"
    }

    static func defaultPredictionValue(for kind: BetKind, match: TennisMatch, player: Player?) -> String {
        switch kind {
        case .finalScore:
            return defaultPredictedScore(for: match, player: player)
        case .tieBreakPlayed:
            return "Sim"
        case .totalSets:
            return match.tournament?.isMajor == true ? "4" : "3"
        case .holdServe, .firstBreak, .nextGameWinner:
            return liveGameSnapshot(for: match)
        default:
            return ""
        }
    }

    private static func setWinnerStatus(for bet: PointBet, match: TennisMatch, player: Player) -> BetStatus? {
        let sets = MatchScoreboardData(score: match.score).sets
        guard !sets.isEmpty else { return nil }

        let targetIndex = bet.targetSetIndex ?? 0
        guard sets.indices.contains(targetIndex) else {
            return match.isCompleted ? .lost : nil
        }

        guard let result = didPlayerWinSet(player, in: sets[targetIndex], match: match) else {
            return match.isCompleted ? .void : nil
        }

        return result ? .won : .lost
    }

    private static func performanceStatus(for bet: PointBet, match: TennisMatch, player: Player) -> BetStatus {
        let sets = MatchScoreboardData(score: match.score).sets
        guard !sets.isEmpty else { return .void }

        let setResults = sets.compactMap { didPlayerWinSet(player, in: $0, match: match) }
        guard setResults.count == sets.count else { return .void }

        switch bet.performanceRule {
        case .straightSets:
            return setResults.allSatisfy { $0 } ? .won : .lost
        case .comebackWin:
            return setResults.first == false && (match.didPlayerWin(player) == true) ? .won : .lost
        case .decisiveSetPlayed:
            return sets.count >= decisiveSetThreshold(for: match) ? .won : .lost
        }
    }

    private static func didPlayerWinSet(_ player: Player, in set: MatchScoreboardData.SetScore, match: TennisMatch) -> Bool? {
        guard
            let player1Games = Int(set.player1Games),
            let player2Games = Int(set.player2Games),
            player1Games != player2Games
        else {
            return nil
        }

        if match.player1?.id == player.id {
            return player1Games > player2Games
        }
        if match.player2?.id == player.id {
            return player2Games > player1Games
        }
        return nil
    }

    private static func decisiveSetThreshold(for match: TennisMatch) -> Int {
        match.tournament?.isMajor == true ? 5 : 3
    }

    private enum NextGameMode {
        case holdServe
        case firstBreak
        case nextGameWinner
    }

    private static func nextGameStatus(for bet: PointBet, match: TennisMatch, player: Player, mode: NextGameMode) -> BetStatus? {
        let snapshot = LiveGameSnapshot(rawValue: bet.predictedScore)
        guard let startGames = snapshot.gameScore, let currentGames = parseGameScore(match.gameScore) else {
            return match.isCompleted ? .void : nil
        }

        guard currentGames != startGames else {
            return match.isCompleted ? .void : nil
        }

        let delta1 = currentGames.0 - startGames.0
        let delta2 = currentGames.1 - startGames.1

        // Resolve the game winner from whichever path applies.
        let gameWinner: Player?
        if abs(delta1) + abs(delta2) == 1 {
            // Normal path: exactly one game played since the snapshot.
            gameWinner = delta1 == 1 ? match.player1 : match.player2
        } else if currentGames == (0, 0) {
            // Set-end path: the game score reset after a set concluded.
            // Use the set-winner as a proxy for the last-game winner — accurate
            // for standard sets (e.g. 6-4) and tiebreaks (7-6). Inaccurate only
            // when multiple sets have been completed since the snapshot, which
            // is rare for a game-level bet.
            gameWinner = inferSetEndGameWinner(match: match)
        } else {
            return match.isCompleted ? .void : nil
        }

        guard let gameWinner else { return match.isCompleted ? .void : nil }
        let serverAtBet = snapshot.serverName
        let wasHold = gameWinner.name == serverAtBet

        switch mode {
        case .holdServe:
            return player.name == serverAtBet && wasHold ? .won : .lost
        case .firstBreak:
            return player.id == gameWinner.id && !wasHold ? .won : .lost
        case .nextGameWinner:
            return player.id == gameWinner.id ? .won : .lost
        }
    }

    /// Returns the player who won the most recently completed set, used as a
    /// proxy for the last game played in that set when the game score resets to
    /// 0-0. Returns nil when the set score is tied or unparseable.
    private static func inferSetEndGameWinner(match: TennisMatch) -> Player? {
        let sets = MatchScoreboardData(score: match.score).sets
        guard let lastSet = sets.last,
              let p1 = Int(lastSet.player1Games),
              let p2 = Int(lastSet.player2Games),
              p1 != p2 else { return nil }
        return p1 > p2 ? match.player1 : match.player2
    }

    private static func didMatchHaveTieBreak(_ match: TennisMatch) -> Bool {
        MatchScoreboardData(score: match.score).sets.contains { set in
            (set.player1Games == "7" && set.player2Games == "6") ||
                (set.player1Games == "6" && set.player2Games == "7")
        } || match.score.contains("(")
    }

    private static func normalizedBoolean(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "sim" || normalized == "yes" || normalized == "true" || normalized == "1"
    }

    private static func liveGameSnapshot(for match: TennisMatch) -> String {
        "\(match.serverName)|\(match.gameScore)|\(match.pointScore)"
    }

    nonisolated private static func parseGameScore(_ value: String) -> (Int, Int)? {
        let parts = value
            .split(separator: "-")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard parts.count == 2, let first = Int(parts[0]), let second = Int(parts[1]) else {
            return nil
        }
        return (first, second)
    }

    private struct LiveGameSnapshot {
        let serverName: String
        let gameScore: (Int, Int)?

        init(rawValue: String) {
            let parts = rawValue.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            self.serverName = parts.first ?? ""
            self.gameScore = parts.dropFirst().first.flatMap(BetSettlementEngine.parseGameScore)
        }
    }

    private static func normalizedScore(_ score: String) -> String {
        let cleaned = score
            .uppercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
        // Reject malformed scores (letters other than digits and hyphens) to avoid
        // false settlements from typos like "6-xyz 4-3" matching "6XYZ43".
        guard cleaned.allSatisfy({ $0.isNumber || $0 == "-" }) else { return "" }
        return cleaned
    }

    /// Attempts to settle a bet against a cancelled/abandoned match, ignoring the
    /// cancellation check. Returns a concrete .won / .lost if the bet kind was
    /// resolvable from the data available, or nil if the outcome cannot be
    /// determined (in which case the caller should fall back to .void).
    private static func settlementIgnoringCancellation(for bet: PointBet, match: TennisMatch) -> BetStatus? {
        switch bet.kind {
        case .matchWinner:
            guard let player = bet.player, let didWin = match.didPlayerWin(player) else { return nil }
            return didWin ? .won : .lost
        case .playerPerformance:
            guard let player = bet.player, match.isCompleted else { return nil }
            return performanceStatus(for: bet, match: match, player: player)
        case .finalScore:
            guard match.isCompleted, !bet.predictedScore.isEmpty else { return nil }
            return normalizedScore(match.score) == normalizedScore(bet.predictedScore) ? .won : .lost
        case .tieBreakPlayed:
            guard match.isCompleted else { return nil }
            return didMatchHaveTieBreak(match) == normalizedBoolean(bet.predictedScore) ? .won : .lost
        case .totalSets:
            guard match.isCompleted, let predicted = Int(bet.predictedScore) else { return nil }
            return MatchScoreboardData(score: match.score).sets.count == predicted ? .won : .lost
        default:
            return nil
        }
    }
}
