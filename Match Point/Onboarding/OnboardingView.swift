import SwiftUI
import SwiftData
import OSLog

struct OnboardingView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var alertStore: AlertPreferencesStore
    @EnvironmentObject private var experienceStore: ExperiencePreferencesStore
    @EnvironmentObject private var analyticsStore: ProductAnalyticsStore

    @State private var selectedPlayerIDs = Set<UUID>()
    @State private var suggestedPlayers: [Player] = []
    @State private var searchText = ""
    @State private var searchResults: [Player] = []

    var onFinish: () -> Void
    private let minimumFavoritePlayers = 1

    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
    }

    private var selectedPlayers: [Player] {
        selectablePlayers.filter { selectedPlayerIDs.contains($0.id) }
    }

    private var selectablePlayers: [Player] {
        uniquePlayers(suggestedPlayers + searchResults)
    }

    private var selectionText: String {
        let count = selectedPlayerIDs.count
        return count == 1 ? "1 selecionado" : "\(count) selecionados"
    }

    private var hasEnoughFavorites: Bool {
        selectedPlayerIDs.count >= minimumFavoritePlayers
    }

    private var callToActionTitle: String {
        hasEnoughFavorites ? "Criar meu radar" : "Escolha mais \(minimumFavoritePlayers - selectedPlayerIDs.count)"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        header
                        radarPreview
                        searchSection
                        playerGrid
                    }
                    .padding(22)
                }

                Button {
                    finish()
                } label: {
                    Label(callToActionTitle, systemImage: hasEnoughFavorites ? "scope" : "person.crop.circle.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!hasEnoughFavorites)
                .padding(16)
                .accessibilityIdentifier("onboarding-enter-app")
            }
            .appleSportsBackground(.royal)
            .task {
                loadSuggestedPlayers()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Monte seu radar pessoal")
                .font(.largeTitle.weight(.heavy))
                .accessibilityIdentifier("onboarding-title")
            Text("Escolha pelo menos 1 jogador para o Match Point saber quem acompanhar, quando alertar e quais jogos explicar primeiro. Você pode selecionar quantos quiser.")
                .font(.subheadline)
                .foregroundStyle(Color.readableSecondary)
            HStack(spacing: 8) {
                Label(selectionText, systemImage: "person.2.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(hasEnoughFavorites ? .green : .orange)
                    .accessibilityIdentifier("onboarding-selection-count")
                Text(hasEnoughFavorites ? "Radar pronto" : "Mínimo de 1")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(hasEnoughFavorites ? .green : .orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background((hasEnoughFavorites ? Color.green : Color.orange).opacity(0.14), in: Capsule())
            }
        }
    }

    private var radarPreview: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Seu radar vai priorizar")
                .font(.headline.weight(.heavy))

            HStack(spacing: 10) {
                onboardingSignal(icon: "calendar.badge.clock", title: "Próximo jogo", detail: "Agenda dos favoritos")
                onboardingSignal(icon: "bell.badge.fill", title: "Alertas", detail: "Entrada em quadra")
                onboardingSignal(icon: "chart.line.uptrend.xyaxis", title: "Ranking", detail: "Impacto explicado")
            }
        }
        .padding(14)
        .background(Color.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func onboardingSignal(icon: String, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.headline.weight(.bold))
                .foregroundStyle(.green)
            Text(title)
                .font(.caption.weight(.heavy))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(Color.readableSecondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private var searchSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Buscar outro jogador")
                .font(.headline.weight(.heavy))

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Color.readableSecondary)
                TextField("Digite pelo menos 2 letras", text: $searchText)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .accessibilityIdentifier("onboarding-player-search")
            }
            .padding(12)
            .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onChange(of: searchText) { _, _ in
                refreshSearchResults()
            }

            if !searchResults.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 148), spacing: 10)], spacing: 10) {
                    ForEach(searchResults) { player in
                        playerButton(player)
                    }
                }
            } else if searchText.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 {
                Text("Nenhum jogador encontrado nos dados já sincronizados. Faça uma sincronização de rankings para ampliar a busca.")
                    .font(.caption)
                    .foregroundStyle(Color.readableSecondary)
            }
        }
    }

    @ViewBuilder
    private var playerGrid: some View {
        if suggestedPlayers.isEmpty {
            ContentUnavailableView(
                "Carregando jogadores...",
                systemImage: "person.2",
                description: Text("A lista inicial aparece automaticamente.")
            )
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("Sugestões rápidas")
                    .font(.headline.weight(.heavy))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 148), spacing: 10)], spacing: 10) {
                    ForEach(suggestedPlayers) { player in
                        playerButton(player)
                    }
                }
            }
        }
    }

    private func playerButton(_ player: Player) -> some View {
        let isSelected = selectedPlayerIDs.contains(player.id)

        return Button {
            toggle(player)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? .green : Color.readableSecondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(player.name)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Text("\(player.isWTA ? "WTA" : "ATP") · \(player.nationality)")
                        .font(.caption2)
                        .foregroundStyle(Color.readableSecondary)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
            .background(Color.white.opacity(isSelected ? 0.20 : 0.10))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("onboarding-player-\(player.externalKey ?? player.id.uuidString)")
    }

    private func toggle(_ player: Player) {
        if selectedPlayerIDs.contains(player.id) {
            selectedPlayerIDs.remove(player.id)
        } else {
            selectedPlayerIDs.insert(player.id)
        }
    }

    private func finish() {
        guard hasEnoughFavorites else { return }
        saveFavorites()
        inferExperiencePreferences()
        inferAlertPreferences()
        recordOnboardingAnalytics()
        onFinish()
    }

    private func saveFavorites() {
        if suggestedPlayers.isEmpty {
            loadSuggestedPlayers()
        }

        for player in selectablePlayers {
            player.isFavorite = selectedPlayerIDs.contains(player.id)
        }

        do {
            try context.save()
            AutoSyncTracker.reset(.matches)
            AutoSyncTracker.reset(.liveMatches)
            AutoSyncTracker.reset(.playersAndRankings)
        } catch {
            AppLogger.persistence.error("Failed to save onboarding favorites: \(AppLogger.message(for: error), privacy: .private)")
            AppLogger.recordFailure(category: "persistence", operation: "onboarding.saveFavorites", error: error)
        }
    }

    private func inferExperiencePreferences() {
        let picked = selectedPlayers
        experienceStore.update {
            $0.matchFilter = .forYou
            $0.prioritizeFavorites = true
            if picked.isEmpty {
                $0.tourFilter = .all
            } else if picked.allSatisfy(\.isWTA) {
                $0.tourFilter = .wta
            } else if picked.allSatisfy({ !$0.isWTA }) {
                $0.tourFilter = .atp
            } else {
                $0.tourFilter = .all
            }
        }
    }

    private func recordOnboardingAnalytics() {
        let picked = selectedPlayers
        guard !picked.isEmpty else { return }
        analyticsStore.record(
            ProductAnalyticsEventName.favoritePlayerChosen,
            properties: [
                "count": "\(picked.count)",
                "tour": pickedTourLabel(players: picked)
            ]
        )
    }

    private func pickedTourLabel(players: [Player]) -> String {
        if players.isEmpty { return "none" }
        if players.allSatisfy(\.isWTA) { return "wta" }
        if players.allSatisfy({ !$0.isWTA }) { return "atp" }
        return "mixed"
    }

    private func inferAlertPreferences() {
        alertStore.update {
            $0.notifyBeforeMatch = true
            $0.notifyMatchStarted = true
            $0.notifyMatchFinished = true
            $0.notifyMatchWalkOn = true
            $0.followFavoriteMatches = false
            $0.followFavoritePlayers = true
            $0.followFavoriteTournaments = false
            $0.leadTimeMinutes = 15
        }
    }

    private func seedPopularPlayers() {
        for seed in Self.popularPlayerSeeds {
            _ = fetchOrCreateSeedPlayer(seed)
        }

        do {
            try context.save()
        } catch {
            AppLogger.persistence.error("Failed to seed onboarding players: \(AppLogger.message(for: error), privacy: .private)")
            AppLogger.recordFailure(category: "persistence", operation: "onboarding.seedPopularPlayers", error: error)
        }
    }

    private func loadSuggestedPlayers() {
        if suggestedPlayers.isEmpty {
            seedPopularPlayers()
        }
        suggestedPlayers = Self.popularPlayerSeeds.compactMap { seed in
            fetchSeedPlayer(slug: seed.slug)
        }
        refreshSearchResults()
    }

    private func refreshSearchResults() {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard needle.count >= 2 else {
            searchResults = []
            return
        }

        let normalizedNeedle = normalizedSearchText(needle)
        var descriptor = FetchDescriptor<Player>(sortBy: [SortDescriptor(\.name)])
        descriptor.fetchLimit = 5_000

        do {
            let matchingSuggestions = suggestedPlayers.filter { player in
                normalizedSearchText(player.name).contains(normalizedNeedle)
            }
            let matchingSyncedPlayers = try context.fetch(descriptor).filter { player in
                normalizedSearchText(player.name).contains(normalizedNeedle)
            }

            searchResults = uniquePlayers(matchingSuggestions + matchingSyncedPlayers)
                .sorted { first, second in
                    searchRank(for: first, needle: normalizedNeedle) < searchRank(for: second, needle: normalizedNeedle)
                }
                .prefix(12)
                .map { $0 }
        } catch {
            AppLogger.persistence.error("Failed to search onboarding players: \(AppLogger.message(for: error), privacy: .private)")
            AppLogger.recordFailure(category: "persistence", operation: "onboarding.searchPlayers", error: error)
            searchResults = []
        }
    }

    private func normalizedSearchText(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func searchRank(for player: Player, needle: String) -> Int {
        let name = normalizedSearchText(player.name)
        if name == needle { return 0 }
        if name.hasPrefix(needle) { return 1 }
        if name.split(separator: " ").contains(where: { $0.hasPrefix(needle) }) { return 2 }
        return 3
    }

    private func uniquePlayers(_ players: [Player]) -> [Player] {
        var seenIDs = Set<UUID>()
        return players.filter { player in
            seenIDs.insert(player.id).inserted
        }
    }

    private func fetchOrCreateSeedPlayer(_ seed: (slug: String, name: String, nationality: String, isWTA: Bool)) -> Player {
        if let existing = fetchSeedPlayer(slug: seed.slug) {
            return existing
        }

        let player = Player(
            externalKey: "seed-\(seed.slug)",
            name: seed.name,
            nationality: seed.nationality,
            isWTA: seed.isWTA
        )
        context.insert(player)
        return player
    }

    private func fetchSeedPlayer(slug: String) -> Player? {
        let key = "seed-\(slug)"
        let descriptor = FetchDescriptor<Player>(predicate: #Predicate { player in
            player.externalKey == key
        })
        do {
            return try context.fetch(descriptor).first
        } catch {
            AppLogger.persistence.error("Failed to fetch onboarding seed player: \(AppLogger.message(for: error), privacy: .private)")
            AppLogger.recordFailure(category: "persistence", operation: "onboarding.fetchSeedPlayer", error: error)
            return nil
        }
    }

    private static let popularPlayerSeeds: [(slug: String, name: String, nationality: String, isWTA: Bool)] = [
        ("carlos-alcaraz", "Carlos Alcaraz", "ESP", false),
        ("jannik-sinner", "Jannik Sinner", "ITA", false),
        ("novak-djokovic", "Novak Djokovic", "SRB", false),
        ("daniil-medvedev", "Daniil Medvedev", "RUS", false),
        ("iga-swiatek", "Iga Swiatek", "POL", true),
        ("aryna-sabalenka", "Aryna Sabalenka", "BLR", true),
        ("coco-gauff", "Coco Gauff", "USA", true),
        ("beatriz-haddad-maia", "Beatriz Haddad Maia", "BRA", true),
        ("naomi-osaka", "Naomi Osaka", "JPN", true),
        ("rafael-nadal", "Rafael Nadal", "ESP", false),
        ("alexander-zverev", "Alexander Zverev", "GER", false),
        ("elena-rybakina", "Elena Rybakina", "KAZ", true),
        ("mirra-andreeva", "Mirra Andreeva", "RUS", true),
        ("jessica-pegula", "Jessica Pegula", "USA", true),
        ("casper-ruud", "Casper Ruud", "NOR", false),
        ("ben-shelton", "Ben Shelton", "USA", false),
        ("ons-jabeur", "Ons Jabeur", "TUN", true),
        ("madison-keys", "Madison Keys", "USA", true)
    ]
}
