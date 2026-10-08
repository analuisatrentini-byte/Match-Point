import SwiftUI
import SwiftData

// MARK: - Live Tracker

struct LiveTrackerView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var experienceStore: ExperiencePreferencesStore
    @Query private var allMatches: [TennisMatch]
    @Query(sort: \RankingEntry.rank) private var rankings: [RankingEntry]
    @Query(sort: \Player.name) private var allPlayers: [Player]

    @State private var liveService: LiveMatchWebSocketService?
    @State private var selectedMatchID: UUID?
    @State private var isSyncing = false
    @State private var animateLivePulse = false
    @State private var syncFeedback: UserFacingSyncFeedback?
    @State private var matchBrainSheetMatchID: UUID?

    init() {
        let threshold = Calendar.current.date(byAdding: .day, value: -14, to: .now) ?? .distantPast
        _allMatches = Query(
            filter: #Predicate<TennisMatch> { $0.date >= threshold },
            sort: \TennisMatch.date,
            order: .reverse
        )
    }

    private var favoritePlayerIDs: Set<UUID> {
        Set(allPlayers.filter(\.isFavorite).map(\.id))
    }

    private var liveFavoriteMatches: [TennisMatch] {
        LiveTrackerBuilder.activeTrackers(
            matches: allMatches,
            favoritePlayerIDs: favoritePlayerIDs,
            rankings: rankings
        )
    }

    private var nextUpcomingFavoriteMatch: TennisMatch? {
        LiveTrackerBuilder.upcomingFavoriteMatch(matches: allMatches, favoritePlayerIDs: favoritePlayerIDs)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let syncFeedback {
                    SyncFeedbackBanner(feedback: syncFeedback)
                }

                header

                if liveFavoriteMatches.isEmpty {
                    emptyState
                } else {
                    if liveFavoriteMatches.count > 1 {
                        selectorRow
                    }
                    scoreboardCarousel
                }

                connectionPanel
            }
            .padding()
        }
        .appleSportsBackground(.clay)
        .navigationTitle("Live Tracker")
        .task {
            guard !isSyncing else { return }
            while !Task.isCancelled {
                if AutoSyncTracker.shouldSync(.liveMatches) {
                    await runAutoSync()
                }
                // Slower cadence when no favorites are on court — saves battery
                // and API quota without missing a match starting.
                let interval: Duration = liveFavoriteMatches.isEmpty ? .seconds(60) : .seconds(15)
                // Exit the polling loop the instant the task is cancelled —
                // `try?` would swallow CancellationError and keep ticking.
                do {
                    try await Task.sleep(for: interval)
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
            ensureValidSelection(from: liveFavoriteMatches.map(\.id))
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                startLivePulseIfActive()
            } else {
                animateLivePulse = false
            }
        }
        .onChange(of: liveFavoriteMatches.map(\.id)) { _, newIDs in
            ensureValidSelection(from: newIDs)
        }
        .refreshable {
            await syncNow()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.title2)
                    .foregroundStyle(.red)
                Text("Live Tracker")
                    .font(.largeTitle.weight(.heavy))
                Spacer()
                SyncFreshnessLabel(scope: .liveMatches, isSyncing: isSyncing)
            }

            Text(headerSubtitle)
                .font(.subheadline)
                .foregroundStyle(Color.readableSecondary)
        }
    }

    private var headerSubtitle: String {
        if liveFavoriteMatches.isEmpty {
            return "Acompanhe ao vivo os jogos dos seus favoritos sem depender de notificações."
        }
        let liveCount = liveFavoriteMatches.filter(\.isLive).count
        let finishingCount = liveFavoriteMatches.count - liveCount
        if finishingCount > 0, liveCount == 0 {
            return "Partida encerrada há instantes. O card sai automaticamente em 2 minutos."
        }
        return liveFavoriteMatches.count == 1
            ? "1 favorito em quadra agora."
            : "\(liveFavoriteMatches.count) favoritos em quadra — deslize ou toque para alternar."
    }

    private var selectorRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(liveFavoriteMatches) { match in
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            selectedMatchID = match.id
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 6, height: 6)
                                .opacity(animateLivePulse ? 1 : 0.5)
                            Text(shortLabel(for: match))
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            Capsule().fill(
                                selectedMatchID == match.id
                                    ? Color.red.opacity(0.16)
                                    : Color.white.opacity(0.12)
                            )
                        )
                        .foregroundStyle(selectedMatchID == match.id ? Color.red : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private var scoreboardCarousel: some View {
#if os(iOS)
        if let fallbackID = liveFavoriteMatches.first?.id {
            TabView(selection: Binding(
                get: { selectedMatchID ?? fallbackID },
                set: { selectedMatchID = $0 }
            )) {
                ForEach(liveFavoriteMatches) { match in
                    scoreboard(for: match)
                    .padding(.horizontal, 2)
                    .padding(.bottom, liveFavoriteMatches.count > 1 ? 28 : 0)
                    .tag(match.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: liveFavoriteMatches.count > 1 ? .always : .never))
            .frame(minHeight: 380)
        }
#else
        VStack(spacing: 16) {
            if let selectedMatch = liveFavoriteMatches.first(where: { $0.id == selectedMatchID }) ?? liveFavoriteMatches.first {
                scoreboard(for: selectedMatch)
            }
        }
#endif
    }

    private func scoreboard(for match: TennisMatch) -> some View {
        let scoreboardData = MatchScoreboardData(score: match.score)
        let intel = MatchIntelligence(match: match, rankings: rankings, allMatches: allMatches)
        let narrative = MatchBrainNarrative(match: match, rankings: rankings, allMatches: allMatches)
        let pointRun = MatchPointRunAnalyzer(match: match)
        let momentum = pointRun.momentumTimeline(limit: 10)
        let player1Name = match.player1TeamName
        let player2Name = match.player2TeamName

        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text((match.tournament?.name ?? "Live").uppercased())
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color.readableSecondary)
                        .lineLimit(1)
                    Text(intel.roundLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.readableSecondary)
                }
                Spacer()
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                        .scaleEffect(animateLivePulse ? 1 : 0.7)
                        .opacity(animateLivePulse ? 1 : 0.5)
                    Text(match.isLive ? "AO VIVO" : (experienceStore.preferences.spoilerFreeMode ? "SPOILER-FREE" : "FINAL"))
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(match.isLive ? .red : Color.readableSecondary)
                }
            }

            if match.isLive {
                liveDataConfidenceBadge(for: match)
            }

            if match.isLive && match.isInTiebreak && !match.pointScore.isEmpty {
                TiebreakCounter(
                    player1Name: player1Name,
                    player2Name: player2Name,
                    pointScore: match.pointScore,
                    serverName: match.serverName
                )
            }

            if match.isLive {
                LiveCourtPointView(
                    player1Name: player1Name,
                    player2Name: player2Name,
                    serverName: match.serverName,
                    pointScore: match.pointScore,
                    gameScore: match.gameScore,
                    momentum: momentum,
                    moment: narrative.whyWatchNow,
                    pulse: animateLivePulse
                )
            }

            scoreboardPlayerRow(
                name: player1Name,
                isServing: !match.serverName.isEmpty && match.serverName == player1Name,
                isFavorite: match.player1.map { favoritePlayerIDs.contains($0.id) } ?? false,
                setValues: spoilerSafeSetValues(scoreboardData.sets.map(\.player1Games), for: match)
            )
            Divider()
            scoreboardPlayerRow(
                name: player2Name,
                isServing: !match.serverName.isEmpty && match.serverName == player2Name,
                isFavorite: match.player2.map { favoritePlayerIDs.contains($0.id) } ?? false,
                setValues: spoilerSafeSetValues(scoreboardData.sets.map(\.player2Games), for: match)
            )

            if match.isLive {
                MomentumBar(
                    points: momentum,
                    player1ShortName: Self.lastNameFragment(player1Name),
                    player2ShortName: Self.lastNameFragment(player2Name)
                )
            }

            HStack(spacing: 10) {
                if !match.gameScore.isEmpty {
                    statusPill(title: "Game", value: match.gameScore)
                }
                if !match.pointScore.isEmpty {
                    statusPill(title: "Ponto", value: match.pointScore)
                }
            }

            if let moment = narrative.whyWatchNow {
                WhyWatchNowCard(moment: moment) {
                    matchBrainSheetMatchID = match.id
                }
            }

            HStack(spacing: 10) {
                NavigationLink(destination: MatchDetailView(match: match)) {
                    Label("Detalhes", systemImage: "list.bullet.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    matchBrainSheetMatchID = match.id
                } label: {
                    Label("Análise", systemImage: "brain.head.profile")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            HStack(spacing: 10) {
                NavigationLink(destination: ProfileView()) {
                    Label("Previsão", systemImage: "ticket.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            }

            if let updatedAt = match.lastUpdatedAt {
                Text("Atualizado \(updatedAt.formatted(date: .omitted, time: .standard))")
                    .font(.caption2)
                    .foregroundStyle(Color.readableSecondary)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.30))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.red.opacity(0.16), lineWidth: 1)
        }
        .shadow(color: Color.red.opacity(0.06), radius: 12, x: 0, y: 6)
        .sheet(isPresented: Binding(
            get: { matchBrainSheetMatchID == match.id },
            set: { newValue in
                if !newValue { matchBrainSheetMatchID = nil }
            }
        )) {
            let sheetIntel = MatchIntelligence(match: match, rankings: rankings, allMatches: allMatches)
            let sheetContext = sheetIntel.liveContext
            MatchBrainDetailSheet(
                narrative: MatchBrainNarrative(match: match, rankings: rankings, allMatches: allMatches),
                liveContext: sheetContext,
                pressureLabel: sheetContext.pressureLabel,
                pressureScore: sheetContext.pressureScore
            )
        }
    }

    private static func lastNameFragment(_ name: String) -> String {
        name.split(separator: " ").last.map(String.init) ?? name
    }

    private func liveDataConfidence(for match: TennisMatch) -> LiveDataConfidence {
        let key = match.externalID ?? ""
        return LiveDataConfidence.bestEffort(
            for: match,
            serviceConfidence: liveService?.qualityByMatchKey[key]
        )
    }

    private func liveDataConfidenceBadge(for match: TennisMatch) -> some View {
        let confidence = liveDataConfidence(for: match)
        let tint = liveDataConfidenceTint(confidence.status)

        return Label(confidence.label, systemImage: confidence.systemImage)
            .font(.caption2.weight(.heavy))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityIdentifier("live-data-confidence-badge")
            .accessibilityLabel("Confiança dos dados")
            .accessibilityValue("\(confidence.label). \(confidence.message)")
    }

    private func liveDataConfidenceTint(_ status: LiveDataConfidence.Status) -> Color {
        switch status {
        case .verified:
            return .green
        case .estimated:
            return .blue
        case .stale:
            return .orange
        case .conflicted:
            return .red
        }
    }

    private func scoreboardPlayerRow(
        name: String,
        isServing: Bool,
        isFavorite: Bool,
        setValues: [String]
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "tennisball.fill")
                .font(.caption)
                .foregroundStyle(isServing ? Color.green : Color.clear)
                .frame(width: 14)
                .accessibilityHidden(true)

            HStack(spacing: 6) {
                Text(name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                if isFavorite {
                    Image(systemName: "star.fill")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if setValues.isEmpty {
                Text("–")
                    .font(.system(.title2, design: .rounded, weight: .heavy))
                    .foregroundStyle(Color.readableSecondary)
                    .frame(width: 34)
            } else {
                ForEach(Array(setValues.enumerated()), id: \.offset) { _, value in
                    Text(value)
                        .font(.system(.title2, design: .rounded, weight: .heavy))
                        .frame(width: 34)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.liveScoreboardRowAccessibilityLabel(
            name: name,
            isServing: isServing,
            isFavorite: isFavorite,
            setValues: setValues
        ))
    }

    private func spoilerSafeSetValues(_ values: [String], for match: TennisMatch) -> [String] {
        experienceStore.preferences.spoilerFreeMode && match.isCompleted ? values.map { _ in "–" } : values
    }

    /// VoiceOver label for the Live Tracker per-player row. Combines name,
    /// serve state, favorite state, and each set score so a screen-reader
    /// user hears one coherent phrase instead of "6", "3", "6" as detached
    /// digits.
    static func liveScoreboardRowAccessibilityLabel(
        name: String,
        isServing: Bool,
        isFavorite: Bool,
        setValues: [String]
    ) -> String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmedName.isEmpty ? "Jogador" : trimmedName
        var parts: [String] = [base]
        if isFavorite { parts.append("favorito") }
        if isServing { parts.append("sacando") }
        if setValues.isEmpty {
            parts.append("sem placar")
        } else {
            let setPhrases = setValues.enumerated().map { index, value in
                let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
                let readable = cleaned.isEmpty || cleaned == "–" ? "sem placar" : "\(cleaned) games"
                return "set \(index + 1): \(readable)"
            }
            parts.append(contentsOf: setPhrases)
        }
        return parts.joined(separator: ". ")
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "tennisball")
                .font(.system(.largeTitle))
                .imageScale(.large)
                .foregroundStyle(Color.readableSecondary)
                .padding(.top, 24)

            Text(emptyStateTitle)
                .font(.headline)
                .multilineTextAlignment(.center)

            Text(emptyStateDescription)
                .font(.subheadline)
                .foregroundStyle(Color.readableSecondary)
                .multilineTextAlignment(.center)

            if let nextMatch = nextUpcomingFavoriteMatch {
                NavigationLink(destination: MatchDetailView(match: nextMatch)) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("PRÓXIMO FAVORITO")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Color.readableSecondary)
                        Text("\(nextMatch.player1TeamName) vs \(nextMatch.player2TeamName)")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text(nextMatch.date.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(Color.readableSecondary)
                        if let tournamentName = nextMatch.tournament?.name {
                            Text(tournamentName)
                                .font(.caption)
                                .foregroundStyle(Color.readableSecondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(Color.orange.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private var emptyStateTitle: String {
        if allPlayers.contains(where: \.isFavorite) == false {
            return "Você ainda não favoritou jogadores"
        }
        return "Nenhum favorito jogando agora"
    }

    private var emptyStateDescription: String {
        if allPlayers.contains(where: \.isFavorite) == false {
            return "Vá em Players ou Rankings e marque os jogadores que você quer acompanhar. As partidas deles ao vivo aparecerão aqui."
        }
        return "Quando algum dos seus favoritos entrar em quadra, o placar aparece aqui automaticamente. Use Sync ou Iniciar Live para forçar uma atualização."
    }

    private var connectionPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: connectionIcon)
                    .foregroundStyle(connectionTint)
                    .accessibilityHidden(true)
                Text(connectionLabel)
                    .font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("live-tracker-connection-label")
                Spacer()
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Status da conexão ao vivo")
            .accessibilityValue(connectionLabel)

            Text(connectionDescription)
                .font(.caption)
                .foregroundStyle(Color.readableSecondary)

            if let fallbackNotice = liveService?.fallbackNotice {
                Label(fallbackNotice, systemImage: "arrow.triangle.2.circlepath.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityIdentifier("live-tracker-rest-fallback-notice")
            }

            if let crossCheckNotice = liveService?.crossCheckNotice {
                Label(crossCheckNotice, systemImage: "checkmark.seal.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.green.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityIdentifier("live-tracker-cross-check-notice")
            }

            HStack(spacing: 12) {
                Button {
                    toggleLiveUpdates()
                } label: {
                    Label(
                        liveService?.state.isActive == true ? "Parar Live" : "Iniciar Live",
                        systemImage: liveService?.state.isActive == true
                            ? "stop.circle.fill"
                            : "dot.radiowaves.left.and.right"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(liveService == nil || TennisAPIConfiguration.selectedProvider != .apiTennis)
                .accessibilityIdentifier("live-tracker-toggle-live")

                if case .failed = liveService?.state {
                    reconnectButton
                }
            }

        }
        .padding(16)
        .background(Color.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var reconnectButton: some View {
        Button {
            liveService?.reconnect()
        } label: {
            Label("Reconectar", systemImage: "arrow.clockwise")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("live-tracker-reconnect")
    }

    private var connectionLabel: String {
        liveService?.state.label ?? "Live Off"
    }

    private var connectionIcon: String {
        guard let state = liveService?.state else { return "dot.radiowaves.left.and.right" }
        switch state {
        case .connected: return "dot.radiowaves.left.and.right"
        case .connecting: return "antenna.radiowaves.left.and.right"
        case .disconnected: return "dot.radiowaves.left.and.right"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var connectionTint: Color {
        guard let state = liveService?.state else { return .secondary }
        switch state {
        case .connected: return .green
        case .connecting: return .orange
        case .disconnected: return .secondary
        case .failed: return .red
        }
    }

    private var connectionDescription: String {
        guard let state = liveService?.state else { return "Conexão inativa." }
        switch state {
        case .connected:
            return "Recebendo atualizações em tempo real via WebSocket."
        case .connecting:
            let attempt = liveService?.retryAttempt ?? 0
            return attempt > 0
                ? "Tentando reconectar automaticamente. Tentativa \(attempt)."
                : "Estabelecendo conexão ao vivo."
        case .disconnected:
            return "Conexão inativa — toque em Iniciar Live para receber updates em tempo real."
        case .failed(let message):
            if let fallback = liveService?.lastRESTFallbackAt {
                return "Erro de conexão: \(message). Fallback REST executado \(fallback.formatted(date: .omitted, time: .shortened))."
            }
            return "Erro de conexão: \(message). O app tentará reconectar e usar REST como fallback."
        }
    }

    private func ensureValidSelection(from ids: [UUID]) {
        if let current = selectedMatchID, ids.contains(current) {
            return
        }
        selectedMatchID = ids.first
    }

    private func toggleLiveUpdates() {
        guard let liveService else { return }
        if liveService.state.isActive {
            liveService.disconnect()
        } else {
            liveService.connect()
        }
    }

    private func syncNow() async {
        await syncMatches(presentsErrors: true, showsLoading: true)
    }

    private func syncMatches(presentsErrors: Bool, showsLoading: Bool) async {
        guard !isSyncing else { return }
        if showsLoading {
            isSyncing = true
        }
        defer {
            if showsLoading {
                isSyncing = false
            }
        }
        let service = DataSyncService(context: context)
        do {
            try await service.syncLiveMatches()
            if presentsErrors {
                syncFeedback = nil
            }
            AutoSyncTracker.markSynced(.liveMatches)
        } catch {
            if presentsErrors {
                syncFeedback = service.userFacingFeedback(for: error)
            }
        }
    }

    @MainActor
    private func runAutoSync() async {
        await syncMatches(presentsErrors: false, showsLoading: false)
    }

    private func shortLabel(for match: TennisMatch) -> String {
        let player1 = lastName(of: match.player1TeamName)
        let player2 = lastName(of: match.player2TeamName)
        return "\(player1) vs \(player2)"
    }

    private func lastName(of fullName: String) -> String {
        fullName.split(separator: " ").last.map(String.init) ?? fullName
    }

    private func statusPill(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.readableSecondary)
            Text(value)
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func startLivePulseIfActive() {
        guard scenePhase == .active, !animateLivePulse else { return }
        withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
            animateLivePulse = true
        }
    }
}
