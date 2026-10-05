import OSLog
import SwiftUI
import SwiftData

// MARK: - Match Detail Support Sections
struct PreviousMatchesSection: View {
    @EnvironmentObject private var experienceStore: ExperiencePreferencesStore

    let currentMatch: TennisMatch
    let allMatches: [TennisMatch]
    let rankings: [RankingEntry]

    @State private var selectedPlayerIsOne: Bool = true

    private var selectedPlayer: Player? {
        selectedPlayerIsOne ? currentMatch.player1 : currentMatch.player2
    }

    private var history: [TennisMatch] {
        guard let player = selectedPlayer else { return [] }
        return allMatches
            .filter { $0.id != currentMatch.id && $0.isCompleted && $0.involves(player: player) }
            .prefix(6)
            .map { $0 }
    }

    var body: some View {
        if currentMatch.player1 != nil || currentMatch.player2 != nil {
            VStack(alignment: .leading, spacing: 12) {
                Text("Previous Matches")
                    .font(.headline)

                playerSelector

                if history.isEmpty {
                    Text("Sem histórico recente para \(selectedPlayer?.name ?? "este jogador").")
                        .font(.caption)
                        .foregroundStyle(Color.readableSecondary)
                        .padding(.top, 4)
                } else {
                    VStack(spacing: 8) {
                        ForEach(history) { match in
                            row(for: match)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var playerSelector: some View {
        let p1Name = currentMatch.player1.map { shortName($0.name) } ?? "Player 1"
        let p2Name = currentMatch.player2.map { shortName($0.name) } ?? "Player 2"
        Picker("Jogador", selection: $selectedPlayerIsOne) {
            Text(p1Name).tag(true)
            Text(p2Name).tag(false)
        }
        .pickerStyle(.segmented)
        .disabled(currentMatch.player1 == nil || currentMatch.player2 == nil)
    }

    @ViewBuilder
    private func row(for match: TennisMatch) -> some View {
        let player = selectedPlayer
        let opponent = player.flatMap { match.opponent(for: $0) }
        let didWin = player.flatMap { match.didPlayerWin($0) }
        let scoreboard = MatchScoreboardData(score: match.score)
        let roundLabel = MatchRoundResolver.roundLabel(for: match, allMatches: match.tournament?.matches ?? [match])
        let opponentRank = opponent.flatMap { o in rankings.first(where: { $0.player?.id == o.id })?.rank }
        let opponentFlag = CountryFlag.emoji(for: opponent?.nationality ?? "")

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(roundLabel.isEmpty ? (match.tournament?.name ?? "Match") : roundLabel)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.readableSecondary)
                Spacer()
                if let didWin {
                    Text(experienceStore.preferences.spoilerFreeMode ? "–" : (didWin ? "V" : "D"))
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(experienceStore.preferences.spoilerFreeMode ? Color.readableSecondary : (didWin ? Color.green : Color.red))
                        .frame(width: 16, height: 16)
                        .background(
                            Circle().fill((experienceStore.preferences.spoilerFreeMode ? Color.secondary : (didWin ? Color.green : Color.red)).opacity(0.15))
                        )
                }
            }

            HStack(spacing: 8) {
                if !opponentFlag.isEmpty {
                    Text(opponentFlag).font(.caption)
                }
                if let opponentRank {
                    Text("\(opponentRank)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color.readableSecondary)
                }
                Text(opponent.map { shortName($0.name) } ?? "—")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                HStack(spacing: 8) {
                    ForEach(scoreboard.sets) { set in
                        setColumn(set: set, didWin: didWin)
                    }
                }
            }
        }
        .padding(10)
        .background(Color.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private func setColumn(set: MatchScoreboardData.SetScore, didWin: Bool?) -> some View {
        let playerGames = selectedPlayerIsOne ? set.player1Games : set.player2Games
        let opponentGames = selectedPlayerIsOne ? set.player2Games : set.player1Games
        VStack(spacing: 2) {
            Text(experienceStore.preferences.spoilerFreeMode ? "–" : playerGames)
                .font(.caption.weight(.heavy))
                .monospacedDigit()
                .foregroundStyle(.primary)
            Text(experienceStore.preferences.spoilerFreeMode ? "–" : opponentGames)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(Color.readableSecondary)
        }
        .frame(minWidth: 16)
    }

    private func shortName(_ name: String) -> String {
        let parts = name.split(separator: " ").map(String.init)
        guard parts.count >= 2, let firstInitial = parts.first?.first else { return name }
        return "\(firstInitial). \(parts.last ?? "")"
    }
}

// Digest puro (sem dependência de View) que agrega os cálculos locais de H2H
// entre os dois jogadores da partida atual. Extraído pra permitir testes
// unitários e reuso caso outra superfície precise dos mesmos números.
struct HeadToHeadDigest {
    struct SurfaceSplit: Identifiable {
        let surface: String
        let player1Wins: Int
        let player2Wins: Int
        var id: String { surface }
        var total: Int { player1Wins + player2Wins }
    }

    let winsByPlayer1: Int
    let winsByPlayer2: Int
    let totalMeetings: Int
    let surfaceSplits: [SurfaceSplit]
    /// Sequência do jogador 1 nas últimas partidas: `true` = venceu, `false` =
    /// perdeu. Ordenado da mais recente pra mais antiga (index 0 é a última).
    let recentPlayer1Outcomes: [Bool]
    let currentStreak: (winnerName: String, count: Int)?
    let lastEncounterID: UUID?

    static func compute(currentMatch: TennisMatch, allMatches: [TennisMatch]) -> HeadToHeadDigest {
        guard let p1 = currentMatch.player1, let p2 = currentMatch.player2 else {
            return HeadToHeadDigest(
                winsByPlayer1: 0,
                winsByPlayer2: 0,
                totalMeetings: 0,
                surfaceSplits: [],
                recentPlayer1Outcomes: [],
                currentStreak: nil,
                lastEncounterID: nil
            )
        }

        let matches = allMatches
            .filter { $0.id != currentMatch.id && $0.isCompleted }
            .filter { $0.involves(player: p1) && $0.involves(player: p2) }
            .sorted { $0.date > $1.date }

        var w1 = 0
        var w2 = 0
        var buckets: [String: (Int, Int)] = [:]
        var outcomes: [Bool] = []

        for m in matches {
            let p1Won = m.didPlayerWin(p1) == true
            let p2Won = m.didPlayerWin(p2) == true

            if p1Won { w1 += 1 }
            else if p2Won { w2 += 1 }

            if p1Won || p2Won {
                outcomes.append(p1Won)
                let raw = m.tournament?.surface.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let surface = raw.isEmpty ? "Outros" : raw
                var current = buckets[surface] ?? (0, 0)
                if p1Won { current.0 += 1 } else { current.1 += 1 }
                buckets[surface] = current
            }
        }

        var streakEntry: (String, Int)? = nil
        if let first = matches.first {
            let leader: Player? = {
                if first.didPlayerWin(p1) == true { return p1 }
                if first.didPlayerWin(p2) == true { return p2 }
                return nil
            }()
            if let leader {
                var count = 0
                for m in matches {
                    if m.didPlayerWin(leader) == true { count += 1 } else { break }
                }
                if count >= 2 { streakEntry = (leader.name, count) }
            }
        }

        let splits = buckets
            .map { SurfaceSplit(surface: $0.key, player1Wins: $0.value.0, player2Wins: $0.value.1) }
            .filter { $0.total > 0 }
            .sorted { $0.total > $1.total }

        return HeadToHeadDigest(
            winsByPlayer1: w1,
            winsByPlayer2: w2,
            totalMeetings: matches.count,
            surfaceSplits: splits,
            recentPlayer1Outcomes: Array(outcomes.prefix(6)),
            currentStreak: streakEntry,
            lastEncounterID: matches.first?.id
        )
    }
}

// Card de destaque exibido no topo da aba "Resumo" da partida. Diferente do
// `HeadToHeadSection` (que consulta a API sob demanda), este card usa apenas
// o histórico local de partidas encerradas — os dois jogadores já sincronizados
// no SwiftData bastam. Isso garante que o H2H aparece instantaneamente na
// abertura da tela, sem botão "Carregar" e sem loading state.
//
// Só renderiza quando há pelo menos 1 encontro no histórico local (senão vira
// EmptyView e ocupa 0 pixels), evitando poluir jogos onde o primeiro encontro
// entre os jogadores é justamente o atual.
struct HeadToHeadHeroCard: View {
    @EnvironmentObject private var experienceStore: ExperiencePreferencesStore

    let match: TennisMatch
    let allMatches: [TennisMatch]

    private var digest: HeadToHeadDigest {
        HeadToHeadDigest.compute(currentMatch: match, allMatches: allMatches)
    }

    private var lastEncounter: TennisMatch? {
        guard let id = digest.lastEncounterID else { return nil }
        return allMatches.first { $0.id == id }
    }

    var body: some View {
        if digest.totalMeetings == 0 {
            EmptyView()
        } else {
            content
        }
    }

    private var content: some View {
        let total = digest.winsByPlayer1 + digest.winsByPlayer2
        let spoilerFree = experienceStore.preferences.spoilerFreeMode
        let leftRatio = spoilerFree ? 0.5 : (total > 0 ? Double(digest.winsByPlayer1) / Double(total) : 0.5)

        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "person.2.wave.2.fill")
                    .font(.subheadline.weight(.heavy))
                    .foregroundStyle(.teal)
                Text("Head-to-head")
                    .font(.headline.weight(.heavy))
                Spacer()
                Text("\(digest.totalMeetings) encontro\(digest.totalMeetings == 1 ? "" : "s")")
                    .font(.caption2.monospacedDigit().weight(.heavy))
                    .foregroundStyle(Color.readableSecondary)
            }

            HStack(alignment: .center, spacing: 14) {
                h2hSideColumn(
                    name: match.player1?.name ?? "P1",
                    nationality: match.player1?.nationality ?? "",
                    wins: spoilerFree ? nil : digest.winsByPlayer1,
                    isLeading: !spoilerFree && digest.winsByPlayer1 > digest.winsByPlayer2,
                    isTrailing: false
                )
                Text("vs")
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(Color.readableSecondary)
                h2hSideColumn(
                    name: match.player2?.name ?? "P2",
                    nationality: match.player2?.nationality ?? "",
                    wins: spoilerFree ? nil : digest.winsByPlayer2,
                    isLeading: !spoilerFree && digest.winsByPlayer2 > digest.winsByPlayer1,
                    isTrailing: true
                )
            }

            AppleSportsStatBar(
                leftValue: spoilerFree ? "–" : "\(digest.winsByPlayer1)",
                label: "Vitórias",
                rightValue: spoilerFree ? "–" : "\(digest.winsByPlayer2)",
                leftRatio: leftRatio
            )

            if !digest.recentPlayer1Outcomes.isEmpty, !spoilerFree {
                VStack(alignment: .leading, spacing: 6) {
                    Text("ÚLTIMOS ENCONTROS")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(Color.readableSecondary)
                    HStack(spacing: 6) {
                        // Renderiza da mais antiga pra mais recente pra o
                        // usuário ler cronologicamente da esquerda pra direita.
                        ForEach(Array(digest.recentPlayer1Outcomes.reversed().enumerated()), id: \.offset) { _, isPlayer1Win in
                            recentDot(isPlayer1Win: isPlayer1Win)
                        }
                        Spacer(minLength: 0)
                        Text("mais recente →")
                            .font(.system(size: 8, weight: .heavy))
                            .foregroundStyle(Color.readableSecondary)
                    }
                }
            }

            if let streak = digest.currentStreak, !spoilerFree {
                Label {
                    Text("\(streak.winnerName) venceu os últimos \(streak.count).")
                        .font(.caption.weight(.semibold))
                } icon: {
                    Image(systemName: "flame.fill")
                        .foregroundStyle(.orange)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.orange.opacity(0.14), in: Capsule())
            }

            if !digest.surfaceSplits.isEmpty, !spoilerFree {
                VStack(alignment: .leading, spacing: 6) {
                    Text("POR SUPERFÍCIE")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(Color.readableSecondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(digest.surfaceSplits) { split in
                                surfacePill(split)
                            }
                        }
                    }
                }
            }

            if let last = lastEncounter {
                lastEncounterRow(match: last)
            }
        }
        .padding(16)
        .background(
            LinearGradient(
                colors: [Color.teal.opacity(0.20), Color.teal.opacity(0.08)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.teal.opacity(0.28), lineWidth: 1)
        )
    }

    private func h2hSideColumn(name: String, nationality: String, wins: Int?, isLeading: Bool, isTrailing: Bool) -> some View {
        VStack(alignment: isTrailing ? .trailing : .leading, spacing: 4) {
            HStack(spacing: 5) {
                if isTrailing { Spacer(minLength: 0) }
                let flag = CountryFlag.emoji(for: nationality)
                if !flag.isEmpty {
                    Text(flag).font(.subheadline)
                }
                Text(shortName(name))
                    .font(.subheadline.weight(.heavy))
                    .lineLimit(1)
                if !isTrailing { Spacer(minLength: 0) }
            }
            Text(wins.map(String.init) ?? "–")
                .font(.system(size: 34, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(isLeading ? Color.green : Color.primary)
                .frame(maxWidth: .infinity, alignment: isTrailing ? .trailing : .leading)
        }
        .frame(maxWidth: .infinity)
    }

    private func recentDot(isPlayer1Win: Bool) -> some View {
        ZStack {
            Circle()
                .fill((isPlayer1Win ? Color.green : Color.orange).opacity(0.22))
            Text(isPlayer1Win ? "1" : "2")
                .font(.system(size: 9, weight: .heavy))
                .foregroundStyle(isPlayer1Win ? Color.green : Color.orange)
        }
        .frame(width: 20, height: 20)
    }

    private func surfacePill(_ split: HeadToHeadDigest.SurfaceSplit) -> some View {
        HStack(spacing: 6) {
            Image(systemName: surfaceSymbol(split.surface))
                .font(.caption2)
                .foregroundStyle(surfaceTint(split.surface))
            Text(split.surface)
                .font(.caption2.weight(.heavy))
            Text("\(split.player1Wins)-\(split.player2Wins)")
                .font(.caption2.monospacedDigit().weight(.bold))
                .foregroundStyle(Color.readableSecondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(surfaceTint(split.surface).opacity(0.14), in: Capsule())
    }

    private func lastEncounterRow(match last: TennisMatch) -> some View {
        let winnerName: String? = {
            if let p1 = match.player1, last.didPlayerWin(p1) == true { return p1.name }
            if let p2 = match.player2, last.didPlayerWin(p2) == true { return p2.name }
            return nil
        }()

        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.caption.weight(.heavy))
                .foregroundStyle(.teal)
            VStack(alignment: .leading, spacing: 2) {
                Text("ÚLTIMO ENCONTRO")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(Color.readableSecondary)
                Text(experienceStore.preferences.spoilerFreeMode ? "Resultado oculto pelo modo spoiler-free." : lastEncounterHeadline(last, winnerName: winnerName))
                    .font(.caption.weight(.semibold))
                if !last.score.isEmpty, !experienceStore.preferences.spoilerFreeMode {
                    Text(last.score)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Color.readableSecondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.black.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func lastEncounterHeadline(_ last: TennisMatch, winnerName: String?) -> String {
        let date = last.date.formatted(.dateTime.month(.abbreviated).day().year())
        let tournamentPiece = last.tournament?.name ?? ""
        let winnerPiece = winnerName.map { "\($0) venceu" } ?? "Resultado"
        return [winnerPiece, tournamentPiece, date]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private func surfaceSymbol(_ surface: String) -> String {
        let lower = surface.lowercased()
        if lower.contains("clay") || lower.contains("saibro") { return "circle.dashed" }
        if lower.contains("grass") || lower.contains("grama") { return "leaf.fill" }
        if lower.contains("hard") || lower.contains("duro") { return "square.grid.2x2" }
        if lower.contains("carpet") { return "rectangle.checkered" }
        return "sportscourt"
    }

    private func surfaceTint(_ surface: String) -> Color {
        let lower = surface.lowercased()
        if lower.contains("clay") || lower.contains("saibro") { return .orange }
        if lower.contains("grass") || lower.contains("grama") { return .green }
        if lower.contains("hard") || lower.contains("duro") { return .blue }
        if lower.contains("carpet") { return .purple }
        return .teal
    }

    private func shortName(_ name: String) -> String {
        let parts = name.split(separator: " ").map(String.init)
        guard parts.count >= 2, let firstInitial = parts.first?.first else { return name }
        return "\(firstInitial). \(parts.last ?? "")"
    }
}

struct HeadToHeadSection: View {
    @Environment(\.modelContext) private var context
    let match: TennisMatch

    @State private var results: [H2HMatchDTO] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var hasFetched = false

    private var firstPlayerKey: String? {
        let key = match.player1?.externalKey ?? ""
        return key.isEmpty ? nil : key
    }

    private var secondPlayerKey: String? {
        let key = match.player2?.externalKey ?? ""
        return key.isEmpty ? nil : key
    }

    private var canFetch: Bool {
        firstPlayerKey != nil && secondPlayerKey != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Head-to-Head")
                    .font(.headline)
                Spacer()
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button {
                        Task { await loadH2H() }
                    } label: {
                        Label(hasFetched ? "Atualizar" : "Carregar", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!canFetch)
                }
            }

            if !canFetch {
                Text("H2H exige IDs externos de ambos os jogadores. Sincronize jogadores antes.")
                    .font(.caption)
                    .foregroundStyle(Color.readableSecondary)
            } else if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if hasFetched && results.isEmpty {
                Text("Sem histórico H2H disponível para esses jogadores.")
                    .font(.caption)
                    .foregroundStyle(Color.readableSecondary)
            } else if !results.isEmpty {
                let totals = totalsByPlayer
                HStack(spacing: 16) {
                    h2hTotalCard(name: match.player1?.name ?? "Player 1", wins: totals.first)
                    Text("vs")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Color.readableSecondary)
                    h2hTotalCard(name: match.player2?.name ?? "Player 2", wins: totals.second)
                }

                VStack(alignment: .leading, spacing: 10) {
                    ForEach(results.prefix(10)) { row in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(row.tournamentName)
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Text(row.date.formatted(date: .abbreviated, time: .omitted))
                                    .font(.caption)
                                    .foregroundStyle(Color.readableSecondary)
                            }
                            HStack {
                                Text("\(row.firstPlayerName) vs \(row.secondPlayerName)")
                                    .font(.caption)
                                    .foregroundStyle(Color.readableSecondary)
                                Spacer()
                                Text(row.finalResult.isEmpty ? "—" : row.finalResult)
                                    .font(.caption.weight(.semibold))
                            }
                            if !row.winner.isEmpty {
                                Text("Vencedor: \(row.winner)")
                                    .font(.caption2)
                                    .foregroundStyle(.green)
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.cardSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
            }
        }
    }

    private var totalsByPlayer: (first: Int, second: Int) {
        guard let first = match.player1?.name, let second = match.player2?.name else { return (0, 0) }
        var firstWins = 0
        var secondWins = 0
        for row in results {
            let winner = row.winner.lowercased()
            if !winner.isEmpty {
                if winner.contains(first.lowercased()) {
                    firstWins += 1
                } else if winner.contains(second.lowercased()) {
                    secondWins += 1
                }
            }
        }
        return (firstWins, secondWins)
    }

    private func h2hTotalCard(name: String, wins: Int) -> some View {
        VStack(spacing: 4) {
            Text("\(wins)")
                .font(.title2.weight(.heavy))
            Text(name)
                .font(.caption)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color.white.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @MainActor
    private func loadH2H() async {
        guard let firstPlayerKey, let secondPlayerKey else { return }
        isLoading = true
        defer {
            isLoading = false
            hasFetched = true
        }
        errorMessage = nil
        do {
            let service = DataSyncService(context: context)
            results = try await service.headToHead(
                firstPlayerKey: firstPlayerKey,
                secondPlayerKey: secondPlayerKey
            )
        } catch {
            results = []
            errorMessage = service(error: error)
        }
    }

    private func service(error: Error) -> String {
        let service = DataSyncService(context: context)
        return service.userFacingMessage(for: error)
    }
}

struct OddsSection: View {
    @Environment(\.modelContext) private var context
    let match: TennisMatch

    @State private var preMatch: [OddsDTO] = []
    @State private var live: [LiveOddsDTO] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var hasFetched = false

    private var matchKey: String? {
        let key = match.externalID ?? ""
        return key.isEmpty ? nil : key
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Odds")
                    .font(.headline)
                Spacer()
                if isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        Task { await loadOdds() }
                    } label: {
                        Label(hasFetched ? "Atualizar" : "Carregar", systemImage: "dollarsign.circle")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(matchKey == nil)
                }
            }

            if matchKey == nil {
                Text("Odds exigem ID externo da partida. Sincronize antes.")
                    .font(.caption)
                    .foregroundStyle(Color.readableSecondary)
            } else if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if hasFetched && preMatch.isEmpty && live.isEmpty {
                Text("Nenhuma odd publicada para essa partida no momento.")
                    .font(.caption)
                    .foregroundStyle(Color.readableSecondary)
            } else {
                if !live.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Live")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.red)
                        ForEach(live.prefix(8)) { row in
                            liveOddsRow(row)
                        }
                    }
                }

                if !preMatch.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Pré-jogo")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.blue)
                        ForEach(preMatch.prefix(12)) { row in
                            preMatchOddsRow(row)
                        }
                    }
                }
            }
        }
    }

    private func liveOddsRow(_ row: LiveOddsDTO) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.bookmakerName)
                    .font(.caption.weight(.semibold))
                Text("Atualizado \(row.updatedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(Color.readableSecondary)
            }
            Spacer()
            HStack(spacing: 8) {
                oddsChip(label: "1", value: row.homeOdd, accent: .green)
                oddsChip(label: "2", value: row.awayOdd, accent: .blue)
            }
        }
        .padding(10)
        .background(Color.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func preMatchOddsRow(_ row: OddsDTO) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.bookmakerName)
                    .font(.caption.weight(.semibold))
                Text(row.market)
                    .font(.caption2)
                    .foregroundStyle(Color.readableSecondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(row.outcome)
                    .font(.caption)
                Text(row.value)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.green)
            }
        }
        .padding(10)
        .background(Color.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func oddsChip(label: String, value: String, accent: Color) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(Color.readableSecondary)
            Text(value)
                .font(.subheadline.weight(.heavy))
                .foregroundStyle(accent)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(accent.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @MainActor
    private func loadOdds() async {
        guard let matchKey else { return }
        isLoading = true
        defer {
            isLoading = false
            hasFetched = true
        }
        errorMessage = nil
        let service = DataSyncService(context: context)

        async let preFetch = fetch(label: "preMatch", fallback: [OddsDTO]()) {
            try await service.odds(matchKey: matchKey)
        }
        async let liveFetch = fetch(label: "live", fallback: [LiveOddsDTO]()) {
            try await service.liveOdds(matchKey: matchKey)
        }
        let (pre, lv) = await (preFetch, liveFetch)
        preMatch = pre.values
        live = lv.values

        if let message = [pre.error, lv.error].compactMap({ $0 }).first {
            errorMessage = message
        }
    }

    private struct OddsFetchResult<Value> {
        let values: Value
        let error: String?
    }

    private func fetch<Value>(label: String, fallback: Value, _ work: () async throws -> Value) async -> OddsFetchResult<Value> {
        do {
            return OddsFetchResult(values: try await work(), error: nil)
        } catch {
            AppLogger.api.error("odds.\(label, privacy: .public) failed: \(AppLogger.message(for: error), privacy: .private)")
            AppLogger.recordFailure(category: "api", operation: "odds.\(label)", error: error)
            return OddsFetchResult(values: fallback, error: "Não foi possível carregar odds (\(label)).")
        }
    }
}
