import OSLog
import SwiftUI
import SwiftData

// MARK: - Match Detail

struct MatchDetailView: View {
    enum DetailSection: String, CaseIterable, Identifiable {
        case scoreboard = "Resumo"
        // Antes eram 2 abas separadas (Match Brain + Stats) competindo por
        // atenção: Match Brain virou storytelling rico, Stats ficou quase
        // invisível. Sub-tabs em iOS já têm custo de descoberta — 3 é o teto
        // saudável. Mesclando, os dados estatísticos passam a ser contexto
        // da narrativa em vez de uma aba paralela ignorada.
        case analysis = "Partida"

        var id: String { rawValue }
    }

    @Environment(\.modelContext) private var context
    @EnvironmentObject private var behaviorStore: BehaviorPersonalizationStore
    @EnvironmentObject private var experienceStore: ExperiencePreferencesStore
    @EnvironmentObject private var analyticsStore: ProductAnalyticsStore
    @Query private var allMatches: [TennisMatch]
    @Query(sort: \RankingEntry.rank) private var rankings: [RankingEntry]
    @State private var section: DetailSection = .scoreboard
    @State private var animateLivePulse = false
    @State private var showMatchBrainDetail = false
    var match: TennisMatch

    init(match: TennisMatch) {
        self.match = match
        // H2H lookup back 5 years — balances completeness (career rivalries remain
        // visible) with performance (avoids loading matches from a first install
        // that imported a decade of history). 180 days was too narrow: a player's
        // first career meeting disappears after 6 months, making H2H stats wrong.
        let threshold = Calendar.current.date(byAdding: .year, value: -5, to: .now) ?? .distantPast
        _allMatches = Query(
            filter: #Predicate<TennisMatch> { $0.date >= threshold },
            sort: \TennisMatch.date,
            order: .reverse
        )
    }

    private var scoreboard: MatchScoreboardData {
        MatchScoreboardData(score: match.score)
    }

    private var hidesResultSpoilers: Bool {
        experienceStore.preferences.spoilerFreeMode && match.isCompleted
    }

    private var liveInsights: LiveMatchInsights {
        LiveMatchInsights(match: match, scoreboard: scoreboard)
    }

    private var feedHealthLabel: String {
        if match.isLive {
            return match.lastUpdatedAt == nil ? "Live sem timestamp" : "Live monitorado"
        }
        if match.isUpcoming {
            return "Pré-jogo"
        }
        return "Encerrado"
    }

    private var liveFeedSummary: String {
        if match.isLive {
            if let lastUpdatedAt = match.lastUpdatedAt {
                return "Atualização mais recente às \(lastUpdatedAt.formatted(date: .omitted, time: .standard))"
            }
            return "A partida está marcada como live, mas ainda sem timestamp."
        }
        if match.isUpcoming {
            return "Aguardando o início oficial da partida."
        }
        return "Feed encerrado. Último estado conhecido: \(match.status.isEmpty ? "Finalizado" : match.status)"
    }

    private var freshnessLabel: String {
        guard let lastUpdatedAt = match.lastUpdatedAt else { return "Sem timestamp" }

        let age = Date.now.timeIntervalSince(lastUpdatedAt)
        switch age {
        case ..<20:
            return "Agora"
        case ..<90:
            return "Quente"
        case ..<300:
            return "Recente"
        default:
            return "Defasado"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Cabeçalho persistente: status + scoreboard. Permanece em
                // todas as sub-abas porque é o contexto que o usuário precisa
                // ver sempre — quem joga, qual o placar, se está ao vivo.
                persistentHeader

                // Segmented picker divide em apenas 2 superfícies agora:
                // Placar (overview + feed state) / Análise (storytelling do
                // Match Brain + stats agregados + H2H + odds). Mesclar Brain
                // e Stats numa aba só elimina a competição por atenção entre
                // duas abas — stats deixou de ser superfície paralela e virou
                // suporte da narrativa.
                AppleSportsSegmentedPicker(
                    options: DetailSection.allCases.map { (label: $0.rawValue, value: $0) },
                    selection: $section
                )
                .accessibilityIdentifier("match-detail-section-picker")

                switch section {
                case .scoreboard:
                    scoreboardSectionContent
                case .analysis:
                    matchBrainSectionContent
                    statsSectionContent
                }
            }
            .padding()
        }
        .appleSportsBackground(.clay)
        .navigationTitle("Detalhes da partida")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
#endif
        .favoriteToolbar(isFavorite: match.isFavorite) {
            let willFavorite = !match.isFavorite
            match.isFavorite.toggle()
            if willFavorite {
                analyticsStore.record(
                    ProductAnalyticsEventName.favoriteMatchChosen,
                    properties: ["matchID": match.behaviorKey]
                )
            }
            Task {
                await AlertEventEngine.shared.refreshScheduledNotifications(in: context, force: true)
            }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                ShareLink(
                    item: ShareTextFactory.match(match),
                    preview: SharePreview("Match Point", image: Image(systemName: "tennisball"))
                ) {
                    Label("Compartilhar partida", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("match-detail-share")
            }
        }
        .onAppear {
            // Peers are the same-day tournament matches — they were shown next
            // to this one in the feed, so treating them as unopened negatives
            // gives the ranker a real contrastive signal per click.
            let calendar = Calendar.current
            let peers = allMatches.filter { peer in
                peer.id != match.id
                    && calendar.isDate(peer.date, inSameDayAs: match.date)
                    && peer.tournament?.id == match.tournament?.id
            }
            behaviorStore.recordMatchOpen(match, peers: peers, rankings: rankings)
            behaviorStore.recordRecommendationOpen(
                match,
                relevanceScore: detailIntelligence.relevanceScore,
                reasons: detailRelevanceReasons
            )
            analyticsStore.record(
                ProductAnalyticsEventName.matchOpened,
                properties: [
                    "matchID": match.behaviorKey,
                    "state": match.isLive ? "live" : match.isUpcoming ? "upcoming" : match.isCompleted ? "completed" : "other"
                ]
            )
            updateLivePulse()
        }
        .onChange(of: match.isLive) { _, _ in
            updateLivePulse()
        }
        .sheet(isPresented: $showMatchBrainDetail) {
            let narrative = MatchBrainNarrative(match: match, rankings: rankings, allMatches: allMatches)
            let liveContext = detailIntelligence.liveContext
            MatchBrainDetailSheet(
                narrative: narrative,
                liveContext: liveContext,
                pressureLabel: liveContext.pressureLabel,
                pressureScore: liveContext.pressureScore
            )
        }
    }

    // MARK: - Sub-tabs content

    private var detailIntelligence: MatchIntelligence {
        MatchIntelligence(match: match, rankings: rankings, allMatches: allMatches)
    }

    private var detailRelevanceReasons: [MatchRelevanceReason] {
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
            behavior: behaviorStore.snapshot,
            preferences: experienceStore.preferences
        )
    }

    private enum MatchHeroSide {
        case leading
        case trailing
    }

    private var tournamentContextLine: String {
        let tournament = match.tournament?.name ?? "Torneio"
        let surface = match.tournament?.surface ?? ""
        let round = matchRoundLabel
        return [tournament, surface, round].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var matchRoundLabel: String {
        let tournamentMatches = match.tournament?.matches ?? allMatches
        return MatchRoundResolver.roundLabel(for: match, allMatches: tournamentMatches)
    }

    private var player1Rank: Int? {
        rank(for: match.player1)
    }

    private var player2Rank: Int? {
        rank(for: match.player2)
    }

    private var topRankingEntries: [RankingEntry] {
        let tour = match.tournament?.tour ?? match.player1?.tour ?? match.player2?.tour
        let filtered = tour.map { selectedTour in
            rankings.filter { $0.tour == selectedTour }
        } ?? rankings
        return Array(filtered.prefix(5))
    }

    private var primaryMatchActionTitle: String {
        if match.isFavorite || match.player1?.isFavorite == true || match.player2?.isFavorite == true {
            return "Seguindo"
        }
        return "Seguir"
    }

    private var matchHeroTopBar: some View {
        HStack(alignment: .center, spacing: 10) {
            statusBadge
            Spacer()
            Text(tournamentContextLine)
                .font(.caption.weight(.bold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .foregroundStyle(Color.readableSecondary)
            Spacer()
            Image(systemName: "square.and.arrow.up")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Color.readableSecondary)
                .frame(width: 30, height: 30)
                .background(Color.black.opacity(0.22), in: Circle())
                .accessibilityHidden(true)
        }
    }

    private var matchHeroCenter: some View {
        VStack(spacing: 6) {
            if match.isLive {
                Text(match.pointScore.isEmpty ? "AO VIVO" : match.pointScore)
                    .font(.title2.monospacedDigit().weight(.heavy))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.75)
                Text(match.gameScore.isEmpty ? "em andamento" : "games \(match.gameScore)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.readableSecondary)
                    .lineLimit(1)
            } else if match.isUpcoming {
                Text(match.date, format: .dateTime.hour().minute())
                    .font(.title2.monospacedDigit().weight(.heavy))
                    .foregroundStyle(.white)
                Text(match.date, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.readableSecondary)
                    .lineLimit(1)
            } else {
                Text(hidesResultSpoilers ? "–" : (scoreboard.hasSets ? "\(scoreboard.setsWonByPlayer.player1)-\(scoreboard.setsWonByPlayer.player2)" : "FINAL"))
                    .font(.title2.monospacedDigit().weight(.heavy))
                    .foregroundStyle(.white)
                Text(hidesResultSpoilers ? "spoiler-free" : (match.status.isEmpty ? "encerrada" : match.status))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.readableSecondary)
                    .lineLimit(1)
            }
        }
        .frame(width: 82)
    }

    private var matchHeroActions: some View {
        HStack(spacing: 10) {
            Button {
                let willFavorite = !match.isFavorite
                match.isFavorite.toggle()
                if willFavorite {
                    analyticsStore.record(
                        ProductAnalyticsEventName.favoriteMatchChosen,
                        properties: ["matchID": match.behaviorKey, "surface": "match-hero"]
                    )
                }
                Task {
                    await AlertEventEngine.shared.refreshScheduledNotifications(in: context, force: true)
                }
            } label: {
                Image(systemName: match.isFavorite ? "checkmark.slider.horizontal.3" : "slider.horizontal.3")
                    .font(.subheadline.weight(.heavy))
                    .frame(width: 42, height: 34)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(Color.black.opacity(0.24), in: Capsule())
            .accessibilityLabel(primaryMatchActionTitle)

            Button {
                if match.isLive {
                    analyticsStore.record(
                        ProductAnalyticsEventName.liveActivityStarted,
                        properties: ["matchID": match.behaviorKey, "surface": "match-detail-button"]
                    )
                    LiveActivityController.shared.handle(match: match, rankings: rankings)
                } else {
                    if !match.isFavorite {
                        analyticsStore.record(
                            ProductAnalyticsEventName.favoriteMatchChosen,
                            properties: ["matchID": match.behaviorKey, "surface": "match-detail-primary"]
                        )
                    }
                    match.isFavorite = true
                    Task {
                        await AlertEventEngine.shared.refreshScheduledNotifications(in: context, force: true)
                    }
                }
            } label: {
                Label(
                    match.isLive ? "Live Activity" : primaryMatchActionTitle,
                    systemImage: match.isLive ? "dot.radiowaves.left.and.right" : "checkmark"
                )
                .font(.subheadline.weight(.heavy))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .padding(.horizontal, 16)
                .frame(height: 34)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(Color.white.opacity(0.22), in: Capsule())
        }
    }

    private var upcomingScoreStrip: some View {
        VStack(spacing: 8) {
            HStack {
                Text(compactName(match.player1?.name ?? "TBD"))
                Spacer()
                Text("Sets")
                    .foregroundStyle(Color.readableSecondary)
                Text("Pts")
                    .foregroundStyle(Color.readableSecondary)
            }
            .font(.caption.weight(.bold))

            HStack {
                Text(compactName(match.player2?.name ?? "TBD"))
                Spacer()
                Text("—")
                    .monospacedDigit()
                Text("—")
                    .monospacedDigit()
            }
            .font(.caption.weight(.bold))
        }
        .padding(12)
        .background(Color.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .foregroundStyle(.white)
    }

    private var matchMetaRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                heroMetaPill(icon: "calendar", text: match.date.formatted(date: .abbreviated, time: .shortened))
                if let tournament = match.tournament, !tournament.city.isEmpty {
                    heroMetaPill(icon: "mappin.and.ellipse", text: tournament.city)
                }
                if let tournament = match.tournament, !tournament.surface.isEmpty {
                    heroMetaPill(icon: "leaf.fill", text: tournament.surface)
                }
                heroMetaPill(icon: "antenna.radiowaves.left.and.right", text: feedHealthLabel)
            }
        }
    }

    private var relevanceReasonRail: some View {
        let rankLookup = Dictionary(
            rankings.compactMap { entry -> (UUID, Int)? in
                guard let playerID = entry.player?.id else { return nil }
                return (playerID, entry.rank)
            },
            uniquingKeysWith: { first, _ in first }
        )
        let reasons = Array(MatchIntelligence.relevanceReasons(
            for: match,
            rankByPlayerID: rankLookup,
            behavior: behaviorStore.snapshot
        ).prefix(4))
        return Group {
            if !reasons.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Por que está em destaque")
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(Color.readableSecondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(reasons) { reason in
                                Label(reason.label, systemImage: reason.symbol)
                                    .font(.caption2.weight(.semibold))
                                    .lineLimit(1)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.white.opacity(0.14), in: Capsule())
                                    .foregroundStyle(.white)
                            }
                        }
                    }
                }
            }
        }
    }

    private var matchHeroBackground: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.17, green: 0.43, blue: 0.10),
                    Color(red: 0.09, green: 0.28, blue: 0.09),
                    Color(red: 0.18, green: 0.10, blue: 0.30)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            VStack(spacing: 4) {
                ForEach(0..<26, id: \.self) { index in
                    Rectangle()
                        .fill(Color.white.opacity(index.isMultiple(of: 2) ? 0.035 : 0.018))
                        .frame(height: 2)
                }
                Spacer(minLength: 0)
            }
            .blendMode(.softLight)
        }
    }

    private var persistentHeader: some View {
        VStack(spacing: 18) {
            matchHeroTopBar

            HStack(alignment: .center, spacing: 12) {
                matchHeroPlayer(match.player1, side: .leading)
                matchHeroCenter
                matchHeroPlayer(match.player2, side: .trailing)
            }

            matchHeroActions

            if scoreboard.hasSets {
                MatchScoreboardView(
                    player1Name: match.player1?.name ?? "TBD",
                    player2Name: match.player2?.name ?? "TBD",
                    scoreboard: scoreboard,
                    highlightLive: match.isLive,
                    hidesScores: hidesResultSpoilers
                )
            } else {
                upcomingScoreStrip
            }

            matchMetaRail
            relevanceReasonRail
        }
        .padding(18)
        .background {
            matchHeroBackground
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
        )
    }

    private var scoreboardSectionContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            if match.isLive {
                liveMatchExperienceBlock
            } else if match.isUpcoming {
                preMatchExperienceBlock
            } else {
                recapSnapshotBlock
            }

            // H2H em destaque: aparece direto no Resumo, sem exigir fetch. O
            // card se auto-oculta quando não há histórico local entre os dois
            // jogadores, então não sujeita a UI a espaço vazio.
            HeadToHeadHeroCard(match: match, allMatches: allMatches)

            PreviousMatchesSection(currentMatch: match, allMatches: allMatches, rankings: rankings)

            rankingImpactBlock

            rankingSnapshotBlock

            if !match.score.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Placar")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.readableSecondary)
                    Text(hidesResultSpoilers ? "Resultado oculto pelo modo spoiler-free" : match.score)
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                }
            }

            overviewBlock
        }
    }

    private var liveMatchExperienceBlock: some View {
        let pointRun = MatchPointRunAnalyzer(match: match)
        let momentum = pointRun.momentumTimeline(limit: 10)
        let narrative = MatchBrainNarrative(match: match, rankings: rankings, allMatches: allMatches)

        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)
                Text("Partida ao vivo")
                    .font(.headline.weight(.heavy))
                Spacer()
                Text(freshnessLabel)
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(Color.readableSecondary)
            }

            LiveCourtPointView(
                player1Name: match.player1?.name ?? "Player 1",
                player2Name: match.player2?.name ?? "Player 2",
                serverName: match.serverName,
                pointScore: match.pointScore,
                gameScore: match.gameScore,
                momentum: momentum,
                moment: narrative.whyWatchNow,
                pulse: animateLivePulse
            )

            MomentumBar(
                points: momentum,
                player1ShortName: compactName(match.player1?.name ?? "P1"),
                player2ShortName: compactName(match.player2?.name ?? "P2")
            )
            .padding(14)
            .background(Color.cardSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            // Probabilidade ao vivo (estilo Sofascore). Só aparece quando o
            // engine tem sinal suficiente — momento, placar de sets ou games
            // do set corrente. Fica ao lado do MomentumBar porque os dois
            // narram a mesma pergunta: "quem tá dominando agora?"
            if let estimate = WinProbabilityEstimate.compute(from: match) {
                WinProbabilityCard(
                    estimate: estimate,
                    player1ShortName: compactName(match.player1?.name ?? "P1"),
                    player2ShortName: compactName(match.player2?.name ?? "P2")
                )
            }

            if let moment = narrative.whyWatchNow {
                WhyWatchNowCard(moment: moment) {
                    showMatchBrainDetail = true
                }
            }

            feedStateBlock
        }
    }

    private var preMatchExperienceBlock: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Prévia da partida")
                .font(.headline.weight(.heavy))

            HStack(spacing: 12) {
                preMatchInfoCard(title: "Começa", value: match.date.formatted(date: .omitted, time: .shortened), icon: "clock.fill")
                preMatchInfoCard(title: "Dia", value: match.date.formatted(date: .abbreviated, time: .omitted), icon: "calendar")
            }

            HStack(spacing: 12) {
                preMatchInfoCard(title: "Ranking", value: rankingVersusText, icon: "list.number")
                preMatchInfoCard(title: "Ação", value: primaryMatchActionTitle, icon: "bell.badge.fill")
            }

            Text(detailIntelligence.liveContext.headline)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.9))
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.cardSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            feedStateBlock
        }
    }

    private var recapSnapshotBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Resultado")
                .font(.headline.weight(.heavy))
            recapCard(
                title: match.status.isEmpty ? "Placar final" : match.status,
                body: hidesResultSpoilers ? "Resultado oculto pelo modo spoiler-free." : (match.score.isEmpty ? "Resultado encerrado sem placar detalhado do provedor." : match.score),
                accent: .green
            )
            feedStateBlock
        }
    }

    private var rankingSnapshotBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Ranking de simples")
                    .font(.headline.weight(.heavy))
                Spacer()
                Text(match.tournament?.tour.rawValue ?? match.player1?.tour.rawValue ?? "ATP/WTA")
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(Color.readableSecondary)
            }

            if topRankingEntries.isEmpty {
                Text("Sincronize rankings para mostrar a tabela do torneio.")
                    .font(.caption)
                    .foregroundStyle(Color.readableSecondary)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.cardSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else {
                VStack(spacing: 0) {
                    rankingHeaderRow
                    ForEach(topRankingEntries) { entry in
                        rankingRow(entry)
                    }
                }
                .background(Color.cardSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
    }

    @ViewBuilder
    private var rankingImpactBlock: some View {
        let narrative = MatchBrainNarrative(match: match, rankings: rankings, allMatches: allMatches)
        if let projection = narrative.liveRankingProjection ?? narrative.rankingImpact {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.blue)
                        .frame(width: 32, height: 32)
                        .background(Color.blue.opacity(0.14), in: Circle())

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Impacto no ranking")
                            .font(.headline.weight(.heavy))
                        Text(rankingImpactSubtitle)
                            .font(.caption)
                            .foregroundStyle(Color.readableSecondary)
                    }
                    Spacer()
                }

                Text(projection)
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)

                if !rankingPlayerPills.isEmpty {
                    FlowTagRow(items: rankingPlayerPills)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.cardSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.blue.opacity(0.28), lineWidth: 1)
            )
            .accessibilityIdentifier("match-detail-ranking-impact")
        }
    }

    private var rankingImpactSubtitle: String {
        if match.isCompleted { return "Leitura pós-jogo baseada no ranking sincronizado." }
        return "Cenário estimado se o jogador melhor ranqueado vencer."
    }

    private var rankingPlayerPills: [String] {
        [match.player1, match.player2].compactMap { player in
            guard let player, let entry = rankings.first(where: { $0.player?.id == player.id }) else {
                return nil
            }
            return "\(player.name): #\(entry.rank) · \(entry.points.formatted()) pts"
        }
    }

    private var rankingHeaderRow: some View {
        HStack {
            Text("Jogador")
            Spacer()
            Text("Total")
        }
        .font(.caption2.weight(.heavy))
        .foregroundStyle(Color.readableSecondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var matchBrainSectionContent: some View {
        if match.isLive {
            VStack(alignment: .leading, spacing: 20) {
                liveMatchPanel
                rankingImpactBlock
                liveActivityButton
                // Feed estilo "notificação Sofascore" — lance a lance da
                // partida em formato de notificação card, sempre renderizado
                // (com placeholder quando ainda não há eventos), do mais
                // recente pro mais antigo.
                liveNotificationsFeed
            }
        } else if match.isCompleted {
            recapContent
        } else {
            VStack(alignment: .leading, spacing: 16) {
                rankingImpactBlock
                ContentUnavailableView(
                    "Match Brain entra em ação ao vivo",
                    systemImage: "sparkles",
                    description: Text("Quando a partida começar, esta aba destaca pressão, momentum e contexto da quadra em tempo real.")
                )
                .padding(.vertical, 24)
            }
        }
    }

    /// Renderização retrospectiva do Match Brain pra jogos encerrados.
    /// Reusa `MatchBrainNarrative` (que existe há tempo no app) pra
    /// transformar headline + turning point + why-it-mattered + sinais +
    /// stats + impacto de ranking em um recap legível.
    private var recapContent: some View {
        let narrative = MatchBrainNarrative(match: match, rankings: rankings, allMatches: allMatches)
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.yellow)
                Text("Recap do jogo")
                    .font(.headline.weight(.bold))
            }

            recapCard(title: "O que decidiu", body: narrative.turningPoint, accent: .orange)
            recapCard(title: "Por que importou", body: narrative.whyItMatters, accent: .green)

            if let projection = narrative.liveRankingProjection ?? narrative.rankingImpact {
                recapCard(title: "Impacto no ranking", body: projection, accent: .blue)
            }

            if !narrative.advancedSignals.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Sinais avançados")
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(Color.readableSecondary)
                    ForEach(narrative.advancedSignals, id: \.self) { signal in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 5))
                                .foregroundStyle(Color.readableSecondary)
                                .padding(.top, 8)
                            Text(signal)
                                .font(.caption)
                                .foregroundStyle(Color.readableSecondary)
                        }
                    }
                }
                .padding(12)
                .background(Color.cardSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            if !narrative.keyStats.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Stats-chave")
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(Color.readableSecondary)
                    FlowTagRow(items: narrative.keyStats)
                }
            }
        }
    }

    private func recapCard(title: String, body: String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption2.weight(.heavy))
                .foregroundStyle(accent)
            Text(body)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.92))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(accent.opacity(0.3), lineWidth: 1)
        )
    }

    private var statsSectionContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            if scoreboard.hasSets {
                matchStatsSection
            }
            PreviousMatchesSection(currentMatch: match, allMatches: allMatches, rankings: rankings)
            HeadToHeadSection(match: match)
            OddsSection(match: match)
        }
    }

    private var feedStateBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Feed State")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.readableSecondary)

            HStack(spacing: 12) {
                headerMetricCard(title: "Status", value: match.status.isEmpty ? matchStatusTitle : match.status)
                headerMetricCard(title: "Feed", value: feedHealthLabel)
                headerMetricCard(title: "Freshness", value: freshnessLabel)
            }

            Text(liveFeedSummary)
                .font(.subheadline)
                .foregroundStyle(Color.readableSecondary)
        }
    }

    private func matchHeroPlayer(_ player: Player?, side: MatchHeroSide) -> some View {
        let name = player?.name ?? "TBD"
        let rank = rank(for: player)
        let flag = CountryFlag.emoji(for: player?.nationality ?? "")
        let isServing = match.serverName.localizedCaseInsensitiveContains(name) && match.isLive
        let alignment: HorizontalAlignment = side == .leading ? .leading : .trailing

        return VStack(alignment: alignment, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                Circle()
                    .fill(Color.white.opacity(0.18))
                    .frame(width: 58, height: 58)
                    .overlay(
                        Text(flag.isEmpty ? initials(for: name) : flag)
                            .font(flag.isEmpty ? .title3.weight(.heavy) : .title)
                    )
                    .overlay(
                        Circle()
                            .strokeBorder(isServing ? Color.yellow : Color.white.opacity(0.18), lineWidth: isServing ? 2 : 1)
                    )

                if isServing {
                    Image(systemName: "tennisball.fill")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                        .frame(width: 20, height: 20)
                        .background(Color.black.opacity(0.42), in: Circle())
                }
            }

            Text(playerDisplayName(name))
                .font(.subheadline.weight(.heavy))
                .multilineTextAlignment(side == .leading ? .leading : .trailing)
                .lineLimit(2)
                .minimumScaleFactor(0.82)
                .foregroundStyle(.white)

            Text(rank.map { "#\($0)" } ?? player?.nationality ?? "Ranking pendente")
                .font(.caption2.weight(.bold))
                .foregroundStyle(Color.readableSecondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: side == .leading ? .leading : .trailing)
    }

    private func heroMetaPill(icon: String, text: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption2.weight(.bold))
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Color.black.opacity(0.24), in: Capsule())
            .foregroundStyle(Color.readableSecondary)
    }

    private func preMatchInfoCard(title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.green)
            Text(title.uppercased())
                .font(.caption2.weight(.heavy))
                .foregroundStyle(Color.readableSecondary)
            Text(value)
                .font(.subheadline.weight(.heavy))
                .lineLimit(2)
                .minimumScaleFactor(0.82)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.cardSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var rankingVersusText: String {
        let first = player1Rank.map { "#\($0)" } ?? "s/r"
        let second = player2Rank.map { "#\($0)" } ?? "s/r"
        return "\(first) x \(second)"
    }

    private func rankingRow(_ entry: RankingEntry) -> some View {
        HStack(spacing: 10) {
            Text("\(entry.rank)")
                .font(.caption.weight(.heavy))
                .monospacedDigit()
                .foregroundStyle(Color.readableSecondary)
                .frame(width: 22, alignment: .leading)

            Text(CountryFlag.emoji(for: entry.player?.nationality ?? ""))
                .font(.caption)
                .frame(width: 20)

            Text(entry.player?.name ?? "Player")
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)

            Spacer()

            Text(entry.points.formatted())
                .font(.subheadline.monospacedDigit().weight(.bold))
                .foregroundStyle(.white.opacity(0.84))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(isMatchPlayer(entry.player) ? Color.white.opacity(0.12) : Color.clear)
    }

    private func rank(for player: Player?) -> Int? {
        guard let player else { return nil }
        return rankings.first(where: { $0.player?.id == player.id })?.rank
    }

    private func isMatchPlayer(_ player: Player?) -> Bool {
        guard let player else { return false }
        return player.id == match.player1?.id || player.id == match.player2?.id
    }

    private func compactName(_ name: String) -> String {
        let parts = name.split(separator: " ").map(String.init)
        guard parts.count >= 2, let firstInitial = parts.first?.first else { return name }
        return "\(firstInitial). \(parts.last ?? "")"
    }

    private func playerDisplayName(_ name: String) -> String {
        compactName(name)
    }

    private func initials(for name: String) -> String {
        let letters = name
            .split(separator: " ")
            .compactMap { $0.first }
            .prefix(2)
        let value = String(letters)
        return value.isEmpty ? "?" : value.uppercased()
    }

    private func updateLivePulse() {
        guard match.isLive else {
            animateLivePulse = false
            return
        }

        withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
            animateLivePulse = true
        }
    }

    private var overviewBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Overview")
                .font(.headline)

            detailRow(title: "Jogadores", value: "\(match.player1?.name ?? "TBD") vs \(match.player2?.name ?? "TBD")")

            if let t = match.tournament {
                detailRow(title: "Torneio", value: t.name)
            }

            detailRow(title: "Data", value: match.date.formatted(date: .abbreviated, time: .shortened))

            if !match.status.isEmpty {
                detailRow(title: "Status", value: match.status)
            }

            detailRow(title: "Feed", value: feedHealthLabel)

            if let updatedAt = match.lastUpdatedAt {
                detailRow(title: "Atualizado em", value: updatedAt.formatted(date: .abbreviated, time: .standard))
            }

            if match.isLive {
                detailRow(title: "Indicadores", value: liveIndicatorSummary)
            }
        }
    }

    /// Feed estilo "notificação Sofascore" pro Match Brain. Cada evento da
    /// timeline vira um card que se parece com uma push notification: ícone
    /// categorizado à esquerda, título + detalhe, timestamp à direita. Ordem
    /// invertida (mais recente em cima) — mesma convenção do Notification
    /// Center do iOS.
    private var liveNotificationsFeed: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "bell.fill")
                    .foregroundStyle(.yellow)
                Text("Lance a lance")
                    .font(.headline)
                Spacer()
                Text("ao vivo")
                    .font(.caption2.weight(.heavy))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.red.opacity(0.22), in: Capsule())
                    .foregroundStyle(.red)
            }

            if liveInsights.timeline.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                        .foregroundStyle(Color.readableSecondary)
                    Text("Aguardando o primeiro lance da partida. Quando o saque sair, os eventos chegam aqui como notificações em tempo real.")
                        .font(.caption)
                        .foregroundStyle(Color.readableSecondary)
                }
                .padding(14)
                .background(Color.cardSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                // `.reversed()` pra renderizar do mais recente pro mais antigo
                // (estilo Notification Center). Cap em 30 pra não explodir UI
                // em jogos com timeline gigante.
                ForEach(Array(liveInsights.timeline.reversed().prefix(30))) { event in
                    notificationCard(for: event)
                }
            }
        }
    }

    private func notificationCard(for event: MatchTimelineEvent) -> some View {
        let category = NotificationCategory.classify(event)
        return HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(category.tint.opacity(0.22))
                Image(systemName: category.icon)
                    .font(.subheadline)
                    .foregroundStyle(category.tint)
            }
            .frame(width: 32, height: 32)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(event.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    Text(event.timestamp, format: .dateTime.hour().minute())
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Color.readableSecondary)
                }
                if !event.detail.isEmpty {
                    Text(event.detail)
                        .font(.caption)
                        .foregroundStyle(Color.readableSecondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(category.tint)
                .frame(width: 3)
                .padding(.vertical, 8)
                .clipShape(RoundedRectangle(cornerRadius: 1.5))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.notificationCardAccessibilityLabel(for: event, category: category))
    }

    /// VoiceOver label for the "Lance a lance" timeline cards. Without this
    /// the reader hears the SF Symbol name, then a fragmented title/timestamp
    /// pair, and finally the detail line — three focus stops per row. Combine
    /// them into one so a screen-reader user can swipe through the timeline
    /// as a linear list, one coherent event per stop.
    fileprivate static func notificationCardAccessibilityLabel(
        for event: MatchTimelineEvent,
        category: NotificationCategory
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        let time = formatter.string(from: event.timestamp)

        var parts: [String] = [category.accessibilityLabel, event.title]
        if !event.detail.isEmpty {
            parts.append(event.detail)
        }
        parts.append(time)
        return parts.joined(separator: ". ")
    }

    /// Mapeia o texto livre do evento (`title`/`detail`) em uma categoria de
    /// ícone+cor. Mesma lógica que apps tipo Sofascore usam pra colorir push
    /// notifications por tipo (winner/break point/match point/etc).
    fileprivate enum NotificationCategory {
        case breakPoint
        case matchPoint
        case setPoint
        case tieBreak
        case ace
        case winner
        case hold
        case generic

        var icon: String {
            switch self {
            case .breakPoint: return "bolt.fill"
            case .matchPoint: return "trophy.fill"
            case .setPoint: return "flag.checkered"
            case .tieBreak: return "equal.circle.fill"
            case .ace: return "burst.fill"
            case .winner: return "checkmark.seal.fill"
            case .hold: return "tennisball.fill"
            case .generic: return "circle.fill"
            }
        }

        var tint: Color {
            switch self {
            case .breakPoint: return .orange
            case .matchPoint: return .red
            case .setPoint: return .pink
            case .tieBreak: return .blue
            case .ace: return .purple
            case .winner: return .green
            case .hold: return .yellow
            case .generic: return .secondary
            }
        }

        var accessibilityLabel: String {
            switch self {
            case .breakPoint: return "Break point"
            case .matchPoint: return "Match point"
            case .setPoint: return "Set point"
            case .tieBreak: return "Tie-break"
            case .ace: return "Ace"
            case .winner: return "Winner"
            case .hold: return "Game confirmado"
            case .generic: return "Atualização"
            }
        }

        static func classify(_ event: MatchTimelineEvent) -> NotificationCategory {
            let text = (event.title + " " + event.detail).lowercased()
            if text.contains("match point") || text.contains("matchpoint") { return .matchPoint }
            if text.contains("set point") || text.contains("setpoint") { return .setPoint }
            if text.contains("break") { return .breakPoint }
            if text.contains("tie") { return .tieBreak }
            if text.contains("ace") { return .ace }
            if text.contains("winner") { return .winner }
            if text.contains("hold") || text.contains("saque") { return .hold }
            return .generic
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        HStack(spacing: 6) {
            if match.isLive {
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)
            }
            Text(match.isLive ? "LIVE" : matchStatusTitle)
                .font(.caption.weight(.bold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(match.isLive ? Color.red.opacity(0.12) : Color.gray.opacity(0.12))
        .foregroundStyle(match.isLive ? .red : Color.readableSecondary)
        .clipShape(Capsule())
    }

    private var matchStatusTitle: String {
        if !match.status.isEmpty {
            return match.status.uppercased()
        }

        return match.date >= .now ? "UPCOMING" : "FINAL"
    }

    private var liveContextAvailable: Bool {
        !match.serverName.isEmpty || !match.pointScore.isEmpty || !match.gameScore.isEmpty
    }

    private var liveIndicatorSummary: String {
        var indicators: [String] = []
        if !match.serverName.isEmpty { indicators.append("saque") }
        if !match.gameScore.isEmpty { indicators.append("game") }
        if !match.pointScore.isEmpty { indicators.append("point-by-point") }
        if !match.timelineEvents.isEmpty { indicators.append("timeline") }
        return indicators.isEmpty ? "telemetria parcial" : indicators.joined(separator: ", ")
    }

    @ViewBuilder
    private func headerMetricCard(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.readableSecondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private var liveActivityButton: some View {
        Button {
            LiveActivityController.shared.handle(match: match, rankings: rankings)
        } label: {
            Label("Iniciar Live Activity", systemImage: "dot.radiowaves.left.and.right")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
        .accessibilityIdentifier("match-detail-start-live-activity")
    }

    @ViewBuilder
    private var liveMatchPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Live Match")
                .font(.headline)

            HStack(spacing: 12) {
                liveMetricCard(title: "Status", value: liveInsights.status)
                liveMetricCard(title: "Set atual", value: liveInsights.currentSetLabel)
            }

            HStack(spacing: 12) {
                liveMetricCard(title: "Game atual", value: liveInsights.currentGameLabel)
                liveMetricCard(title: "Saque", value: liveInsights.serverLabel)
            }

            HStack(spacing: 12) {
                liveMetricCard(title: "Ponto", value: liveInsights.pointLabel)
                liveMetricCard(title: "Break point", value: liveInsights.breakPointLabel)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Momentum")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.readableSecondary)
                    Spacer()
                    Text("\(liveInsights.momentumSegments[0].label) vs \(liveInsights.momentumSegments[1].label)")
                        .font(.caption2)
                        .foregroundStyle(Color.readableSecondary)
                }

                HStack(spacing: 8) {
                    ForEach(liveInsights.momentumSegments) { segment in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(segment.label)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Color.readableSecondary)

                            Capsule()
                                .fill(segment.color.opacity(0.22))
                                .overlay(alignment: .leading) {
                                    GeometryReader { proxy in
                                        Capsule()
                                            .fill(segment.color)
                                            .frame(width: max(18, proxy.size.width * segment.weight))
                                    }
                                }
                                .frame(height: 10)
                        }
                    }
                }
            }
            .padding(14)
            .background(Color.cardSurface)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    @ViewBuilder
    private func scoreboardRow(name: String) -> some View {
        HStack {
            Text(name)
                .font(.title3.weight(.semibold))
            Spacer()
        }
    }

    @ViewBuilder
    private func detailRow(title: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(title)
                .foregroundStyle(Color.readableSecondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
        }
    }

    private var matchStatsSection: some View {
        let setsWon = scoreboard.setsWonByPlayer
        let games = scoreboard.totalGames
        let bestSet = scoreboard.bestSetForPlayer1
        let breakdown = MatchStatsBreakdown.compute(from: match)

        return VStack(alignment: .leading, spacing: 14) {
            Text("Estatísticas da partida")
                .font(.headline)

            VStack(spacing: 14) {
                AppleSportsStatBar(
                    leftValue: String(setsWon.player1),
                    label: "Sets vencidos",
                    rightValue: String(setsWon.player2),
                    leftRatio: ratio(setsWon.player1, setsWon.player2)
                )
                AppleSportsStatBar(
                    leftValue: String(games.player1),
                    label: "Games totais",
                    rightValue: String(games.player2),
                    leftRatio: ratio(games.player1, games.player2)
                )
                if scoreboard.sets.count > 0 {
                    AppleSportsStatBar(
                        leftValue: String(scoreboard.sets.count),
                        label: "Sets disputados",
                        rightValue: String(scoreboard.sets.count),
                        leftRatio: 0.5
                    )
                }
                if let bestSet {
                    AppleSportsStatBar(
                        leftValue: "Set \(bestSet.setIndex + 1)",
                        label: "Melhor set p/ \(match.player1?.name ?? "P1")",
                        rightValue: "\(bestSet.player1Games)-\(bestSet.player2Games)",
                        leftRatio: ratio(bestSet.player1Games, bestSet.player2Games)
                    )
                }
            }
            .liquidGlassCard(cornerRadius: 22, padding: 18)

            if breakdown.isMeaningful {
                advancedStatsCard(for: breakdown)
            } else {
                advancedStatsPlaceholder
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Por set")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.readableSecondary)

                VStack(spacing: 14) {
                    ForEach(scoreboard.sets) { set in
                        AppleSportsStatBar(
                            leftValue: set.player1Games,
                            label: "Set \(set.id + 1)",
                            rightValue: set.player2Games,
                            leftRatio: ratio(Int(set.player1Games) ?? 0, Int(set.player2Games) ?? 0)
                        )
                    }
                }
                .liquidGlassCard(cornerRadius: 22, padding: 18)
            }
        }
    }

    // Card com stats derivados da timeline (aces, winners, break points, etc).
    // Só renderiza barras onde há amostra ≥ 1 pra pelo menos um dos jogadores —
    // evita mostrar "0-0 Aces" pra jogos onde essa dimensão nunca apareceu.
    private func advancedStatsCard(for breakdown: MatchStatsBreakdown) -> some View {
        let p1 = breakdown.player1
        let p2 = breakdown.player2

        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Detalhes por ponto")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.readableSecondary)
                Spacer()
                Text("\(breakdown.sampleSize) pontos")
                    .font(.caption2.monospacedDigit().weight(.heavy))
                    .foregroundStyle(Color.readableSecondary)
            }

            VStack(spacing: 14) {
                statBar(
                    leftInt: p1.totalPoints,
                    rightInt: p2.totalPoints,
                    label: "Pontos ganhos"
                )
                if p1.serviceAttempts + p2.serviceAttempts > 0 {
                    statBar(
                        leftLabel: percentText(p1.servicePointsWonRatio, count: p1.pointsOnServe, of: p1.serviceAttempts),
                        rightLabel: percentText(p2.servicePointsWonRatio, count: p2.pointsOnServe, of: p2.serviceAttempts),
                        label: "Pontos no saque",
                        leftRatio: p1.servicePointsWonRatio,
                        rightRatio: p2.servicePointsWonRatio
                    )
                }
                if p1.returnAttempts + p2.returnAttempts > 0 {
                    statBar(
                        leftLabel: percentText(p1.returnPointsWonRatio, count: p1.pointsOnReturn, of: p1.returnAttempts),
                        rightLabel: percentText(p2.returnPointsWonRatio, count: p2.pointsOnReturn, of: p2.returnAttempts),
                        label: "Pontos no retorno",
                        leftRatio: p1.returnPointsWonRatio,
                        rightRatio: p2.returnPointsWonRatio
                    )
                }
                if p1.aces + p2.aces > 0 {
                    statBar(leftInt: p1.aces, rightInt: p2.aces, label: "Aces")
                }
                if p1.winners + p2.winners > 0 {
                    statBar(leftInt: p1.winners, rightInt: p2.winners, label: "Winners")
                }
                if p1.unforcedErrors != nil || p2.unforcedErrors != nil {
                    statBar(
                        leftInt: p1.unforcedErrors ?? 0,
                        rightInt: p2.unforcedErrors ?? 0,
                        label: "Erros não forçados"
                    )
                }
                if p1.doubleFaults + p2.doubleFaults > 0 {
                    statBar(leftInt: p1.doubleFaults, rightInt: p2.doubleFaults, label: "Duplas faltas")
                }
                if p1.netPointsWon != nil || p2.netPointsWon != nil {
                    if p1.netPointsPlayed != nil || p2.netPointsPlayed != nil {
                        statBar(
                            leftLabel: netPointText(won: p1.netPointsWon, played: p1.netPointsPlayed),
                            rightLabel: netPointText(won: p2.netPointsWon, played: p2.netPointsPlayed),
                            label: "Pontos na rede",
                            leftRatio: p1.netPointsWonRatio,
                            rightRatio: p2.netPointsWonRatio
                        )
                    } else {
                        statBar(
                            leftInt: p1.netPointsWon ?? 0,
                            rightInt: p2.netPointsWon ?? 0,
                            label: "Pontos na rede"
                        )
                    }
                }
                if p1.breakPointOpportunities + p2.breakPointOpportunities > 0 {
                    statBar(
                        leftLabel: "\(p1.breakPointsConverted)/\(p1.breakPointOpportunities)",
                        rightLabel: "\(p2.breakPointsConverted)/\(p2.breakPointOpportunities)",
                        label: "Break points convertidos",
                        leftRatio: p1.breakPointConversionRatio,
                        rightRatio: p2.breakPointConversionRatio
                    )
                }
                if p1.breakPointsFaced + p2.breakPointsFaced > 0 {
                    statBar(
                        leftLabel: "\(p1.breakPointsSaved)/\(p1.breakPointsFaced)",
                        rightLabel: "\(p2.breakPointsSaved)/\(p2.breakPointsFaced)",
                        label: "Break points salvos",
                        leftRatio: p1.breakPointSaveRatio,
                        rightRatio: p2.breakPointSaveRatio
                    )
                }
            }
            .liquidGlassCard(cornerRadius: 22, padding: 18)

            Text(advancedStatsFootnote)
                .font(.caption2)
                .foregroundStyle(Color.readableSecondary)
        }
    }

    private var advancedStatsPlaceholder: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .foregroundStyle(.teal)
                Text("Estatísticas expandidas em breve")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
            }
            Text("Aces, winners, unforced errors, net points e break points aparecem aqui quando o feed da partida envia timeline ou estatísticas oficiais.")
                .font(.caption)
                .foregroundStyle(Color.readableSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.cardSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // Overloads que padronizam a construção de AppleSportsStatBar pra stats:
    // - Ints puros -> proporção pelo total.
    // - Porcentagem/label livre -> proporção comparativa entre os dois lados.
    private func statBar(leftInt: Int, rightInt: Int, label: String) -> some View {
        AppleSportsStatBar(
            leftValue: String(leftInt),
            label: label,
            rightValue: String(rightInt),
            leftRatio: ratio(leftInt, rightInt)
        )
    }

    private func statBar(
        leftLabel: String,
        rightLabel: String,
        label: String,
        leftRatio: Double,
        rightRatio: Double
    ) -> some View {
        // A barra normaliza os dois ratios entre si — se ambos são zero, cada
        // lado ocupa metade; caso contrário divide proporcionalmente pra que
        // uma superioridade percentual seja visível de relance.
        let total = leftRatio + rightRatio
        let normalized = total > 0 ? leftRatio / total : 0.5
        return AppleSportsStatBar(
            leftValue: leftLabel,
            label: label,
            rightValue: rightLabel,
            leftRatio: normalized
        )
    }

    private func percentText(_ ratio: Double, count: Int, of total: Int) -> String {
        guard total > 0 else { return "—" }
        let pct = Int((ratio * 100).rounded())
        return "\(pct)% (\(count)/\(total))"
    }

    private func netPointText(won: Int?, played: Int?) -> String {
        guard let won else { return "—" }
        if let played, played > 0 {
            let ratio = Double(won) / Double(played)
            let pct = Int((ratio * 100).rounded())
            return "\(pct)% (\(won)/\(played))"
        }
        return "\(won)"
    }

    private var advancedStatsFootnote: String {
        if match.advancedStatsSnapshot != nil {
            return "Winners, erros não forçados e pontos na rede usam estatística oficial quando disponível. O restante pode ser derivado da timeline ao vivo."
        }
        return "Números derivados da timeline ao vivo. Podem se ajustar durante a partida conforme novos lances chegam."
    }

    private func ratio(_ left: Int, _ right: Int) -> Double {
        let total = left + right
        guard total > 0 else { return 0.5 }
        return Double(left) / Double(total)
    }

    @ViewBuilder
    private func livePill(title: String, value: String) -> some View {
        if !value.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.readableSecondary)
                Text(value)
                    .font(.headline)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.red.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    @ViewBuilder
    private func liveMetricCard(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.readableSecondary)
            Text(value)
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(Color.red.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

#Preview {
    NavigationStack {
        PlayerDetailView(player: Player(name: "Sample Player", nationality: "USA", isWTA: false))
    }
}
