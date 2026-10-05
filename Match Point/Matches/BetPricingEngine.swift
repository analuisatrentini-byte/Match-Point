import Foundation

struct BetPricingQuote: Equatable {
    enum Source: Equatable {
        case bookmaker(name: String, isLive: Bool)
        case symbolicFallback
    }

    let multiplier: Double
    let payout: Int
    let source: Source

    var sourceLabel: String {
        switch source {
        case .bookmaker(let name, let isLive):
            return isLive ? "Odd live de \(name)" : "Odd pré-jogo de \(name)"
        case .symbolicFallback:
            return "Cotação simbólica do Match Point"
        }
    }

    var isBookmakerBacked: Bool {
        if case .bookmaker = source { return true }
        return false
    }
}

enum BetPricingEngine {
    static func quote(
        kind: BetKind,
        match: TennisMatch,
        player: Player?,
        stake: Int,
        preMatchOdds: [OddsDTO],
        liveOdds: [LiveOddsDTO]
    ) -> BetPricingQuote {
        let multiplier = bookmakerMultiplier(
            kind: kind,
            match: match,
            player: player,
            preMatchOdds: preMatchOdds,
            liveOdds: liveOdds
        ) ?? (fallbackMultiplier(for: kind), .symbolicFallback)

        return BetPricingQuote(
            multiplier: multiplier.value,
            payout: max(stake, Int((Double(stake) * multiplier.value).rounded(.down))),
            source: multiplier.source
        )
    }

    static func fallbackMultiplier(for kind: BetKind) -> Double {
        switch kind {
        case .matchWinner: return 1.8
        case .setWinner: return 2.2
        case .finalScore: return 3.4
        case .playerPerformance: return 2.6
        case .tieBreakPlayed: return 2.1
        case .totalSets: return 2.5
        case .holdServe: return 1.5
        case .firstBreak: return 2.8
        case .nextGameWinner: return 1.9
        }
    }

    private static func bookmakerMultiplier(
        kind: BetKind,
        match: TennisMatch,
        player: Player?,
        preMatchOdds: [OddsDTO],
        liveOdds: [LiveOddsDTO]
    ) -> (value: Double, source: BetPricingQuote.Source)? {
        guard kind == .matchWinner, let player else { return nil }

        if match.isLive, let liveQuote = liveQuote(for: player, match: match, odds: liveOdds) {
            return liveQuote
        }

        return preMatchOdds
            .compactMap { row -> (value: Double, source: BetPricingQuote.Source)? in
                guard isMatchWinnerMarket(row.market), outcome(row.outcome, matches: player.name), let value = decimalOdd(row.value) else {
                    return nil
                }
                return (value, .bookmaker(name: row.bookmakerName, isLive: false))
            }
            .sorted { $0.value > $1.value }
            .first
    }

    private static func liveQuote(for player: Player, match: TennisMatch, odds: [LiveOddsDTO]) -> (value: Double, source: BetPricingQuote.Source)? {
        odds.compactMap { row -> (value: Double, source: BetPricingQuote.Source)? in
            let rawOdd: String?
            if match.player1?.id == player.id {
                rawOdd = row.homeOdd
            } else if match.player2?.id == player.id {
                rawOdd = row.awayOdd
            } else {
                rawOdd = nil
            }

            guard let rawOdd, let value = decimalOdd(rawOdd) else { return nil }
            return (value, .bookmaker(name: row.bookmakerName, isLive: true))
        }
        .sorted { $0.value > $1.value }
        .first
    }

    private static func isMatchWinnerMarket(_ value: String) -> Bool {
        let normalized = value.lowercased()
        return normalized.contains("match")
            || normalized.contains("winner")
            || normalized.contains("vencedor")
            || normalized.contains("home/away")
            || normalized.contains("to win")
    }

    private static func outcome(_ outcome: String, matches playerName: String) -> Bool {
        let normalizedOutcome = normalized(outcome)
        let normalizedPlayer = normalized(playerName)
        return normalizedOutcome == normalizedPlayer
            || normalizedOutcome.contains(normalizedPlayer)
            || normalizedPlayer.contains(normalizedOutcome)
    }

    private static func decimalOdd(_ value: String) -> Double? {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard let number = Double(normalized), number >= 1 else { return nil }
        return number
    }

    private static func normalized(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
