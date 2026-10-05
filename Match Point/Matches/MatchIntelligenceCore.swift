import Foundation
import SwiftUI

// MARK: - Match Intelligence

private enum MatchPointLocalizedCopy {
    static func string(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: String(localized: String.LocalizationValue(key)), locale: .current, arguments: arguments)
    }
}

/// Single triggered factor that contributed to a match's relevance score, suitable
/// for rendering as an inline chip ("Por que estou vendo isso?") on feed cards.
struct MatchRelevanceReason: Identifiable, Hashable {
    let symbol: String
    let label: String
    let points: Int

    var id: String { "\(symbol)|\(label)" }
}

struct MatchIntelligence: Equatable {
    let match: TennisMatch
    let rankings: [RankingEntry]
    let allMatches: [TennisMatch]

    var relevanceScore: Int {
        Self.computeRelevanceScore(for: match, rankByPlayerID: Self.rankLookup(from: rankings))
    }

    /// Pre-computes relevance scores for a batch of matches against a single
    /// shared rank lookup. Use this from sort comparators — building a fresh
    /// `MatchIntelligence` per comparison re-scanned `rankings` linearly inside
    /// `rank(for:)`, turning sort into O(N log N × R).
    static func relevanceScores(
        for matches: [TennisMatch],
        rankings: [RankingEntry],
        behavior: BehaviorPersonalizationSnapshot? = nil,
        preferences: ExperiencePreferences? = nil
    ) -> [UUID: Int] {
        let rankByPlayerID = rankLookup(from: rankings)
        var scores: [UUID: Int] = [:]
        scores.reserveCapacity(matches.count)
        for match in matches {
            scores[match.id] = computeRelevanceScore(for: match, rankByPlayerID: rankByPlayerID, behavior: behavior, preferences: preferences)
        }
        return scores
    }

    /// Sorts by descending relevance using a one-shot score map. Ties break on
    /// nearer `match.date` so re-renders preserve order.
    static func sortedByRelevance(
        _ matches: [TennisMatch],
        rankings: [RankingEntry],
        behavior: BehaviorPersonalizationSnapshot? = nil,
        preferences: ExperiencePreferences? = nil
    ) -> [TennisMatch] {
        let scores = relevanceScores(for: matches, rankings: rankings, behavior: behavior, preferences: preferences)
        return matches.sorted { lhs, rhs in
            let lScore = scores[lhs.id] ?? 0
            let rScore = scores[rhs.id] ?? 0
            if lScore != rScore { return lScore > rScore }
            return lhs.date < rhs.date
        }
    }

    private static func rankLookup(from rankings: [RankingEntry]) -> [UUID: Int] {
        var map: [UUID: Int] = [:]
        map.reserveCapacity(rankings.count)
        for entry in rankings {
            guard let playerID = entry.player?.id else { continue }
            if map[playerID] == nil {
                map[playerID] = entry.rank
            }
        }
        return map
    }

    private static func computeRelevanceScore(
        for match: TennisMatch,
        rankByPlayerID: [UUID: Int],
        behavior: BehaviorPersonalizationSnapshot? = nil,
        preferences: ExperiencePreferences? = nil
    ) -> Int {
        relevanceReasons(for: match, rankByPlayerID: rankByPlayerID, behavior: behavior, preferences: preferences).reduce(0) { $0 + $1.points }
    }

    /// Per-factor breakdown of the relevance score — the "why am I seeing this?" surface
    /// on the feed cards reads this directly so the rule list stays in sync with the
    /// score (changing one place changes both). Keep ordered by descending points so
    /// the chip row in `MatchHeroCard` shows the strongest signals first.
    static func relevanceReasons(
        for match: TennisMatch,
        rankByPlayerID: [UUID: Int],
        behavior: BehaviorPersonalizationSnapshot? = nil,
        preferences: ExperiencePreferences? = nil
    ) -> [MatchRelevanceReason] {
        var reasons: [MatchRelevanceReason] = []

        if match.isLive {
            reasons.append(MatchRelevanceReason(symbol: "dot.radiowaves.left.and.right", label: Self.localized("Está ao vivo agora"), points: 70))
        }
        if match.isFavorite {
            reasons.append(MatchRelevanceReason(symbol: "star.fill", label: Self.localized("Partida favoritada"), points: 40))
        }
        let favoritePlayerNames = [match.player1, match.player2]
            .compactMap { $0 }
            .filter(\.isFavorite)
            .map(\.name)
        if !favoritePlayerNames.isEmpty {
            let label = Self.localized("Jogador favorito: %@", favoritePlayerNames.joined(separator: String(localized: " e ")))
            reasons.append(MatchRelevanceReason(symbol: "person.crop.circle.badge.checkmark", label: label, points: 35))
        }
        if match.tournament?.isFavorite == true {
            let name = match.tournament?.name ?? "torneio"
            reasons.append(MatchRelevanceReason(symbol: "trophy.fill", label: Self.localized("Torneio favorito: %@", name), points: 25))
        }
        if match.isUpcoming {
            let hours = abs(match.date.timeIntervalSinceNow) / 3600
            let bonus = max(0, 24 - Int(hours))
            if bonus > 0 {
                let when = hours < 1 ? Self.localized("em menos de 1h") : Self.localized("em ~%dh", Int(hours))
                reasons.append(MatchRelevanceReason(symbol: "clock.badge.checkmark", label: Self.localized("Começa %@", when), points: bonus))
            }
        }
        var topPlayers: [(name: String, rank: Int)] = []
        if let id = match.player1?.id, let r = rankByPlayerID[id], r <= 10 {
            topPlayers.append((match.player1?.name ?? "Jogador 1", r))
        }
        if let id = match.player2?.id, let r = rankByPlayerID[id], r <= 10 {
            topPlayers.append((match.player2?.name ?? "Jogador 2", r))
        }
        for player in topPlayers {
            reasons.append(MatchRelevanceReason(
                symbol: "rosette",
                label: Self.localized("Top 10: %@ (#%d)", player.name, player.rank),
                points: 10
            ))
        }
        if breakPointLabel(for: match) != "Sem break point" {
            reasons.append(MatchRelevanceReason(symbol: "bolt.fill", label: Self.localized("Break point ativo"), points: 12))
        }
        if let behavior {
            reasons.append(contentsOf: BehaviorPersonalizationScorer.relevanceReasons(for: match, snapshot: behavior))
        }
        if let preferences {
            reasons.append(contentsOf: BehaviorPersonalizationScorer.preferenceReasons(
                for: match,
                preferences: preferences,
                snapshot: behavior,
                rankByPlayerID: rankByPlayerID
            ))
        }

        // Personalized boost from the on-device learn-to-rank model. Only
        // contributes once the model has trained on a handful of open events
        // — before that `relevanceBoost` returns 0 so the feed order stays
        // driven by the deterministic factors above.
        let personalizedBoost = FeedRankerBridge.currentBoost(
            for: match,
            rankByPlayerID: rankByPlayerID,
            behavior: behavior
        )
        if personalizedBoost > 0 {
            reasons.append(MatchRelevanceReason(
                symbol: "wand.and.stars",
                label: Self.localized("Ajuste personalizado (IA)"),
                points: personalizedBoost
            ))
        }

        return reasons.sorted { $0.points > $1.points }
    }

    /// Convenience for callers that only have the `MatchIntelligence` instance —
    /// rebuilds the rank lookup locally instead of forcing them to pass one in.
    var relevanceReasons: [MatchRelevanceReason] {
        Self.relevanceReasons(for: match, rankByPlayerID: Self.rankLookup(from: rankings))
    }

    /// Static mirror of the instance `breakPointLabel` — kept identical so the
    /// instance accessor and the batch scoring path can share one source of
    /// truth without forcing a `MatchIntelligence` allocation.
    static func breakPointLabel(for match: TennisMatch) -> String {
        let player1 = match.player1?.name ?? "Player 1"
        let player2 = match.player2?.name ?? "Player 2"
        let parts = match.pointScore.split(separator: "-").map(String.init)
        guard parts.count == 2 else { return "Sem break point" }

        let values = ["0": 0, "15": 1, "30": 2, "40": 3, "A": 4, "AD": 4]
        let p1 = values[parts[0].uppercased()] ?? 0
        let p2 = values[parts[1].uppercased()] ?? 0

        if match.serverName == player1, p2 >= 3, p2 > p1 {
            return "Break point \(player2)"
        }
        if match.serverName == player2, p1 >= 3, p1 > p2 {
            return "Break point \(player1)"
        }
        return "Sem break point"
    }

    var relevanceLabel: String {
        switch relevanceScore {
        case 90...: return Self.localized("Must Watch")
        case 65..<90: return Self.localized("High Relevance")
        case 40..<65: return Self.localized("Worth Checking")
        default: return Self.localized("Background")
        }
    }

    var predictedWinner: String {
        guard let player1 = match.player1, let player2 = match.player2 else {
            return Self.localized("Sem previsão")
        }

        let player1Score = predictionScore(for: player1)
        let player2Score = predictionScore(for: player2)
        if player1Score == player2Score {
            return Self.localized("Equilibrado")
        }
        return player1Score > player2Score ? player1.name : player2.name
    }

    var summary: String {
        if match.isLive {
            return Self.localized("%@ está ao vivo. %@", matchLabel, liveStateSentence)
        }
        if match.isUpcoming {
            return Self.localized("%@ começa %@ em %@.", matchLabel, match.date.formatted(date: .omitted, time: .shortened), match.tournament?.name ?? String(localized: "torneio"))
        }
        if match.isCompleted {
            return Self.localized("%@ terminou com %@.", matchLabel, match.score.isEmpty ? match.status : match.score)
        }
        return Self.localized("%@ segue em %@.", matchLabel, match.tournament?.name ?? String(localized: "torneio"))
    }

    var recommendation: String {
        if match.isLive, relevanceScore >= 90 {
            return Self.localized("Abrir agora")
        }
        if match.isUpcoming, relevanceScore >= 65 {
            return Self.localized("Vale ativar alerta")
        }
        if match.isCompleted {
            return Self.localized("Bom para revisar histórico")
        }
        return Self.localized("Acompanhar se sobrar tempo")
    }

    var liveContext: PremiumLiveContext {
        PremiumLiveContext(match: match, rankings: rankings, allMatches: allMatches)
    }

    var roundLabel: String {
        MatchRoundResolver.roundLabel(for: match, allMatches: tournamentMatches)
    }

    var liveStateSentence: String {
        var parts: [String] = []
        if !match.status.isEmpty { parts.append(match.status) }
        if !match.gameScore.isEmpty { parts.append(Self.localized("game %@", match.gameScore)) }
        if !match.pointScore.isEmpty { parts.append(Self.localized("pontos %@", match.pointScore)) }
        if !match.serverName.isEmpty { parts.append(Self.localized("saque %@", match.serverName)) }
        if parts.isEmpty { return Self.localized("Sem telemetria adicional.") }
        return parts.joined(separator: " • ")
    }

    var breakPointLabel: String {
        Self.breakPointLabel(for: match)
    }

    private var matchLabel: String {
        "\(match.player1?.name ?? "TBD") vs \(match.player2?.name ?? "TBD")"
    }

    private var tournamentMatches: [TennisMatch] {
        guard let tournamentID = match.tournament?.id else { return [] }
        return allMatches.filter { $0.tournament?.id == tournamentID }
    }

    private func rank(for player: Player?) -> Int? {
        guard let player else { return nil }
        return rankings.first(where: { $0.player?.id == player.id })?.rank
    }

    private func predictionScore(for player: Player) -> Int {
        var score = 50
        if let rank = rank(for: player) {
            score += max(0, 30 - rank)
        }

        let insights = PlayerProfileInsights(player: player, matches: allMatches, rankings: rankings)
        score += (insights.wins - insights.losses)
        score += insights.recentForm.suffix(3).reduce(0) { $0 + ($1 ? 4 : -2) }
        if match.serverName == player.name { score += 3 }
        return score
    }

    static func == (lhs: MatchIntelligence, rhs: MatchIntelligence) -> Bool {
        signature(for: lhs.match, rankings: lhs.rankings, allMatches: lhs.allMatches) ==
        signature(for: rhs.match, rankings: rhs.rankings, allMatches: rhs.allMatches)
    }

    private static func localized(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: String(localized: String.LocalizationValue(key)), locale: .current, arguments: arguments)
    }

    private static func signature(
        for match: TennisMatch,
        rankings: [RankingEntry],
        allMatches: [TennisMatch]
    ) -> String {
        [
            match.id.uuidString,
            match.status,
            match.score,
            match.gameScore,
            match.pointScore,
            match.serverName,
            String(match.isLive),
            String(match.isFavorite),
            String(match.date.timeIntervalSince1970),
            match.player1?.id.uuidString ?? "",
            match.player2?.id.uuidString ?? "",
            match.tournament?.id.uuidString ?? "",
            rankings.map { "\($0.id.uuidString):\($0.rank):\($0.points)" }.joined(separator: ","),
            allMatches.map { "\($0.id.uuidString):\($0.status):\($0.score):\($0.date.timeIntervalSince1970)" }.joined(separator: ",")
        ].joined(separator: "|")
    }
}

struct PremiumLiveContext {
    let headline: String
    let detail: String
    let pressureLabel: String
    let pressureScore: Double
    let momentumLabel: String
    let nextBestAction: String
    let chips: [String]

    init(match: TennisMatch, rankings: [RankingEntry], allMatches: [TennisMatch]) {
        let intelligence = MatchIntelligence(match: match, rankings: rankings, allMatches: allMatches)
        let player1Name = match.player1?.name ?? "Player 1"
        let player2Name = match.player2?.name ?? "Player 2"
        let server = match.serverName.isEmpty ? "saque indefinido" : "saque \(match.serverName)"
        let score = match.score.isEmpty ? "sets ainda sem placar" : "sets \(match.score)"
        let game = match.gameScore.isEmpty ? "game atual não informado" : "game \(match.gameScore)"
        let point = match.pointScore.isEmpty ? "ponto não informado" : "ponto \(match.pointScore)"
        let pressure = Self.pressure(for: match, intelligence: intelligence)

        self.pressureScore = pressure.score
        self.pressureLabel = pressure.label
        self.momentumLabel = Self.momentumLabel(for: match, player1Name: player1Name, player2Name: player2Name)
        self.headline = Self.headline(for: match, intelligence: intelligence, player1Name: player1Name, player2Name: player2Name)
        self.detail = "\(score) • \(game) • \(point) • \(server)"
        self.nextBestAction = Self.nextBestAction(for: match, intelligence: intelligence)
        self.chips = Self.chips(for: match, intelligence: intelligence, pressureLabel: pressure.label)
    }

    private static func headline(
        for match: TennisMatch,
        intelligence: MatchIntelligence,
        player1Name: String,
        player2Name: String
    ) -> String {
        if intelligence.breakPointLabel != "Sem break point" {
            return intelligence.breakPointLabel
        }
        if match.status.localizedCaseInsensitiveContains("match point") {
            return "Match point em \(player1Name) vs \(player2Name)"
        }
        if match.isCompleted {
            return "Partida encerrada: \(match.score.isEmpty ? match.status : match.score)"
        }
        if match.isLive {
            return "Momento-chave ao vivo"
        }
        return "Próximo jogo dos seus favoritos"
    }

    private static func pressure(for match: TennisMatch, intelligence: MatchIntelligence) -> (label: String, score: Double) {
        var score = 0.25
        if match.isLive { score += 0.25 }
        if intelligence.breakPointLabel != "Sem break point" { score += 0.30 }
        if match.status.localizedCaseInsensitiveContains("match point") { score += 0.35 }
        if match.status.localizedCaseInsensitiveContains("tie") || match.gameScore.contains("6-6") { score += 0.18 }
        if match.pointScore.contains("40-40") || match.pointScore.localizedCaseInsensitiveContains("deuce") { score += 0.16 }
        score = min(score, 1.0)

        switch score {
        case 0.80...:
            return ("Pressão máxima", score)
        case 0.55..<0.80:
            return ("Game crítico", score)
        case 0.35..<0.55:
            return ("Atenção", score)
        default:
            return ("Construindo", score)
        }
    }

    private static func momentumLabel(for match: TennisMatch, player1Name: String, player2Name: String) -> String {
        if !match.serverName.isEmpty {
            return "Controle com \(match.serverName)"
        }
        let timeline = match.timelineEvents.suffix(5)
        let player1Hits = timeline.filter { event in
            event.title.localizedCaseInsensitiveContains(player1Name) || event.detail.localizedCaseInsensitiveContains(player1Name)
        }.count
        let player2Hits = timeline.filter { event in
            event.title.localizedCaseInsensitiveContains(player2Name) || event.detail.localizedCaseInsensitiveContains(player2Name)
        }.count

        if player1Hits == player2Hits {
            return "Momentum equilibrado"
        }
        return player1Hits > player2Hits ? "Momentum \(player1Name)" : "Momentum \(player2Name)"
    }

    private static func nextBestAction(for match: TennisMatch, intelligence: MatchIntelligence) -> String {
        if match.isLive, intelligence.breakPointLabel != "Sem break point" {
            return "Abrir discussão da partida"
        }
        if match.isLive {
            return "Criar previsão para o próximo set"
        }
        if match.isUpcoming {
            return "Preparar previsão antes do início"
        }
        return "Ver reações e resultado"
    }

    private static func chips(for match: TennisMatch, intelligence: MatchIntelligence, pressureLabel: String) -> [String] {
        var values = [pressureLabel, intelligence.relevanceLabel]
        if match.player1?.isFavorite == true || match.player2?.isFavorite == true { values.append("Favorito") }
        if !match.pointScore.isEmpty { values.append(match.pointScore) }
        if !match.gameScore.isEmpty { values.append("Game \(match.gameScore)") }
        return Array(values.prefix(4))
    }
}

struct FavoritePlayerFeed {
    let favoritePlayers: [Player]
    let liveMatches: [TennisMatch]
    let upcomingMatches: [TennisMatch]
    let completedMatches: [TennisMatch]
    let spotlight: [TennisMatch]

    init(players: [Player], matches: [TennisMatch], rankings: [RankingEntry]) {
        self.favoritePlayers = players.filter(\.isFavorite).sorted { $0.name < $1.name }
        let favoriteIDs = Set(favoritePlayers.map(\.id))
        let related = matches.filter { match in
            if let player1 = match.player1, favoriteIDs.contains(player1.id) { return true }
            if let player2 = match.player2, favoriteIDs.contains(player2.id) { return true }
            return match.isFavorite || match.tournament?.isFavorite == true
        }

        self.liveMatches = MatchIntelligence.sortedByRelevance(related.filter(\.isLive), rankings: rankings)
        self.upcomingMatches = related.filter(\.isUpcoming).sorted { $0.date < $1.date }
        self.completedMatches = related.filter(\.isCompleted).sorted { $0.date > $1.date }
        self.spotlight = (liveMatches + upcomingMatches + completedMatches).reduce(into: []) { partial, match in
            if !partial.contains(where: { $0.id == match.id }) {
                partial.append(match)
            }
        }
    }
}

struct MatchBrainNarrative {
    let headline: String
    let turningPoint: String
    let whyItMatters: String
    let rankingImpact: String?
    let liveRankingProjection: String?
    let advancedSignals: [String]
    let keyStats: [String]
    let glossaryInsights: [CasualTennisInsight]
    let whyWatchNow: WhyWatchNowMoment?

    init(
        match: TennisMatch,
        rankings: [RankingEntry],
        allMatches: [TennisMatch],
        officialRankingSnapshot: OfficialRankingProjectionSnapshot? = nil
    ) {
        let intelligence = MatchIntelligence(match: match, rankings: rankings, allMatches: allMatches)
        let scoreboard = MatchScoreboardData(score: match.score)
        let pointRun = MatchPointRunAnalyzer(match: match)
        let player1Name = match.player1?.name ?? "Player 1"
        let player2Name = match.player2?.name ?? "Player 2"
        let server = match.serverName.isEmpty ? MatchPointLocalizedCopy.string("saque indefinido") : MatchPointLocalizedCopy.string("%@ sacando", match.serverName)

        if intelligence.breakPointLabel != "Sem break point" {
            headline = MatchPointLocalizedCopy.string("%@. %@ que pode mudar o set.", server, intelligence.breakPointLabel)
        } else if Self.isMatchPoint(match) {
            headline = MatchPointLocalizedCopy.string("%@. Match point: a partida pode acabar neste game.", server)
        } else if match.gameScore.contains("6-6") || match.status.localizedCaseInsensitiveContains("tie") {
            headline = MatchPointLocalizedCopy.string("Tie-break em andamento. Cada mini-break pesa dobrado agora.")
        } else if match.isLive {
            let pointText = match.pointScore.isEmpty ? MatchPointLocalizedCopy.string("Game em construção.") : MatchPointLocalizedCopy.string("Ponto %@.", match.pointScore)
            headline = MatchPointLocalizedCopy.string("%@. %@", server, pointText)
        } else if match.isUpcoming {
            headline = MatchPointLocalizedCopy.string("Jogo chegando: %@ vs %@.", player1Name, player2Name)
        } else {
            headline = MatchPointLocalizedCopy.string("Resultado consolidado: %@.", match.score.isEmpty ? match.status : match.score)
        }

        turningPoint = Self.turningPoint(for: match, scoreboard: scoreboard, intelligence: intelligence, pointRun: pointRun)
        whyItMatters = Self.whyItMatters(for: match, intelligence: intelligence, player1Name: player1Name, player2Name: player2Name)
        rankingImpact = Self.rankingImpact(for: match, rankings: rankings)
        liveRankingProjection = RankingProjectionEngine.projectionText(
            for: match,
            rankings: rankings,
            officialSnapshot: officialRankingSnapshot
        )
        advancedSignals = Self.advancedSignals(for: match, intelligence: intelligence, pointRun: pointRun)
        keyStats = Self.keyStats(for: match, scoreboard: scoreboard, allMatches: allMatches)
        glossaryInsights = TennisGlossaryEngine.insights(for: match)
        whyWatchNow = Self.whyWatchNow(
            match: match,
            intelligence: intelligence,
            pointRun: pointRun,
            player1Name: player1Name,
            player2Name: player2Name
        )
    }

    private static func whyWatchNow(
        match: TennisMatch,
        intelligence: MatchIntelligence,
        pointRun: MatchPointRunAnalyzer,
        player1Name: String,
        player2Name: String
    ) -> WhyWatchNowMoment? {
        guard match.isLive else { return nil }

        let breakLabel = intelligence.breakPointLabel
        if breakLabel != "Sem break point" {
            let receiver = breakLabel.replacingOccurrences(of: "Break point ", with: "")
            let server = match.serverName.isEmpty ? "adversário" : match.serverName
            return WhyWatchNowMoment(
                kind: .breakPoint,
                headline: breakLabel,
                detail: MatchPointLocalizedCopy.string("%@ a um ponto de quebrar o saque de %@.", receiver, server),
                icon: "bolt.fill",
                tintName: "red"
            )
        }

        let normalizedStatus = match.status.lowercased()
        if normalizedStatus.contains("match point") || normalizedStatus.contains("matchpoint") {
            let closer = match.serverName.isEmpty ? "quem saca" : match.serverName
            return WhyWatchNowMoment(
                kind: .matchPoint,
                headline: MatchPointLocalizedCopy.string("Match point"),
                detail: MatchPointLocalizedCopy.string("%@ pode fechar a partida neste ponto.", closer),
                icon: "flag.checkered",
                tintName: "orange"
            )
        }

        if normalizedStatus.contains("set point") || normalizedStatus.contains("setpoint") {
            return WhyWatchNowMoment(
                kind: .setPoint,
                headline: MatchPointLocalizedCopy.string("Set point"),
                detail: MatchPointLocalizedCopy.string("Este ponto pode fechar o set atual."),
                icon: "target",
                tintName: "orange"
            )
        }

        if match.isInTiebreak {
            return WhyWatchNowMoment(
                kind: .tiebreak,
                headline: MatchPointLocalizedCopy.string("Tie-break em andamento"),
                detail: MatchPointLocalizedCopy.string("Cada mini-break pesa dobrado. Quem abrir 2 pontos vira o set."),
                icon: "arrow.left.arrow.right.circle.fill",
                tintName: "yellow"
            )
        }

        if let swing = pointRun.swingExplanation {
            return WhyWatchNowMoment(
                kind: .comeback,
                headline: MatchPointLocalizedCopy.string("Virada em curso"),
                detail: swing,
                icon: "arrow.triangle.swap",
                tintName: "purple"
            )
        }

        let pressure = intelligence.liveContext.pressureScore
        if pressure >= 0.55 {
            return WhyWatchNowMoment(
                kind: .highPressure,
                headline: intelligence.liveContext.pressureLabel,
                detail: MatchPointLocalizedCopy.string("%@ x %@ num momento decisivo.", player1Name, player2Name),
                icon: "sparkles",
                tintName: "orange"
            )
        }

        return nil
    }

    private static func turningPoint(for match: TennisMatch, scoreboard: MatchScoreboardData, intelligence: MatchIntelligence, pointRun: MatchPointRunAnalyzer) -> String {
        if let swing = pointRun.swingExplanation {
            return swing
        }
        if intelligence.breakPointLabel != "Sem break point" {
            return MatchPointLocalizedCopy.string("O game virou zona de pressão porque quem recebe está a um ponto de quebrar.")
        }
        if let lastSet = scoreboard.sets.last, lastSet.player1Games == "7" || lastSet.player2Games == "7" {
            return MatchPointLocalizedCopy.string("O último set foi decidido no detalhe, então qualquer oscilação de saque importa.")
        }
        if match.pointScore.contains("40-40") || match.pointScore.localizedCaseInsensitiveContains("deuce") {
            return MatchPointLocalizedCopy.string("O game travou no iguais; quem ganhar dois pontos seguidos ganha controle emocional.")
        }
        if match.isLive {
            return MatchPointLocalizedCopy.string("Ainda não há ruptura clara, mas o saque atual define o ritmo do próximo game.")
        }
        return MatchPointLocalizedCopy.string("A leitura principal vem do placar final e da sequência recente dos jogadores.")
    }

    private static func whyItMatters(for match: TennisMatch, intelligence: MatchIntelligence, player1Name: String, player2Name: String) -> String {
        if intelligence.relevanceScore >= 90 {
            return MatchPointLocalizedCopy.string("Importa agora porque envolve favorito, placar vivo e chance real de mudar o roteiro da partida.")
        }
        if match.player1?.isFavorite == true || match.player2?.isFavorite == true {
            return MatchPointLocalizedCopy.string("Importa para você porque um dos seus jogadores favoritos está diretamente envolvido.")
        }
        if match.isUpcoming {
            return MatchPointLocalizedCopy.string("Importa antes do início porque é a melhor janela para previsão e alerta.")
        }
        return MatchPointLocalizedCopy.string("%@ e %@ ainda têm contexto útil para ranking, forma e retrospecto.", player1Name, player2Name)
    }

    private static func advancedSignals(for match: TennisMatch, intelligence: MatchIntelligence, pointRun: MatchPointRunAnalyzer) -> [String] {
        var signals: [String] = []
        if let serveRun = pointRun.serviceRunText {
            signals.append(serveRun)
        }
        if let importantGame = pointRun.importantGameText ?? importantGameText(for: match, intelligence: intelligence) {
            signals.append(importantGame)
        }
        if let swing = pointRun.swingExplanation {
            signals.append(swing)
        }
        return Array(signals.prefix(4))
    }

    private static func importantGameText(for match: TennisMatch, intelligence: MatchIntelligence) -> String? {
        if intelligence.breakPointLabel != "Sem break point" {
            let scoreText = match.gameScore.isEmpty ? MatchPointLocalizedCopy.string("placar pressionado") : MatchPointLocalizedCopy.string("games %@", match.gameScore)
            return MatchPointLocalizedCopy.string("Este é o game mais importante agora: break point com %@.", scoreText)
        }
        if match.status.localizedCaseInsensitiveContains("set point") {
            return MatchPointLocalizedCopy.string("Este game pode decidir o set.")
        }
        if match.status.localizedCaseInsensitiveContains("match point") {
            return MatchPointLocalizedCopy.string("Este game pode decidir a partida.")
        }
        return nil
    }

    private static func rankingImpact(for match: TennisMatch, rankings: [RankingEntry]) -> String? {
        let players = [match.player1, match.player2].compactMap { $0 }
        let ranked = players.compactMap { player -> (Player, RankingEntry)? in
            guard let entry = rankings.first(where: { $0.player?.id == player.id }) else { return nil }
            return (player, entry)
        }
        guard let best = ranked.min(by: { $0.1.rank < $1.1.rank }) else { return nil }
        if best.1.rank <= 5 {
            return MatchPointLocalizedCopy.string("Se vencer, %@ protege posição de elite e pressiona a briga pelo topo.", best.0.name)
        }
        if best.1.rank <= 20 {
            return MatchPointLocalizedCopy.string("Vitória pode aproximar %@ de cabeça de chave maior nas próximas semanas.", best.0.name)
        }
        return MatchPointLocalizedCopy.string("Resultado ajuda %@ a ganhar fôlego no ranking e no calendário.", best.0.name)
    }

    private static func keyStats(for match: TennisMatch, scoreboard: MatchScoreboardData, allMatches: [TennisMatch]) -> [String] {
        var values: [String] = []
        if !match.serverName.isEmpty {
            values.append(MatchPointLocalizedCopy.string("Saque atual: %@", match.serverName))
        }
        if !match.gameScore.isEmpty {
            values.append(MatchPointLocalizedCopy.string("Game atual: %@", match.gameScore))
        }
        if !scoreboard.sets.isEmpty {
            values.append(MatchPointLocalizedCopy.string("%d set(s) no placar", scoreboard.sets.count))
        }
        if let player1 = match.player1, let player2 = match.player2 {
            let h2h = allMatches.filter { $0.involves(player: player1) && $0.involves(player: player2) && $0.isCompleted }
            if !h2h.isEmpty {
                values.append(MatchPointLocalizedCopy.string("H2H registrado no app: %d jogo(s)", h2h.count))
            }
        }
        return Array(values.prefix(4))
    }

    private static func isMatchPoint(_ match: TennisMatch) -> Bool {
        match.status.localizedCaseInsensitiveContains("match point") ||
            match.status.localizedCaseInsensitiveContains("matchpoint")
    }
}

// MARK: - Live UX primitives

/// Which side of the court a recent point belongs to. `.unknown` covers rows in
/// the momentum timeline that we couldn't attribute to either player (padding
/// so the bar always renders a stable N-cell strip).
enum MomentumSide: Hashable {
    case player1
    case player2
    case unknown
}

/// One cell in the `MomentumBar`. `isEstimated` is true when we inferred the
/// winner heuristically from the timeline (title/detail mention) instead of
/// reading it from a real `pointWinnerName`.
struct MomentumPoint: Identifiable, Hashable {
    let id: Int
    let side: MomentumSide
    let isEstimated: Bool
}

/// Dramatic moment surfaced on `WhyWatchNowCard`. `nil` means the match is
/// running quietly and the card should hide entirely.
struct WhyWatchNowMoment: Equatable {
    enum Kind: String, Hashable {
        case breakPoint
        case matchPoint
        case setPoint
        case tiebreak
        case comeback
        case highPressure
    }

    let kind: Kind
    let headline: String
    let detail: String
    let icon: String
    let tintName: String
}

struct MatchPointRunAnalyzer {
    let match: TennisMatch

    private var playerNames: [String] {
        [match.player1?.name, match.player2?.name].compactMap { $0 }
    }

    /// Last-N momentum cells. Prefers real `pointWinnerName` from the
    /// timeline; when the provider hasn't populated any winner names, falls
    /// back to the same leader heuristic used by `LiveMatchInsights` and
    /// tags every cell as estimated so the UI can badge the row.
    func momentumTimeline(limit: Int = 10) -> [MomentumPoint] {
        let player1Name = match.player1?.name ?? ""
        let player2Name = match.player2?.name ?? ""
        let recent = Array(match.timelineEvents.suffix(limit))
        guard !recent.isEmpty, !player1Name.isEmpty || !player2Name.isEmpty else {
            return []
        }

        let hasWinners = recent.contains { $0.pointWinnerName?.isEmpty == false }

        if hasWinners {
            return recent.enumerated().map { index, event in
                let side = Self.side(for: event.pointWinnerName, player1Name: player1Name, player2Name: player2Name)
                return MomentumPoint(id: index, side: side, isEstimated: event.pointWinnerName?.isEmpty != false)
            }
        }

        return recent.enumerated().map { index, event in
            let text = "\(event.title) \(event.detail)"
            let matches1 = !player1Name.isEmpty && text.localizedCaseInsensitiveContains(player1Name)
            let matches2 = !player2Name.isEmpty && text.localizedCaseInsensitiveContains(player2Name)
            let side: MomentumSide
            switch (matches1, matches2) {
            case (true, false): side = .player1
            case (false, true): side = .player2
            default: side = .unknown
            }
            return MomentumPoint(id: index, side: side, isEstimated: true)
        }
    }

    private static func side(for winnerName: String?, player1Name: String, player2Name: String) -> MomentumSide {
        guard let winnerName, !winnerName.isEmpty else { return .unknown }
        if !player1Name.isEmpty,
           winnerName.localizedCaseInsensitiveContains(player1Name) || player1Name.localizedCaseInsensitiveContains(winnerName) {
            return .player1
        }
        if !player2Name.isEmpty,
           winnerName.localizedCaseInsensitiveContains(player2Name) || player2Name.localizedCaseInsensitiveContains(winnerName) {
            return .player2
        }
        return .unknown
    }

    var serviceRunText: String? {
        guard !match.serverName.isEmpty else { return nil }
        let stats = recentPointStats(for: match.serverName, limit: 10)
        if stats.total >= 4, stats.won > 0 {
            return MatchPointLocalizedCopy.string("%@ ganhou %d dos últimos %d pontos confirmados no saque.", match.serverName, stats.won, stats.total)
        }
        return nil
    }

    var importantGameText: String? {
        let recent = match.timelineEvents.suffix(8)
        let pressureHits = recent.filter { event in
            let text = "\(event.title) \(event.detail)".lowercased()
            return text.contains("break") || text.contains("set point") || text.contains("match point") || text.contains("40-40") || text.contains("deuce")
        }.count
        guard pressureHits >= 2 else { return nil }
        return MatchPointLocalizedCopy.string("Este foi o game mais carregado até aqui: %d eventos de pressão nos últimos %d registros.", pressureHits, recent.count)
    }

    var swingExplanation: String? {
        guard playerNames.count == 2 else { return nil }
        let recent = Array(match.timelineEvents.suffix(8))
        guard recent.count >= 4 else { return nil }

        let firstHalf = recent.prefix(recent.count / 2)
        let secondHalf = recent.suffix(recent.count / 2)
        let firstLeader = leader(in: Array(firstHalf))
        let secondLeader = leader(in: Array(secondHalf))

        if
            let firstLeader,
            let secondLeader,
            firstLeader != secondLeader
        {
            return MatchPointLocalizedCopy.string("O jogo virou porque %@ passou a dominar os registros recentes depois de uma sequência de %@.", secondLeader, firstLeader)
        }
        return nil
    }

    private func leader(in events: [MatchTimelineEvent]) -> String? {
        let confirmedEvents = events.filter { $0.pointWinnerName?.isEmpty == false }
        if !confirmedEvents.isEmpty {
            let confirmedCounts = playerNames.map { player in
                (
                    player,
                    confirmedEvents.filter {
                        guard let winner = $0.pointWinnerName else { return false }
                        return winner.localizedCaseInsensitiveContains(player) ||
                            player.localizedCaseInsensitiveContains(winner)
                    }.count
                )
            }
            guard let best = confirmedCounts.max(by: { $0.1 < $1.1 }), best.1 > 0 else { return nil }
            return best.0
        }

        let counts = playerNames.map { player in
            (
                player,
                events.filter {
                    $0.title.localizedCaseInsensitiveContains(player) ||
                        $0.detail.localizedCaseInsensitiveContains(player)
                }.count
            )
        }
        guard let best = counts.max(by: { $0.1 < $1.1 }), best.1 > 0 else { return nil }
        return best.0
    }

    private func recentPointStats(for playerName: String, limit: Int) -> (won: Int, total: Int) {
        let pointEvents = match.timelineEvents
            .filter { event in
                guard event.pointWinnerName != nil else { return false }
                guard let serverName = event.serverName else { return false }
                return serverName.localizedCaseInsensitiveContains(playerName) ||
                    playerName.localizedCaseInsensitiveContains(serverName)
            }
            .suffix(limit)
        let total = pointEvents.count
        let won = pointEvents.filter { event in
            guard let winner = event.pointWinnerName else { return false }
            return winner.localizedCaseInsensitiveContains(playerName) ||
                playerName.localizedCaseInsensitiveContains(winner)
        }.count
        return (won, total)
    }
}
