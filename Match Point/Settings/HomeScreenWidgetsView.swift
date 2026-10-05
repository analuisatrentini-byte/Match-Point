import SwiftData
import SwiftUI

struct HomeScreenWidgetsView: View {
    @Query(sort: \Player.name) private var players: [Player]
    @Query(sort: \Tournament.startDate) private var tournaments: [Tournament]
    @AppStorage("match-point.widgets.preferred-player-id") private var preferredPlayerID = ""
    @AppStorage("match-point.widgets.preferred-tournament-id") private var preferredTournamentID = ""
    @AppStorage("match-point.widgets.tour-filter") private var tourFilter = "ATP + WTA"
    @AppStorage("match-point.widgets.timezone") private var timezone = "Local"
    @AppStorage("match-point.widgets.show-ranking") private var showRanking = true
    @AppStorage("match-point.widgets.show-photos") private var showPhotos = true
    @AppStorage("match-point.widgets.show-live-scores") private var showLiveScores = true
    @AppStorage("match-point.widgets.show-result-spoilers") private var showResultSpoilers = true
    @State private var selectedWidgetID = 0
    @State private var selectedWidgetSize: WidgetSize = .medium

    private let widgets = HomeScreenWidgetCatalog.items

    private var favoritePlayers: [Player] {
        players.filter(\.isFavorite).sorted { $0.name < $1.name }
    }

    private var favoriteTournaments: [Tournament] {
        tournaments.filter(\.isFavorite).sorted { $0.startDate < $1.startDate }
    }

    private var selectedWidget: HomeScreenWidgetDescriptor {
        widgets.first { $0.id == selectedWidgetID } ?? widgets[0]
    }

    var body: some View {
        List {
            preferencesSection
            previewSection
            catalogSection
        }
        .listStyle(.plain)
        .appleSportsBackground(.royal)
        .navigationTitle("Home Screen Widgets")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .onAppear {
            syncWidgetPreferencesToAppGroup()
        }
        .onChange(of: preferredPlayerID) { _, _ in
            syncWidgetPreferencesToAppGroup()
        }
        .onChange(of: preferredTournamentID) { _, _ in
            syncWidgetPreferencesToAppGroup()
        }
        .onChange(of: showResultSpoilers) { _, newValue in
            UserDefaults(suiteName: "group.ALTB.Match-Point")?.set(newValue, forKey: "match-point.widgets.show-result-spoilers")
            syncSpoilerFreeMode(showResultSpoilers: newValue)
        }
        .onChange(of: selectedWidgetID) { _, _ in
            normalizeSelectedWidgetSize()
        }
    }

    private var previewSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 14) {
                WidgetHeader(title: "Premium Tennis", subtitle: "Home, Lock Screen e Watch")
                SelectedWidgetPreview(
                    widget: selectedWidget,
                    size: selectedWidgetSize,
                    playerName: preferredPlayerName,
                    playerCountry: preferredPlayerCountry,
                    playerShortName: preferredPlayerShortName,
                    tournamentName: preferredTournamentName,
                    showRanking: showRanking,
                    showLiveScores: showLiveScores
                )
            }
            .padding(.vertical, 4)
            .appListCardRow(cornerRadius: 22, padding: 16)
        }
    }

    private var preferencesSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Jogador favorito", selection: $preferredPlayerID) {
                    Text("Automático").tag("")
                    ForEach(favoritePlayers) { player in
                        Text(player.name).tag(player.id.uuidString)
                    }
                }

                Picker("Estilo", selection: $selectedWidgetID) {
                    ForEach(widgets) { widget in
                        Text(widget.name).tag(widget.id)
                    }
                }

                Picker("Circuito", selection: $tourFilter) {
                    Text("ATP + WTA").tag("ATP + WTA")
                    Text("ATP").tag("ATP")
                    Text("WTA").tag("WTA")
                    Text("Grand Slams").tag("Grand Slams")
                }

                Picker("Tamanho", selection: $selectedWidgetSize) {
                    ForEach(selectedWidget.sizes) { size in
                        Text(size.rawValue).tag(size)
                    }
                }
                .pickerStyle(.segmented)

                Toggle("Ocultar spoilers", isOn: Binding(
                    get: { !showResultSpoilers },
                    set: { showResultSpoilers = !$0 }
                ))
            }
            .appListCardRow()
        } header: {
            Text("Configuração do widget")
        } footer: {
            Text("O app completa automaticamente fotos, ranking, placar ao vivo e horário quando houver dados disponíveis.")
        }
    }

    private var catalogSection: some View {
        Section {
            ForEach(widgets) { widget in
                WidgetCatalogRow(
                    widget: widget,
                    selectedSize: widget.id == selectedWidgetID ? selectedWidgetSize : nil,
                    onSelect: {
                        selectWidget(widget)
                    },
                    onSizeSelect: { size in
                        selectWidget(widget, size: size)
                    }
                )
                .appListCardRow()
            }
        } header: {
            Text("Widgets disponíveis")
        } footer: {
            Text("Small mostra uma informação principal. Medium adiciona contexto. Large funciona como dashboard compacto.")
        }
    }

    private var preferredPlayerName: String {
        if let player = favoritePlayers.first(where: { $0.id.uuidString == preferredPlayerID }) {
            return player.name
        }
        return favoritePlayers.first?.name ?? "Jannik Sinner"
    }

    private var preferredPlayerCountry: String {
        if let player = favoritePlayers.first(where: { $0.id.uuidString == preferredPlayerID }) {
            return CountryFlag.emoji(for: player.nationality)
        }
        return favoritePlayers.first.map { CountryFlag.emoji(for: $0.nationality) } ?? "ITA"
    }

    private var preferredPlayerShortName: String {
        preferredPlayerName.split(separator: " ").last.map(String.init) ?? preferredPlayerName
    }

    private var preferredTournamentName: String {
        if let tournament = favoriteTournaments.first(where: { $0.id.uuidString == preferredTournamentID }) {
            return tournament.name
        }
        return favoriteTournaments.first?.name ?? "US Open"
    }

    private func syncSpoilerFreeMode(showResultSpoilers: Bool) {
        let key = "match-point.experience-preferences"
        let defaults = UserDefaults.standard
        var preferences = defaults.data(forKey: key)
            .flatMap { try? JSONDecoder().decode(ExperiencePreferences.self, from: $0) } ?? ExperiencePreferences()
        preferences.spoilerFreeMode = !showResultSpoilers
        if let data = try? JSONEncoder().encode(preferences) {
            defaults.set(data, forKey: key)
        }
    }

    private func syncWidgetPreferencesToAppGroup() {
        guard let defaults = UserDefaults(suiteName: "group.ALTB.Match-Point") else { return }
        defaults.set(preferredPlayerID, forKey: "match-point.widgets.preferred-player-id")
        defaults.set(preferredTournamentID, forKey: "match-point.widgets.preferred-tournament-id")
        defaults.set(showResultSpoilers, forKey: "match-point.widgets.show-result-spoilers")
    }

    private func selectWidget(_ widget: HomeScreenWidgetDescriptor, size: WidgetSize? = nil) {
        selectedWidgetID = widget.id
        if let size, widget.sizes.contains(size) {
            selectedWidgetSize = size
        } else if !widget.sizes.contains(selectedWidgetSize), let fallback = widget.sizes.first {
            selectedWidgetSize = fallback
        }
    }

    private func normalizeSelectedWidgetSize() {
        guard !selectedWidget.sizes.contains(selectedWidgetSize), let fallback = selectedWidget.sizes.first else {
            return
        }
        selectedWidgetSize = fallback
    }
}

struct HomeScreenWidgetInlinePanel: View {
    @Query(sort: \Player.name) private var players: [Player]
    @Query(sort: \Tournament.startDate) private var tournaments: [Tournament]
    @AppStorage("match-point.widgets.preferred-player-id") private var preferredPlayerID = ""
    @AppStorage("match-point.widgets.preferred-tournament-id") private var preferredTournamentID = ""
    @AppStorage("match-point.widgets.tour-filter") private var tourFilter = "ATP + WTA"
    @AppStorage("match-point.widgets.timezone") private var timezone = "Local"
    @AppStorage("match-point.widgets.show-ranking") private var showRanking = true
    @AppStorage("match-point.widgets.show-photos") private var showPhotos = true
    @AppStorage("match-point.widgets.show-live-scores") private var showLiveScores = true
    @AppStorage("match-point.widgets.show-result-spoilers") private var showResultSpoilers = true
    @State private var selectedWidgetID = 0
    @State private var selectedWidgetSize: WidgetSize = .medium

    private let widgets = HomeScreenWidgetCatalog.items

    private var favoritePlayers: [Player] {
        players.filter(\.isFavorite).sorted { $0.name < $1.name }
    }

    private var favoriteTournaments: [Tournament] {
        tournaments.filter(\.isFavorite).sorted { $0.startDate < $1.startDate }
    }

    private var selectedWidget: HomeScreenWidgetDescriptor {
        widgets.first { $0.id == selectedWidgetID } ?? widgets[0]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle(
                "Widgets",
                subtitle: "Escolha um favorito, um estilo e veja como ele aparece na Home, Lock Screen e Watch."
            )

            VStack(alignment: .leading, spacing: 14) {
                Picker("Jogador favorito", selection: $preferredPlayerID) {
                    Text("Automático").tag("")
                    ForEach(favoritePlayers) { player in
                        Text(player.name).tag(player.id.uuidString)
                    }
                }

                Picker("Estilo", selection: $selectedWidgetID) {
                    ForEach(widgets) { widget in
                        Text(widget.name).tag(widget.id)
                    }
                }

                Picker("Circuito", selection: $tourFilter) {
                    Text("ATP + WTA").tag("ATP + WTA")
                    Text("ATP").tag("ATP")
                    Text("WTA").tag("WTA")
                    Text("Grand Slams").tag("Grand Slams")
                }

                Picker("Tamanho", selection: $selectedWidgetSize) {
                    ForEach(selectedWidget.sizes) { size in
                        Text(size.rawValue).tag(size)
                    }
                }
                .pickerStyle(.segmented)

                Toggle("Ocultar spoilers", isOn: Binding(
                    get: { !showResultSpoilers },
                    set: { showResultSpoilers = !$0 }
                ))
            }
            .font(.subheadline)
            .appListCardRow(cornerRadius: 18, padding: 14)

            sectionTitle("Prévia", subtitle: nil)

            SelectedWidgetPreview(
                widget: selectedWidget,
                size: selectedWidgetSize,
                playerName: preferredPlayerName,
                playerCountry: preferredPlayerCountry,
                playerShortName: preferredPlayerShortName,
                tournamentName: preferredTournamentName,
                showRanking: showRanking,
                showLiveScores: showLiveScores
            )

            sectionTitle(
                "Widgets disponíveis",
                subtitle: "Modelos prontos para quem quiser trocar o estilo rapidamente."
            )

            VStack(spacing: 10) {
                ForEach(widgets) { widget in
                    WidgetCatalogRow(
                        widget: widget,
                        selectedSize: widget.id == selectedWidgetID ? selectedWidgetSize : nil,
                        onSelect: {
                            selectWidget(widget)
                        },
                        onSizeSelect: { size in
                            selectWidget(widget, size: size)
                        }
                    )
                    .appListCardRow(cornerRadius: 18, padding: 12)
                }
            }
        }
        .padding(.top, 28)
        .accessibilityIdentifier("favorites-inline-widget-settings")
        .onAppear {
            syncWidgetPreferencesToAppGroup()
        }
        .onChange(of: preferredPlayerID) { _, _ in
            syncWidgetPreferencesToAppGroup()
        }
        .onChange(of: preferredTournamentID) { _, _ in
            syncWidgetPreferencesToAppGroup()
        }
        .onChange(of: showResultSpoilers) { _, newValue in
            UserDefaults(suiteName: "group.ALTB.Match-Point")?.set(newValue, forKey: "match-point.widgets.show-result-spoilers")
            syncSpoilerFreeMode(showResultSpoilers: newValue)
        }
        .onChange(of: selectedWidgetID) { _, _ in
            normalizeSelectedWidgetSize()
        }
    }

    private func sectionTitle(_ title: String, subtitle: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title3.weight(.bold))
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Color.readableSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var preferredPlayerName: String {
        if let player = favoritePlayers.first(where: { $0.id.uuidString == preferredPlayerID }) {
            return player.name
        }
        return favoritePlayers.first?.name ?? "Jannik Sinner"
    }

    private var preferredPlayerShortName: String {
        preferredPlayerName.split(separator: " ").last.map(String.init) ?? preferredPlayerName
    }

    private var preferredPlayerCountry: String {
        if let player = favoritePlayers.first(where: { $0.id.uuidString == preferredPlayerID }) {
            return CountryFlag.emoji(for: player.nationality)
        }
        return favoritePlayers.first.map { CountryFlag.emoji(for: $0.nationality) } ?? "ITA"
    }

    private var preferredTournamentName: String {
        if let tournament = favoriteTournaments.first(where: { $0.id.uuidString == preferredTournamentID }) {
            return tournament.name
        }
        return favoriteTournaments.first?.name ?? "US Open"
    }

    private func syncSpoilerFreeMode(showResultSpoilers: Bool) {
        let key = "match-point.experience-preferences"
        let defaults = UserDefaults.standard
        var preferences = defaults.data(forKey: key)
            .flatMap { try? JSONDecoder().decode(ExperiencePreferences.self, from: $0) } ?? ExperiencePreferences()
        preferences.spoilerFreeMode = !showResultSpoilers
        if let data = try? JSONEncoder().encode(preferences) {
            defaults.set(data, forKey: key)
        }
    }

    private func syncWidgetPreferencesToAppGroup() {
        guard let defaults = UserDefaults(suiteName: "group.ALTB.Match-Point") else { return }
        defaults.set(preferredPlayerID, forKey: "match-point.widgets.preferred-player-id")
        defaults.set(preferredTournamentID, forKey: "match-point.widgets.preferred-tournament-id")
        defaults.set(showResultSpoilers, forKey: "match-point.widgets.show-result-spoilers")
    }

    private func selectWidget(_ widget: HomeScreenWidgetDescriptor, size: WidgetSize? = nil) {
        selectedWidgetID = widget.id
        if let size, widget.sizes.contains(size) {
            selectedWidgetSize = size
        } else if !widget.sizes.contains(selectedWidgetSize), let fallback = widget.sizes.first {
            selectedWidgetSize = fallback
        }
    }

    private func normalizeSelectedWidgetSize() {
        guard !selectedWidget.sizes.contains(selectedWidgetSize), let fallback = selectedWidget.sizes.first else {
            return
        }
        selectedWidgetSize = fallback
    }
}

private struct HomeScreenWidgetDescriptor: Identifiable {
    let id: Int
    let name: String
    let description: String
    let systemImage: String
    let sizes: [WidgetSize]
    let category: String
}

private enum WidgetSize: String, CaseIterable, Identifiable {
    case small = "Small"
    case medium = "Medium"
    case large = "Large"

    var id: String { rawValue }

    var previewHeight: CGFloat {
        switch self {
        case .small: 118
        case .medium: 150
        case .large: 218
        }
    }

    var previewMaxWidth: CGFloat? {
        switch self {
        case .small: 170
        case .medium, .large: nil
        }
    }
}

private enum HomeScreenWidgetCatalog {
    static let items: [HomeScreenWidgetDescriptor] = [
        .init(id: 0, name: "Meu jogador", description: "Favorito com ranking, país, forma recente, foto quando disponível e próximo jogo.", systemImage: "person.crop.circle.fill.badge.checkmark", sizes: [.small, .medium, .large], category: "Jogador"),
        .init(id: 1, name: "Próxima partida", description: "Próximo jogo de favorito com torneio, horário, fase, quadra e contagem regressiva automática.", systemImage: "calendar.badge.clock", sizes: [.small, .medium, .large], category: "Partidas"),
        .init(id: 3, name: "Placar ao vivo", description: "Sets, ponto atual, saque e resultado final temporário quando a partida acabar.", systemImage: "dot.radiowaves.left.and.right", sizes: [.small, .medium, .large], category: "Ao vivo"),
        .init(id: 6, name: "Calendário de torneios", description: "Torneios ATP/WTA, Grand Slams e datas principais em um calendário compacto.", systemImage: "calendar", sizes: [.small, .medium, .large], category: "Torneios"),
        .init(id: 8, name: "Ranking ATP/WTA", description: "Ranking compacto com pontos, movimento e evolução dos principais jogadores.", systemImage: "list.number", sizes: [.small, .medium, .large], category: "Ranking"),
        .init(id: 18, name: "Favoritos", description: "Lista dos jogadores seguidos com indicação de próximo jogo ou status ao vivo.", systemImage: "star.circle.fill", sizes: [.medium, .large], category: "Favoritos"),
        .init(id: 10, name: "Head-to-Head", description: "Confronto direto automático para partidas importantes dos seus favoritos.", systemImage: "person.2.fill", sizes: [.small, .medium], category: "Análise"),
        .init(id: 13, name: "Hoje no tênis", description: "Briefing diário com agenda, favoritos, top ranking e melhor jogo para acompanhar.", systemImage: "sun.max.fill", sizes: [.small, .medium, .large], category: "Resumo")
    ]
}

private struct SelectedWidgetPreview: View {
    let widget: HomeScreenWidgetDescriptor
    let size: WidgetSize
    let playerName: String
    let playerCountry: String
    let playerShortName: String
    let tournamentName: String
    let showRanking: Bool
    let showLiveScores: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: widget.systemImage)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(Color.matchPointGreen)
                    .frame(width: 34, height: 34)
                    .background(Color.matchPointGreen.opacity(0.16), in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text("Prévia \(size.rawValue): \(widget.name)")
                        .font(.subheadline.weight(.bold))
                    Text(widget.description)
                        .font(.caption)
                        .foregroundStyle(Color.readableSecondary)
                        .lineLimit(2)
                }
            }

            WidgetBackground(surface: previewSurface) {
                previewContent
            }
            .frame(maxWidth: size.previewMaxWidth, minHeight: size.previewHeight, maxHeight: size.previewHeight, alignment: .leading)
        }
    }

    private var previewSurface: WidgetSurfaceKind {
        switch widget.category {
        case "Tournaments", "Tours":
            return .grass
        case "Matches", "Live":
            return .clay
        default:
            return .hard
        }
    }

    @ViewBuilder
    private var previewContent: some View {
        switch widget.id {
        case 0:
            VStack(alignment: .leading, spacing: 8) {
                TournamentBadge(name: tournamentName)
                PlayerCard(name: playerName, country: playerCountry, rank: showRanking ? "#1" : nil)
                if size != .small {
                    HStack(spacing: 10) {
                        StatCell(title: "PTS", value: "11.3k")
                        StatCell(title: "NEXT", value: "19:30")
                    }
                }
                if size == .large {
                    WidgetFooter(text: "Status ao vivo e próximo jogo do favorito")
                }
            }
        case 1:
            VStack(alignment: .leading, spacing: 8) {
                WidgetHeader(title: "NEXT MATCH", subtitle: tournamentName)
                ScheduleRow(time: "19:30", match: "\(playerShortName) vs Rival")
                if size != .small {
                    SurfaceBadge(text: "Hard court")
                    WidgetFooter(text: "Semifinal · Quadra central")
                }
                if size == .large {
                    ScheduleRow(time: "21:00", match: "Possível atraso por jogo anterior")
                }
            }
        case 2:
            VStack(alignment: .leading, spacing: 8) {
                WidgetHeader(title: "COUNTDOWN", subtitle: tournamentName)
                CountdownTimer(hours: "02", minutes: "14")
                if size != .small {
                    WidgetFooter(text: "\(playerShortName) entra em quadra em breve")
                }
            }
        case 3:
            VStack(alignment: .leading, spacing: 8) {
                WidgetHeader(title: "LIVE", subtitle: "\(tournamentName) · SF")
                ScoreBoard(
                    player1: playerShortName,
                    player2: "Rival",
                    score1: "6 4 2",
                    score2: "4 6 1",
                    point: showLiveScores ? "40–30" : "Ao vivo"
                )
                if size != .small {
                    ServeIndicator(name: "Favorito em quadra")
                }
                if size == .large {
                    WidgetFooter(text: "Break point salvo no game anterior")
                }
            }
        case 4:
            VStack(alignment: .leading, spacing: 8) {
                WidgetHeader(title: "RANKING", subtitle: "Atualizado")
                PlayerCard(name: playerName, country: playerCountry, rank: showRanking ? "#1" : nil)
                if size != .small {
                    HStack(spacing: 16) {
                        StatCell(title: "PTS", value: "11.3k")
                        StatCell(title: "MOVE", value: "+1")
                    }
                }
            }
        case 5:
            VStack(alignment: .leading, spacing: 8) {
                WidgetHeader(title: "FORM", subtitle: playerShortName)
                PlayerCard(name: playerName, country: playerCountry, rank: nil)
                if size != .small {
                    FormIndicator(results: [true, true, false, true, true])
                    WidgetFooter(text: "4 vitórias nos últimos 5 jogos")
                }
            }
        case 6, 15:
            VStack(alignment: .leading, spacing: 8) {
                WidgetHeader(title: widget.id == 15 ? "GRAND SLAMS" : "CALENDAR", subtitle: "Próximos torneios")
                TournamentCard(name: tournamentName, dates: "Hoje · Rodada principal")
                if size != .small {
                    TournamentCard(name: "Wimbledon", dates: "Próximo Slam")
                }
                if size == .large {
                    TournamentCard(name: "Roland Garros", dates: "Temporada de saibro")
                }
            }
        case 7:
            VStack(alignment: .leading, spacing: 8) {
                TournamentBadge(name: tournamentName)
                ScheduleRow(time: "14:00", match: "\(playerShortName) em quadra")
                if size != .small {
                    ScheduleRow(time: "19:30", match: "Sessão noturna")
                    WidgetFooter(text: "Jogos de hoje")
                }
            }
        case 8:
            VStack(alignment: .leading, spacing: 8) {
                WidgetHeader(title: "ATP / WTA", subtitle: "Top ranking")
                RankingLine(rank: "#1", name: playerShortName, points: "11.3k")
                if size != .small {
                    RankingLine(rank: "#2", name: "Rival", points: "9.8k")
                    RankingLine(rank: "#3", name: "Chaser", points: "8.7k")
                }
            }
        case 9:
            VStack(alignment: .leading, spacing: 8) {
                WidgetHeader(title: "MOVEMENT", subtitle: playerShortName)
                Label("+2 posições", systemImage: "arrow.up.circle.fill")
                    .font(.title3.weight(.heavy))
                    .foregroundStyle(Color.matchPointGreen)
                if size != .small {
                    WidgetFooter(text: "Projeção pós-torneio")
                }
            }
        case 10:
            VStack(alignment: .leading, spacing: 8) {
                WidgetHeader(title: "HEAD-TO-HEAD", subtitle: tournamentName)
                HStack {
                    PlayerAvatar(name: playerName, country: playerCountry)
                    Text("6–4")
                        .font(.title2.monospacedDigit().weight(.heavy))
                    PlayerAvatar(name: "Rival", country: "ESP")
                }
                if size != .small {
                    WidgetFooter(text: "Últimos confrontos favorecem seu jogador")
                }
            }
        case 11:
            VStack(alignment: .leading, spacing: 8) {
                WidgetHeader(title: "STAT", subtitle: "Tennis Stats")
                Text("72%")
                    .font(.largeTitle.monospacedDigit().weight(.heavy))
                if size != .small {
                    WidgetFooter(text: "Pontos vencidos com 1º saque")
                }
            }
        case 12:
            VStack(alignment: .leading, spacing: 8) {
                WidgetHeader(title: "PHOTO", subtitle: playerShortName)
                Image(systemName: "photo.fill")
                    .font(.largeTitle.weight(.bold))
                if size != .small {
                    WidgetFooter(text: "Momento do jogador favorito")
                }
            }
        case 13:
            VStack(alignment: .leading, spacing: 8) {
                WidgetHeader(title: "TODAY", subtitle: "Briefing")
                ScheduleRow(time: "Agora", match: "Melhor jogo para abrir")
                if size != .small {
                    ScheduleRow(time: "19:30", match: "\(playerShortName) joga")
                    WidgetFooter(text: "Resumo do dia no tênis")
                }
            }
        case 14:
            VStack(alignment: .leading, spacing: 8) {
                WidgetHeader(title: "SCHEDULE", subtitle: "Agenda")
                ScheduleRow(time: "14:00", match: "Favorito em quadra")
                if size != .small {
                    ScheduleRow(time: "16:30", match: "Top 10 em ação")
                    ScheduleRow(time: "19:30", match: "Sessão noturna")
                }
                if size == .large {
                    ScheduleRow(time: "21:15", match: "Jogo recomendado")
                }
            }
        case 16:
            VStack(alignment: .leading, spacing: 8) {
                WidgetHeader(title: "SURFACE", subtitle: tournamentName)
                SurfaceBadge(text: "Grass")
                Text("Rápido")
                    .font(.title2.weight(.heavy))
                if size != .small {
                    WidgetFooter(text: "Superfície favorece saque e rede")
                }
            }
        case 17:
            VStack(alignment: .leading, spacing: 8) {
                WidgetHeader(title: "SEASON", subtitle: playerShortName)
                HStack(spacing: size == .small ? 10 : 16) {
                    StatCell(title: "W-L", value: "42–8")
                    StatCell(title: "TITLES", value: "5")
                    if size != .small {
                        StatCell(title: "ACES", value: "312")
                    }
                }
                if size == .large {
                    WidgetFooter(text: "Temporada do jogador favorito")
                }
            }
        case 18:
            VStack(alignment: .leading, spacing: 8) {
                WidgetHeader(title: "FAVORITES", subtitle: "Jogadores seguidos")
                PlayerCard(name: playerName, country: playerCountry, rank: showRanking ? "#1" : nil)
                if size != .small {
                    PlayerCard(name: "Coco Gauff", country: "USA", rank: "#3")
                }
            }
        case 19:
            VStack(alignment: .leading, spacing: 8) {
                WidgetHeader(title: "TOUR", subtitle: "Categorias")
                HStack {
                    TourPill(text: "ATP")
                    TourPill(text: "WTA")
                    if size != .small {
                        TourPill(text: "SLAM")
                    }
                }
                if size == .large {
                    WidgetFooter(text: "Filtro rápido por circuito")
                }
            }
        case 20:
            VStack(alignment: .leading, spacing: 8) {
                WidgetHeader(title: "RESULT", subtitle: tournamentName)
                ScoreBoard(player1: playerShortName, player2: "Rival", score1: "6 7 6", score2: "4 6 3", point: "FINAL")
                if size != .small {
                    WidgetFooter(text: "Ocultável pelo modo spoiler-free")
                }
            }
        default:
            WidgetHeader(title: widget.name, subtitle: widget.category)
        }
    }
}

private struct WidgetCatalogRow: View {
    let widget: HomeScreenWidgetDescriptor
    var selectedSize: WidgetSize?
    let onSelect: () -> Void
    let onSizeSelect: (WidgetSize) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: widget.systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(LinearGradient(colors: [.black, .green.opacity(0.45)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 8))
                .onTapGesture(perform: onSelect)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(widget.name)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if selectedSize != nil {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.matchPointGreen)
                    } else {
                        Text(widget.category.uppercased())
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Color.readableSecondary)
                    }
                }
                Text(widget.description)
                    .font(.caption)
                    .foregroundStyle(Color.readableSecondary)
                    .lineLimit(2)
                    .onTapGesture(perform: onSelect)
                HStack(spacing: 6) {
                    ForEach(widget.sizes) { size in
                        Button {
                            onSizeSelect(size)
                        } label: {
                            Text(size.rawValue)
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(selectedSize == size ? Color.matchPointPurpleDeep : Color.readableSecondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    selectedSize == size ? Color.matchPointGreen : Color.white.opacity(0.10),
                                    in: Capsule()
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }
}

// MARK: - Widget Design System previews used inside the app catalog

private enum WidgetSurfaceKind {
    case hard
    case clay
    case grass
}

private struct WidgetBackground<Content: View>: View {
    let surface: WidgetSurfaceKind
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .foregroundStyle(.white)
            .background(gradient, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                Circle()
                    .fill(Color.white.opacity(0.14))
                    .frame(width: 76, height: 76)
                    .blur(radius: 18)
                    .offset(x: 18, y: 18)
            }
    }

    private var gradient: LinearGradient {
        switch surface {
        case .hard:
            LinearGradient(colors: [Color.black, Color(red: 0.04, green: 0.19, blue: 0.34)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .clay:
            LinearGradient(colors: [Color.black, Color(red: 0.55, green: 0.22, blue: 0.13)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .grass:
            LinearGradient(colors: [Color.black, Color(red: 0.13, green: 0.35, blue: 0.17)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

private struct WidgetHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.caption2.weight(.heavy))
                .foregroundStyle(Color.readableSecondary)
            Text(subtitle)
                .font(.caption.weight(.bold))
                .lineLimit(1)
        }
    }
}

private struct PlayerCard: View {
    let name: String
    let country: String
    let rank: String?

    var body: some View {
        HStack(spacing: 8) {
            PlayerAvatar(name: name, country: country)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.caption.weight(.heavy))
                    .lineLimit(1)
                if let rank {
                    RankingBadge(text: rank)
                }
            }
        }
    }
}

private struct PlayerAvatar: View {
    let name: String
    let country: String

    var body: some View {
        ZStack {
            Circle().fill(.white.opacity(0.12))
            Text(country.isEmpty ? initials : country)
                .font(.caption.weight(.heavy))
        }
        .frame(width: 34, height: 34)
    }

    private var initials: String {
        name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }
}

private struct TournamentBadge: View {
    let name: String

    var body: some View {
        Label(name.uppercased(), systemImage: "trophy.fill")
            .font(.caption2.weight(.heavy))
            .lineLimit(1)
    }
}

private struct RankingBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.monospacedDigit().weight(.heavy))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.white.opacity(0.14), in: Capsule())
    }
}

private struct RankingLine: View {
    let rank: String
    let name: String
    let points: String

    var body: some View {
        HStack(spacing: 8) {
            Text(rank)
                .font(.caption.monospacedDigit().weight(.heavy))
                .foregroundStyle(Color.matchPointGreen)
                .frame(width: 28, alignment: .leading)
            Text(name)
                .font(.caption.weight(.bold))
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(points)
                .font(.caption.monospacedDigit().weight(.heavy))
                .foregroundStyle(Color.readableSecondary)
        }
    }
}

private struct LiveIndicator: View {
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(.red).frame(width: 6, height: 6)
            Text("LIVE").font(.caption2.weight(.heavy))
        }
    }
}

private struct ScoreBoard: View {
    let player1: String
    let player2: String
    let score1: String
    let score2: String
    let point: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            SetScore(name: player1, score: score1)
            SetScore(name: player2, score: score2)
            Text(point)
                .font(.title3.monospacedDigit().weight(.heavy))
        }
    }
}

private struct SetScore: View {
    let name: String
    let score: String

    var body: some View {
        HStack {
            Text(name).lineLimit(1)
            Spacer(minLength: 4)
            Text(score).monospacedDigit()
        }
        .font(.caption.weight(.bold))
    }
}

private struct ServeIndicator: View {
    let name: String

    var body: some View {
        Label(name, systemImage: "circle.fill")
            .font(.caption2.weight(.bold))
            .foregroundStyle(Color.readableSecondary)
    }
}

private struct SurfaceBadge: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "sportscourt")
            .font(.caption2.weight(.bold))
    }
}

private struct CountdownTimer: View {
    let hours: String
    let minutes: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(hours)
            Text(":")
            Text(minutes)
        }
        .font(.title.monospacedDigit().weight(.heavy))
    }
}

private struct StatCell: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 8, weight: .heavy))
                .foregroundStyle(Color.readableSecondary)
            Text(value)
                .font(.caption.monospacedDigit().weight(.heavy))
        }
    }
}

private struct FormIndicator: View {
    let results: [Bool]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(results.enumerated()), id: \.offset) { _, win in
                Circle()
                    .fill(win ? Color.green : Color.white.opacity(0.22))
                    .frame(width: 7, height: 7)
            }
        }
    }
}

private struct ScheduleRow: View {
    let time: String
    let match: String

    var body: some View {
        HStack {
            Text(time).monospacedDigit().frame(width: 44, alignment: .leading)
            Text(match).lineLimit(1)
        }
        .font(.caption.weight(.semibold))
    }
}

private struct TournamentCard: View {
    let name: String
    let dates: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TournamentBadge(name: name)
            Text(dates)
                .font(.caption2.weight(.bold))
                .foregroundStyle(Color.readableSecondary)
        }
    }
}

private struct TourPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.heavy))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.matchPointGreen.opacity(0.18), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.matchPointGreen.opacity(0.45), lineWidth: 1))
    }
}

private struct WidgetFooter: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .foregroundStyle(Color.readableSecondary)
            .lineLimit(1)
    }
}

#Preview {
    NavigationStack {
        HomeScreenWidgetsView()
            .modelContainer(for: MatchPointPreviewData.modelTypes, inMemory: true) { result in
                if case .success(let container) = result {
                    MatchPointPreviewData.seed(container)
                }
            }
    }
}
