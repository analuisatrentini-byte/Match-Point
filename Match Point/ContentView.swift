//  ContentView.swift
//  Match Point
//
//  Created by Ana Luisa Bittencourt on 26/03/26.
//

import SwiftUI
import SwiftData
import OSLog

// Player-first: se o usuário tem jogador favorito, a aba "Jogadores"
// vira a homepage mental — próximo jogo, ranking, forma, rivalidade,
// calendário e alertas em um scroll só. Caso contrário, o fallback é
// "Partidas" (comportamento antigo).

struct ContentView: View {
    private enum DeepLinkRoute: Identifiable {
        case match(TennisMatch)
        case player(Player)
        case tournament(Tournament)

        var id: String {
            switch self {
            case .match(let match):
                return "match-\(match.persistentModelID)"
            case .player(let player):
                return "player-\(player.persistentModelID)"
            case .tournament(let tournament):
                return "tournament-\(tournament.persistentModelID)"
            }
        }
    }

    private enum AppTab {
        case matches
        case forYou
        case circuit
        case profile
        case social
    }

    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var alertStore: AlertPreferencesStore
    @EnvironmentObject private var remotePushManager: RemotePushManager
    @EnvironmentObject private var analyticsStore: ProductAnalyticsStore
    @AppStorage("match-point.onboarding-completed") private var onboardingCompleted = false
    @AppStorage("match-point.activation-completed") private var activationCompleted = false
    @Query(filter: #Predicate<Player> { $0.isFavorite }) private var favoritePlayers: [Player]
    @Query private var deepLinkMatches: [TennisMatch]
    @Query private var deepLinkPlayers: [Player]
    @Query private var deepLinkTournaments: [Tournament]
    @Query(sort: \RankingEntry.rank) private var rankings: [RankingEntry]
    @State private var selectedTab: AppTab = .matches
    @State private var deepLinkRoute: DeepLinkRoute?
    @State private var showNotificationPriming = false
    @State private var showActivation = false
    @State private var didApplyInitialTab = false

    var body: some View {
        Group {
            #if os(iOS)
            if onboardingCompleted {
                appTabs
                    .fullScreenCover(isPresented: $showActivation) {
                        PostOnboardingActivationView {
                            activationCompleted = true
                            showActivation = false
                        }
                    }
            } else {
                OnboardingView {
                    analyticsStore.record(ProductAnalyticsEventName.onboardingCompleted)
                    onboardingCompleted = true
                    selectedTab = .forYou
                    // Show the activation spotlight before the tab view takes
                    // over. Only presents once — controlled by
                    // `activation-completed` UserDefaults key so subsequent
                    // launches skip straight to the main tabs.
                    if !activationCompleted {
                        showActivation = true
                    }
                }
            }
            #else
            // macOS fallback: present a simpler navigation without iOS-only APIs
            NavigationStack {
                MatchesView()
                    .navigationTitle("Match Point")
            }
            #endif
        }
        .task {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("MATCH_POINT_UI_SEED_DATA") {
                UITestSeedData.seedIfNeeded(in: context)
            }
            applyUITestInitialTabIfNeeded()
            #endif
            analyticsStore.recordAppLaunch()
            analyticsStore.recordSessionStarted()
            await analyticsStore.refreshWidgetInstallState()
            SocialRetentionService.pruneStale(in: context)
            SocialRetentionService.pruneOrphanedRankings(in: context)
            SocialRetentionService.pruneOrphanedBets(in: context)
            SocialRetentionService.pruneOnboardingSeeds(in: context)
            refreshPlayerRankingWidget()
            applyPlayerFirstLandingIfNeeded()
        }
        .onChange(of: favoritePlayers.count) { _, _ in
            refreshPlayerRankingWidget()
            applyPlayerFirstLandingIfNeeded()
        }
        .onOpenURL { url in
            handleDeepLink(url, source: "url")
        }
        .onReceive(NotificationCenter.default.publisher(for: .openDeepLink)) { notification in
            guard let url = notification.userInfo?["url"] as? URL else { return }
            handleDeepLink(url, source: "notification")
        }
        .sheet(item: $deepLinkRoute) { route in
            NavigationStack {
                deepLinkDestination(for: route)
            }
        }
    }

    /// Player-first landing: on the first render after the app is ready, if
    /// the user has at least one favorite player *and* is still on the default
    /// (.matches) tab, jump to the favorites hub. Runs once per app process so
    /// we never fight the user's tab switches mid-session.
    private func applyPlayerFirstLandingIfNeeded() {
        guard onboardingCompleted, !didApplyInitialTab else { return }
        guard !favoritePlayers.isEmpty else { return }
        didApplyInitialTab = true
        if selectedTab == .matches {
            selectedTab = .forYou
        }
    }

    #if DEBUG
    private func applyUITestInitialTabIfNeeded() {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("MATCH_POINT_UI_TESTING") else { return }

        if arguments.contains("MATCH_POINT_UI_START_MATCHES") {
            selectedTab = .matches
            didApplyInitialTab = true
        } else if arguments.contains("MATCH_POINT_UI_START_PROFILE") {
            selectedTab = .profile
            didApplyInitialTab = true
        }
    }
    #endif

    #if os(iOS)
    private var appTabs: some View {
        // Top 5 primary tabs surface the highest-frequency journeys; iOS routes the
        // remaining destinations through the native "More" overflow.
        TabView(selection: $selectedTab) {
                tabRoot { MatchesView() }
                    .tabItem { Label("Partidas", systemImage: "tennisball.fill") }
                    .tag(AppTab.matches)

                tabRoot { MyPlayersFeedView() }
                    .tabItem { Label("Jogadores", systemImage: "person.crop.circle.fill.badge.checkmark") }
                    .tag(AppTab.forYou)

                tabRoot { SocialFeedView() }
                    .tabItem { Label("Diário", systemImage: "star.bubble.fill") }
                    .tag(AppTab.social)

                tabRoot(showsNavigationBar: true) { CircuitView() }
                    .tabItem { Label("Torneios", systemImage: "trophy") }
                    .tag(AppTab.circuit)

                tabRoot(showsNavigationBar: true) { ProfileView() }
                    .tabItem { Label("Perfil", systemImage: "person.crop.circle.fill") }
                    .tag(AppTab.profile)

                // Settings ficam acessíveis pela engrenagem no topo da aba Perfil,
                // sem aba "Mais" overflow nem ferramentas internas expostas.
            }
            .accessibilityIdentifier("main-tab-view")
            .onReceive(NotificationCenter.default.publisher(for: .openBetWizard)) { _ in
                selectedTab = .profile
            }
            .onReceive(NotificationCenter.default.publisher(for: .navigateToPlayersDirectory)) { _ in
                UserDefaults.standard.set(
                    CircuitView.Section.players.rawValue,
                    forKey: CircuitView.selectedSectionStorageKey
                )
                selectedTab = .circuit
            }
            .onReceive(NotificationCenter.default.publisher(for: .didToggleFavorite)) { _ in
                refreshPlayerRankingWidget()
            }
            .onReceive(NotificationCenter.default.publisher(for: .didFirstFavorite)) { _ in
                if alertStore.authorizationStatus == .notDetermined
                    || !alertStore.preferences.notificationsEnabled {
                    showNotificationPriming = true
                }
            }
            .alert("Receber alertas sobre este favorito?", isPresented: $showNotificationPriming) {
                Button("Ativar alertas") {
                    Task {
                        let accepted = await alertStore.requestAuthorization()
                        analyticsStore.record(accepted ? ProductAnalyticsEventName.alertPermissionAccepted : ProductAnalyticsEventName.alertPermissionDeclined)
                        alertStore.update { $0.notificationsEnabled = true }
                        alertStore.update { $0.followFavoritePlayers = true }
                        alertStore.update { $0.followFavoriteMatches = true }
                        alertStore.update { $0.followFavoriteTournaments = true }
                        await remotePushManager.syncNotificationSubscriptions(in: context, reason: "notification-priming")
                    }
                }
                Button("Não, obrigado", role: .cancel) {
                    analyticsStore.record(ProductAnalyticsEventName.alertPermissionDeclined)
                }
            } message: {
                Text("Quer ser avisado quando jogadores, partidas ou torneios favoritos estiverem acontecendo?")
            }
            .task {
                await alertStore.refreshAuthorizationStatus()
            }
            .onChange(of: scenePhase) { _, newPhase in
                guard newPhase == .active else { return }
                Task {
                    analyticsStore.recordAppLaunch()
                    analyticsStore.recordSessionStarted()
                    await analyticsStore.refreshWidgetInstallState()
                    await alertStore.refreshAuthorizationStatus()
                    refreshPlayerRankingWidget()
                    await remotePushManager.syncNotificationSubscriptions(in: context, reason: "app-active")
                }
            }
    }

    private func refreshPlayerRankingWidget() {
        MatchWidgetSnapshotStore.shared.replaceTopRankingPlayers(rankings)
    }

    private func handleDeepLink(_ url: URL, source: String) {
        guard url.scheme == "matchpoint" else { return }
        if source != "notification" {
            analyticsStore.record(
                ProductAnalyticsEventName.appOpenedFromWidget,
                properties: [
                    "host": url.host ?? "unknown",
                    "path": url.path.isEmpty ? "/" : url.path,
                    "source": source
                ]
            )
        }
        switch url.host {
        case "players":
            selectedTab = .forYou
            if let identifier = deepLinkIdentifier(from: url),
               let player = findPlayer(identifier: identifier) {
                deepLinkRoute = .player(player)
            }
        case "rankings":
            selectedTab = .forYou
        case "tournaments", "calendar":
            selectedTab = .circuit
            if url.host == "tournaments",
               let identifier = deepLinkIdentifier(from: url),
               let tournament = findTournament(identifier: identifier) {
                deepLinkRoute = .tournament(tournament)
            }
        case "profile", "widgets":
            selectedTab = .profile
        case "matches", "live":
            selectedTab = .matches
            if let identifier = deepLinkIdentifier(from: url),
               let match = findMatch(identifier: identifier) {
                deepLinkRoute = .match(match)
            }
        case "today":
            selectedTab = .matches
        default:
            selectedTab = .matches
        }
    }

    @ViewBuilder
    private func deepLinkDestination(for route: DeepLinkRoute) -> some View {
        switch route {
        case .match(let match):
            MatchDetailView(match: match)
        case .player(let player):
            PlayerDetailView(player: player)
        case .tournament(let tournament):
            TournamentDetailView(tournament: tournament)
        }
    }

    private func deepLinkIdentifier(from url: URL) -> String? {
        let value = url.pathComponents.dropFirst().first ?? url.queryValue(for: "id")
        return value?.removingPercentEncoding?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func findMatch(identifier: String) -> TennisMatch? {
        deepLinkMatches.first { match in
            match.externalID == identifier || match.id.uuidString == identifier
        }
    }

    private func findPlayer(identifier: String) -> Player? {
        deepLinkPlayers.first { player in
            player.externalKey == identifier
                || player.id.uuidString == identifier
                || player.externalKey.map { identifier == "\(player.tour.rawValue)-\($0)" } == true
        }
    }

    private func findTournament(identifier: String) -> Tournament? {
        deepLinkTournaments.first { tournament in
            tournament.externalKey == identifier || tournament.id.uuidString == identifier
        }
    }

    private func tabRoot<Content: View>(
        showsNavigationBar: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        // Quando `showsNavigationBar` é false (default), o tabRoot esconde a
        // nav bar pra deixar as abas com cabeçalho inline customizado (gradient
        // Apple Sports + título dentro do scroll). Profile passa true porque
        // depende da nav bar pra mostrar o ícone de Settings.
        NavigationStack {
            content()
                .toolbar(showsNavigationBar ? .visible : .hidden, for: .navigationBar)
        }
    }
    #endif
}

#Preview {
    #if os(iOS)
    ContentView()
        .environmentObject(AlertPreferencesStore.shared)
        .environmentObject(ExperiencePreferencesStore.shared)
        .environmentObject(BehaviorPersonalizationStore.shared)
        .environmentObject(ProductAnalyticsStore.shared)
        .environmentObject(ResponsibleGamblingStore.shared)
        .environmentObject(RemotePushManager())
        .environmentObject(CloudSocialBackend.previewStub())
        .modelContainer(for: MatchPointPreviewData.modelTypes, inMemory: true) { result in
            if case .success(let container) = result {
                MatchPointPreviewData.seed(container)
            }
        }
    #else
    ContentView()
        .environmentObject(CloudSocialBackend.previewStub())
        .modelContainer(for: MatchPointPreviewData.modelTypes, inMemory: true) { result in
            if case .success(let container) = result {
                MatchPointPreviewData.seed(container)
            }
        }
    #endif
}
