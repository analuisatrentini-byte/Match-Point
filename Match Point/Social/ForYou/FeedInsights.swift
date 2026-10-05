import Foundation
import SwiftUI

struct FavoritePlayerRadar: Identifiable {
    let player: Player
    let liveMatch: TennisMatch?
    let nextMatch: TennisMatch?
    let alertLine: String
    let rankingLine: String
    let headToHeadLine: String
    let surfaceLine: String
    let formLine: String

    var id: UUID { player.id }

    init(player: Player, matches: [TennisMatch], rankings: [RankingEntry]) {
        self.player = player
        let insights = PlayerProfileInsights(player: player, matches: matches, rankings: rankings)
        self.liveMatch = matches
            .filter { $0.isLive && $0.involves(player: player) }
            .sorted { $0.date > $1.date }
            .first
        self.nextMatch = insights.upcomingMatches.first

        if let liveMatch {
            alertLine = "Em quadra agora contra \(liveMatch.opponent(for: player)?.name ?? "adversário")."
        } else if let nextMatch {
            alertLine = "Vai entrar em quadra \(nextMatch.date.formatted(date: .abbreviated, time: .shortened))."
        } else {
            alertLine = "Sem partida confirmada no radar imediato."
        }

        if let rank = insights.rank {
            rankingLine = "#\(rank) no ranking, \(insights.points ?? 0) pts."
        } else {
            rankingLine = "Ranking ainda não sincronizado."
        }

        if let h2h = insights.headToHead.first {
            headToHeadLine = "Retrospecto principal: \(h2h.wins)-\(h2h.losses) vs \(h2h.opponent.name)."
        } else {
            headToHeadLine = "Sem H2H suficiente no app."
        }

        surfaceLine = Self.favoriteSurface(for: player, matches: matches)
        formLine = insights.recentForm.isEmpty
            ? "Forma recente sem amostra."
            : "Forma recente: \(insights.recentForm.map { $0 ? "W" : "L" }.joined(separator: " "))"
    }

    private static func favoriteSurface(for player: Player, matches: [TennisMatch]) -> String {
        let winsBySurface = Dictionary(grouping: matches.filter { match in
            match.involves(player: player) && match.didPlayerWin(player) == true
        }) { match in
            match.tournament?.surface.isEmpty == false ? match.tournament?.surface ?? "Unknown" : "Unknown"
        }
        guard let best = winsBySurface.max(by: { $0.value.count < $1.value.count }) else {
            return "Superfície favorita ainda indefinida."
        }
        return "Superfície mais forte no app: \(best.key)."
    }
}

struct TournamentModeDigest {
    struct FeaturedMatch: Identifiable {
        let match: TennisMatch
        let reason: String

        var id: UUID { match.id }
    }

    let favoritesAlive: [Player]
    let favoritesEliminated: [Player]
    let upsets: [TennisMatch]
    let mustWatch: [TennisMatch]
    let onlyThree: [TennisMatch]
    let featuredReasons: [FeaturedMatch]
    let bracketSections: [(String, [TennisMatch])]
    let stageLabel: String
    let formatHighlights: [String]
    let localStorylines: [String]
    let favoritePaths: [String]
    let headline: String

    init(tournament: Tournament, matches: [TennisMatch], rankings: [RankingEntry]) {
        let tournamentMatches = matches
            .filter { $0.tournament?.id == tournament.id }
            .sorted { $0.date < $1.date }
        let favoritePlayers = tournamentMatches
            .flatMap { [$0.player1, $0.player2].compactMap { $0 } }
            .filter(\.isFavorite)
            .reduce(into: [UUID: Player]()) { partial, player in
                partial[player.id] = player
            }
        let favoritePlayerList = Array(favoritePlayers.values)
        let liveOrUpcoming = tournamentMatches.filter { $0.isLive || $0.isUpcoming }

        let alive = favoritePlayerList.filter { player in
            liveOrUpcoming.contains { $0.involves(player: player) }
        }
        .sorted { $0.name < $1.name }
        self.favoritesAlive = alive

        self.favoritesEliminated = favoritePlayerList.filter { player in
            !alive.contains(where: { $0.id == player.id }) &&
                tournamentMatches.contains { $0.involves(player: player) && $0.isCompleted }
        }
        .sorted { $0.name < $1.name }

        self.upsets = tournamentMatches
            .filter(\.isCompleted)
            .filter { Self.isUpset($0, rankings: rankings) }
            .sorted { $0.date > $1.date }

        self.mustWatch = MatchIntelligence.sortedByRelevance(liveOrUpcoming, rankings: rankings)

        self.onlyThree = Array(mustWatch.prefix(3))
        self.featuredReasons = Self.featuredReasons(for: onlyThree, rankings: rankings, allMatches: matches)

        let grouped = Dictionary(grouping: tournamentMatches) { match in
            MatchRoundResolver.roundLabel(for: match, allMatches: tournamentMatches)
        }
        let order = ["Final", "Semi-final", "Quarter-final", "Round of 16", "Upcoming Round", "Live Round", "Completed Match"]
        self.bracketSections = grouped.keys
            .sorted { left, right in
                (order.firstIndex(of: left) ?? 99) < (order.firstIndex(of: right) ?? 99)
            }
            .map { ($0, grouped[$0]!.sorted { $0.date < $1.date }) }

        self.stageLabel = Self.stageLabel(for: tournament)
        self.formatHighlights = Self.formatHighlights(for: tournament, matches: tournamentMatches)
        self.favoritePaths = Self.favoritePaths(for: favoritesAlive, matches: tournamentMatches)
        self.localStorylines = Self.localStorylines(
            tournament: tournament,
            matches: tournamentMatches,
            favoritesAlive: favoritesAlive,
            favoritesEliminated: favoritesEliminated,
            upsets: upsets,
            rankings: rankings
        )

        if !onlyThree.isEmpty {
            headline = "\(stageLabel): se você só puder ver 3 jogos hoje, comece por \(onlyThree.first.map(Self.title) ?? "os favoritos")."
        } else if !favoritesEliminated.isEmpty {
            headline = "Favoritos já caíram; o torneio ganhou cara de surpresa."
        } else {
            headline = "\(stageLabel): central pronta para agenda, favoritos e jogos imperdíveis."
        }
    }

    private static func isUpset(_ match: TennisMatch, rankings: [RankingEntry]) -> Bool {
        guard
            let winner = [match.player1, match.player2].compactMap({ $0 }).first(where: { match.didPlayerWin($0) == true }),
            let loser = match.opponent(for: winner),
            let winnerRank = rankings.first(where: { $0.player?.id == winner.id })?.rank,
            let loserRank = rankings.first(where: { $0.player?.id == loser.id })?.rank
        else {
            return false
        }
        return winnerRank - loserRank >= 20
    }

    nonisolated private static func title(_ match: TennisMatch) -> String {
        "\(match.player1?.name ?? "TBD") vs \(match.player2?.name ?? "TBD")"
    }

    private static func featuredReasons(for matches: [TennisMatch], rankings: [RankingEntry], allMatches: [TennisMatch]) -> [FeaturedMatch] {
        matches.map { match in
            let intelligence = MatchIntelligence(match: match, rankings: rankings, allMatches: allMatches)
            let favorite = match.player1?.isFavorite == true || match.player2?.isFavorite == true
            let rankingText = rankingReason(for: match, rankings: rankings)
            let reason: String

            if favorite, match.isLive {
                reason = "Favorito em quadra agora, com \(intelligence.liveContext.pressureLabel.lowercased())."
            } else if let rankingText {
                reason = rankingText
            } else if intelligence.relevanceScore >= 80 {
                reason = "Alta relevância pelo momento, ranking e contexto do torneio."
            } else {
                reason = intelligence.summary
            }

            return FeaturedMatch(match: match, reason: reason)
        }
    }

    private static func rankingReason(for match: TennisMatch, rankings: [RankingEntry]) -> String? {
        let entries = [match.player1, match.player2]
            .compactMap { player -> (Player, RankingEntry)? in
                guard let player, let entry = rankings.first(where: { $0.player?.id == player.id }) else { return nil }
                return (player, entry)
            }
            .sorted { $0.1.rank < $1.1.rank }

        guard let top = entries.first else { return nil }
        if top.1.rank <= 10 {
            return "\(top.0.name) é top 10; resultado pesa na corrida por cabeças de chave."
        }
        if let second = entries.dropFirst().first, abs(top.1.rank - second.1.rank) <= 8 {
            return "Confronto parelho de ranking: #\(top.1.rank) contra #\(second.1.rank)."
        }
        return nil
    }

    private static func stageLabel(for tournament: Tournament) -> String {
        let name = tournament.name.lowercased()
        if name.contains("australian open") || name.contains("roland garros") || name.contains("wimbledon") || name.contains("us open") {
            return "Grand Slam Mode"
        }
        if name.contains("masters") || name.contains("1000") || name.contains("wta 1000") {
            return "Masters Mode"
        }
        return "Tournament Mode"
    }

    private static func formatHighlights(for tournament: Tournament, matches: [TennisMatch]) -> [String] {
        var values: [String] = []
        values.append(tournamentDayLabel(for: tournament))
        values.append("Superfície: \(tournament.surface)")

        let name = tournament.name.lowercased()
        if name.contains("australian open") || name.contains("roland garros") || name.contains("wimbledon") || name.contains("us open") {
            values.append(tournament.tour == .atp ? "ATP: melhor de 5 sets" : "WTA: melhor de 3 sets")
            values.append("Grand Slam: maior peso de calendário")
        } else if name.contains("masters") || name.contains("1000") || name.contains("wta 1000") {
            values.append("Evento 1000: chave forte e alto impacto de ranking")
        } else {
            values.append("Formato padrão: foco em forma, superfície e sequência")
        }

        let liveCount = matches.filter(\.isLive).count
        if liveCount > 0 {
            values.append("\(liveCount) jogo(s) ao vivo")
        }
        return values
    }

    private static func localStorylines(
        tournament: Tournament,
        matches: [TennisMatch],
        favoritesAlive: [Player],
        favoritesEliminated: [Player],
        upsets: [TennisMatch],
        rankings: [RankingEntry]
    ) -> [String] {
        var values: [String] = []
        if !favoritesAlive.isEmpty {
            values.append("\(favoritesAlive.count) favorito(s) ainda vivos na chave.")
        }
        if !favoritesEliminated.isEmpty {
            values.append("\(favoritesEliminated.count) favorito(s) já eliminado(s), abrindo espaço para surpresa.")
        }
        if let topMatch = matches.first(where: { match in
            [match.player1, match.player2].compactMap { $0 }.contains { player in
                (rankings.first { $0.player?.id == player.id }?.rank ?? 999) <= 10
            }
        }) {
            values.append("Jogo com top 10 no radar: \(title(topMatch)).")
        }
        if let upset = upsets.first {
            values.append("Upset recente mudou a chave: \(title(upset)).")
        }
        if values.isEmpty {
            values.append("Acompanhe a chave por superfície, favoritos e jogos em sequência.")
        }
        return values
    }

    private static func favoritePaths(for favorites: [Player], matches: [TennisMatch]) -> [String] {
        favorites.prefix(4).map { player in
            let playerMatches = matches
                .filter { $0.involves(player: player) && ($0.isLive || $0.isUpcoming) }
                .sorted { $0.date < $1.date }
            guard let next = playerMatches.first else {
                return "\(player.name): aguardando próximo caminho."
            }
            let round = MatchRoundResolver.roundLabel(for: next, allMatches: matches)
            let opponent = next.opponent(for: player)?.name ?? "adversário a definir"
            return "\(player.name): \(round) vs \(opponent)."
        }
    }

    private static func tournamentDayLabel(for tournament: Tournament, now: Date = .now) -> String {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: tournament.startDate)
        let today = calendar.startOfDay(for: now)
        let end = calendar.startOfDay(for: tournament.endDate)

        if today < start { return "Pré-torneio" }
        if today > end { return "Torneio encerrado" }

        let day = (calendar.dateComponents([.day], from: start, to: today).day ?? 0) + 1
        let total = max(1, (calendar.dateComponents([.day], from: start, to: end).day ?? 0) + 1)
        return "Dia \(day) de \(total)"
    }
}

struct CasualTennisInsight: Identifiable, Hashable {
    let term: String
    let explanation: String

    var id: String { term }
}

enum TennisGlossaryEngine {
    static func insights(for match: TennisMatch) -> [CasualTennisInsight] {
        var insights: [CasualTennisInsight] = []
        let status = match.status.lowercased()

        if MatchIntelligence(match: match, rankings: [], allMatches: [match]).breakPointLabel != "Sem break point" {
            insights.append(CasualTennisInsight(term: "Break point", explanation: "Quem recebe pode vencer o game no próximo ponto."))
        }
        if match.serverName.isEmpty == false {
            insights.append(CasualTennisInsight(term: "Hold", explanation: "Quando o jogador confirma o próprio saque."))
        }
        if status.contains("tie") || match.gameScore.contains("6-6") {
            insights.append(CasualTennisInsight(term: "Mini-break", explanation: "Ponto vencido no saque do adversário durante o tie-break."))
        }
        if status.contains("wild") {
            insights.append(CasualTennisInsight(term: "Wild card", explanation: "Convite para entrar no torneio sem ranking suficiente."))
        }
        if status.contains("protected") {
            insights.append(CasualTennisInsight(term: "Protected ranking", explanation: "Ranking protegido usado após ausência longa por lesão."))
        }
        if status.contains("qual") || match.tournament?.name.localizedCaseInsensitiveContains("qualifying") == true {
            insights.append(CasualTennisInsight(term: "Qualifying", explanation: "Fase classificatória que dá vaga na chave principal."))
        }

        return Array(insights.prefix(3))
    }
}

enum PredictionPromptCatalog {
    static func prompts(for match: TennisMatch) -> [String] {
        var prompts = ["Quem vence?", "Quem leva o próximo set?", "Terá tie-break?", "Quantos sets?"]
        if match.isLive {
            prompts.append("Confirma o saque?")
            prompts.append("Quem quebra primeiro?")
            prompts.append("Quem vence o próximo game?")
        } else {
            prompts.append("Quem quebra primeiro?")
        }
        return Array(prompts.prefix(5))
    }
}

enum MatchRoundResolver {
    static func roundLabel(for match: TennisMatch, allMatches: [TennisMatch]) -> String {
        let ordered = allMatches.sorted { $0.date < $1.date }
        guard let index = ordered.firstIndex(where: { $0.id == match.id }) else {
            return fallbackRound(for: match)
        }

        let remaining = ordered.count - index
        switch remaining {
        case 1:
            return "Final"
        case 2...3:
            return "Semi-final"
        case 4...7:
            return "Quarter-final"
        case 8...15:
            return "Round of 16"
        default:
            return fallbackRound(for: match)
        }
    }

    static func fallbackRound(for match: TennisMatch) -> String {
        if match.isCompleted { return "Completed Match" }
        if match.isUpcoming { return "Upcoming Round" }
        return "Live Round"
    }
}

struct TournamentCalendarInsights {
    let todayMatches: [TennisMatch]
    let upcomingMatches: [TennisMatch]
    let bracketSections: [(String, [TennisMatch])]

    init(tournament: Tournament, matches: [TennisMatch]) {
        let tournamentMatches = matches
            .filter { $0.tournament?.id == tournament.id }
            .sorted { $0.date < $1.date }

        let calendar = Calendar.current
        self.todayMatches = tournamentMatches.filter { calendar.isDateInToday($0.date) }
        self.upcomingMatches = tournamentMatches.filter(\.isUpcoming).prefix(6).map { $0 }

        let grouped = Dictionary(grouping: tournamentMatches) { match in
            MatchRoundResolver.roundLabel(for: match, allMatches: tournamentMatches)
        }
        let order = ["Final", "Semi-final", "Quarter-final", "Round of 16", "Upcoming Round", "Live Round", "Completed Match"]
        self.bracketSections = grouped.keys
            .sorted { left, right in
                (order.firstIndex(of: left) ?? 99) < (order.firstIndex(of: right) ?? 99)
            }
            .map { ($0, grouped[$0]!.sorted { $0.date < $1.date }) }
    }
}

struct FeedSectionModel: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let matches: [TennisMatch]
}

struct MatchBrainLiveComparison: Identifiable {
    let id: UUID
    let match: TennisMatch
    let rank: Int
    let score: Int
    let headline: String
    let detail: String
    let reasons: [MatchRelevanceReason]

    var matchup: String {
        "\(match.player1TeamName) vs \(match.player2TeamName)"
    }
}

struct MatchBrainHistorySummary {
    let title: String
    let detail: String
    let accuracyRate: Double?

    init(snapshot: BehaviorPersonalizationSnapshot) {
        accuracyRate = snapshot.recommendationAccuracyRate
        if let accuracyRate {
            let percent = Int((accuracyRate * 100).rounded())
            title = String(format: String(localized: "%d%% de sinais úteis"), percent)
            detail = snapshot.lastRecommendationSummary ?? String(
                format: String(localized: "%d de %d aberturas recomendadas viraram sinal positivo."),
                snapshot.usefulRecommendationOpenCount,
                snapshot.recommendationOpenCount
            )
        } else {
            title = String(localized: "Aprendendo com suas aberturas")
            detail = String(localized: "Abra jogos recomendados para o Match Brain medir quais sinais realmente valem seu tempo.")
        }
    }
}

struct MatchBrainDigest {
    let featuredMatch: TennisMatch?
    let headline: String
    let whyNowAlerts: [String]
    let liveComparisons: [MatchBrainLiveComparison]
    let history: MatchBrainHistorySummary

    init(
        matches: [TennisMatch],
        rankings: [RankingEntry],
        preferences: ExperiencePreferences,
        behavior: BehaviorPersonalizationSnapshot
    ) {
        let filtered = Self.filtered(matches: matches, preferences: preferences)
        let rankByPlayerID = Self.rankLookup(from: rankings)
        let scoreByID = MatchIntelligence.relevanceScores(
            for: filtered,
            rankings: rankings,
            behavior: behavior,
            preferences: preferences
        )
        let sorted = filtered.sorted { lhs, rhs in
            let lhsScore = scoreByID[lhs.id] ?? 0
            let rhsScore = scoreByID[rhs.id] ?? 0
            if lhsScore != rhsScore { return lhsScore > rhsScore }
            return lhs.date < rhs.date
        }

        featuredMatch = sorted.first
        liveComparisons = sorted
            .filter(\.isLive)
            .prefix(4)
            .enumerated()
            .map { index, match in
                let reasons = MatchIntelligence.relevanceReasons(
                    for: match,
                    rankByPlayerID: rankByPlayerID,
                    behavior: behavior,
                    preferences: preferences
                )
                return MatchBrainLiveComparison(
                    id: match.id,
                    match: match,
                    rank: index + 1,
                    score: scoreByID[match.id] ?? 0,
                    headline: Self.liveHeadline(for: match, reasons: reasons),
                    detail: Self.liveDetail(for: match, reasons: reasons),
                    reasons: Array(reasons.prefix(3))
                )
            }
        whyNowAlerts = Self.whyNowAlerts(
            from: sorted,
            scoreByID: scoreByID,
            rankByPlayerID: rankByPlayerID,
            behavior: behavior,
            preferences: preferences
        )
        headline = Self.headline(featuredMatch: featuredMatch, liveCount: liveComparisons.count)
        history = MatchBrainHistorySummary(snapshot: behavior)
    }

    private static func filtered(matches: [TennisMatch], preferences: ExperiencePreferences) -> [TennisMatch] {
        matches.filter { match in
            if preferences.matchBrainViewingWindow == .quickCheck,
               !match.isLive,
               match.date.timeIntervalSinceNow > 30 * 60 {
                return false
            }

            switch preferences.tourFilter {
            case .all:
                return true
            case .atp:
                return match.player1?.isWTA == false || match.player2?.isWTA == false || match.tournament?.tour == .atp
            case .wta:
                return match.player1?.isWTA == true || match.player2?.isWTA == true || match.tournament?.tour == .wta
            }
        }
    }

    private static func rankLookup(from rankings: [RankingEntry]) -> [UUID: Int] {
        Dictionary(
            rankings.compactMap { entry -> (UUID, Int)? in
                guard let playerID = entry.player?.id else { return nil }
                return (playerID, entry.rank)
            },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private static func headline(featuredMatch: TennisMatch?, liveCount: Int) -> String {
        guard let featuredMatch else { return String(localized: "Sem jogo forte no radar agora") }
        if featuredMatch.isLive {
            return liveCount > 1 ? String(localized: "Melhor jogo ao vivo agora") : String(localized: "Abra agora")
        }
        if featuredMatch.isUpcoming {
            return String(localized: "Prepare o alerta certo")
        }
        return String(localized: "Contexto mais útil para revisar")
    }

    private static func liveHeadline(for match: TennisMatch, reasons: [MatchRelevanceReason]) -> String {
        if MatchIntelligence.breakPointLabel(for: match) != "Sem break point" {
            return MatchIntelligence.breakPointLabel(for: match)
        }
        if match.status.localizedCaseInsensitiveContains("match point") {
            return "Match point"
        }
        return reasons.first?.label ?? String(localized: "Ao vivo agora")
    }

    private static func liveDetail(for match: TennisMatch, reasons: [MatchRelevanceReason]) -> String {
        var parts: [String] = []
        if !match.gameScore.isEmpty { parts.append(String(format: String(localized: "games %@"), match.gameScore)) }
        if !match.pointScore.isEmpty { parts.append(String(format: String(localized: "pontos %@"), match.pointScore)) }
        if !match.serverName.isEmpty { parts.append(String(format: String(localized: "saque %@"), match.serverName)) }
        if parts.isEmpty {
            parts = Array(reasons.prefix(2).map(\.label))
        }
        return parts.isEmpty ? String(localized: "Sem telemetria extra ainda.") : parts.joined(separator: " • ")
    }

    private static func whyNowAlerts(
        from matches: [TennisMatch],
        scoreByID: [UUID: Int],
        rankByPlayerID: [UUID: Int],
        behavior: BehaviorPersonalizationSnapshot,
        preferences: ExperiencePreferences
    ) -> [String] {
        var alerts: [String] = []
        for match in matches.prefix(8) {
            let reasons = MatchIntelligence.relevanceReasons(
                for: match,
                rankByPlayerID: rankByPlayerID,
                behavior: behavior,
                preferences: preferences
            )
            let label = "\(match.player1TeamName) vs \(match.player2TeamName)"
            if match.isLive, MatchIntelligence.breakPointLabel(for: match) != "Sem break point" {
                alerts.append(String(format: String(localized: "%@: %@ agora."), label, MatchIntelligence.breakPointLabel(for: match)))
            } else if preferences.matchBrainViewingWindow == .quickCheck, match.isLive {
                alerts.append(String(format: String(localized: "%@: melhor opção para abrir nos próximos 20 min."), label))
            } else if match.isLive, (scoreByID[match.id] ?? 0) >= 90 {
                alerts.append(String(format: String(localized: "%@: %@ com jogo em andamento."), label, reasons.first?.label ?? String(localized: "sinal forte")))
            } else if match.isUpcoming, match.date.timeIntervalSinceNow < 90 * 60 {
                alerts.append(String(format: String(localized: "%@: começa em menos de 90 min."), label))
            }
        }
        return Array(alerts.prefix(3))
    }
}

struct ForYouFeedBuilder {
    /// LRU memoization of the most recent `sections(...)` results. The
    /// builder is invoked once per body re-render in BOTH `MatchesView` and
    /// `ForYouView`. A single-slot cache would thrash if those two views
    /// looked at the feed simultaneously with even slightly different
    /// `preferences` — e.g. MatchesView with tourFilter=.all and ForYouView
    /// with prioritizeFavorites=true. Three slots cover that pattern plus
    /// the common "previous tick of the same input" case.
    private static let cacheCapacity = 3
    @MainActor private static var cache: [(signature: Int, sections: [FeedSectionModel])] = []

    static func sections(
        matches: [TennisMatch],
        rankings: [RankingEntry],
        preferences: ExperiencePreferences,
        behavior: BehaviorPersonalizationSnapshot? = nil
    ) -> [FeedSectionModel] {
        let signature = makeSignature(matches: matches, rankings: rankings, preferences: preferences, behavior: behavior)
        if let hitIndex = cache.firstIndex(where: { $0.signature == signature }) {
            // Move the hit to the front (most-recently-used) so a cold third
            // input doesn't evict the active one on the next miss.
            let entry = cache.remove(at: hitIndex)
            cache.insert(entry, at: 0)
            return entry.sections
        }

        let filtered = matches.filter { match in
            if preferences.matchBrainViewingWindow == .quickCheck,
               !match.isLive,
               match.date.timeIntervalSinceNow > 30 * 60 {
                return false
            }

            switch preferences.tourFilter {
            case .all:
                return true
            case .atp:
                return match.player1?.isWTA == false || match.player2?.isWTA == false || match.tournament?.tour == .atp
            case .wta:
                return match.player1?.isWTA == true || match.player2?.isWTA == true || match.tournament?.tour == .wta
            }
        }

        let relevanceByID = MatchIntelligence.relevanceScores(for: filtered, rankings: rankings, behavior: behavior, preferences: preferences)
        let sorted = filtered.sorted {
            (relevanceByID[$0.id] ?? 0) > (relevanceByID[$1.id] ?? 0)
        }

        let liveNow = sorted.filter(\.isLive)
        let urgent = sorted.filter { $0.isUpcoming && $0.date.timeIntervalSinceNow < 4 * 3600 }
        let favorites = sorted.filter {
            $0.isFavorite || $0.player1?.isFavorite == true || $0.player2?.isFavorite == true || $0.tournament?.isFavorite == true
        }

        var sections: [FeedSectionModel] = []

        if !liveNow.isEmpty {
            sections.append(FeedSectionModel(id: "live", title: "Ao vivo agora", subtitle: "Partidas em maior evidência", matches: Array(liveNow.prefix(4))))
        }
        if !urgent.isEmpty {
            sections.append(FeedSectionModel(id: "urgent", title: "Vindo a seguir", subtitle: "Jogos nas próximas horas", matches: Array(urgent.prefix(4))))
        }
        if preferences.prioritizeFavorites, !favorites.isEmpty {
            sections.append(FeedSectionModel(id: "favorites", title: "Importa para você", subtitle: "Baseado nos seus favoritos", matches: Array(favorites.prefix(4))))
        }

        let rest = preferences.showOnlyRelevantNow ? sorted.filter { (relevanceByID[$0.id] ?? 0) >= 65 } : sorted
        if !rest.isEmpty {
            sections.append(FeedSectionModel(id: "recommended", title: "Recomendados", subtitle: "Resumo e previsão automáticos", matches: Array(rest.prefix(6))))
        }

        // Insert at the front; evict the LRU entry if we're over capacity.
        cache.insert((signature, sections), at: 0)
        if cache.count > Self.cacheCapacity {
            cache.removeLast()
        }
        return sections
    }

    /// Hashes the inputs into a single Int. `lastUpdatedAt` is the canonical
    /// per-match invalidation signal — a WebSocket sync touches it on every
    /// frame, so any meaningful score / state change re-hashes the signature
    /// and forces a rebuild on the next call.
    private static func makeSignature(
        matches: [TennisMatch],
        rankings: [RankingEntry],
        preferences: ExperiencePreferences,
        behavior: BehaviorPersonalizationSnapshot? = nil
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(matches.count)
        hasher.combine(rankings.count)
        hasher.combine(preferences.tourFilter)
        hasher.combine(preferences.prioritizeFavorites)
        hasher.combine(preferences.showOnlyRelevantNow)
        hasher.combine(preferences.matchBrainStyle)
        hasher.combine(preferences.matchBrainViewingWindow)
        hasher.combine(preferences.spoilerFreeMode)
        hasher.combine(behavior?.signature)
        for match in matches {
            hasher.combine(match.id)
            hasher.combine(match.isLive)
            hasher.combine(match.isFavorite)
            hasher.combine(match.lastUpdatedAt)
        }
        return hasher.finalize()
    }
}

enum LiveTrackerBuilder {
    static let completedRetentionInterval: TimeInterval = 120

    static func activeTrackers(
        matches: [TennisMatch],
        favoritePlayerIDs: Set<UUID>,
        rankings: [RankingEntry],
        now: Date = .now
    ) -> [TennisMatch] {
        let candidates = matches.filter { match in
            guard isFavoriteContext(match: match, favoritePlayerIDs: favoritePlayerIDs) else {
                return false
            }

            if match.isLive {
                return true
            }

            guard match.isCompleted else {
                return false
            }

            let endedAt = match.lastUpdatedAt ?? match.date
            return now.timeIntervalSince(endedAt) < completedRetentionInterval
        }
        return MatchIntelligence.sortedByRelevance(candidates, rankings: rankings)
    }

    static func upcomingFavoriteMatch(matches: [TennisMatch], favoritePlayerIDs: Set<UUID>) -> TennisMatch? {
        matches
            .filter { match in
                match.isUpcoming && isFavoriteContext(match: match, favoritePlayerIDs: favoritePlayerIDs)
            }
            .sorted { $0.date < $1.date }
            .first
    }

    private static func isFavoriteContext(match: TennisMatch, favoritePlayerIDs: Set<UUID>) -> Bool {
        if let player1 = match.player1, favoritePlayerIDs.contains(player1.id) { return true }
        if let player2 = match.player2, favoritePlayerIDs.contains(player2.id) { return true }
        if match.isFavorite { return true }
        if match.tournament?.isFavorite == true { return true }
        return false
    }
}
