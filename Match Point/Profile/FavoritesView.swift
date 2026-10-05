import SwiftUI
import SwiftData

struct FavoritesView: View {
    @EnvironmentObject private var experienceStore: ExperiencePreferencesStore
    // Push the `isFavorite` filter down into SwiftData instead of fetching
    // every Player / Tournament / TennisMatch and filtering in memory. With
    // a synced install the unfiltered queries pulled the whole tables on
    // every tab visit.
    @Query(
        filter: #Predicate<Player> { $0.isFavorite },
        sort: \Player.name
    ) private var favoritePlayers: [Player]

    @Query(
        filter: #Predicate<Tournament> { $0.isFavorite },
        sort: \Tournament.startDate,
        order: .forward
    ) private var favoriteTournaments: [Tournament]

    @Query(
        filter: #Predicate<TennisMatch> { $0.isFavorite },
        sort: \TennisMatch.date,
        order: .reverse
    ) private var favoriteMatches: [TennisMatch]

    var body: some View {
        List {
            if favoriteMatches.isEmpty, favoritePlayers.isEmpty, favoriteTournaments.isEmpty {
                Section {
                    EmptyStateActionCard(
                        title: "Nenhum favorito ainda",
                        message: "Siga jogadores, partidas e torneios para transformar essa aba em uma central com próximo jogo, forma, alertas e ranking dos seus atletas.",
                        systemImage: "star",
                        primaryAction: EmptyStateAction(
                            label: "Escolher jogadores",
                            systemImage: "person.crop.circle.badge.plus",
                            accessibilityIdentifier: "favorites-empty-choose-players"
                        ) {
                            NotificationCenter.default.post(
                                name: .navigateToPlayersDirectory,
                                object: nil
                            )
                        }
                    )
                    .appListCardRow(cornerRadius: 22, padding: 16)
                }
            }

            if !favoriteMatches.isEmpty {
                Section("Partidas") {
                    ForEach(favoriteMatches) { match in
                        NavigationLink(destination: MatchDetailView(match: match)) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(match.player1?.name ?? "TBD") vs \(match.player2?.name ?? "TBD")")
                                    .font(.headline)
                                Text(match.tournament?.name ?? "Torneio ao vivo")
                                    .font(.caption)
                                    .foregroundStyle(Color.readableSecondary)
                                if !match.status.isEmpty {
                                    Text(experienceStore.preferences.spoilerFreeMode && match.isCompleted ? "Resultado oculto pelo modo spoiler-free" : match.status)
                                        .font(.caption)
                                        .foregroundStyle(match.isLive ? .red : Color.readableSecondary)
                                }
                            }
                        }
                        .appListCardRow()
                    }
                }
            }

            if !favoritePlayers.isEmpty {
                Section("Jogadores") {
                    ForEach(favoritePlayers) { player in
                        NavigationLink(destination: PlayerDetailView(player: player)) {
                            HStack {
                                Text(player.name)
                                Spacer()
                                Text(player.nationality)
                                    .foregroundStyle(Color.readableSecondary)
                            }
                        }
                        .appListCardRow()
                    }
                }
            }

            if !favoriteTournaments.isEmpty {
                Section("Torneios") {
                    ForEach(favoriteTournaments) { tournament in
                        NavigationLink(destination: TournamentDetailView(tournament: tournament)) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(tournament.name)
                                Text("\(tournament.city), \(tournament.country)")
                                    .font(.caption)
                                    .foregroundStyle(Color.readableSecondary)
                            }
                        }
                        .appListCardRow()
                    }
                }
            }
        }
        .listStyle(.plain)
        .appleSportsBackground(.royal)
        .navigationTitle("Favoritos")
    }
}

struct MyPlayersFeedView: View {
    @EnvironmentObject private var analyticsStore: ProductAnalyticsStore
    @EnvironmentObject private var behaviorStore: BehaviorPersonalizationStore
    @EnvironmentObject private var experienceStore: ExperiencePreferencesStore
    @Query(
        filter: #Predicate<Player> { $0.isFavorite },
        sort: \Player.name
    ) private var players: [Player]
    @Query private var matches: [TennisMatch]
    @Query(sort: \RankingEntry.rank) private var rankings: [RankingEntry]
    // Tournament-level favorites are surfaced inline here too — this view is
    // the merged "Meus favoritos" hub (former "Meus jogadores" + "Favoritos"
    // tabs), so it owns every favorite-driven surface in one scroll.
    @Query(
        filter: #Predicate<Tournament> { $0.isFavorite },
        sort: \Tournament.startDate,
        order: .forward
    ) private var favoriteTournaments: [Tournament]
    // Match-level favorites live alongside player-driven matches. They overlap
    // partially with the radar/spotlight feed; this section lists matches the
    // user explicitly starred (which won't always equal "player favorite").
    @Query(
        filter: #Predicate<TennisMatch> { $0.isFavorite },
        sort: \TennisMatch.date,
        order: .reverse
    ) private var explicitFavoriteMatches: [TennisMatch]

    init() {
        // The radar/spotlight only needs upcoming + recent matches of favorited
        // players. A 60-day rolling window keeps the feed responsive on installs
        // that have years of synced history.
        let threshold = MatchQueryWindow.matchList()
        _matches = Query(
            filter: #Predicate<TennisMatch> { $0.date >= threshold },
            sort: \TennisMatch.date,
            order: .reverse
        )
    }

    private var feed: FavoritePlayerFeed {
        FavoritePlayerFeed(players: players, matches: matches, rankings: rankings)
    }

    private var hasAnyFavorites: Bool {
        !feed.favoritePlayers.isEmpty || !favoriteTournaments.isEmpty || !explicitFavoriteMatches.isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                if !hasAnyFavorites {
                    EmptyStateActionCard(
                        title: "Nenhum favorito ainda",
                        message: "Escolha pelo menos um jogador para ver próximo jogo, motivos pra acompanhar e ativar alertas em um toque.",
                        systemImage: "star",
                        primaryAction: EmptyStateAction(
                            label: "Escolher jogadores",
                            systemImage: "person.crop.circle.badge.plus",
                            accessibilityIdentifier: "my-players-empty-choose"
                        ) {
                            NotificationCenter.default.post(
                                name: .navigateToPlayersDirectory,
                                object: nil
                            )
                        }
                    )
                }

                HomeScreenWidgetInlinePanel()

                if hasAnyFavorites {
                    if let primary = primaryFavoritePlayer {
                        PrimaryFavoritePlayerHero(
                            player: primary,
                            matches: matches,
                            rankings: rankings,
                            onNextMatchTap: { match in
                                analyticsStore.record(
                                    ProductAnalyticsEventName.matchOpenedFromPlayerHome,
                                    properties: [
                                        "matchID": match.behaviorKey,
                                        "playerID": primary.behaviorKey
                                    ]
                                )
                            },
                            onStoryShown: { storyKind in
                                analyticsStore.record(
                                    ProductAnalyticsEventName.playerStoryShown,
                                    properties: [
                                        "playerID": primary.behaviorKey,
                                        "kind": storyKind
                                    ]
                                )
                            }
                        )
                    }

                    if !feed.favoritePlayers.isEmpty {
                        playerFirstHomeSection
                        favoriteCalendarPreview
                        favoriteStrip
                        radarSection
                        spotlightSection
                        matchSection(title: "Ao vivo", subtitle: "Atualizadores ativos", matches: feed.liveMatches)
                        matchSection(title: "Próximos", subtitle: "Agenda dos seus favoritos", matches: Array(feed.upcomingMatches.prefix(8)))
                        matchSection(title: "Depois do jogo", subtitle: "Resultados e reações recentes", matches: Array(feed.completedMatches.prefix(6)))
                    }
                    explicitMatchesSection
                    tournamentsSection
                }
            }
            .padding()
        }
        .appleSportsBackground(.royal)
        .accessibilityIdentifier("my-players-screen")
        .navigationTitle("Meus favoritos")
        .onAppear {
            if !feed.favoritePlayers.isEmpty {
                analyticsStore.record(
                    ProductAnalyticsEventName.playerHomeViewed,
                    properties: [
                        "favoriteCount": "\(feed.favoritePlayers.count)",
                        "hasLive": feed.liveMatches.isEmpty ? "false" : "true"
                    ]
                )
            }
        }
    }

    /// Selects the "hero" favorite for the player-first landing card. Preference
    /// order: player with a live match → highest-ranked → most-viewed (per the
    /// behavior store) → first alphabetically. The behavior signal makes the
    /// hero converge on whoever the user actually pays attention to, so the
    /// homepage feels less like a list and more like *their* player.
    private var primaryFavoritePlayer: Player? {
        let favorites = feed.favoritePlayers
        guard !favorites.isEmpty else { return nil }

        if let live = favorites.first(where: { player in
            matches.contains { $0.isLive && $0.involves(player: player) }
        }) {
            return live
        }

        let behaviorSnapshot = behaviorStore.snapshot
        let scored = favorites.map { player -> (Player, Int, Int) in
            let rank = rankings.first { $0.player?.id == player.id }?.rank ?? 99999
            let views = behaviorSnapshot.playerViews[player.behaviorKey]?.count ?? 0
            return (player, rank, views)
        }
        return scored
            .sorted { lhs, rhs in
                if lhs.2 != rhs.2 { return lhs.2 > rhs.2 }
                if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
                return lhs.0.name < rhs.0.name
            }
            .first?.0
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Meus favoritos")
                .font(.largeTitle.weight(.heavy))
            Text(headerSubtitle)
                .font(.subheadline)
                .foregroundStyle(Color.readableSecondary)

            HStack(spacing: 10) {
                feedMetric(title: "Jogadores", value: "\(feed.favoritePlayers.count)", tint: .green)
                feedMetric(title: "Torneios", value: "\(favoriteTournaments.count)", tint: .yellow)
                feedMetric(title: "Partidas", value: "\(explicitFavoriteMatches.count)", tint: .blue)
            }
        }
    }

    private var headerSubtitle: String {
        if !hasAnyFavorites {
            return "Siga jogadores, torneios e partidas para transformar o app em uma central pessoal de tênis."
        }
        if let firstLive = feed.liveMatches.first {
            return "\(firstLive.player1?.name ?? "TBD") vs \(firstLive.player2?.name ?? "TBD") está pedindo atenção agora."
        }
        if let next = feed.upcomingMatches.first {
            return "Próximo jogo: \(next.player1?.name ?? "TBD") vs \(next.player2?.name ?? "TBD")."
        }
        return "Jogadores, torneios e partidas que você segue — tudo num lugar só."
    }

    @ViewBuilder
    private var explicitMatchesSection: some View {
        if !explicitFavoriteMatches.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Partidas favoritadas")
                    .font(.title3.weight(.bold))
                ForEach(explicitFavoriteMatches.prefix(8)) { match in
                    NavigationLink(destination: MatchDetailView(match: match)) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(match.player1?.name ?? "TBD") vs \(match.player2?.name ?? "TBD")")
                                .font(.headline)
                            Text(match.tournament?.name ?? "Torneio")
                                .font(.caption)
                                .foregroundStyle(Color.readableSecondary)
                            if !match.status.isEmpty {
                                Text(experienceStore.preferences.spoilerFreeMode && match.isCompleted ? "Resultado oculto pelo modo spoiler-free" : match.status)
                                    .font(.caption)
                                    .foregroundStyle(match.isLive ? .red : Color.readableSecondary)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.cardSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private var tournamentsSection: some View {
        if !favoriteTournaments.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Torneios favoritos")
                    .font(.title3.weight(.bold))
                ForEach(favoriteTournaments) { tournament in
                    NavigationLink(destination: TournamentDetailView(tournament: tournament)) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(tournament.name)
                                .font(.headline)
                            Text("\(tournament.city), \(tournament.country)")
                                .font(.caption)
                                .foregroundStyle(Color.readableSecondary)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.cardSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var playerFirstHomeSection: some View {
        let radars = feed.favoritePlayers.map { FavoritePlayerRadar(player: $0, matches: matches, rankings: rankings) }
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .lastTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Radar dos seus jogadores")
                        .font(.title3.weight(.bold))
                    Text("Próximo jogo, ranking, forma, rivalidade, calendário e alertas em um só lugar.")
                        .font(.caption)
                        .foregroundStyle(Color.readableSecondary)
                }
                Spacer(minLength: 0)
            }

            ForEach(radars) { radar in
                NavigationLink(destination: PlayerDetailView(player: radar.player)) {
                    playerHomeCard(radar)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func playerHomeCard(_ radar: FavoritePlayerRadar) -> some View {
        let insights = PlayerProfileInsights(player: radar.player, matches: matches, rankings: rankings)
        let nextMatch = radar.liveMatch ?? radar.nextMatch
        let calendarCount = (insights.nextMatch == nil ? 0 : 1) + insights.upcomingMatches.count
        let story = playerStoryLine(radar: radar, insights: insights)

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(radar.liveMatch == nil ? Color.green.opacity(0.22) : Color.red.opacity(0.24))
                        .frame(width: 46, height: 46)
                    Image(systemName: radar.liveMatch == nil ? "person.crop.circle.fill" : "dot.radiowaves.left.and.right")
                        .font(.title3.weight(.heavy))
                        .foregroundStyle(radar.liveMatch == nil ? .green : .red)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(radar.player.name)
                        .font(.headline)
                    Text(nextMatch.map { radar.liveMatch == nil ? "Próximo: \(opponentName(for: radar.player, in: $0))" : "Ao vivo vs \(opponentName(for: radar.player, in: $0))" } ?? "Sem jogo confirmado")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                }

                Spacer(minLength: 0)

                Text(radar.liveMatch == nil ? "PLAYER" : "LIVE")
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(radar.liveMatch == nil ? .green : .red)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.12), in: Capsule())
            }

            Text(story)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                playerHomeMetric("Ranking", insights.rank.map { "#\($0)" } ?? "N/A", "number")
                playerHomeMetric("Forma", insights.recentForm.isEmpty ? "Sem amostra" : insights.recentForm.map { $0 ? "W" : "L" }.joined(separator: " "), "chart.line.uptrend.xyaxis")
                playerHomeMetric("Calendário", "\(calendarCount) jogos", "calendar")
                playerHomeMetric("Alertas", radar.player.isFavorite ? "Agregados" : "Desligados", radar.player.isFavorite ? "bell.badge.fill" : "bell.slash")
            }

            FlowTagRow(items: [radar.rankingLine, radar.headToHeadLine, radar.surfaceLine])
        }
        .padding(14)
        .background(Color.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func playerHomeMetric(_ title: String, _ value: String, _ icon: String) -> some View {
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
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func playerStoryLine(radar: FavoritePlayerRadar, insights: PlayerProfileInsights) -> String {
        if let liveMatch = radar.liveMatch {
            return "Story agora: \(radar.player.name) está em quadra contra \(opponentName(for: radar.player, in: liveMatch)); acompanhe placar, momentum e alertas críticos."
        }
        if let nextMatch = radar.nextMatch {
            let projection = insights.rankingProjectionText ?? radar.rankingLine
            return "Story automático: \(radar.player.name) chega contra \(opponentName(for: radar.player, in: nextMatch)). \(projection)"
        }
        if !insights.recentForm.isEmpty {
            return "Story automático: forma recente \(insights.recentForm.map { $0 ? "W" : "L" }.joined(separator: " ")); o app destaca o próximo compromisso assim que sincronizar."
        }
        return "Story automático pronto para próximo jogo, ranking projetado e rivalidade assim que houver dados sincronizados."
    }

    private func opponentName(for player: Player, in match: TennisMatch) -> String {
        match.opponent(for: player)?.name ?? "adversário"
    }

    private var favoriteStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(feed.favoritePlayers) { player in
                    NavigationLink(destination: PlayerDetailView(player: player)) {
                        VStack(alignment: .leading, spacing: 6) {
                            Image(systemName: "star.fill")
                                .foregroundStyle(.yellow)
                            Text(player.name)
                                .font(.caption.weight(.bold))
                                .lineLimit(1)
                            Text(player.isWTA ? "WTA" : "ATP")
                                .font(.caption2)
                                .foregroundStyle(Color.readableSecondary)
                        }
                        .padding(14)
                        .frame(width: 148, height: 96, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // `.contentShape(.rect)` faz o card INTEIRO virar alvo
                        // do tap, não só o texto. Combinado com altura fixa
                        // (96pt) atende o mínimo Fitts/HIG de 44pt.
                        .contentShape(Rectangle())
                        .background(Color.cardSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2) // sombra/borda não cortar
        }
    }

    private var favoriteCalendarMatches: [TennisMatch] {
        let favoriteIDs = Set(feed.favoritePlayers.map(\.id))
        let favoriteTournamentIDs = Set(favoriteTournaments.map(\.id))
        let now = Date()
        let end = Calendar.current.date(byAdding: .day, value: 7, to: now) ?? now
        return matches
            .filter { match in
                match.date >= Calendar.current.startOfDay(for: now) && match.date <= end
            }
            .sorted { lhs, rhs in
                let lhsPriority = calendarPriority(for: lhs, favoritePlayerIDs: favoriteIDs, favoriteTournamentIDs: favoriteTournamentIDs)
                let rhsPriority = calendarPriority(for: rhs, favoritePlayerIDs: favoriteIDs, favoriteTournamentIDs: favoriteTournamentIDs)
                if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
                return lhs.date < rhs.date
            }
    }

    private func calendarPriority(for match: TennisMatch, favoritePlayerIDs: Set<UUID>, favoriteTournamentIDs: Set<UUID>) -> Int {
        if match.isFavorite { return 0 }
        if let player1 = match.player1, favoritePlayerIDs.contains(player1.id) { return 1 }
        if let player2 = match.player2, favoritePlayerIDs.contains(player2.id) { return 1 }
        if let tournament = match.tournament, favoriteTournamentIDs.contains(tournament.id) || tournament.isFavorite { return 2 }
        return 3
    }

    private var favoriteCalendarPreview: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .lastTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Calendário dos favoritos")
                        .font(.title3.weight(.bold))
                    Text("Hoje, amanhã e próximos 7 dias em ordem de quadra.")
                        .font(.caption)
                        .foregroundStyle(Color.readableSecondary)
                }
                Spacer(minLength: 0)
                NavigationLink {
                    FavoriteMatchCalendarView(
                        matches: favoriteCalendarMatches,
                        players: feed.favoritePlayers,
                        tournaments: favoriteCalendarTournaments
                    )
                } label: {
                    Label("Abrir", systemImage: "calendar")
                        .font(.caption.weight(.bold))
                }
                .buttonStyle(.bordered)
                .simultaneousGesture(TapGesture().onEnded {
                    analyticsStore.record(
                        ProductAnalyticsEventName.favoriteCalendarCTASelected,
                        properties: [
                            "entry": "favorites_preview",
                            "matchCount": "\(favoriteCalendarMatches.count)"
                        ]
                    )
                })
            }

            if favoriteCalendarMatches.filter({ calendarPriority(for: $0, favoritePlayerIDs: Set(feed.favoritePlayers.map(\.id)), favoriteTournamentIDs: Set(favoriteTournaments.map(\.id))) < 3 }).isEmpty {
                Text("Nenhuma partida dos favoritos nos próximos 7 dias.")
                    .font(.caption)
                    .foregroundStyle(Color.readableSecondary)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.cardSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else {
                let favoritePlayerIDs = Set(feed.favoritePlayers.map(\.id))
                let favoriteTournamentIDs = Set(favoriteTournaments.map(\.id))
                ForEach(Array(favoriteCalendarMatches.filter { calendarPriority(for: $0, favoritePlayerIDs: favoritePlayerIDs, favoriteTournamentIDs: favoriteTournamentIDs) < 3 }.prefix(3))) { match in
                    NavigationLink(destination: MatchDetailView(match: match)) {
                        FavoriteCalendarCompactRow(match: match)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var favoriteCalendarTournaments: [Tournament] {
        var byID: [UUID: Tournament] = [:]
        for tournament in favoriteTournaments {
            byID[tournament.id] = tournament
        }
        for match in favoriteCalendarMatches {
            if let tournament = match.tournament {
                byID[tournament.id] = tournament
            }
        }
        return byID.values.sorted { $0.startDate < $1.startDate }
    }

    private var radarSection: some View {
        let radars = feed.favoritePlayers.map {
            FavoritePlayerRadar(player: $0, matches: matches, rankings: rankings)
        }

        return VStack(alignment: .leading, spacing: 12) {
            Text("Radar dos favoritos")
                .font(.title3.weight(.bold))

            ForEach(radars) { radar in
                let isLive = radar.liveMatch != nil
                let badgeColor: Color = isLive ? .red : .secondary
                NavigationLink(destination: PlayerDetailView(player: radar.player)) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(radar.player.name)
                                .font(.headline)
                            Spacer()
                            Text(isLive ? "AO VIVO" : "RADAR")
                                .font(.caption2.weight(.heavy))
                                .foregroundStyle(badgeColor)
                        }

                        Text(radar.alertLine)
                            .font(.subheadline.weight(.semibold))

                        FlowTagRow(items: [
                            radar.rankingLine,
                            radar.formLine,
                            radar.surfaceLine,
                            radar.headToHeadLine
                        ])
                    }
                    .padding(14)
                    .background(Color.cardSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var spotlightSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Prioridade agora")
                .font(.title3.weight(.bold))

            if feed.spotlight.isEmpty {
                Text("Sem partidas conectadas aos seus favoritos ainda.")
                    .font(.subheadline)
                    .foregroundStyle(Color.readableSecondary)
            } else {
                ForEach(Array(feed.spotlight.prefix(3))) { match in
                    NavigationLink(destination: MatchDetailView(match: match)) {
                        favoriteMatchCard(match)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func matchSection(title: String, subtitle: String, matches: [TennisMatch]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.title3.weight(.bold))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Color.readableSecondary)
                }
                Spacer()
            }

            if matches.isEmpty {
                Text("Nada por aqui no momento.")
                    .font(.caption)
                    .foregroundStyle(Color.readableSecondary)
            } else {
                ForEach(matches) { match in
                    NavigationLink(destination: MatchDetailView(match: match)) {
                        favoriteMatchCard(match)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func favoriteMatchCard(_ match: TennisMatch) -> some View {
        let intelligence = MatchIntelligence(match: match, rankings: rankings, allMatches: matches)
        let context = intelligence.liveContext

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(match.isLive ? "AO VIVO" : match.isUpcoming ? "PRÓXIMO" : (experienceStore.preferences.spoilerFreeMode ? "SPOILER-FREE" : "FINAL"))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(match.isLive ? .red : Color.readableSecondary)
                Spacer()
                Text(match.date, format: .dateTime.month().day().hour().minute())
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color.readableSecondary)
            }
            Text("\(match.player1?.name ?? "TBD") vs \(match.player2?.name ?? "TBD")")
                .font(.headline)
            Text(context.headline)
                .font(.subheadline.weight(.semibold))
            Text(experienceStore.preferences.spoilerFreeMode && match.isCompleted ? "Resultado oculto pelo modo spoiler-free." : context.detail)
                .font(.caption)
                .foregroundStyle(Color.readableSecondary)
        }
        .padding(14)
        .background(Color.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func feedMetric(title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(Color.readableSecondary)
            Text(value)
                .font(.title3.monospacedDigit().weight(.heavy))
                .foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// The player-first "mental homepage" card: one hero-sized panel that puts a
/// single favorite front and center — next match with countdown, ranking &
/// projected ranking, form, rivalry against next opponent, an inline calendar
/// snippet, alert status, and an automatic story line.
///
/// The card fires `onStoryShown` when the automatic story is rendered and
/// `onNextMatchTap` when the "abrir próximo jogo" CTA is used. Together those
/// telemetry hooks close the loop on the player-first funnel — the parent view
/// forwards them to `ProductAnalyticsStore`.
struct PrimaryFavoritePlayerHero: View {
    @EnvironmentObject private var experienceStore: ExperiencePreferencesStore

    let player: Player
    let matches: [TennisMatch]
    let rankings: [RankingEntry]
    let onNextMatchTap: (TennisMatch) -> Void
    let onStoryShown: (String) -> Void

    @State private var lastStoryKindReported: String?

    private var insights: PlayerProfileInsights {
        PlayerProfileInsights(player: player, matches: matches, rankings: rankings)
    }

    private var liveMatch: TennisMatch? {
        matches
            .filter { $0.isLive && $0.involves(player: player) }
            .sorted { $0.date > $1.date }
            .first
    }

    private var focusMatch: TennisMatch? {
        liveMatch ?? insights.nextMatch
    }

    private var upcomingCalendar: [TennisMatch] {
        var results: [TennisMatch] = []
        if let next = insights.nextMatch { results.append(next) }
        results.append(contentsOf: insights.upcomingMatches)
        return Array(results.prefix(3))
    }

    private var opponentForFocus: Player? {
        focusMatch?.opponent(for: player)
    }

    private var rivalrySummary: PlayerProfileInsights.HeadToHeadSummary? {
        guard let opponentForFocus else { return nil }
        return insights.headToHead.first { $0.opponent.id == opponentForFocus.id }
    }

    private var storyLine: (kind: String, text: String) {
        if let live = liveMatch {
            let scoreText = experienceStore.preferences.spoilerFreeMode
                ? "placar oculto pelo modo spoiler-free"
                : (live.score.isEmpty ? live.status : live.score)
            return (
                "live",
                "Story agora: \(player.name) está em quadra contra \(live.opponent(for: player)?.name ?? "adversário"). \(scoreText)."
            )
        }
        if let next = insights.nextMatch, let opponent = next.opponent(for: player) {
            let projection = insights.rankingProjectionText.map { " " + $0 } ?? ""
            return (
                "upcoming",
                "Story automático: próximo jogo vs \(opponent.name) em \(next.date.formatted(.relative(presentation: .named))).\(projection)"
            )
        }
        if !insights.recentForm.isEmpty {
            let formText = insights.recentForm.map { $0 ? "W" : "L" }.joined(separator: " ")
            return (
                "form",
                "Story automático: forma recente \(formText). Assim que houver próximo jogo, o app destaca aqui."
            )
        }
        return (
            "empty",
            "Story automático pronto: próximo jogo, ranking projetado e rivalidade aparecem aqui assim que os dados sincronizarem."
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            heroHeader
            focusSection
            storySection
            metricsGrid
            if let rivalry = rivalrySummary {
                rivalryBlock(rivalry)
            }
            if !upcomingCalendar.isEmpty {
                calendarBlock
            }
            alertBlock
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [Color.green.opacity(0.20), Color.black.opacity(0.55)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.green.opacity(liveMatch == nil ? 0.25 : 0.55), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
    }

    private var heroHeader: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .fill(liveMatch == nil ? Color.green.opacity(0.25) : Color.red.opacity(0.28))
                    .frame(width: 56, height: 56)
                Image(systemName: liveMatch == nil ? "person.crop.circle.fill" : "dot.radiowaves.left.and.right")
                    .font(.title.weight(.heavy))
                    .foregroundStyle(liveMatch == nil ? .green : .red)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("HOME DO SEU JOGADOR")
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(Color.readableSecondary)
                NavigationLink(destination: PlayerDetailView(player: player)) {
                    HStack(spacing: 6) {
                        Text(player.name)
                            .font(.title2.weight(.heavy))
                            .foregroundStyle(.primary)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Color.readableSecondary)
                    }
                }
                .buttonStyle(.plain)
                Text("\(player.isWTA ? "WTA" : "ATP") · \(player.nationality)")
                    .font(.caption)
                    .foregroundStyle(Color.readableSecondary)
            }

            Spacer(minLength: 0)

            Text(liveMatch == nil ? "PLAYER" : "LIVE")
                .font(.caption2.weight(.heavy))
                .foregroundStyle(liveMatch == nil ? .green : .red)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.white.opacity(0.14), in: Capsule())
        }
    }

    @ViewBuilder
    private var focusSection: some View {
        if let focus = focusMatch {
            NavigationLink(destination: MatchDetailView(match: focus)) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: focus.isLive ? "dot.radiowaves.left.and.right" : "calendar.badge.clock")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(focus.isLive ? .red : .green)
                        Text(focus.isLive ? "AO VIVO AGORA" : "PRÓXIMO JOGO")
                            .font(.caption2.weight(.heavy))
                            .foregroundStyle(focus.isLive ? .red : .green)
                        Spacer(minLength: 0)
                        Text(countdownLine(for: focus))
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(Color.readableSecondary)
                    }

                    Text("vs \(opponentName(in: focus))")
                        .font(.title3.weight(.bold))

                    Text("\(focus.tournament?.name ?? "Torneio") • \(focus.date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(Color.readableSecondary)

                    if focus.isLive, !focus.score.isEmpty {
                        Text(experienceStore.preferences.spoilerFreeMode ? "Placar oculto pelo modo spoiler-free" : focus.score)
                            .font(.subheadline.weight(.semibold))
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.cardSurface)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture().onEnded {
                onNextMatchTap(focus)
            })
        } else {
            HStack(spacing: 10) {
                Image(systemName: "calendar")
                    .foregroundStyle(Color.readableSecondary)
                Text("Sem próximo jogo sincronizado ainda.")
                    .font(.subheadline)
                    .foregroundStyle(Color.readableSecondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.cardSurface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private var storySection: some View {
        let story = storyLine
        return Text(story.text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onAppear {
                guard lastStoryKindReported != story.kind else { return }
                lastStoryKindReported = story.kind
                onStoryShown(story.kind)
            }
    }

    private var metricsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            metricCell(
                title: "Ranking",
                value: insights.rank.map { "#\($0)" } ?? "N/A",
                icon: "number"
            )
            metricCell(
                title: "Projeção",
                value: insights.rankingProjectionText.map { shorten($0) } ?? "Sem projeção",
                icon: "chart.line.uptrend.xyaxis"
            )
            metricCell(
                title: "Forma",
                value: insights.recentForm.isEmpty ? "Sem amostra" : insights.recentForm.map { $0 ? "W" : "L" }.joined(separator: " "),
                icon: "waveform.path.ecg"
            )
            metricCell(
                title: "Calendário",
                value: "\(upcomingCalendar.count) próxima(s)",
                icon: "calendar"
            )
        }
    }

    private func rivalryBlock(_ rivalry: PlayerProfileInsights.HeadToHeadSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "person.2.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.orange)
                Text("Rivalidade vs \(rivalry.opponent.name)")
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(.orange)
                Spacer()
                Text(rivalry.record)
                    .font(.subheadline.weight(.bold))
            }
            if !rivalry.bySurface.isEmpty {
                HStack(spacing: 6) {
                    ForEach(rivalry.bySurface) { surface in
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
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var calendarBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.green)
                Text("Agenda")
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(.green)
                Spacer()
            }
            ForEach(upcomingCalendar) { match in
                NavigationLink(destination: MatchDetailView(match: match)) {
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(match.date, format: .dateTime.month().day())
                                .font(.caption.weight(.heavy))
                                .monospacedDigit()
                            Text(match.date, format: .dateTime.hour().minute())
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(Color.readableSecondary)
                        }
                        .frame(width: 44, alignment: .leading)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("vs \(opponentName(in: match))")
                                .font(.subheadline.weight(.semibold))
                            Text(match.tournament?.name ?? "Torneio")
                                .font(.caption2)
                                .foregroundStyle(Color.readableSecondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(Color.readableSecondary)
                    }
                    .padding(10)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .simultaneousGesture(TapGesture().onEnded {
                    onNextMatchTap(match)
                })
            }
        }
    }

    private var alertBlock: some View {
        HStack(spacing: 10) {
            Image(systemName: player.isFavorite ? "bell.badge.fill" : "bell.slash")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(player.isFavorite ? .green : Color.readableSecondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(player.isFavorite ? "Alertas agregados" : "Alertas desligados")
                    .font(.caption.weight(.heavy))
                Text(player.isFavorite
                     ? "Você recebe entrada em quadra, início e fim de \(player.name)."
                     : "Ative o jogador para receber alertas de partida.")
                    .font(.caption2)
                    .foregroundStyle(Color.readableSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func metricCell(title: String, value: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(.green)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title.uppercased())
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(Color.readableSecondary)
                Text(value)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func opponentName(in match: TennisMatch) -> String {
        match.opponent(for: player)?.name ?? "TBD"
    }

    private func countdownLine(for match: TennisMatch) -> String {
        if match.isLive { return "Em quadra" }
        let interval = match.date.timeIntervalSinceNow
        if interval <= 0 { return match.date.formatted(.relative(presentation: .named)) }
        let hours = Int(interval / 3600)
        let minutes = Int(interval.truncatingRemainder(dividingBy: 3600) / 60)
        if hours >= 24 {
            let days = hours / 24
            return "em \(days)d"
        }
        if hours >= 1 { return "em \(hours)h \(minutes)m" }
        return "em \(max(1, minutes))m"
    }

    private func shorten(_ text: String, limit: Int = 34) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "…"
    }
}

private struct FavoriteCalendarCompactRow: View {
    let match: TennisMatch

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .center, spacing: 2) {
                Text(dayLabel)
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(Color.readableSecondary)
                Text(match.date.formatted(date: .omitted, time: .shortened))
                    .font(.caption.monospacedDigit().weight(.bold))
            }
            .frame(width: 58)

            VStack(alignment: .leading, spacing: 3) {
                Text("\(match.player1TeamName) vs \(match.player2TeamName)")
                    .font(.subheadline.weight(.heavy))
                    .lineLimit(1)
                Text([match.tournament?.name, courtText].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(Color.readableSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Text(match.isLive ? "LIVE" : "NEXT")
                .font(.caption2.weight(.heavy))
                .foregroundStyle(match.isLive ? .red : .green)
        }
        .padding(12)
        .background(Color.cardSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var dayLabel: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(match.date) { return "Hoje" }
        if calendar.isDateInTomorrow(match.date) { return "Amanhã" }
        return match.date.formatted(.dateTime.weekday(.abbreviated))
    }

    private var courtText: String? {
        guard let orderOfPlay = match.orderOfPlaySnapshot else { return nil }
        if let order = orderOfPlay.order {
            return "\(orderOfPlay.courtName) #\(order)"
        }
        return orderOfPlay.courtName
    }
}

private struct FavoriteMatchCalendarView: View {
    @EnvironmentObject private var analyticsStore: ProductAnalyticsStore

    enum Window: String, CaseIterable, Identifiable {
        case today = "Hoje"
        case tomorrow = "Amanhã"
        case sevenDays = "7 dias"

        var id: String { rawValue }
    }

    let matches: [TennisMatch]
    let players: [Player]
    let tournaments: [Tournament]

    @State private var window: Window = .today
    @State private var selectedPlayerID = ""
    @State private var selectedTournamentID = ""
    @State private var didRecordCalendarViewed = false

    private var filteredMatches: [TennisMatch] {
        matches
            .filter(matchesWindow)
            .filter { match in
                if !selectedPlayerID.isEmpty {
                    return match.player1?.id.uuidString == selectedPlayerID || match.player2?.id.uuidString == selectedPlayerID
                }
                return true
            }
            .filter { match in
                if !selectedTournamentID.isEmpty {
                    return match.tournament?.id.uuidString == selectedTournamentID
                }
                return true
            }
            .sorted { lhs, rhs in
                let lhsPriority = priority(for: lhs)
                let rhsPriority = priority(for: rhs)
                if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
                let lhsOrder = lhs.orderOfPlaySnapshot?.order ?? Int.max
                let rhsOrder = rhs.orderOfPlaySnapshot?.order ?? Int.max
                if Calendar.current.isDate(lhs.date, inSameDayAs: rhs.date), lhsOrder != rhsOrder {
                    return lhsOrder < rhsOrder
                }
                return lhs.date < rhs.date
            }
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Janela", selection: $window) {
                        ForEach(Window.allCases) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)

                    Picker("Jogador", selection: $selectedPlayerID) {
                        Text("Todos").tag("")
                        ForEach(players) { player in
                            Text(player.name).tag(player.id.uuidString)
                        }
                    }

                    Picker("Torneio", selection: $selectedTournamentID) {
                        Text("Todos").tag("")
                        ForEach(tournaments) { tournament in
                            Text(tournament.name).tag(tournament.id.uuidString)
                        }
                    }
                }
                .appListCardRow()
            } header: {
                Text("Filtros")
            }

            if filteredMatches.isEmpty {
                Section {
                    ContentUnavailableView(
                        "Sem partidas nessa janela",
                        systemImage: "calendar.badge.exclamationmark",
                        description: Text("Quando a API sincronizar novos horários dos favoritos, eles aparecem aqui.")
                    )
                    .appListCardRow()
                }
            } else {
                ForEach(groupedDays, id: \.day) { group in
                    Section(dayTitle(group.day)) {
                        ForEach(group.matches) { match in
                            NavigationLink(destination: MatchDetailView(match: match)) {
                                FavoriteCalendarDetailRow(match: match)
                            }
                            .appListCardRow()
                            .simultaneousGesture(TapGesture().onEnded {
                                analyticsStore.record(
                                    ProductAnalyticsEventName.favoriteCalendarMatchOpened,
                                    properties: [
                                        "matchID": match.behaviorKey,
                                        "window": window.rawValue,
                                        "isLive": match.isLive ? "true" : "false",
                                        "priority": "\(priority(for: match))"
                                    ]
                                )
                            })
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .appleSportsBackground(.royal)
        .navigationTitle("Calendário dos favoritos")
        .onAppear {
            guard !didRecordCalendarViewed else { return }
            didRecordCalendarViewed = true
            analyticsStore.record(
                ProductAnalyticsEventName.favoriteCalendarViewed,
                properties: [
                    "entry": "calendar_screen",
                    "matchCount": "\(matches.count)",
                    "players": "\(players.count)",
                    "tournaments": "\(tournaments.count)"
                ]
            )
        }
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
    }

    private var groupedDays: [(day: Date, matches: [TennisMatch])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: filteredMatches) { match in
            calendar.startOfDay(for: match.date)
        }
        return grouped.keys
            .sorted()
            .map { day in (day, grouped[day]?.sorted { $0.date < $1.date } ?? []) }
    }

    private func matchesWindow(_ match: TennisMatch) -> Bool {
        let calendar = Calendar.current
        switch window {
        case .today:
            return calendar.isDateInToday(match.date)
        case .tomorrow:
            return calendar.isDateInTomorrow(match.date)
        case .sevenDays:
            let start = calendar.startOfDay(for: .now)
            let end = calendar.date(byAdding: .day, value: 7, to: start) ?? start
            return match.date >= start && match.date <= end
        }
    }

    private func priority(for match: TennisMatch) -> Int {
        if match.isFavorite { return 0 }
        let playerIDs = Set(players.map(\.id))
        if let player1 = match.player1, playerIDs.contains(player1.id) { return 1 }
        if let player2 = match.player2, playerIDs.contains(player2.id) { return 1 }
        if match.tournament?.isFavorite == true { return 2 }
        return 3
    }

    private func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Hoje" }
        if calendar.isDateInTomorrow(day) { return "Amanhã" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
    }
}

private struct FavoriteCalendarDetailRow: View {
    let match: TennisMatch

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .center, spacing: 2) {
                Text(match.date.formatted(date: .omitted, time: .shortened))
                    .font(.headline.monospacedDigit())
                Text(match.isLive ? "AO VIVO" : "Agenda")
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(match.isLive ? .red : Color.readableSecondary)
            }
            .frame(width: 62)

            VStack(alignment: .leading, spacing: 4) {
                Text("\(match.player1TeamName) vs \(match.player2TeamName)")
                    .font(.subheadline.weight(.semibold))
                Text(match.tournament?.name ?? "Torneio")
                    .font(.caption)
                    .foregroundStyle(Color.readableSecondary)
                if let court = courtText {
                    Label(court, systemImage: "sportscourt")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.readableSecondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var courtText: String? {
        guard let orderOfPlay = match.orderOfPlaySnapshot else { return nil }
        if let order = orderOfPlay.order {
            return "\(orderOfPlay.courtName) #\(order)"
        }
        return orderOfPlay.courtName
    }
}
