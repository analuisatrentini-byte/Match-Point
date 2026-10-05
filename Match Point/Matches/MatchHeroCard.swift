import SwiftUI
import SwiftData

struct CachedMatchHeroCard: View {
    let match: TennisMatch
    let rankings: [RankingEntry]
    let allMatches: [TennisMatch]

    @State private var cachedSignature: String
    @State private var cachedIntelligence: MatchIntelligence

    init(match: TennisMatch, rankings: [RankingEntry], allMatches: [TennisMatch]) {
        self.match = match
        self.rankings = rankings
        self.allMatches = allMatches
        let initialSignature = Self.signature(for: match, rankings: rankings, allMatches: allMatches)
        _cachedSignature = State(initialValue: initialSignature)
        _cachedIntelligence = State(initialValue: MatchIntelligence(match: match, rankings: rankings, allMatches: allMatches))
    }

    private var signature: String {
        Self.signature(for: match, rankings: rankings, allMatches: allMatches)
    }

    private static func signature(for match: TennisMatch, rankings: [RankingEntry], allMatches: [TennisMatch]) -> String {
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
            String(rankings.count),
            String(allMatches.count)
        ].joined(separator: "|")
    }

    var body: some View {
        MatchHeroCard(
            match: match,
            intelligence: cachedIntelligence,
            rankings: rankings
        )
        .onAppear(perform: refreshIfNeeded)
        .onChange(of: signature) { _, _ in
            refreshIfNeeded()
        }
    }

    private func refreshIfNeeded() {
        let currentSignature = signature
        guard cachedSignature != currentSignature else { return }
        cachedSignature = currentSignature
        cachedIntelligence = MatchIntelligence(match: match, rankings: rankings, allMatches: allMatches)
    }
}

struct MatchHeroCard: View {
    @EnvironmentObject private var behaviorStore: BehaviorPersonalizationStore
    @EnvironmentObject private var experienceStore: ExperiencePreferencesStore
    @ScaledMetric(relativeTo: .largeTitle) private var scoreFontSize = 56

    let match: TennisMatch
    let intelligence: MatchIntelligence
    var rankings: [RankingEntry] = []

    private var scoreboard: MatchScoreboardData {
        MatchScoreboardData(score: match.score)
    }

    private var relevanceReasons: [MatchRelevanceReason] {
        let rankLookup = Dictionary(
            rankings.compactMap { entry -> (UUID, Int)? in
                guard let playerID = entry.player?.id else { return nil }
                return (playerID, entry.rank)
            },
            uniquingKeysWith: { first, _ in first }
        )
        return MatchIntelligence.relevanceReasons(
            for: match,
            rankByPlayerID: rankLookup,
            behavior: behaviorStore.snapshot
        )
    }

    private var player1SetsWon: Int { setsWon(forPlayerOne: true) }
    private var player2SetsWon: Int { setsWon(forPlayerOne: false) }

    private var player1Rank: Int? {
        guard let player = match.player1 else { return nil }
        return rankings.first(where: { $0.player?.id == player.id })?.rank
    }

    private var player2Rank: Int? {
        guard let player = match.player2 else { return nil }
        return rankings.first(where: { $0.player?.id == player.id })?.rank
    }

    private var player1IsServing: Bool {
        isServing(match.player1?.name)
    }

    private var player2IsServing: Bool {
        isServing(match.player2?.name)
    }

    private var hidesResultSpoilers: Bool {
        experienceStore.preferences.spoilerFreeMode && match.isCompleted
    }

    private var headerLine: String {
        var fragments: [String] = []
        if let name = match.tournament?.name, !name.isEmpty {
            fragments.append(name)
        }
        let round = intelligence.roundLabel
        if !round.isEmpty {
            fragments.append(round)
        }
        return fragments.joined(separator: " · ")
    }

    private var centerTopText: String {
        if match.isLive {
            return "Set \(scoreboard.sets.count + 1)"
        }
        if match.isCompleted {
            return hidesResultSpoilers ? "SPOILER-FREE" : "FINAL"
        }
        return match.date.formatted(.dateTime.weekday(.short).hour().minute())
    }

    private var centerBottomText: String {
        if match.isLive {
            if !match.pointScore.isEmpty {
                return match.pointScore.replacingOccurrences(of: "-", with: " - ")
            }
            if !match.gameScore.isEmpty {
                return match.gameScore
            }
            return ""
        }
        if !match.isLive && !match.isCompleted {
            return match.tournament?.city ?? ""
        }
        return ""
    }

    var body: some View {
        VStack(spacing: 14) {
            headerBar

            scoreRow

            playerRow

            if scoreboard.hasSets {
                scoreboardTable
            }

            footerRow

            if !relevanceReasons.isEmpty {
                relevanceReasonRow
            }
        }
        .liquidGlassCard(cornerRadius: 22, padding: 18)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var relevanceReasonRow: some View {
        // Always-visible "Por que estou vendo isso?" surface. Inline (not behind a
        // tap) because the card sits inside a NavigationLink — a button would
        // either steal the row tap or get swallowed by it. Cap to the 3 strongest
        // factors so the row stays compact even when every signal fires.
        VStack(alignment: .leading, spacing: 6) {
            Text("Por que está aqui")
                .font(.caption2.weight(.bold))
                .foregroundStyle(Color.readableSecondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(relevanceReasons.prefix(3)) { reason in
                        HStack(spacing: 4) {
                            Image(systemName: reason.symbol)
                                .font(.caption2)
                            Text(reason.label)
                                .font(.caption2.weight(.semibold))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.14))
                        .clipShape(Capsule())
                        .foregroundStyle(.white)
                    }
                }
            }
        }
    }

    private var accessibilitySummary: String {
        let p1 = match.player1TeamName
        let p2 = match.player2TeamName
        var parts: [String] = []
        if match.isLive {
            parts.append("Partida ao vivo")
        } else if match.isCompleted {
            parts.append("Partida encerrada")
        } else {
            parts.append("Partida agendada")
        }
        if !headerLine.isEmpty {
            parts.append(headerLine)
        }
        parts.append("\(p1) versus \(p2)")
        if hidesResultSpoilers {
            parts.append("Resultado oculto pelo modo spoiler-free")
        } else {
            parts.append("Sets: \(player1SetsWon) a \(player2SetsWon)")
        }
        if match.isLive, !match.pointScore.isEmpty {
            parts.append("Pontos: \(match.pointScore)")
        }
        if match.isLive, !match.serverName.isEmpty {
            parts.append("Saque com \(match.serverName)")
        }
        if match.isFavorite {
            parts.append("Favorito")
        }
        let topReasons = relevanceReasons.prefix(3).map(\.label)
        if !topReasons.isEmpty {
            parts.append("Aparece aqui por: \(topReasons.joined(separator: ", "))")
        }
        return parts.joined(separator: ". ")
    }

    private var headerBar: some View {
        HStack(spacing: 8) {
            if match.isLive {
                Circle()
                    .fill(Color.red)
                    .frame(width: 7, height: 7)
                Text("LIVE")
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(.white)
            }
            Text(headerLine.isEmpty ? "Partida" : headerLine)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: match.isLive ? .leading : .center)
            // O ícone de estrela inline foi removido daqui. O status "favorito"
            // já é mostrado de duas formas que NÃO duplicam:
            //  • Chip "Partida favoritada" no `relevanceReasonRow` quando o
            //    Match Brain pontua isFavorite (+40).
            //  • Estrela amarela na toolbar do `MatchDetailView` via
            //    `favoriteToolbar`, junto da única ação canônica de favoritar.
            // Manter o ícone aqui criava a impressão de que era tappable e
            // competia com o swipe-action (`favoriteSwipeAction`) — único
            // canal de toggle padronizado em todas as listas.
        }
    }

    private var scoreRow: some View {
        HStack(alignment: .center, spacing: 14) {
            Text(hidesResultSpoilers ? "–" : "\(player1SetsWon)")
                .font(.system(size: min(scoreFontSize, 74), weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .monospacedDigit()
                .minimumScaleFactor(0.55)
                .frame(maxWidth: .infinity)

            VStack(spacing: 4) {
                Text(centerTopText)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if !centerBottomText.isEmpty {
                    Text(centerBottomText)
                        .font(.callout.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            .frame(minWidth: 80)

            Text(hidesResultSpoilers ? "–" : "\(player2SetsWon)")
                .font(.system(size: min(scoreFontSize, 74), weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .monospacedDigit()
                .minimumScaleFactor(0.55)
                .frame(maxWidth: .infinity)
        }
    }

    private var playerRow: some View {
        HStack(alignment: .center, spacing: 12) {
            playerBadge(
                name: match.player1TeamName,
                nationality: match.player1?.nationality ?? "",
                rank: player1Rank,
                isServing: player1IsServing,
                tint: Color.orange
            )

            Spacer(minLength: 8)

            playerBadge(
                name: match.player2TeamName,
                nationality: match.player2?.nationality ?? "",
                rank: player2Rank,
                isServing: player2IsServing,
                tint: Color.blue,
                trailing: true
            )
        }
    }

    private func playerBadge(name: String, nationality: String, rank: Int?, isServing: Bool, tint: Color, trailing: Bool = false) -> some View {
        HStack(spacing: 10) {
            if trailing {
                nameStack(name: name, rank: rank, isServing: isServing, trailing: true)
                avatar(for: name, nationality: nationality, tint: tint)
            } else {
                avatar(for: name, nationality: nationality, tint: tint)
                nameStack(name: name, rank: rank, isServing: isServing, trailing: false)
            }
        }
    }

    private func avatar(for name: String, nationality: String, tint: Color) -> some View {
        let flag = CountryFlag.emoji(for: nationality)
        return Circle()
            .fill(tint)
            .frame(width: 38, height: 38)
            .overlay {
                Text(initials(for: name))
                    .font(.subheadline.weight(.heavy))
                    .foregroundStyle(.white)
            }
            .overlay(
                Circle().stroke(Color.cardSurfaceStroke, lineWidth: 1)
            )
            .overlay(alignment: .bottomTrailing) {
                if !flag.isEmpty {
                    Text(flag)
                        .font(.callout)
                        .padding(1)
                        .background(Circle().fill(Color.black.opacity(0.6)))
                        .overlay(Circle().stroke(Color.white.opacity(0.4), lineWidth: 0.5))
                        .offset(x: 3, y: 3)
                }
            }
    }

    private func nameStack(name: String, rank: Int?, isServing: Bool, trailing: Bool) -> some View {
        VStack(alignment: trailing ? .trailing : .leading, spacing: 2) {
            HStack(spacing: 5) {
                if trailing {
                    if isServing { tennisBallDot }
                    if let rank {
                        Text("\(rank)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Color.readableSecondary)
                    }
                    Text(shortName(name))
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                } else {
                    if let rank {
                        Text("\(rank)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Color.readableSecondary)
                    }
                    Text(shortName(name))
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                    if isServing { tennisBallDot }
                }
            }
            .lineLimit(1)
        }
    }

    private var tennisBallDot: some View {
        Circle()
            .fill(Color(red: 0.85, green: 0.95, blue: 0.30))
            .frame(width: 8, height: 8)
            .overlay(
                Circle().stroke(Color.white.opacity(0.5), lineWidth: 0.5)
            )
    }

    private var scoreboardTable: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(match.isLive ? "Live" : (match.isCompleted ? "Final" : "Agendada"))
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(.white.opacity(0.85))
                Text(shortName(match.player1TeamName))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                Text(shortName(match.player2TeamName))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }

            Spacer(minLength: 8)

            if hidesResultSpoilers {
                Text("Resultado oculto pelo modo spoiler-free")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))
            } else {
                HStack(spacing: 10) {
                    ForEach(scoreboard.sets) { set in
                        VStack(spacing: 4) {
                            Text("\(set.id + 1)")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(Color.readableSecondary)
                            Text(set.player1Games)
                                .font(.caption.weight(.heavy))
                                .monospacedDigit()
                                .foregroundStyle(.white)
                            Text(set.player2Games)
                                .font(.caption.weight(.heavy))
                                .monospacedDigit()
                                .foregroundStyle(.white.opacity(0.9))
                        }
                        .frame(minWidth: 18)
                    }
                }
            }
        }
        .padding(12)
        .background(Color.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var footerRow: some View {
        HStack(spacing: 8) {
            Text(intelligence.relevanceLabel)
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.18))
                .clipShape(Capsule())
                .foregroundStyle(.white)

            Text(hidesResultSpoilers ? "Resultado oculto pelo modo spoiler-free." : intelligence.summary)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let updatedAt = match.lastUpdatedAt, match.isLive {
                Text(updatedAt, format: .dateTime.hour().minute().second())
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Color.readableSecondary)
            }
        }
    }

    private var surfaceGradient: LinearGradient {
        let surface = (match.tournament?.surface ?? "").lowercased()
        let colors: [Color]
        if surface.contains("grass") || surface.contains("grama") {
            colors = [
                Color(red: 0.28, green: 0.58, blue: 0.30),
                Color(red: 0.08, green: 0.28, blue: 0.14)
            ]
        } else if surface.contains("clay") || surface.contains("saibro") {
            colors = [
                Color(red: 0.78, green: 0.42, blue: 0.26),
                Color(red: 0.42, green: 0.18, blue: 0.10)
            ]
        } else if surface.contains("hard") || surface.contains("dura") {
            colors = [
                Color(red: 0.22, green: 0.45, blue: 0.72),
                Color(red: 0.06, green: 0.18, blue: 0.38)
            ]
        } else {
            colors = [
                Color(red: 0.20, green: 0.24, blue: 0.32),
                Color(red: 0.06, green: 0.09, blue: 0.16)
            ]
        }
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private func setsWon(forPlayerOne: Bool) -> Int {
        scoreboard.sets.reduce(into: 0) { partial, set in
            let p1 = Int(set.player1Games) ?? 0
            let p2 = Int(set.player2Games) ?? 0
            if forPlayerOne {
                if p1 > p2 { partial += 1 }
            } else {
                if p2 > p1 { partial += 1 }
            }
        }
    }

    private func isServing(_ playerName: String?) -> Bool {
        guard let playerName, !playerName.isEmpty, !match.serverName.isEmpty else { return false }
        return match.serverName.localizedCaseInsensitiveContains(playerName)
            || playerName.localizedCaseInsensitiveContains(match.serverName)
    }

    private func initials(for name: String) -> String {
        let parts = name.split(separator: " ")
        let first = parts.first?.first.map(String.init) ?? ""
        let last = parts.dropFirst().last?.first.map(String.init) ?? ""
        let combined = (first + last).uppercased()
        return combined.isEmpty ? "?" : combined
    }

    private func shortName(_ name: String) -> String {
        let parts = name.split(separator: " ").map(String.init)
        guard parts.count >= 2, let firstInitial = parts.first?.first else { return name }
        return "\(firstInitial). \(parts.last ?? "")"
    }
}
