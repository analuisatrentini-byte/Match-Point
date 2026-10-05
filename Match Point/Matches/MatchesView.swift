import SwiftUI
import SwiftData

struct MatchesView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var experienceStore: ExperiencePreferencesStore
    @EnvironmentObject private var behaviorStore: BehaviorPersonalizationStore
    @EnvironmentObject private var analyticsStore: ProductAnalyticsStore
    @Query private var matches: [TennisMatch]
    @Query(sort: \RankingEntry.rank) private var rankings: [RankingEntry]
    @State private var isSyncing = false
    @State private var liveService: LiveMatchWebSocketService?
    @State private var syncFeedback: UserFacingSyncFeedback?
    @State private var animateLivePulse = false
    @State private var visibleMatchLimit = 30
    // Materialized derived data. Previously these were `var liveMatches: ...`
    // computed properties that recomputed every time body ran — and body
    // accessed them 6+ times (count badges, section guards, ForEach prefixes,
    // `.forYou` filter pipeline). That made every WebSocket frame trigger a
    // full re-sort of relevance scores. The values below are recomputed only
    // when the underlying inputs (matches, rankings, picker filter) change.
    @State private var liveMatches: [TennisMatch] = []
    @State private var todayAgenda: [TennisMatch] = []
    @State private var upcomingMatches: [TennisMatch] = []
    @State private var filteredMatches: [TennisMatch] = []
    /// Last signature computed by the polling task. Kept in @State so the
    /// O(n) walk happens on a 2-second timer instead of every body re-render
    /// (which a noisy WebSocket frame stream can trigger many times per
    /// second). `.onChange(of:)` listens to this cached value, which only
    /// advances when the timer detects a real transition.
    @State private var derivedDataSignature: Int = 0

    init() {
        let threshold = MatchQueryWindow.matchList()
        _matches = Query(
            filter: #Predicate<TennisMatch> { $0.date >= threshold },
            sort: \TennisMatch.date,
            order: .reverse
        )
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let syncFeedback {
                    SyncFeedbackBanner(feedback: syncFeedback)
                }

                liveCenterHeader

                if !liveMatches.isEmpty {
                    liveTicker
                    livePulseBoard
                }

                VStack(alignment: .leading, spacing: 12) {
                    Picker("Filtro", selection: Binding(
                        get: { experienceStore.preferences.matchFilter },
                        set: { newValue in
                            experienceStore.update { $0.matchFilter = newValue }
                            visibleMatchLimit = 30
                        }
                    )) {
                        ForEach(MatchPresentationFilter.allCases) { filter in
                            Text(filter.rawValue).tag(filter)
                        }
                    }
                    .pickerStyle(.segmented)

                    if case .failed(let message) = liveService?.state {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(Color.readableSecondary)
                    }

                    if !TennisAPIConfiguration.selectedProviderHasConfiguredKey {
                        Text(providerConfigurationMessage)
                            .font(.caption)
                            .foregroundStyle(Color.readableSecondary)
                    }
                }

                if !liveMatches.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        sectionHeader(title: "Live Center", subtitle: "Cartões de alta prioridade")

                        ForEach(liveMatches.prefix(4)) { match in
                            NavigationLink(destination: MatchDetailView(match: match)) {
                                CachedMatchHeroCard(
                                    match: match,
                                    rankings: rankings,
                                    allMatches: matches
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if !todayAgenda.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        sectionHeader(title: "Agenda do dia", subtitle: "O que acontece hoje")

                        ForEach(todayAgenda.prefix(6)) { match in
                            NavigationLink(destination: MatchDetailView(match: match)) {
                                agendaRow(for: match)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if !upcomingMatches.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        sectionHeader(title: "Próximas", subtitle: "Confrontos mais relevantes")

                        ForEach(upcomingMatches.prefix(6)) { match in
                            NavigationLink(destination: MatchDetailView(match: match)) {
                                upcomingCard(for: match)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    sectionHeader(title: "Todas as partidas", subtitle: "Lista dentro do filtro ativo")

                    if filteredMatches.isEmpty {
                        EmptyStateActionCard(
                            title: emptyMatchesTitle,
                            message: emptyMatchesMessage,
                            systemImage: "calendar.badge.exclamationmark",
                            primaryAction: EmptyStateAction(
                                label: "Sincronizar agora",
                                systemImage: "arrow.clockwise",
                                tint: .green,
                                accessibilityIdentifier: "matches-empty-sync"
                            ) {
                                Task { await runManualSync() }
                            }
                        )
                    }

                    ForEach(Array(filteredMatches.prefix(visibleMatchLimit))) { m in
                        NavigationLink(destination: MatchDetailView(match: m)) {
                            matchListCard(for: m)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .leading) {
                            Button {
                                NotificationCenter.default.post(
                                    name: .openBetWizard,
                                    object: nil,
                                    userInfo: ["matchID": m.id]
                                )
                            } label: {
                                Label("Apostar", systemImage: "ticket")
                            }
                            .tint(.green)
                        }
                        .favoriteSwipeAction(isFavorite: m.isFavorite) {
                            let willFavorite = !m.isFavorite
                            m.isFavorite.toggle()
                            if willFavorite {
                                analyticsStore.record(
                                    ProductAnalyticsEventName.favoriteMatchChosen,
                                    properties: ["matchID": m.behaviorKey, "surface": "matches-list"]
                                )
                            }
                            Task {
                                await AlertEventEngine.shared.refreshScheduledNotifications(in: context, force: true)
                            }
                        }
                    }

                    if filteredMatches.count > visibleMatchLimit {
                        Button {
                            visibleMatchLimit += 30
                        } label: {
                            Label("Carregar mais partidas", systemImage: "chevron.down.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .padding()
        }
        .appleSportsBackground(.clay)
        .navigationTitle("Partidas")
        .task {
            guard !isSyncing else { return }
            while !Task.isCancelled {
                if AutoSyncTracker.shouldSync(.matches) {
                    await runAutoSync()
                }
                do {
                    try await Task.sleep(for: .seconds(15))
                } catch {
                    return
                }
            }
        }
        // Poll the matches signature on a 2-second cadence. This pulls the
        // O(n) walk out of the body hot path — body re-renders on every
        // @Published change from CloudSocialBackend / live service, and we
        // don't want each of those to scan the full match list.
        .task {
            while !Task.isCancelled {
                let newSignature = Self.makeSignature(for: matches)
                if newSignature != derivedDataSignature {
                    derivedDataSignature = newSignature
                }
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }
            }
        }
        .onAppear {
            if liveService == nil {
                liveService = LiveMatchWebSocketService(context: context)
            }
            startLivePulseIfActive()
            recomputeDerivedData()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                startLivePulseIfActive()
            } else {
                // .repeatForever animations keep ticking when the app is
                // backgrounded, burning CPU/battery. Stop the loop here and
                // resume on `.active`.
                animateLivePulse = false
            }
        }
        // Recompute derived data only when the relevant inputs really change.
        // `.onChange(of: matches)` catches set membership changes (new sync,
        // delete), but it does NOT fire when an existing @Model instance
        // mutates in place — most importantly the `isUpcoming → isLive`
        // flip during a WebSocket sync, where the array's reference identity
        // stays stable. `derivedDataSignature` rolls every match's live /
        // upcoming / completed state into a single Int so SwiftUI catches
        // that transition through a normal value comparison.
        .onChange(of: matches) { _, _ in recomputeDerivedData() }
        .onChange(of: derivedDataSignature) { _, _ in recomputeDerivedData() }
        .onChange(of: rankings) { _, _ in recomputeDerivedData() }
        .onChange(of: experienceStore.preferences.matchFilter) { _, _ in recomputeDerivedData() }
        .onChange(of: experienceStore.preferences.tourFilter) { _, _ in recomputeDerivedData() }
        .onChange(of: behaviorStore.snapshot.signature) { _, _ in recomputeDerivedData() }
        .toolbar {
            #if DEBUG
            ToolbarItem(placement: .primaryAction) {
                Button { addSampleMatch() } label: { Label("Add", systemImage: "plus") }
            }
            #endif
            ToolbarItem(placement: .automatic) {
                Button {
                    toggleLiveUpdates()
                } label: {
                    Label(liveStatusLabel, systemImage: liveStatusIcon)
                }
                .disabled(liveService == nil)
            }
            ToolbarItem(placement: .status) {
                if isSyncing {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Sincronizando partidas")
                }
            }
        }
    }

    // MARK: - Derived Data

    /// Pure signature of the current matches list — used by the polling
    /// task below. Walks every match once and rolls live/upcoming/favorite
    /// counts plus the array length into a single Int. Stable across body
    /// re-renders so SwiftUI's `.onChange(of:)` only fires when the *value*
    /// actually changes.
    private static func makeSignature(for matches: [TennisMatch]) -> Int {
        var live = 0
        var upcoming = 0
        var favorited = 0
        for m in matches {
            if m.isLive { live += 1 }
            if m.isUpcoming { upcoming += 1 }
            if m.isFavorite { favorited += 1 }
        }
        return (live &* 1_000_003) &+ (upcoming &* 65_537) &+ (favorited &* 257) &+ matches.count
    }

    /// Single recomputation entry point. Called from `.onAppear` and from
    /// `.onChange` hooks on the inputs (matches, rankings, picker filter).
    /// Keeps the work off the body hot path.
    private func recomputeDerivedData() {
        let behavior = behaviorStore.snapshot
        let live = MatchIntelligence.sortedByRelevance(matches.filter(\.isLive), rankings: rankings, behavior: behavior)
        let upcoming = MatchIntelligence.sortedByRelevance(matches.filter(\.isUpcoming), rankings: rankings, behavior: behavior)
        let today = matches.filter { Calendar.current.isDateInToday($0.date) }.sorted { $0.date < $1.date }

        let source: [TennisMatch]
        switch experienceStore.preferences.matchFilter {
        case .all:
            source = matches
        case .live:
            source = live
        case .upcoming:
            source = upcoming
        case .forYou:
            source = ForYouFeedBuilder
                .sections(matches: matches, rankings: rankings, preferences: experienceStore.preferences, behavior: behavior)
                .flatMap(\.matches)
        }

        liveMatches = live
        todayAgenda = today
        upcomingMatches = upcoming
        filteredMatches = deduplicate(source)
    }

    private var providerConfigurationMessage: String {
        "A sincronização está temporariamente indisponível. Tente novamente em instantes."
    }

    private var emptyMatchesTitle: String {
        switch experienceStore.preferences.matchFilter {
        case .live:
            return "Sem partidas ao vivo"
        case .upcoming:
            return "Sem próximas partidas"
        case .forYou:
            return "Nada recomendado ainda"
        case .all:
            return "Nenhuma partida encontrada"
        }
    }

    private var emptyMatchesMessage: String {
        if !TennisAPIConfiguration.selectedProviderHasConfiguredKey {
            return providerConfigurationMessage
        }
        switch experienceStore.preferences.matchFilter {
        case .live:
            return "Quando o feed ao vivo trouxer jogos em andamento, eles aparecem aqui."
        case .upcoming:
            return "Sincronize o calendário para carregar próximos confrontos."
        case .forYou:
            return "Favorite jogadores ou torneios para melhorar as recomendações."
        case .all:
            return "Sincronize para carregar a lista de partidas."
        }
    }

    // MARK: - Header

    private var liveCenterHeader: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Live Center")
                        .font(.largeTitle.weight(.black))
                        .accessibilityIdentifier("matches-live-center-title")
                    Text(homeSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(Color.readableSecondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    Text(liveStatusLabel)
                        .font(.caption)
                        .foregroundStyle(Color.readableSecondary)
                    SyncFreshnessLabel(scope: .matches, isSyncing: isSyncing)
                    if liveMatches.isEmpty == false {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 8, height: 8)
                                .scaleEffect(animateLivePulse ? 1 : 0.72)
                                .opacity(animateLivePulse ? 1 : 0.45)
                            Text("Sinal ao vivo")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Color.readableSecondary)
                        }
                    }
                }
            }

            HStack(spacing: 12) {
                headlineMetric(title: "Ao vivo", value: "\(liveMatches.count)", accent: .red)
                headlineMetric(title: "Hoje", value: "\(todayAgenda.count)", accent: .green)
                headlineMetric(title: "Próximas", value: "\(upcomingMatches.count)", accent: .blue)
            }

            HStack(spacing: 12) {
                Button {
                    toggleLiveUpdates()
                } label: {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(liveConnectionDotColor)
                            .frame(width: 8, height: 8)
                            .scaleEffect(liveService?.state.isActive == true ? (animateLivePulse ? 1 : 0.7) : 1)
                        Text(liveService?.state.isActive == true ? "Desconectar" : "Conectar ao vivo")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(liveService == nil || TennisAPIConfiguration.selectedProvider != .apiTennis)
                .accessibilityIdentifier("matches-toggle-live")

                if case .failed = liveService?.state {
                    reconnectButton
                }
            }

            if let liveRecoveryMessage {
                Text(liveRecoveryMessage)
                    .font(.caption)
                    .foregroundStyle(Color.readableSecondary)
            }

            if let fallbackNotice = liveService?.fallbackNotice {
                Label(fallbackNotice, systemImage: "arrow.triangle.2.circlepath.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.cardOverlaySoft)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityIdentifier("matches-rest-fallback-notice")
            }

        }
        .padding(20)
        .background(Color.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(Color.cardSurfaceStroke.opacity(0.42), lineWidth: 1)
        }
    }

    private var reconnectButton: some View {
        Button {
            liveService?.reconnect()
        } label: {
            Label("Reconectar", systemImage: "arrow.clockwise")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("matches-reconnect")
    }

    // MARK: - Match Rows

    private var liveTicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(liveMatches.prefix(10)) { match in
                    NavigationLink(destination: MatchDetailView(match: match)) {
                        liveTickerChip(for: match)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var livePulseBoard: some View {
        HStack(spacing: 12) {
            pulseBoardMetric(
                title: "Destaque",
                value: liveMatches.first?.status.isEmpty == false ? (liveMatches.first?.status ?? "Ao vivo") : "Partidas quentes",
                accent: .red
            )
            pulseBoardMetric(
                title: "Atualização",
                value: liveStatusLabel,
                accent: .green
            )
            pulseBoardMetric(
                title: "Filtro",
                value: experienceStore.preferences.matchFilter.rawValue,
                accent: .black
            )
        }
    }

    private var homeSubtitle: String {
        if liveMatches.isEmpty {
            return "Sem partidas ao vivo agora. Acompanhe agenda, próximas e sincronização automática."
        }
        return "\(liveMatches.count) partida(s) ao vivo com prioridade por relevância e favoritos."
    }

    private func headlineMetric(title: String, value: String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(Color.readableSecondary)
            Text(value)
                .font(.system(.title2, design: .rounded, weight: .heavy))
                .foregroundStyle(accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.cardOverlaySoft)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func liveTickerChip(for match: TennisMatch) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 7, height: 7)
                    .scaleEffect(animateLivePulse ? 1 : 0.7)
                    .opacity(animateLivePulse ? 1 : 0.5)
                Text(match.status.isEmpty ? "Ao vivo" : match.status)
                    .font(.caption2.weight(.bold))
                Spacer(minLength: 0)
                Text(match.date, format: .dateTime.hour().minute())
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Color.readableSecondary)
            }

            Text("\(match.player1TeamName) vs \(match.player2TeamName)")
                .font(.caption.weight(.semibold))
                .lineLimit(1)

            HStack(spacing: 8) {
                liveTickerPill(title: "Sets", value: match.score.isEmpty ? "Sem placar" : match.score)
                if !match.gameScore.isEmpty {
                    liveTickerPill(title: "Game", value: match.gameScore)
                }
                if !match.pointScore.isEmpty {
                    liveTickerPill(title: "Ponto", value: match.pointScore)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 240, alignment: .leading)
        .background(Color.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.red.opacity(0.12), lineWidth: 1)
        }
    }

    private func deduplicate(_ items: [TennisMatch]) -> [TennisMatch] {
        var seen = Set<UUID>()
        return items.filter {
            seen.insert($0.id).inserted
        }
    }

    private func sectionHeader(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title3.weight(.bold))
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(Color.readableSecondary)
        }
    }

    private func agendaRow(for match: TennisMatch) -> some View {
        let intelligence = MatchIntelligence(match: match, rankings: rankings, allMatches: matches)
        return HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(intelligence.roundLabel.uppercased())
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.green)
                    if let tournament = match.tournament?.name {
                        Text(tournament)
                            .font(.caption)
                            .foregroundStyle(Color.readableSecondary)
                            .lineLimit(1)
                    }
                }

                Text("\(match.player1TeamName) vs \(match.player2TeamName)")
                    .font(.headline.weight(.semibold))
                Text(intelligence.summary)
                    .font(.caption)
                    .foregroundStyle(Color.readableSecondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Text(match.date, format: .dateTime.hour().minute())
                    .font(.title3.monospacedDigit().weight(.bold))
                Text(match.isLive ? "Ao vivo" : "Hoje")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(match.isLive ? .red : Color.readableSecondary)
            }
        }
        .padding(16)
        .background(Color.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.cardSurfaceStroke.opacity(0.30), lineWidth: 1)
        }
    }

    private func upcomingCard(for match: TennisMatch) -> some View {
        let intelligence = MatchIntelligence(match: match, rankings: rankings, allMatches: matches)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(intelligence.roundLabel)
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.cardOverlaySoft)
                    .clipShape(Capsule())
                Spacer()
                Text(match.date.formatted(date: .omitted, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(Color.readableSecondary)
            }

            Text("\(match.player1TeamName) vs \(match.player2TeamName)")
                .font(.headline)
            Text(intelligence.summary)
                .font(.caption)
                .foregroundStyle(Color.readableSecondary)
            HStack(spacing: 10) {
                compactTag(text: "Previsão \(intelligence.predictedWinner)", tint: .green)
                compactTag(text: intelligence.recommendation, tint: .blue)
            }
        }
        .padding(16)
        .background(Color.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.cardSurfaceStroke.opacity(0.30), lineWidth: 1)
        }
    }

    private func matchListCard(for m: TennisMatch) -> some View {
        let intelligence = MatchIntelligence(match: m, rankings: rankings, allMatches: matches)
        let scoreboard = MatchScoreboardData(score: m.score)

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                HStack(spacing: 8) {
                    matchBadge(for: m)
                    Text(intelligence.relevanceLabel)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color.readableSecondary)
                }
                Spacer()
                Text(m.date, format: .dateTime.hour().minute())
                    .font(.caption)
                    .foregroundStyle(Color.readableSecondary)
            }

            HStack(spacing: 10) {
                compactTag(text: m.tournament?.name ?? "Torneio", tint: .blue)
                compactTag(text: intelligence.roundLabel, tint: .secondary)
                if m.isFavorite {
                    compactTag(text: "Favorito", tint: .yellow)
                }
            }

            if scoreboard.hasSets {
                MatchScoreboardView(
                    player1Name: m.player1TeamName,
                    player2Name: m.player2TeamName,
                    scoreboard: scoreboard,
                    highlightLive: m.isLive,
                    hidesScores: experienceStore.preferences.spoilerFreeMode && m.isCompleted
                )
            } else {
                playerRow(name: m.player1TeamName, emphasis: true)
                playerRow(name: m.player2TeamName, emphasis: true)
            }

            Text(experienceStore.preferences.spoilerFreeMode && m.isCompleted ? "Resultado oculto pelo modo spoiler-free." : intelligence.summary)
                .font(.caption)
                .foregroundStyle(Color.readableSecondary)
        }
        .padding(16)
        .background(Color.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(m.isLive ? Color.red.opacity(0.18) : Color.black.opacity(0.06), lineWidth: 1)
        }
    }
    private var liveStatusLabel: String {
        liveService?.state.label ?? "Live Off"
    }

    private var liveStatusIcon: String {
        guard let state = liveService?.state else {
            return "dot.radiowaves.left.and.right"
        }

        switch state {
        case .connected:
            return "dot.radiowaves.left.and.right"
        case .connecting:
            return "antenna.radiowaves.left.and.right"
        case .disconnected:
            return "dot.radiowaves.left.and.right"
        case .failed:
            return "exclamationmark.triangle"
        }
    }

    private var liveConnectionDotColor: Color {
        guard let state = liveService?.state else { return .gray.opacity(0.6) }
        switch state {
        case .connected: return .green
        case .connecting: return .yellow
        case .disconnected: return .gray.opacity(0.6)
        case .failed: return .orange
        }
    }

    private var liveRecoveryMessage: String? {
        guard let liveService else { return nil }
        if case .connecting = liveService.state, liveService.retryAttempt > 0 {
            return "Reconectando automaticamente. Tentativa \(liveService.retryAttempt)."
        }
        if case .failed(let message) = liveService.state {
            if let fallback = liveService.lastRESTFallbackAt {
                return "WebSocket falhou: \(message). REST atualizado \(fallback.formatted(date: .omitted, time: .shortened))."
            }
            return "WebSocket falhou: \(message). O app tentará reconectar e usar REST como fallback."
        }
        return nil
    }

    private func toggleLiveUpdates() {
        guard let liveService else { return }

        if liveService.state.isActive {
            liveService.disconnect()
        } else {
            liveService.connect()
        }
    }

    private func startLivePulseIfActive() {
        guard scenePhase == .active, !animateLivePulse else { return }
        withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
            animateLivePulse = true
        }
    }

    @ViewBuilder
    private func matchBadge(for match: TennisMatch) -> some View {
        Label(match.isLive ? "AO VIVO" : "PARTIDA", systemImage: match.isLive ? "dot.radiowaves.left.and.right" : "calendar")
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(match.isLive ? Color.red.opacity(0.12) : Color.gray.opacity(0.12))
            .foregroundStyle(match.isLive ? .red : Color.readableSecondary)
            .clipShape(Capsule())
    }

    @ViewBuilder
    private func playerRow(name: String, emphasis: Bool) -> some View {
        HStack {
            Text(name)
                .font(emphasis ? .headline : .body)
            Spacer()
        }
    }

    private func pulseBoardMetric(title: String, value: String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(Color.readableSecondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(accent.opacity(0.14), lineWidth: 1)
        }
    }

    private func liveTickerPill(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.readableSecondary)
            Text(value)
                .font(.caption.monospacedDigit().weight(.semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func compactTag(text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(tint.opacity(0.12))
            .foregroundStyle(tint == .secondary ? Color.readableSecondary : tint)
            .clipShape(Capsule())
    }

    private func addSampleMatch() {
        let p1 = Player(name: "Player A", nationality: "USA", isWTA: false)
        let p2 = Player(name: "Player B", nationality: "FRA", isWTA: false)
        let t = Tournament(name: "Sample Open", city: "Paris", country: "France", surface: "Clay", tour: .atp, startDate: Date(), endDate: Date())
        let m = TennisMatch(date: Date(), status: "Final", isLive: false, lastUpdatedAt: .now, serverName: "", pointScore: "", gameScore: "", tournament: t, player1: p1, player2: p2, score: "6-4 3-6 7-6")
        context.insert(p1)
        context.insert(p2)
        context.insert(t)
        context.insert(m)
        Task {
            await AlertEventEngine.shared.refreshScheduledNotifications(in: context, force: true)
        }
    }

    @MainActor
    private func runAutoSync() async {
        isSyncing = true
        defer { isSyncing = false }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("MATCH_POINT_UI_FORCE_SYNC_ERROR") {
            syncFeedback = DataSyncService(context: context).userFacingFeedback(for: APIError(message: "UI test forced sync failure"))
            return
        }
        #endif
        let service = DataSyncService(context: context)
        do {
            try await service.syncMatches()
            AutoSyncTracker.markSynced(.matches)
            AutoSyncTracker.markSynced(.liveMatches)
        } catch {
            // Silent failure on auto-sync; manual button still surfaces errors.
        }
    }

    @MainActor
    private func runManualSync() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        let service = DataSyncService(context: context)
        do {
            try await service.syncMatches()
            syncFeedback = nil
            AutoSyncTracker.markSynced(.matches)
            AutoSyncTracker.markSynced(.liveMatches)
        } catch {
            syncFeedback = service.userFacingFeedback(for: error)
        }
    }
}
