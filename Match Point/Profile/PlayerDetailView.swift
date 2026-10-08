import SwiftUI
import SwiftData

struct PlayerProfileInsights {
    struct HeadToHeadSummary: Identifiable {
        let opponent: Player
        let wins: Int
        let losses: Int
        /// W/L split by canonical surface bucket (Hard / Clay / Grass / Other).
        /// Empty buckets are dropped before the row reaches the UI so the chip
        /// strip only shows surfaces where the pair has actually met.
        let bySurface: [SurfaceRecord]

        var id: UUID { opponent.id }

        var record: String { "\(wins)-\(losses)" }
    }

    struct SurfaceRecord: Identifiable, Hashable {
        let surface: String
        let wins: Int
        let losses: Int

        var id: String { surface }
        var matches: Int { wins + losses }
        var winRate: Double {
            guard matches > 0 else { return 0 }
            return Double(wins) / Double(matches)
        }
        var winRateText: String {
            guard matches > 0 else { return "—" }
            return "\(Int(winRate * 100))%"
        }
    }

    let rank: Int?
    let points: Int?
    let recentForm: [Bool]
    let nextMatch: TennisMatch?
    let upcomingMatches: [TennisMatch]
    let recentHistory: [TennisMatch]
    let rankingProjectionText: String?
    let titles: Int
    let wins: Int
    let losses: Int
    let liveMatches: Int
    let headToHead: [HeadToHeadSummary]
    /// Per-surface W/L for the player. Ordered Hard → Clay → Grass → Other so
    /// the UI renders the canonical Tour-circuit order.
    let surfaceRecords: [SurfaceRecord]

    init(player: Player, matches: [TennisMatch], rankings: [RankingEntry]) {
        let playerMatches = matches
            .filter { $0.involves(player: player) }
            .sorted { $0.date > $1.date }
        let completedMatches = playerMatches.filter(\.isCompleted)
        let upcomingMatches = playerMatches.filter(\.isUpcoming).sorted { $0.date < $1.date }
        let recentCompleted = Array(completedMatches.prefix(5))
        let ranking = rankings.first { $0.player?.id == player.id }

        var wins = 0
        var losses = 0
        var titleIDs = Set<UUID>()
        var h2hMap: [UUID: (player: Player, wins: Int, losses: Int, surfaces: [String: (Int, Int)])] = [:]
        var surfaceMap: [String: (Int, Int)] = [:]

        for match in completedMatches {
            guard let result = match.didPlayerWin(player) else { continue }

            if result {
                wins += 1
                if let tournament = match.tournament, tournament.endDate <= .now {
                    titleIDs.insert(tournament.id)
                }
            } else {
                losses += 1
            }

            let surfaceKey = Self.canonicalSurface(match.tournament?.surface)
            var bucket = surfaceMap[surfaceKey] ?? (0, 0)
            if result { bucket.0 += 1 } else { bucket.1 += 1 }
            surfaceMap[surfaceKey] = bucket

            if let opponent = match.opponent(for: player) {
                var current = h2hMap[opponent.id] ?? (opponent, 0, 0, [:])
                if result {
                    current.wins += 1
                } else {
                    current.losses += 1
                }
                var surfaceBucket = current.surfaces[surfaceKey] ?? (0, 0)
                if result { surfaceBucket.0 += 1 } else { surfaceBucket.1 += 1 }
                current.surfaces[surfaceKey] = surfaceBucket
                h2hMap[opponent.id] = current
            }
        }

        self.rank = ranking?.rank
        self.points = ranking?.points
        self.recentForm = recentCompleted.compactMap { $0.didPlayerWin(player) }
        self.nextMatch = upcomingMatches.first
        self.upcomingMatches = Array(upcomingMatches.prefix(3))
        self.recentHistory = Array(playerMatches.prefix(10))
        self.rankingProjectionText = upcomingMatches.first.flatMap {
            RankingProjectionEngine.projectionText(for: player, in: $0, rankings: rankings)
        }
        self.titles = titleIDs.count
        self.wins = wins
        self.losses = losses
        self.liveMatches = playerMatches.filter(\.isLive).count
        self.headToHead = h2hMap.values
            .map { value in
                HeadToHeadSummary(
                    opponent: value.player,
                    wins: value.wins,
                    losses: value.losses,
                    bySurface: Self.orderedSurfaceRecords(from: value.surfaces)
                )
            }
            .sorted { ($0.wins - $0.losses) > ($1.wins - $1.losses) }
        self.surfaceRecords = Self.orderedSurfaceRecords(from: surfaceMap)
    }

    var matchesPlayed: Int {
        wins + losses
    }

    var winRateText: String {
        guard matchesPlayed > 0 else { return "0%" }
        return "\(Int((Double(wins) / Double(matchesPlayed)) * 100))%"
    }

    /// Maps freeform provider surface strings into the canonical Tour buckets.
    /// Matches `MatchHeroCard.surfaceGradient` keyword set so the H2H stats and
    /// the card chrome agree on what counts as "Hard" / "Clay" / "Grass".
    private static func canonicalSurface(_ raw: String?) -> String {
        let normalized = (raw ?? "").lowercased()
        if normalized.contains("clay") || normalized.contains("saibro") { return "Saibro" }
        if normalized.contains("grass") || normalized.contains("grama") { return "Grama" }
        if normalized.contains("hard") || normalized.contains("dura") { return "Dura" }
        return "Outras"
    }

    private static let surfaceOrder = ["Dura", "Saibro", "Grama", "Outras"]

    private static func orderedSurfaceRecords(from map: [String: (Int, Int)]) -> [SurfaceRecord] {
        map
            .map { SurfaceRecord(surface: $0.key, wins: $0.value.0, losses: $0.value.1) }
            .filter { $0.matches > 0 }
            .sorted { lhs, rhs in
                let lIndex = surfaceOrder.firstIndex(of: lhs.surface) ?? Int.max
                let rIndex = surfaceOrder.firstIndex(of: rhs.surface) ?? Int.max
                if lIndex != rIndex { return lIndex < rIndex }
                return lhs.matches > rhs.matches
            }
    }
}

struct PlayerDetailView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var behaviorStore: BehaviorPersonalizationStore
    @EnvironmentObject private var experienceStore: ExperiencePreferencesStore
    @EnvironmentObject private var analyticsStore: ProductAnalyticsStore
    @Query private var matches: [TennisMatch]
    @Query(sort: \RankingEntry.rank) private var rankings: [RankingEntry]
    var player: Player

    init(player: Player) {
        self.player = player
        // Player history goes back ~1 year — `matches` used to load every
        // record in the database on each detail open, then filter to this
        // player in memory. The predicate trims it at the SwiftData layer.
        let threshold = Calendar.current.date(byAdding: .day, value: -365, to: .now) ?? .distantPast
        _matches = Query(
            filter: #Predicate<TennisMatch> { $0.date >= threshold },
            sort: \TennisMatch.date,
            order: .reverse
        )
    }

    private var recentMatches: [TennisMatch] {
        matches.filter { match in
            match.player1?.id == player.id || match.player2?.id == player.id
        }
    }

    private var insights: PlayerProfileInsights {
        PlayerProfileInsights(player: player, matches: matches, rankings: rankings)
    }

    var body: some View {
        List {
            Section("Radar do jogador") {
                playerRadarDashboard
                    .appListCardRow(cornerRadius: 22, padding: 18)
            }

            Section("Timeline do jogador") {
                playerTimeline
                    .appListCardRow()
            }

            Section("Notificações do jogador") {
                playerNotificationSummary
                    .appListCardRow()
            }

            Section("Snapshot") {
                statGrid(items: [
                    ("Rank", insights.rank.map { "#\($0)" } ?? "N/A"),
                    ("Points", insights.points.map(String.init) ?? "N/A"),
                    ("Titles", "\(insights.titles)"),
                    ("Win Rate", insights.winRateText)
                ])
                .appListCardRow()
            }

            let additionalUpcomingMatches = Array(insights.upcomingMatches.dropFirst().prefix(2))
            if !additionalUpcomingMatches.isEmpty {
                Section("Outros próximos jogos") {
                    ForEach(additionalUpcomingMatches) { match in
                        NavigationLink(destination: MatchDetailView(match: match)) {
                            compactMatchRow(match)
                        }
                        .appListCardRow()
                    }
                }
            }

            Section("Por superfície") {
                if insights.surfaceRecords.isEmpty {
                    Text("Sem partidas finalizadas com superfície registrada.")
                        .foregroundStyle(Color.readableSecondary)
                        .appListCardRow()
                } else {
                    ForEach(insights.surfaceRecords) { record in
                        surfaceRecordRow(record)
                            .appListCardRow()
                    }
                }
            }

            Section("H2H recorrentes") {
                if insights.headToHead.isEmpty {
                    Text("Sem histórico head-to-head suficiente.")
                        .foregroundStyle(Color.readableSecondary)
                        .appListCardRow()
                } else {
                    ForEach(insights.headToHead.prefix(5)) { entry in
                        headToHeadRow(entry)
                            .appListCardRow()
                    }
                }
            }

            Section("Perfil API") {
                PlayerAPIProfileSection(player: player)
                    .appListCardRow()
            }

            Section("Info") {
                VStack(alignment: .leading, spacing: 12) {
                    LabeledContent("Name", value: player.name)
                    LabeledContent("Nationality", value: player.nationality)
                    LabeledContent("Tour", value: player.isWTA ? "WTA" : "ATP")
                    if let birth = player.birthDate {
                        LabeledContent("Birthdate", value: birth.formatted(date: .abbreviated, time: .omitted))
                    }
                }
                .appListCardRow()
            }

            Section("Histórico") {
                ForEach(insights.recentHistory) { m in
                    NavigationLink(destination: MatchDetailView(match: m)) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("\(m.player1?.name ?? "TBD") vs \(m.player2?.name ?? "TBD")")
                                Spacer()
                                if let didWin = m.didPlayerWin(player) {
                                    Text(didWin ? "W" : "L")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(didWin ? .green : .red)
                                } else if m.isLive {
                                    Text("LIVE")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(.red)
                                }
                            }
                            Text(m.tournament?.name ?? "")
                                .font(.caption)
                                .foregroundStyle(Color.readableSecondary)
                            Text(experienceStore.preferences.spoilerFreeMode && m.isCompleted ? "Resultado oculto pelo modo spoiler-free" : (m.score.isEmpty ? m.status : m.score))
                                .font(.caption)
                                .foregroundStyle(Color.readableSecondary)
                        }
                    }
                    .appListCardRow()
                }
            }
        }
        .listStyle(.plain)
        .appleSportsBackground(.royal)
        .navigationTitle(player.name)
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
#endif
        .favoriteToolbar(isFavorite: player.isFavorite) {
            let willFavorite = !player.isFavorite
            player.isFavorite.toggle()
            AutoSyncTracker.reset(.matches)
            AutoSyncTracker.reset(.liveMatches)
            if willFavorite {
                analyticsStore.record(
                    ProductAnalyticsEventName.favoritePlayerChosen,
                    properties: ["playerID": player.behaviorKey]
                )
            }
            Task {
                await AlertEventEngine.shared.refreshScheduledNotifications(in: context, force: true)
            }
        }
        .onAppear {
            behaviorStore.recordPlayerView(player)
            analyticsStore.record(
                ProductAnalyticsEventName.playerOpened,
                properties: ["playerID": player.behaviorKey]
            )
        }
    }

    private var playerRadarDashboard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(radarTint.opacity(0.20))
                        .frame(width: 48, height: 48)
                    Image(systemName: radarIcon)
                        .font(.title3.weight(.heavy))
                        .foregroundStyle(radarTint)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(radarHeadline)
                        .font(.headline.weight(.heavy))
                    Text(radarSubheadline)
                        .font(.caption)
                        .foregroundStyle(Color.readableSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Text(player.isFavorite ? "SEGUIDO" : "RADAR")
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(player.isFavorite ? .green : Color.readableSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.10), in: Capsule())
            }

            if let focusMatch = radarFocusMatch {
                NavigationLink(destination: MatchDetailView(match: focusMatch)) {
                    HStack(alignment: .center, spacing: 10) {
                        Image(systemName: focusMatch.isLive ? "dot.radiowaves.left.and.right" : "calendar.badge.clock")
                            .font(.headline.weight(.bold))
                            .foregroundStyle(focusMatch.isLive ? .red : .green)
                            .frame(width: 28)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(focusMatch.isLive ? "Ao vivo contra \(opponentName(for: focusMatch))" : "Próximo contra \(opponentName(for: focusMatch))")
                                .font(.subheadline.weight(.heavy))
                                .lineLimit(2)
                            Text("\(focusMatch.tournament?.name ?? "Torneio") · \(focusMatch.date.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(Color.readableSecondary)
                        }

                        Spacer(minLength: 0)

                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Color.readableSecondary)
                    }
                    .padding(12)
                    .background(Color.cardSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                radarMetric("Ranking", insights.rank.map { "#\($0)" } ?? "N/A", "number")
                radarMetric("Forma", radarFormText, "chart.line.uptrend.xyaxis")
                radarMetric("Superfície", radarSurfaceText, "sportscourt")
                radarMetric("Alertas", player.isFavorite ? "Ativos" : "Favoritar", player.isFavorite ? "bell.badge.fill" : "bell")
            }

            if let projection = insights.rankingProjectionText {
                radarInsightRow(icon: "chart.line.uptrend.xyaxis", title: "Projeção", text: projection, tint: .blue)
            }

            if let nextOpponentHeadToHead {
                radarInsightRow(
                    icon: "person.2.fill",
                    title: "H2H vs próximo adversário",
                    text: "\(nextOpponentHeadToHead.record) contra \(nextOpponentHeadToHead.opponent.name)",
                    tint: .orange
                )
            } else if let firstRivalry = insights.headToHead.first {
                radarInsightRow(
                    icon: "person.2.fill",
                    title: "Rivalidade recorrente",
                    text: "\(firstRivalry.record) contra \(firstRivalry.opponent.name)",
                    tint: .orange
                )
            }
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("player-radar-dashboard")
    }

    private var radarFocusMatch: TennisMatch? {
        matches
            .filter { $0.isLive && $0.involves(player: player) }
            .sorted { $0.date > $1.date }
            .first ?? insights.nextMatch
    }

    private var radarTint: Color {
        radarFocusMatch?.isLive == true ? .red : .green
    }

    private var radarIcon: String {
        radarFocusMatch?.isLive == true ? "dot.radiowaves.left.and.right" : "scope"
    }

    private var radarHeadline: String {
        if radarFocusMatch?.isLive == true {
            return "\(player.name) está em quadra agora"
        }
        if insights.nextMatch != nil {
            return "Próximo compromisso definido"
        }
        return "Radar pronto para o próximo jogo"
    }

    private var radarSubheadline: String {
        if let focusMatch = radarFocusMatch, focusMatch.isLive {
            return "Acompanhe placar, pressão e alertas do jogo contra \(opponentName(for: focusMatch))."
        }
        if let nextMatch = insights.nextMatch {
            return "Agenda, projeção de ranking e histórico contra \(opponentName(for: nextMatch)) em um só lugar."
        }
        return "Quando a sincronização trouxer calendário novo, esta área vira o painel do jogador."
    }

    private var radarFormText: String {
        insights.recentForm.isEmpty ? "Sem amostra" : insights.recentForm.map { $0 ? "W" : "L" }.joined(separator: " ")
    }

    private var radarSurfaceText: String {
        guard let best = insights.surfaceRecords.max(by: { lhs, rhs in
            if lhs.winRate != rhs.winRate { return lhs.winRate < rhs.winRate }
            return lhs.matches < rhs.matches
        }) else {
            return "Sem dados"
        }
        return "\(best.surface) \(best.winRateText)"
    }

    private func radarMetric(_ title: String, _ value: String, _ icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(.green)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title.uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.readableSecondary)
                Text(value)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func radarInsightRow(icon: String, title: String, text: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(title.uppercased())
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(tint)
                Text(text)
                    .font(.caption.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func opponentName(for match: TennisMatch) -> String {
        match.opponent(for: player)?.name ?? "\(match.player1?.name ?? "TBD") vs \(match.player2?.name ?? "TBD")"
    }

    private var nextOpponentHeadToHead: PlayerProfileInsights.HeadToHeadSummary? {
        guard let nextMatch = insights.nextMatch,
              let opponent = nextMatch.opponent(for: player)
        else {
            return nil
        }

        return insights.headToHead.first { $0.opponent.id == opponent.id }
    }

    @ViewBuilder
    private var playerTimeline: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let nextMatch = insights.nextMatch {
                NavigationLink(destination: MatchDetailView(match: nextMatch)) {
                    timelineItem(
                        icon: "calendar.badge.clock",
                        title: "Próximo jogo",
                        value: opponentName(for: nextMatch),
                        detail: "\(nextMatch.tournament?.name ?? "Torneio") • \(nextMatch.date.formatted(date: .abbreviated, time: .shortened))"
                    )
                }
            } else {
                timelineItem(
                    icon: "calendar",
                    title: "Próximo jogo",
                    value: "Sem partida futura sincronizada",
                    detail: "Quando o calendário trouxer um novo jogo, ele aparece primeiro aqui."
                )
            }

            timelineItem(icon: "chart.line.uptrend.xyaxis", title: "Forma recente") {
                recentFormRow
            }

            timelineItem(icon: "number", title: "Ranking projetado") {
                Text(insights.rankingProjectionText ?? "Sem projeção disponível para o próximo jogo.")
                    .font(.subheadline)
                    .foregroundStyle(insights.rankingProjectionText == nil ? Color.readableSecondary : .primary)
            }

            timelineItem(icon: "person.2", title: "H2H com adversário") {
                if let nextOpponentHeadToHead {
                    headToHeadRow(nextOpponentHeadToHead)
                } else {
                    Text("Sem histórico contra o próximo adversário.")
                        .font(.subheadline)
                        .foregroundStyle(Color.readableSecondary)
                }
            }
        }
    }

    @ViewBuilder
    private var playerNotificationSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(player.isFavorite ? "Jogador seguido" : "Jogador ainda não seguido", systemImage: player.isFavorite ? "bell.badge.fill" : "bell.slash")
                .font(.headline)
                .foregroundStyle(player.isFavorite ? .green : Color.readableSecondary)
            Text(player.isFavorite ? "Alertas agregam todas as partidas futuras deste jogador quando 'Jogadores favoritos' está ativo nas preferências." : "Favorite o jogador para agregar lembretes, entrada em quadra, início e fim das partidas dele.")
                .font(.caption)
                .foregroundStyle(Color.readableSecondary)
            Text("Cobertura atual: \(insights.liveMatches) ao vivo, \(insights.upcomingMatches.count) futuras.")
                .font(.caption.weight(.semibold))
        }
    }

    @ViewBuilder
    private var recentFormRow: some View {
        if insights.recentForm.isEmpty {
            Text("Ainda não há partidas finalizadas suficientes.")
                .font(.subheadline)
                .foregroundStyle(Color.readableSecondary)
        } else {
            HStack(spacing: 8) {
                ForEach(Array(insights.recentForm.enumerated()), id: \.offset) { _, didWin in
                    Text(didWin ? "W" : "L")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(didWin ? Color.green : Color.red)
                        .clipShape(Circle())
                }
            }
        }
    }

    @ViewBuilder
    private func timelineItem(icon: String, title: String, value: String, detail: String) -> some View {
        timelineItem(icon: icon, title: title) {
            VStack(alignment: .leading, spacing: 4) {
                Text(value)
                    .font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Color.readableSecondary)
            }
        }
    }

    @ViewBuilder
    private func timelineItem<Content: View>(icon: String, title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.green)
                .frame(width: 28, height: 28)
                .background(Color.green.opacity(0.16))
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.readableSecondary)
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(Color.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private func compactMatchRow(_ match: TennisMatch) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(opponentName(for: match))
                .font(.headline)
            Text(match.tournament?.name ?? "Torneio")
                .font(.caption)
                .foregroundStyle(Color.readableSecondary)
            Text(match.date.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(Color.readableSecondary)
        }
    }

    @ViewBuilder
    private func headToHeadRow(_ entry: PlayerProfileInsights.HeadToHeadSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.opponent.name)
                    Text(entry.opponent.nationality)
                        .font(.caption)
                        .foregroundStyle(Color.readableSecondary)
                }
                Spacer()
                Text(entry.record)
                    .font(.headline)
            }
            if !entry.bySurface.isEmpty {
                HStack(spacing: 6) {
                    ForEach(entry.bySurface) { surface in
                        Text("\(surface.surface) \(surface.wins)-\(surface.losses)")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.white.opacity(0.12))
                            .clipShape(Capsule())
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func surfaceRecordRow(_ record: PlayerProfileInsights.SurfaceRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(record.surface)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(record.wins)V \(record.losses)D")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color.readableSecondary)
                Text(record.winRateText)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.green)
            }
            GeometryReader { geo in
                let width = geo.size.width * CGFloat(record.winRate)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12))
                    Capsule().fill(Color.green).frame(width: width)
                }
            }
            .frame(height: 6)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(record.surface): \(record.wins) vitórias e \(record.losses) derrotas, \(record.winRateText) de aproveitamento.")
    }

    @ViewBuilder
    private func statGrid(items: [(String, String)]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.0)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.readableSecondary)
                    Text(item.1)
                        .font(.headline)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.cardSurface)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }
}

struct PlayerAPIProfileSection: View {
    @Environment(\.modelContext) private var context
    let player: Player

    @State private var profile: PlayerProfileDTO?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var hasFetched = false

    private var playerKey: String? {
        let key = player.externalKey ?? ""
        return key.isEmpty ? nil : key
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        Task { await loadProfile() }
                    } label: {
                        Label(hasFetched ? "Atualizar perfil" : "Carregar perfil", systemImage: "person.crop.circle.badge.checkmark")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(playerKey == nil)
                }
                Spacer()
            }

            if playerKey == nil {
                Text("Perfil API exige o ID externo do jogador. Sincronize antes.")
                    .font(.caption)
                    .foregroundStyle(Color.readableSecondary)
            } else if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if hasFetched && profile == nil {
                Text("Sem perfil disponível na API para este jogador.")
                    .font(.caption)
                    .foregroundStyle(Color.readableSecondary)
            } else if let profile {
                if let url = profile.photoURL {
                    AsyncImage(url: url) { image in
                        image.resizable()
                            .aspectRatio(contentMode: .fill)
                    } placeholder: {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.primary.opacity(0.1))
                            .overlay(ProgressView())
                    }
                    .frame(width: 100, height: 100)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                if let bio = profile.bio, !bio.isEmpty {
                    Text(bio)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                }

                if !profile.tournamentsPlayed.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Torneios disputados")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.readableSecondary)
                        Text(profile.tournamentsPlayed.prefix(8).joined(separator: " • "))
                            .font(.caption)
                    }
                }

                if !profile.stats.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Stats")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.readableSecondary)
                        ForEach(Array(profile.stats.prefix(10).enumerated()), id: \.offset) { _, stat in
                            HStack {
                                Text("\(stat.season) \(stat.type)")
                                    .font(.caption)
                                Spacer()
                                Text(stat.value)
                                    .font(.caption.weight(.bold))
                            }
                        }
                    }
                }
            }
        }
    }

    @MainActor
    private func loadProfile() async {
        guard let playerKey else { return }
        isLoading = true
        defer {
            isLoading = false
            hasFetched = true
        }
        errorMessage = nil
        do {
            let service = DataSyncService(context: context)
            profile = try await service.playerProfile(playerKey: playerKey, tour: player.isWTA ? "WTA" : "ATP")
        } catch {
            profile = nil
            let service = DataSyncService(context: context)
            errorMessage = service.userFacingMessage(for: error)
        }
    }
}
