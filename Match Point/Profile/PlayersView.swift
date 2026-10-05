import SwiftUI
import SwiftData

// Seção "Jogadores" agora é o ranking de simples ATP/WTA — top 100 de cada
// tour, layout inspirado em apps de ranking de tênis (Apple Sports style):
// header com toggle de tour + bloco-título + lista compacta de posições.
//
// Cada row mostra: posição, bandeira do país, nome curto ("C. Alcaraz") e
// pontos no ranking. Tap → PlayerDetailView (perfil completo). Swipe →
// favoritar (padrão único do app via `favoriteSwipeAction`).

struct PlayersView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var analyticsStore: ProductAnalyticsStore
    @Query(sort: \Player.name) private var players: [Player]
    @Query(sort: \RankingEntry.rank) private var rankings: [RankingEntry]
    @State private var isSyncing = false
    @State private var syncFeedback: UserFacingSyncFeedback?
    @State private var searchText: String = ""
    @State private var tourFilter: Tour = .atp

    private enum Tour: String, CaseIterable, Identifiable {
        case atp = "ATP"
        case wta = "WTA"

        var id: String { rawValue }

        var titleLabel: String { "Ranking de simples da \(rawValue)" }
    }

    private static let topNCap = 100

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                freshnessRow

                if let syncFeedback {
                    SyncFeedbackBanner(feedback: syncFeedback)
                }

                rankingHeader

                if topRankings.isEmpty {
                    emptyState
                } else {
                    rankingCard
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: Text("Buscar jogador ou país")
        )
        .task {
            guard AutoSyncTracker.shouldSync(.playersAndRankings), !isSyncing else { return }
            await runAutoSync()
        }
        .appleSportsBackground(.royal)
        .navigationTitle("Rankings")
        .onDisappear { searchText = "" }
    }

    // MARK: - Header

    private var freshnessRow: some View {
        HStack {
            SyncFreshnessLabel(scope: .playersAndRankings, isSyncing: isSyncing)
            Spacer()
        }
    }

    private var rankingHeader: some View {
        HStack(alignment: .center) {
            HStack(spacing: 6) {
                Image(systemName: "tennisball.fill")
                    .foregroundStyle(.yellow)
                Text("Rankings")
                    .font(.title2.weight(.heavy))
                    .foregroundStyle(.white)
            }
            Spacer()
            // Segmented picker binário ATP/WTA. Honesta vs a pill antiga:
            // o chevron up-down (`chevron.up.chevron.down`) sugeria abrir
            // menu/picker, mas o comportamento era apenas alternar entre
            // 2 valores. Affordance e comportamento agora batem — o
            // segmented mostra as duas opções, tap muda direto, sem mentir
            // sobre menu.
            Picker("Tour", selection: $tourFilter) {
                ForEach(Tour.allCases) { tour in
                    Text(tour.rawValue).tag(tour)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 140)
            .accessibilityIdentifier("players-tour-toggle")
        }
    }

    // MARK: - List

    private var rankingCard: some View {
        VStack(spacing: 0) {
            // Bloco-título centralizado em cima da lista, igual ao print de
            // referência: "Ranking de simples da ATP" / "...da WTA".
            Text(tourFilter.titleLabel)
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)

            ForEach(Array(topRankings.enumerated()), id: \.element.id) { index, entry in
                NavigationLink(destination: PlayerDetailView(player: entry.player ?? Player(name: "?", nationality: "UNK", isWTA: tourFilter == .wta))) {
                    rankingRow(entry: entry, showsDivider: index < topRankings.count - 1)
                }
                .buttonStyle(.plain)
                .favoriteSwipeAction(isFavorite: entry.player?.isFavorite == true) {
                    if let player = entry.player {
                        let willFavorite = !player.isFavorite
                        player.isFavorite.toggle()
                        if willFavorite {
                            analyticsStore.record(
                                ProductAnalyticsEventName.favoritePlayerChosen,
                                properties: ["playerID": player.behaviorKey, "surface": "rankings-list"]
                            )
                        }
                    }
                    Task {
                        await AlertEventEngine.shared.refreshScheduledNotifications(in: context, force: true)
                    }
                }
            }
        }
        .background(Color.black.opacity(0.28))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func rankingRow(entry: RankingEntry, showsDivider: Bool) -> some View {
        let player = entry.player
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("\(entry.rank)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(Color.readableSecondary)
                    .frame(width: 32, alignment: .leading)

                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.14))
                    Text(CountryFlag.emoji(for: player?.nationality ?? ""))
                        .font(.system(size: 18))
                }
                .frame(width: 30, height: 30)

                Text(shortName(player?.name ?? "?"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                if player?.isFavorite == true {
                    Image(systemName: "star.fill")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                }

                Spacer(minLength: 8)

                Text(pointsLabel(entry.points))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.85))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())

            if showsDivider {
                Rectangle()
                    .fill(Color.white.opacity(0.07))
                    .frame(height: 1)
                    .padding(.leading, 60)
            }
        }
    }

    private var emptyState: some View {
        Group {
            if players.isEmpty {
                EmptyStateActionCard(
                    title: "Os rankings estão chegando",
                    message: "O ranking ATP/WTA será baixado no próximo ciclo de sincronização assim que a API responder.",
                    systemImage: "list.number"
                )
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            } else {
                ContentUnavailableView(
                    "Nenhum jogador encontrado",
                    systemImage: "magnifyingglass",
                    description: Text("Refine a busca ou mude o tour entre ATP e WTA.")
                )
                .padding(.vertical, 24)
            }
        }
    }

    // MARK: - Derived data

    /// Top 100 do tour selecionado, filtrado pela busca. `RankingEntry.rank`
    /// já vem em ordem crescente do `@Query(sort: \RankingEntry.rank)`.
    private var topRankings: [RankingEntry] {
        rankings
            .filter { entry in
                guard let player = entry.player else { return false }
                let tourMatches = tourFilter == .wta ? player.isWTA : !player.isWTA
                guard tourMatches else { return false }
                guard !searchText.isEmpty else { return true }
                return player.name.localizedCaseInsensitiveContains(searchText)
                    || player.nationality.localizedCaseInsensitiveContains(searchText)
            }
            .prefix(Self.topNCap)
            .map { $0 }
    }

    // MARK: - Helpers

    private func shortName(_ full: String) -> String {
        let parts = full.split(separator: " ").map(String.init)
        guard parts.count >= 2, let firstInitial = parts.first?.first else { return full }
        return "\(firstInitial). \(parts.last ?? "")"
    }

    private func pointsLabel(_ value: Int) -> String {
        value.formatted(.number)
    }

    @MainActor
    private func runAutoSync() async {
        isSyncing = true
        defer { isSyncing = false }
        let service = DataSyncService(context: context)
        do {
            try await service.syncPlayersAndRankings()
            AutoSyncTracker.markSynced(.playersAndRankings)
        } catch {
            // Silent on auto-sync; manual button surfaces errors.
        }
    }
}
