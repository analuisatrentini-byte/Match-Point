import SwiftUI
import SwiftData
import OSLog

struct OnboardingView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var alertStore: AlertPreferencesStore
    @EnvironmentObject private var experienceStore: ExperiencePreferencesStore
    @EnvironmentObject private var analyticsStore: ProductAnalyticsStore
    @Query(sort: \Player.name) private var players: [Player]

    @State private var selectedPlayerIDs = Set<UUID>()

    var onFinish: () -> Void
    private let minimumFavoritePlayers = 1

    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
    }

    private var suggestedPlayers: [Player] {
        Array(players.prefix(18))
    }

    private var selectedPlayers: [Player] {
        players.filter { selectedPlayerIDs.contains($0.id) }
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
                if players.isEmpty {
                    seedPopularPlayers()
                }
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
    private var playerGrid: some View {
        if suggestedPlayers.isEmpty {
            ContentUnavailableView(
                "Carregando jogadores...",
                systemImage: "person.2",
                description: Text("A lista inicial aparece automaticamente.")
            )
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 148), spacing: 10)], spacing: 10) {
                ForEach(suggestedPlayers) { player in
                    playerButton(player)
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
        if players.isEmpty {
            seedPopularPlayers()
        }

        for player in players {
            player.isFavorite = selectedPlayerIDs.contains(player.id)
        }

        do {
            try context.save()
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
        guard players.isEmpty else { return }

        for seed in Self.popularPlayerSeeds {
            context.insert(
                Player(
                    externalKey: "seed-\(seed.slug)",
                    name: seed.name,
                    nationality: seed.nationality,
                    isWTA: seed.isWTA
                )
            )
        }

        do {
            try context.save()
        } catch {
            AppLogger.persistence.error("Failed to seed onboarding players: \(AppLogger.message(for: error), privacy: .private)")
            AppLogger.recordFailure(category: "persistence", operation: "onboarding.seedPopularPlayers", error: error)
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
