import SwiftUI
import SwiftData

struct ToursView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var analyticsStore: ProductAnalyticsStore
    @Query private var tournaments: [Tournament]
    @State private var isSyncing = false
    @State private var selectedTour: Tournament.Tour? = nil
    @State private var selectedSurface: String = ""
    @State private var searchText: String = ""

    init() {
        // Hide tournaments that ended more than a week ago — the user is
        // browsing what's coming up, not the archive.
        let threshold = Calendar.current.date(byAdding: .day, value: -7, to: .now) ?? .distantPast
        _tournaments = Query(
            filter: #Predicate<Tournament> { $0.endDate >= threshold },
            sort: \Tournament.startDate,
            order: .forward
        )
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    SyncFreshnessLabel(scope: .tournaments, isSyncing: isSyncing)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                    Spacer()
                    if activeFilterCount > 0 {
                        Button {
                            selectedTour = nil
                            selectedSurface = ""
                        } label: {
                            Label("Limpar filtros", systemImage: "xmark.circle.fill")
                                .font(.caption.weight(.semibold))
                                .labelStyle(.titleAndIcon)
                                .lineLimit(1)
                                .minimumScaleFactor(0.82)
                        }
                        .buttonStyle(.borderless)
                        .tint(.matchPointGreen)
                        .accessibilityIdentifier("tours-clear-filters")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 4, trailing: 16))
                .listRowBackground(Color.clear)
            }

            Section {
                VStack(spacing: 10) {
                    tournamentFilterPicker(
                        options: [
                            ("Todos", nil as Tournament.Tour?),
                            ("ATP", .atp),
                            ("WTA", .wta)
                        ],
                        selection: $selectedTour
                    )
                    .accessibilityIdentifier("tours-tour-filter")

                    tournamentFilterPicker(
                        options: [
                            ("Todas", ""),
                            ("Hard", "Hard"),
                            ("Clay", "Clay"),
                            ("Grass", "Grass")
                        ],
                        selection: $selectedSurface
                    )
                    .accessibilityIdentifier("tours-surface-filter")
                }
                .padding(.vertical, 2)
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 8, trailing: 16))
                .listRowBackground(Color.clear)
            }

            if filteredTournaments.isEmpty {
                Section {
                    if tournaments.isEmpty {
                        EmptyStateActionCard(
                            title: "Circuito ainda em cache",
                            message: "O calendário aparece assim que a próxima sincronização da API terminar.",
                            systemImage: "trophy"
                        )
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    } else {
                        ContentUnavailableView(
                            "Nenhum torneio encontrado",
                            systemImage: "line.3.horizontal.decrease.circle",
                            description: Text("Ajuste busca e filtros para ampliar os resultados.")
                        )
                        .tournamentCardRow()
                    }
                }
            }

            ForEach(filteredTournaments) { t in
                NavigationLink(destination: TournamentDetailView(tournament: t)) {
                    tournamentCard(t)
                }
                .buttonStyle(.plain)
                .tournamentCardRow()
                .favoriteSwipeAction(isFavorite: t.isFavorite) {
                    let willFavorite = !t.isFavorite
                    t.isFavorite.toggle()
                    AutoSyncTracker.reset(.matches)
                    AutoSyncTracker.reset(.liveMatches)
                    if willFavorite {
                        analyticsStore.record(
                            ProductAnalyticsEventName.favoriteTournamentChosen,
                            properties: ["tournamentID": t.behaviorKey, "surface": "tours-list"]
                        )
                    }
                    Task {
                        await AlertEventEngine.shared.refreshScheduledNotifications(in: context, force: true)
                    }
                }
            }
            .onDelete { indexSet in
                indexSet.map { tournaments[$0] }.forEach(context.delete)
            }
        }
        .listStyle(.plain)
        // Search bar SEMPRE visível (não esconde ao scroll). Antes era o
        // default `.automatic`, que combinado com o segmented picker do
        // CircuitView em `safeAreaInset(.top)` deixava o campo de busca
        // escondido até o usuário descobrir o swipe-down. Forçar `.always`
        // garante que tanto Torneios quanto Rankings (que já força .always)
        // mostrem a busca de forma consistente.
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: Text("Buscar torneio, cidade ou país")
        )
        .task {
            guard tournaments.isEmpty, AutoSyncTracker.shouldSync(.tournaments), !isSyncing else { return }
            await runAutoSync()
        }
        .appleSportsBackground(.royal)
        .navigationTitle("Tours")
        .onDisappear { searchText = "" }
    }

    private var activeFilterCount: Int {
        var n = 0
        if selectedTour != nil { n += 1 }
        if !selectedSurface.isEmpty { n += 1 }
        return n
    }

    private func tournamentFilterPicker<SelectionValue: Hashable>(
        options: [(label: String, value: SelectionValue)],
        selection: Binding<SelectionValue>
    ) -> some View {
        HStack(spacing: 3) {
            ForEach(options, id: \.value) { option in
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        selection.wrappedValue = option.value
                    }
                } label: {
                    Text(option.label)
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .foregroundStyle(selection.wrappedValue == option.value ? Color.black : Color.readableSecondary)
                        .background(
                            Capsule(style: .continuous)
                                .fill(selection.wrappedValue == option.value ? Color.matchPointGreen : Color.clear)
                                .overlay(
                                    Capsule(style: .continuous)
                                        .strokeBorder(selection.wrappedValue == option.value ? Color.white.opacity(0.28) : Color.clear, lineWidth: 1)
                                )
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(
            Capsule(style: .continuous)
                .fill(Color.black.opacity(0.50))
                .overlay(Capsule(style: .continuous).strokeBorder(Color.cardSurfaceStroke.opacity(0.26), lineWidth: 1))
        )
    }

    private func tournamentCard(_ tournament: Tournament) -> some View {
        let dateRange = "\(tournament.startDate.formatted(.dateTime.month().day()))-\(tournament.endDate.formatted(.dateTime.month().day()))"

        return HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 4) {
                Text(tournament.startDate, format: .dateTime.month(.abbreviated))
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(Color.readableSecondary)
                    .textCase(.uppercase)
                Text(tournament.startDate, format: .dateTime.day())
                    .font(.title3.monospacedDigit().weight(.heavy))
            }
            .frame(width: 48, height: 54)
            .background(Color.cardOverlaySoft)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(tournament.name)
                        .font(.headline.weight(.semibold))
                        .lineLimit(2)
                    if tournament.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.yellow)
                    }
                    Spacer(minLength: 0)
                    Text(tournament.tour == .atp ? "ATP" : "WTA")
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.green.opacity(0.14), in: Capsule())
                }

                Label("\(displayCity(for: tournament)), \(displayCountry(for: tournament))", systemImage: "mappin.and.ellipse")
                    .font(.caption)
                    .foregroundStyle(Color.readableSecondary)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    tournamentPill(displaySurface(for: tournament), systemImage: "circle.grid.2x2.fill")
                    tournamentPill(dateRange, systemImage: "calendar")
                }
            }
        }
    }

    private func tournamentPill(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Color.readableSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.cardOverlaySoft, in: Capsule())
            .lineLimit(1)
    }

    private var filteredTournaments: [Tournament] {
        tournaments.filter { t in
            guard t.isMainCircuitEvent else { return false }
            let matchesSearch = searchText.isEmpty || t.name.localizedCaseInsensitiveContains(searchText) || t.city.localizedCaseInsensitiveContains(searchText) || t.country.localizedCaseInsensitiveContains(searchText)
            let matchesTour = selectedTour == nil || t.tour == selectedTour!
            let matchesSurface = selectedSurface.isEmpty || t.surface.localizedCaseInsensitiveContains(selectedSurface)
            return matchesSearch && matchesTour && matchesSurface
        }
    }

    private func addSampleTournament(tour: Tournament.Tour, name: String, surface: String) {
        let now = Date()
        let end = Calendar.current.date(byAdding: .day, value: 7, to: now) ?? now
        let t = Tournament(name: name, city: "City", country: "Country", surface: surface, tour: tour, startDate: now, endDate: end)
        context.insert(t)
    }

    private func displayCity(for tournament: Tournament) -> String {
        tournament.city == "TBD" ? "City TBA" : tournament.city
    }

    private func displayCountry(for tournament: Tournament) -> String {
        tournament.country == "TBD" ? "Country TBA" : tournament.country
    }

    private func displaySurface(for tournament: Tournament) -> String {
        tournament.surface == "Unknown" ? "Superfície a confirmar" : tournament.surface
    }

    @MainActor
    private func runAutoSync() async {
        isSyncing = true
        defer { isSyncing = false }
        AutoSyncTracker.markAttempted(.tournaments)
        let service = DataSyncService(context: context)
        do {
            try await service.syncTournaments(allowFallback: false)
            AutoSyncTracker.markSynced(.tournaments)
        } catch {
            // Torneios should not surface backend configuration banners in the
            // browsing UI. The Settings/diagnostics area owns setup guidance.
        }
    }
}

private extension View {
    func tournamentCardRow() -> some View {
        self
            .foregroundStyle(Color.white)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.cardSurface)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.cardSurfaceStroke.opacity(0.30), lineWidth: 1)
            }
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}
