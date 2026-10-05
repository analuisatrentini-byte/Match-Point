//
//  MatchPointScoreWidget.swift
//  MatchPointLiveActivity
//
//  Fixed Home Screen / Lock Screen widget for the best current match snapshot.
//

import AppIntents
import SwiftUI
import WidgetKit

private enum MatchWidgetSharedStorage {
    static let appGroupID = "group.ALTB.Match-Point"
    static let snapshotKey = "match-point.widget.match-snapshots"
    static let preferredPlayerKey = "match-point.widgets.preferred-player-id"

    static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroupID) ?? .standard
    }
}

private struct FavoriteWidgetPlayer: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Jogador")
    static var defaultQuery = FavoriteWidgetPlayerQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

private struct FavoriteWidgetPlayerQuery: EntityQuery {
    func entities(for identifiers: [FavoriteWidgetPlayer.ID]) async throws -> [FavoriteWidgetPlayer] {
        let wanted = Set(identifiers)
        return Self.availablePlayers().filter { wanted.contains($0.id) }
    }

    func suggestedEntities() async throws -> [FavoriteWidgetPlayer] {
        Self.availablePlayers()
    }

    func defaultResult() async -> FavoriteWidgetPlayer? {
        Self.availablePlayers().first
    }

    static func availablePlayers() -> [FavoriteWidgetPlayer] {
        WidgetPlayerCatalog.availablePlayers()
    }
}

private struct FavoritePlayerWidgetConfiguration: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Jogador favorito"
    static var description = IntentDescription("Escolha qual jogador favorito este widget deve acompanhar.")

    @Parameter(title: "Jogador")
    var player: FavoriteWidgetPlayer?

    init() {}

    init(player: FavoriteWidgetPlayer?) {
        self.player = player
    }
}

private enum WidgetPlayerCatalog {
    static func availablePlayers() -> [FavoriteWidgetPlayer] {
        loadSnapshots()
            .flatMap { snapshot in
                [
                    player(id: snapshot.player1ID, name: snapshot.player1Name),
                    player(id: snapshot.player2ID, name: snapshot.player2Name)
                ]
            }
            .compactMap { $0 }
            .uniquedByID()
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func player(id: String?, name: String) -> FavoriteWidgetPlayer? {
        guard let id, !id.isEmpty, !name.isEmpty else { return nil }
        return FavoriteWidgetPlayer(id: id, name: name)
    }

    private static func loadSnapshots() -> [MatchWidgetSnapshot] {
        guard let data = MatchWidgetSharedStorage.defaults.data(forKey: MatchWidgetSharedStorage.snapshotKey) else {
            return []
        }
        return (try? JSONDecoder().decode([MatchWidgetSnapshot].self, from: data)) ?? []
    }
}

private struct MatchWidgetSnapshot: Codable, Identifiable {
    struct SetScore: Codable, Hashable {
        var player1Games: String
        var player2Games: String
    }

    var id: String
    var tournamentName: String
    var roundLabel: String
    var surface: String
    var player1Name: String
    var player2Name: String
    var player1ID: String?
    var player2ID: String?
    var player1Flag: String
    var player2Flag: String
    var player1Rank: Int?
    var player2Rank: Int?
    var player1SetsWon: Int
    var player2SetsWon: Int
    var setScores: [SetScore]
    var pointScore: String
    var gameScore: String
    var serverName: String
    var status: String
    var isLive: Bool
    var isFavorite: Bool
    var courtName: String?
    var orderOfPlay: Int?
    var criticalMomentKind: String?
    var criticalMomentHeadline: String?
    var matchDate: Date?
    var lastUpdated: Date
}

private enum FavoritePlayerWidgetCopy {
    static let title = "Meu jogador"

    static func emptyMessage(playerName: String?) -> String {
        if let playerName, !playerName.isEmpty {
            return "Sem jogo ao vivo ou próximo de \(playerName)."
        }
        return "Escolha um jogador favorito ao editar o widget."
    }
}

private struct MatchPointScoreEntry: TimelineEntry {
    var date: Date
    var snapshots: [MatchWidgetSnapshot]
    var selectedPlayerID: String?
    var selectedPlayerName: String?

    var snapshot: MatchWidgetSnapshot? {
        snapshots.first
    }
}

private struct MatchPointScoreProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> MatchPointScoreEntry {
        MatchPointScoreEntry(
            date: .now,
            snapshots: [.placeholder, .secondPlaceholder],
            selectedPlayerID: "preview-alcaraz",
            selectedPlayerName: "Carlos Alcaraz"
        )
    }

    func snapshot(for configuration: FavoritePlayerWidgetConfiguration, in context: Context) async -> MatchPointScoreEntry {
        let selection = resolvedSelection(for: configuration)
        let snapshots = loadSnapshots(for: configuration, selection: selection)
        return MatchPointScoreEntry(
            date: .now,
            snapshots: snapshots.isEmpty && context.isPreview ? [.placeholder, .secondPlaceholder] : snapshots,
            selectedPlayerID: selection?.id,
            selectedPlayerName: selection?.name
        )
    }

    func timeline(for configuration: FavoritePlayerWidgetConfiguration, in context: Context) async -> Timeline<MatchPointScoreEntry> {
        let selection = resolvedSelection(for: configuration)
        let snapshots = loadSnapshots(for: configuration, selection: selection)
        let entry = MatchPointScoreEntry(
            date: .now,
            snapshots: snapshots,
            selectedPlayerID: selection?.id,
            selectedPlayerName: selection?.name
        )
        let nextRefresh = refreshDate(for: snapshots.first)
        return Timeline(entries: [entry], policy: .after(nextRefresh))
    }

    func recommendations() -> [AppIntentRecommendation<FavoritePlayerWidgetConfiguration>] {
        WidgetPlayerCatalog.availablePlayers().prefix(8).map { player in
            AppIntentRecommendation(
                intent: FavoritePlayerWidgetConfiguration(player: player),
                description: Text("Meu jogador: \(player.name)")
            )
        }
    }

    private func resolvedSelection(for configuration: FavoritePlayerWidgetConfiguration) -> FavoriteWidgetPlayer? {
        if let player = configuration.player {
            return player
        }
        let preferredPlayerID = MatchWidgetSharedStorage.defaults.string(forKey: MatchWidgetSharedStorage.preferredPlayerKey) ?? ""
        if !preferredPlayerID.isEmpty,
           let preferred = WidgetPlayerCatalog.availablePlayers().first(where: { $0.id == preferredPlayerID }) {
            return preferred
        }
        return nil
    }

    private func loadSnapshots(
        for configuration: FavoritePlayerWidgetConfiguration,
        selection: FavoriteWidgetPlayer?
    ) -> [MatchWidgetSnapshot] {
        guard let data = MatchWidgetSharedStorage.defaults.data(forKey: MatchWidgetSharedStorage.snapshotKey) else {
            return []
        }
        let preferredPlayerID = selection?.id ?? ""
        let decoded = ((try? JSONDecoder().decode([MatchWidgetSnapshot].self, from: data)) ?? [])
            .sorted { lhs, rhs in
                let lhsPreferred = lhs.involves(playerID: preferredPlayerID)
                let rhsPreferred = rhs.involves(playerID: preferredPlayerID)
                if lhsPreferred != rhsPreferred { return lhsPreferred && !rhsPreferred }
                if lhs.isLive != rhs.isLive { return lhs.isLive && !rhs.isLive }
                if lhs.isFavorite != rhs.isFavorite { return lhs.isFavorite && !rhs.isFavorite }
                let lhsDate = lhs.matchDate ?? lhs.lastUpdated
                let rhsDate = rhs.matchDate ?? rhs.lastUpdated
                if lhsDate >= .now, rhsDate >= .now, lhsDate != rhsDate { return lhsDate < rhsDate }
                return lhs.lastUpdated > rhs.lastUpdated
            }
        guard configuration.player != nil else { return decoded }
        return decoded.filter { $0.involves(playerID: preferredPlayerID) }
    }

    private func refreshDate(for snapshot: MatchWidgetSnapshot?) -> Date {
        guard let snapshot else {
            return Calendar.current.date(byAdding: .minute, value: 30, to: .now) ?? .now.addingTimeInterval(1_800)
        }
        if snapshot.isLive {
            return Calendar.current.date(byAdding: .minute, value: 2, to: .now) ?? .now.addingTimeInterval(120)
        }
        if let matchDate = snapshot.matchDate {
            let interval = matchDate.timeIntervalSinceNow
            if interval > 0, interval <= 60 * 60 * 3 {
                return Calendar.current.date(byAdding: .minute, value: 10, to: .now) ?? .now.addingTimeInterval(600)
            }
        }
        return Calendar.current.date(byAdding: .minute, value: 30, to: .now) ?? .now.addingTimeInterval(1_800)
    }
}

private extension MatchWidgetSnapshot {
    func involves(playerID: String) -> Bool {
        guard !playerID.isEmpty else { return false }
        return player1ID == playerID || player2ID == playerID
    }

    func playerName(for playerID: String?) -> String {
        guard let playerID, !playerID.isEmpty else {
            return player1Name
        }
        if player1ID == playerID { return player1Name }
        if player2ID == playerID { return player2Name }
        return player1Name
    }

    func opponentName(for playerID: String?) -> String {
        guard let playerID, !playerID.isEmpty else {
            return player2Name
        }
        if player1ID == playerID { return player2Name }
        if player2ID == playerID { return player1Name }
        return player2Name
    }

    func flag(for playerID: String?) -> String {
        guard let playerID, !playerID.isEmpty else {
            return player1Flag
        }
        if player1ID == playerID { return player1Flag }
        if player2ID == playerID { return player2Flag }
        return player1Flag
    }

    func rank(for playerID: String?) -> Int? {
        guard let playerID, !playerID.isEmpty else {
            return player1Rank
        }
        if player1ID == playerID { return player1Rank }
        if player2ID == playerID { return player2Rank }
        return player1Rank
    }
}

struct MatchPointScoreWidget: Widget {
    let kind = "MatchPointScoreWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: FavoritePlayerWidgetConfiguration.self, provider: MatchPointScoreProvider()) { entry in
            MatchPointScoreWidgetView(entry: entry)
                .containerBackground(surfaceBackground(for: entry.snapshot), for: .widget)
                .widgetURL(URL(string: "matchpoint://matches/\(entry.snapshot?.id ?? "latest")"))
        }
        .configurationDisplayName("Match Point")
        .description("Acompanhe placares ao vivo e o próximo jogo dos seus favoritos.")
        .supportedFamilies(Self.supportedFamilies)
    }

    private static var supportedFamilies: [WidgetFamily] {
        #if os(watchOS)
        [.accessoryCircular, .accessoryCorner, .accessoryRectangular, .accessoryInline]
        #else
        [.systemSmall, .systemMedium, .systemLarge, .accessoryCircular, .accessoryRectangular, .accessoryInline]
        #endif
    }

    private func surfaceBackground(for snapshot: MatchWidgetSnapshot?) -> LinearGradient {
        SurfacePalette.colors(for: snapshot?.surface ?? "")
    }
}

struct MatchPointFavoritePlayerWidget: Widget {
    let kind = "MatchPointFavoritePlayerWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: FavoritePlayerWidgetConfiguration.self, provider: MatchPointScoreProvider()) { entry in
            FavoritePlayerWidgetView(entry: entry)
                .containerBackground(SurfacePalette.colors(for: entry.snapshot?.surface ?? ""), for: .widget)
                .widgetURL(deepLinkURL(for: entry))
        }
        .configurationDisplayName("Meu jogador")
        .description("Escolha um jogador favorito e veja próximo jogo, horário, torneio e status ao vivo.")
        .supportedFamilies(Self.supportedFamilies)
    }

    private static var supportedFamilies: [WidgetFamily] {
        #if os(watchOS)
        [.accessoryCircular, .accessoryRectangular, .accessoryInline]
        #else
        [.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular, .accessoryInline]
        #endif
    }

    private func deepLinkURL(for entry: MatchPointScoreEntry) -> URL? {
        if let playerID = entry.selectedPlayerID, !playerID.isEmpty {
            return URL(string: "matchpoint://players/\(playerID)")
        }
        return URL(string: "matchpoint://matches/\(entry.snapshot?.id ?? "latest")")
    }
}

private struct MatchPointScoreWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: MatchPointScoreEntry

    var body: some View {
        switch family {
        case .accessoryInline:
            accessoryInline
        case .accessoryCircular:
            accessoryCircular
        case .accessoryRectangular:
            accessoryRectangular
        #if os(watchOS)
        case .accessoryCorner:
            accessoryCorner
        #endif
        case .systemSmall:
            small
        case .systemLarge:
            large
        default:
            medium
        }
    }

    private var small: some View {
        WidgetSurface(snapshot: entry.snapshot) {
            if let snapshot = entry.snapshot {
                VStack(alignment: .leading, spacing: 8) {
                    HeaderLine(snapshot: snapshot, compact: true)
                    ScoreRows(snapshot: snapshot, showRanks: false)
                    Spacer(minLength: 0)
                    StatusLine(snapshot: snapshot)
                }
            } else {
                EmptyWidgetState(compact: true, selectedPlayerName: entry.selectedPlayerName)
            }
        }
    }

    private var medium: some View {
        WidgetSurface(snapshot: entry.snapshot) {
            if entry.snapshots.isEmpty {
                EmptyWidgetState(compact: false, selectedPlayerName: entry.selectedPlayerName)
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(entry.snapshots.prefix(2))) { snapshot in
                        MultiMatchWidgetCard(snapshot: snapshot)
                    }
                    if entry.snapshots.count > 2 {
                        HStack(spacing: 5) {
                            Image(systemName: "plus.circle.fill")
                                .font(.caption2)
                            Text("+\(entry.snapshots.count - 2) partidas dos favoritos")
                                .font(.caption2.weight(.bold))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(.white.opacity(0.76))
                    }
                }
            }
        }
    }

    private var large: some View {
        WidgetSurface(snapshot: entry.snapshot) {
            if entry.snapshots.isEmpty {
                EmptyWidgetState(compact: false, selectedPlayerName: entry.selectedPlayerName)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    if let snapshot = entry.snapshot {
                        HeaderLine(snapshot: snapshot, compact: false)
                        HStack(alignment: .top, spacing: 14) {
                            VStack(alignment: .leading, spacing: 10) {
                                ScoreRows(snapshot: snapshot, showRanks: true)
                                SetStrip(snapshot: snapshot)
                            }
                            Spacer(minLength: 0)
                            VStack(alignment: .trailing, spacing: 8) {
                                Text(snapshot.isLive ? "LIVE" : snapshot.isCompletedText ? "FINAL" : "NEXT")
                                    .font(.caption.weight(.heavy))
                                    .foregroundStyle(snapshot.isLive ? Color(red: 1.0, green: 0.32, blue: 0.28) : .white.opacity(0.72))
                                Text(snapshot.isLive ? livePointText(snapshot) : circularTime(snapshot))
                                    .font(.system(size: 32, weight: .heavy, design: .rounded))
                                    .monospacedDigit()
                                    .minimumScaleFactor(0.62)
                                if let court = courtText(snapshot) {
                                    Label(court, systemImage: "sportscourt")
                                        .font(.caption2.weight(.semibold))
                                        .lineLimit(2)
                                        .multilineTextAlignment(.trailing)
                                }
                            }
                        }
                        Divider()
                            .overlay(.white.opacity(0.16))
                        VStack(alignment: .leading, spacing: 8) {
                            Text(accessoryDetail(snapshot))
                                .font(.callout.weight(.bold))
                                .lineLimit(2)
                            ForEach(Array(entry.snapshots.dropFirst().prefix(3))) { snapshot in
                                MultiMatchWidgetCard(snapshot: snapshot)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var accessoryCircular: some View {
        if let snapshot = entry.snapshot {
            VStack(spacing: 2) {
                Text(snapshot.criticalMomentKind ?? (snapshot.isLive ? "LIVE" : "NEXT"))
                    .font(.system(size: 8, weight: .heavy))
                Text(snapshot.isLive ? "\(snapshot.player1SetsWon)-\(snapshot.player2SetsWon)" : circularTime(snapshot))
                    .font(.caption.monospacedDigit().weight(.heavy))
                    .minimumScaleFactor(0.72)
                Image(systemName: snapshotSymbol(snapshot))
                    .font(.caption2)
            }
            .widgetAccentable()
        } else {
            Image(systemName: "tennisball")
        }
    }

    #if os(watchOS)
    @ViewBuilder
    private var accessoryCorner: some View {
        if let snapshot = entry.snapshot {
            Text(snapshot.criticalMomentKind ?? (snapshot.isLive ? "LIVE" : circularTime(snapshot)))
                .widgetCurvesContent()
                .widgetAccentable()
        } else {
            Text("MP")
                .widgetCurvesContent()
        }
    }
    #endif

    @ViewBuilder
    private var accessoryRectangular: some View {
        if let snapshot = entry.snapshot {
            VStack(alignment: .leading, spacing: 3) {
                Text(snapshot.isLive ? "LIVE" : "PRÓXIMO")
                    .font(.caption2.weight(.heavy))
                Text("\(shortName(snapshot.player1Name)) \(snapshot.isLive ? "\(snapshot.player1SetsWon)-\(snapshot.player2SetsWon)" : circularTime(snapshot)) \(shortName(snapshot.player2Name))")
                    .font(.caption.weight(.bold))
                    .lineLimit(1)
                Text(accessoryDetail(snapshot))
                    .font(.caption2)
                    .lineLimit(1)
            }
        } else {
            Text("Match Point sem jogos favoritos")
                .font(.caption.weight(.semibold))
        }
    }

    @ViewBuilder
    private var accessoryInline: some View {
        if let snapshot = entry.snapshot {
            Text(inlineText(snapshot))
        } else {
            Text("Match Point")
        }
    }

    private func accessoryDetail(_ snapshot: MatchWidgetSnapshot) -> String {
        if let criticalMomentHeadline = snapshot.criticalMomentHeadline, !criticalMomentHeadline.isEmpty {
            return criticalMomentHeadline
        }
        if !snapshot.isLive, let matchDate = snapshot.matchDate, matchDate >= .now {
            return [courtText(snapshot), matchDate.formatted(date: .abbreviated, time: .shortened)]
                .compactMap { $0 }
                .joined(separator: " • ")
        }
        if !snapshot.pointScore.isEmpty {
            return snapshot.pointScore.replacingOccurrences(of: "-", with: " - ")
        }
        if !snapshot.tournamentName.isEmpty {
            return snapshot.tournamentName
        }
        if let matchDate = snapshot.matchDate, matchDate >= .now {
            return "Começa \(matchDate.formatted(date: .abbreviated, time: .shortened))"
        }
        return snapshot.status
    }

    private func inlineText(_ snapshot: MatchWidgetSnapshot) -> String {
        let phase = snapshot.criticalMomentKind ?? (snapshot.isLive ? "LIVE" : "NEXT")
        let scoreOrTime = snapshot.isLive ? "\(snapshot.player1SetsWon)-\(snapshot.player2SetsWon)" : circularTime(snapshot)
        let base = "\(phase) \(shortName(snapshot.player1Name)) \(scoreOrTime) \(shortName(snapshot.player2Name))"
        guard let detail = snapshot.criticalMomentHeadline, !detail.isEmpty else {
            return base
        }
        return "\(base) • \(detail)"
    }

    private func courtText(_ snapshot: MatchWidgetSnapshot) -> String? {
        guard let courtName = snapshot.courtName, !courtName.isEmpty else { return nil }
        if let orderOfPlay = snapshot.orderOfPlay {
            return "\(courtName) #\(orderOfPlay)"
        }
        return courtName
    }

    private func snapshotSymbol(_ snapshot: MatchWidgetSnapshot) -> String {
        switch snapshot.criticalMomentKind {
        case "BP": return "bolt.fill"
        case "MP": return "flag.checkered"
        case "SP": return "target"
        case "TB": return "arrow.left.arrow.right.circle.fill"
        default: return snapshot.isLive ? "tennisball.fill" : "calendar"
        }
    }

    private func livePointText(_ snapshot: MatchWidgetSnapshot) -> String {
        if !snapshot.pointScore.isEmpty {
            return snapshot.pointScore.replacingOccurrences(of: "-", with: "–")
        }
        if !snapshot.gameScore.isEmpty {
            return snapshot.gameScore.replacingOccurrences(of: "-", with: "–")
        }
        return "\(snapshot.player1SetsWon)–\(snapshot.player2SetsWon)"
    }

    private func circularTime(_ snapshot: MatchWidgetSnapshot) -> String {
        guard let matchDate = snapshot.matchDate else { return "--" }
        return matchDate.formatted(date: .omitted, time: .shortened)
    }
}

private struct FavoritePlayerWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: MatchPointScoreEntry

    var body: some View {
        switch family {
        case .accessoryInline:
            accessoryInline
        case .accessoryRectangular:
            accessoryRectangular
        case .systemLarge:
            large
        case .systemMedium:
            medium
        default:
            small
        }
    }

    private var small: some View {
        WidgetSurface(snapshot: entry.snapshot) {
            if let snapshot = entry.snapshot {
                VStack(alignment: .leading, spacing: 8) {
                    playerHeader(snapshot)
                    Text(snapshot.isLive ? "AO VIVO" : "PRÓXIMO")
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(snapshot.isLive ? Color(red: 1.0, green: 0.32, blue: 0.28) : .white.opacity(0.76))
                    Text(snapshot.opponentName(for: entry.selectedPlayerID))
                        .font(.headline.weight(.heavy))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(primaryStatus(snapshot))
                        .font(.caption.monospacedDigit().weight(.bold))
                        .lineLimit(1)
                }
            } else {
                FavoritePlayerEmptyState(selectedPlayerName: entry.selectedPlayerName, compact: true)
            }
        }
    }

    private var medium: some View {
        WidgetSurface(snapshot: entry.snapshot) {
            if let snapshot = entry.snapshot {
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        playerHeader(snapshot)
                        Text("vs \(snapshot.opponentName(for: entry.selectedPlayerID))")
                            .font(.title3.weight(.heavy))
                            .lineLimit(1)
                        Text([snapshot.tournamentName, snapshot.roundLabel].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.72))
                            .lineLimit(2)
                        Spacer(minLength: 0)
                        Text(detailLine(snapshot))
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)

                    VStack(alignment: .trailing, spacing: 8) {
                        Text(snapshot.isLive ? "LIVE" : "NEXT")
                            .font(.caption2.weight(.heavy))
                            .foregroundStyle(snapshot.isLive ? Color(red: 1.0, green: 0.32, blue: 0.28) : .white.opacity(0.72))
                        Text(primaryStatus(snapshot))
                            .font(.system(size: 28, weight: .heavy, design: .rounded))
                            .monospacedDigit()
                            .minimumScaleFactor(0.62)
                        if let rank = snapshot.rank(for: entry.selectedPlayerID) {
                            Text("#\(rank)")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white.opacity(0.72))
                        }
                    }
                }
            } else {
                FavoritePlayerEmptyState(selectedPlayerName: entry.selectedPlayerName, compact: false)
            }
        }
    }

    private var large: some View {
        WidgetSurface(snapshot: entry.snapshot) {
            if let snapshot = entry.snapshot {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 8) {
                            playerHeader(snapshot)
                            Text("vs \(snapshot.opponentName(for: entry.selectedPlayerID))")
                                .font(.title2.weight(.heavy))
                                .lineLimit(1)
                            Text([snapshot.tournamentName, snapshot.roundLabel].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.72))
                                .lineLimit(2)
                        }
                        Spacer(minLength: 0)
                        Text(primaryStatus(snapshot))
                            .font(.system(size: 32, weight: .heavy, design: .rounded))
                            .monospacedDigit()
                    }

                    HStack(spacing: 8) {
                        favoritePlayerMetric("Status", snapshot.isLive ? "Ao vivo" : "Próximo", "dot.radiowaves.left.and.right")
                        favoritePlayerMetric("Ranking", snapshot.rank(for: entry.selectedPlayerID).map { "#\($0)" } ?? "N/A", "number")
                    }

                    if let court = courtText(snapshot) {
                        Label(court, systemImage: "sportscourt")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.76))
                            .lineLimit(1)
                    }

                    if !entry.snapshots.dropFirst().isEmpty {
                        Divider()
                            .overlay(.white.opacity(0.16))
                        ForEach(Array(entry.snapshots.dropFirst().prefix(2))) { snapshot in
                            Text("\(snapshot.playerName(for: entry.selectedPlayerID)) vs \(snapshot.opponentName(for: entry.selectedPlayerID)) · \(primaryStatus(snapshot))")
                                .font(.caption.weight(.bold))
                                .lineLimit(1)
                        }
                    }
                }
            } else {
                FavoritePlayerEmptyState(selectedPlayerName: entry.selectedPlayerName, compact: false)
            }
        }
    }

    @ViewBuilder
    private var accessoryRectangular: some View {
        if let snapshot = entry.snapshot {
            VStack(alignment: .leading, spacing: 3) {
                Text(snapshot.playerName(for: entry.selectedPlayerID))
                    .font(.caption2.weight(.heavy))
                Text("\(snapshot.isLive ? "LIVE" : "NEXT") vs \(shortName(snapshot.opponentName(for: entry.selectedPlayerID)))")
                    .font(.caption.weight(.bold))
                    .lineLimit(1)
                Text(primaryStatus(snapshot))
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .lineLimit(1)
            }
        } else {
            Text(FavoritePlayerWidgetCopy.emptyMessage(playerName: entry.selectedPlayerName))
                .font(.caption.weight(.semibold))
        }
    }

    @ViewBuilder
    private var accessoryInline: some View {
        if let snapshot = entry.snapshot {
            Text("\(shortName(snapshot.playerName(for: entry.selectedPlayerID))) \(snapshot.isLive ? "LIVE" : "NEXT") \(primaryStatus(snapshot))")
        } else {
            Text(entry.selectedPlayerName ?? FavoritePlayerWidgetCopy.title)
        }
    }

    private func playerHeader(_ snapshot: MatchWidgetSnapshot) -> some View {
        HStack(spacing: 6) {
            let flag = snapshot.flag(for: entry.selectedPlayerID)
            if !flag.isEmpty {
                Text(flag)
            }
            Text(snapshot.playerName(for: entry.selectedPlayerID))
                .font(.caption.weight(.heavy))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white.opacity(0.88))
    }

    private func favoritePlayerMetric(_ title: String, _ value: String, _ icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption2.weight(.heavy))
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(title.uppercased())
                    .font(.system(size: 8, weight: .heavy))
                    .foregroundStyle(.white.opacity(0.58))
                Text(value)
                    .font(.caption.weight(.heavy))
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func primaryStatus(_ snapshot: MatchWidgetSnapshot) -> String {
        if snapshot.isLive {
            if !snapshot.pointScore.isEmpty {
                return snapshot.pointScore.replacingOccurrences(of: "-", with: "–")
            }
            if !snapshot.gameScore.isEmpty {
                return snapshot.gameScore.replacingOccurrences(of: "-", with: "–")
            }
            return "\(snapshot.player1SetsWon)–\(snapshot.player2SetsWon)"
        }
        guard let matchDate = snapshot.matchDate else { return "--" }
        return matchDate.formatted(date: .omitted, time: .shortened)
    }

    private func detailLine(_ snapshot: MatchWidgetSnapshot) -> String {
        if let headline = snapshot.criticalMomentHeadline, !headline.isEmpty {
            return headline
        }
        return courtText(snapshot) ?? snapshot.status
    }

    private func courtText(_ snapshot: MatchWidgetSnapshot) -> String? {
        guard let courtName = snapshot.courtName, !courtName.isEmpty else { return nil }
        if let orderOfPlay = snapshot.orderOfPlay {
            return "\(courtName) #\(orderOfPlay)"
        }
        return courtName
    }
}

private struct FavoritePlayerEmptyState: View {
    let selectedPlayerName: String?
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 10) {
            Text(FavoritePlayerWidgetCopy.title)
                .font(.headline.weight(.heavy))
            Text(FavoritePlayerWidgetCopy.emptyMessage(playerName: selectedPlayerName))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.78))
                .lineLimit(compact ? 3 : 4)
            Spacer(minLength: 0)
            Text(selectedPlayerName == nil ? "Editar widget para escolher" : "Atualiza quando sincronizar")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white.opacity(0.62))
        }
    }
}

private struct WidgetSurface<Content: View>: View {
    let snapshot: MatchWidgetSnapshot?
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .foregroundStyle(.white)
    }
}

private struct HeaderLine: View {
    let snapshot: MatchWidgetSnapshot
    let compact: Bool

    var body: some View {
        HStack(spacing: 6) {
            if snapshot.isLive {
                Circle()
                    .fill(.red)
                    .frame(width: 6, height: 6)
                Text("LIVE")
                    .font(.caption2.weight(.heavy))
            }
            Text(title)
                .font((compact ? Font.caption2 : Font.caption).weight(.semibold))
                .lineLimit(1)
                .foregroundStyle(.white.opacity(0.86))
            Spacer(minLength: 0)
        }
    }

    private var title: String {
        [snapshot.tournamentName, snapshot.roundLabel]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

private struct ScoreRows: View {
    let snapshot: MatchWidgetSnapshot
    let showRanks: Bool

    var body: some View {
        VStack(spacing: 7) {
            playerRow(
                name: snapshot.player1Name,
                flag: snapshot.player1Flag,
                rank: snapshot.player1Rank,
                sets: snapshot.player1SetsWon,
                isServing: isServer(snapshot.player1Name)
            )
            playerRow(
                name: snapshot.player2Name,
                flag: snapshot.player2Flag,
                rank: snapshot.player2Rank,
                sets: snapshot.player2SetsWon,
                isServing: isServer(snapshot.player2Name)
            )
        }
    }

    private func playerRow(name: String, flag: String, rank: Int?, sets: Int, isServing: Bool) -> some View {
        HStack(spacing: 6) {
            if isServing {
                Circle()
                    .fill(Color(red: 0.83, green: 0.96, blue: 0.30))
                    .frame(width: 5, height: 5)
            }
            if !flag.isEmpty {
                Text(flag)
            }
            Text(shortName(name))
                .font(.callout.weight(.heavy))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            if showRanks, let rank {
                Text("#\(rank)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white.opacity(0.64))
            }
            Spacer(minLength: 0)
            Text("\(sets)")
                .font(.title3.weight(.heavy))
                .monospacedDigit()
        }
    }

    private func isServer(_ name: String) -> Bool {
        guard !snapshot.serverName.isEmpty else { return false }
        return name.localizedCaseInsensitiveContains(snapshot.serverName) || snapshot.serverName.localizedCaseInsensitiveContains(name)
    }
}

private struct SetStrip: View {
    let snapshot: MatchWidgetSnapshot

    var body: some View {
        HStack(spacing: 7) {
            ForEach(Array(snapshot.setScores.prefix(5).enumerated()), id: \.offset) { index, set in
                VStack(spacing: 2) {
                    Text("\(index + 1)")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white.opacity(0.55))
                    Text(set.player1Games)
                        .font(.caption2.weight(.heavy))
                        .monospacedDigit()
                    Text(set.player2Games)
                        .font(.caption2.weight(.heavy))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.85))
                }
                .frame(minWidth: 16)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct MultiMatchWidgetCard: View {
    let snapshot: MatchWidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HeaderLine(snapshot: snapshot, compact: true)

            HStack(alignment: .center, spacing: 8) {
                VStack(spacing: 4) {
                    playerRow(
                        name: snapshot.player1Name,
                        flag: snapshot.player1Flag,
                        rank: snapshot.player1Rank,
                        isServing: isServer(snapshot.player1Name),
                        dimmed: false
                    )
                    playerRow(
                        name: snapshot.player2Name,
                        flag: snapshot.player2Flag,
                        rank: snapshot.player2Rank,
                        isServing: isServer(snapshot.player2Name),
                        dimmed: snapshot.player1SetsWon > snapshot.player2SetsWon
                    )
                }

                Spacer(minLength: 4)

                compactSetGrid

                Text(scoreText)
                    .font(.title3.monospacedDigit().weight(.heavy))
                    .foregroundStyle(.white)
                    .frame(width: 34, alignment: .trailing)
            }
        }
        .padding(10)
        .background {
            SurfacePalette.colors(for: snapshot.surface)
                .overlay(Color.black.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        )
    }

    private func playerRow(name: String, flag: String, rank: Int?, isServing: Bool, dimmed: Bool) -> some View {
        HStack(spacing: 5) {
            if !flag.isEmpty {
                Text(flag)
                    .font(.caption2)
            }
            if let rank {
                Text("\(rank)")
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(.white.opacity(0.62))
            }
            Text(shortName(name))
                .font(.caption.weight(.heavy))
                .lineLimit(1)
                .minimumScaleFactor(0.76)
            if isServing {
                Circle()
                    .fill(Color(red: 0.83, green: 0.96, blue: 0.30))
                    .frame(width: 5, height: 5)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(dimmed ? .white.opacity(0.62) : .white)
    }

    private var compactSetGrid: some View {
        HStack(spacing: 8) {
            ForEach(Array(snapshot.setScores.prefix(4).enumerated()), id: \.offset) { _, set in
                VStack(spacing: 2) {
                    Text(set.player1Games)
                    Text(set.player2Games)
                        .foregroundStyle(.white.opacity(0.72))
                }
                .font(.caption.monospacedDigit().weight(.heavy))
                .frame(minWidth: 13)
            }
        }
    }

    private var scoreText: String {
        if !snapshot.isLive, let matchDate = snapshot.matchDate, matchDate >= .now {
            return matchDate.formatted(date: .omitted, time: .shortened)
        }
        if !snapshot.pointScore.isEmpty {
            return snapshot.pointScore
                .split(separator: "-")
                .last
                .map(String.init) ?? snapshot.pointScore
        }
        if !snapshot.gameScore.isEmpty {
            return snapshot.gameScore
                .split(separator: "-")
                .last
                .map(String.init) ?? snapshot.gameScore
        }
        return "\(snapshot.player1SetsWon)-\(snapshot.player2SetsWon)"
    }

    private func isServer(_ name: String) -> Bool {
        guard !snapshot.serverName.isEmpty else { return false }
        return name.localizedCaseInsensitiveContains(snapshot.serverName) || snapshot.serverName.localizedCaseInsensitiveContains(name)
    }
}

private struct StatusLine: View {
    let snapshot: MatchWidgetSnapshot

    var body: some View {
        HStack(spacing: 6) {
            Text(statusText)
                .font(.caption2.weight(.bold))
                .lineLimit(1)
            Spacer(minLength: 0)
            Text(snapshot.lastUpdated, style: .relative)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.66))
        }
        .foregroundStyle(.white.opacity(0.82))
    }

    private var statusText: String {
        if !snapshot.isLive, let matchDate = snapshot.matchDate, matchDate >= .now {
            return "Começa \(matchDate.formatted(date: .abbreviated, time: .shortened))"
        }
        if !snapshot.pointScore.isEmpty {
            return snapshot.pointScore.replacingOccurrences(of: "-", with: " - ")
        }
        if !snapshot.gameScore.isEmpty {
            return snapshot.gameScore
        }
        return snapshot.status.isEmpty ? "Aguardando atualização" : snapshot.status
    }
}

private struct EmptyWidgetState: View {
    let compact: Bool
    let selectedPlayerName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 10) {
            Text("Match Point")
                .font(.headline.weight(.heavy))
            Text(message)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.78))
                .lineLimit(2)
            Spacer(minLength: 0)
            Text("Abra o app para seguir jogadores")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white.opacity(0.62))
        }
    }

    private var message: String {
        if let selectedPlayerName {
            return "Sem próximo jogo ou jogo ao vivo de \(selectedPlayerName)."
        }
        return "Sem partidas ao vivo dos favoritos."
    }
}

private enum SurfacePalette {
    static func colors(for surface: String) -> LinearGradient {
        let surface = surface.lowercased()
        let colors: [Color]
        if surface.contains("grass") || surface.contains("grama") {
            colors = [Color(red: 0.20, green: 0.52, blue: 0.28), Color(red: 0.04, green: 0.22, blue: 0.13)]
        } else if surface.contains("clay") || surface.contains("saibro") {
            colors = [Color(red: 0.74, green: 0.34, blue: 0.22), Color(red: 0.32, green: 0.10, blue: 0.08)]
        } else if surface.contains("hard") || surface.contains("dura") {
            colors = [Color(red: 0.15, green: 0.42, blue: 0.72), Color(red: 0.04, green: 0.13, blue: 0.33)]
        } else {
            colors = [Color(red: 0.13, green: 0.18, blue: 0.25), Color(red: 0.03, green: 0.06, blue: 0.11)]
        }
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

private extension MatchWidgetSnapshot {
    var isCompletedText: Bool {
        let normalizedStatus = status.lowercased()
        return normalizedStatus.contains("finished")
            || normalizedStatus.contains("final")
            || normalizedStatus.contains("ended")
            || normalizedStatus.contains("completed")
    }

    static let placeholder = MatchWidgetSnapshot(
        id: "preview",
        tournamentName: "Roland Garros",
        roundLabel: "Semifinal",
        surface: "Clay",
        player1Name: "Carlos Alcaraz",
        player2Name: "Jannik Sinner",
        player1ID: "preview-alcaraz",
        player2ID: "preview-sinner",
        player1Flag: "🇪🇸",
        player2Flag: "🇮🇹",
        player1Rank: 2,
        player2Rank: 1,
        player1SetsWon: 1,
        player2SetsWon: 1,
        setScores: [
            .init(player1Games: "6", player2Games: "4"),
            .init(player1Games: "3", player2Games: "6"),
            .init(player1Games: "4", player2Games: "5")
        ],
        pointScore: "30-40",
        gameScore: "4-5",
        serverName: "Carlos Alcaraz",
        status: "Live",
        isLive: true,
        isFavorite: true,
        courtName: "Court Philippe-Chatrier",
        orderOfPlay: 3,
        criticalMomentKind: "BP",
        criticalMomentHeadline: "Break point Sinner",
        matchDate: .now,
        lastUpdated: .now
    )

    static let secondPlaceholder = MatchWidgetSnapshot(
        id: "placeholder-second",
        tournamentName: "Wimbledon",
        roundLabel: "3ª rodada",
        surface: "Grass",
        player1Name: "A. Rinderknech",
        player2Name: "N. Djokovic",
        player1ID: "preview-rinderknech",
        player2ID: "preview-djokovic",
        player1Flag: "🇫🇷",
        player2Flag: "🇷🇸",
        player1Rank: 25,
        player2Rank: 7,
        player1SetsWon: 2,
        player2SetsWon: 1,
        setScores: [
            .init(player1Games: "5", player2Games: "7"),
            .init(player1Games: "4", player2Games: "6"),
            .init(player1Games: "6", player2Games: "1"),
            .init(player1Games: "6", player2Games: "6")
        ],
        pointScore: "2-1",
        gameScore: "",
        serverName: "N. Djokovic",
        status: "Live",
        isLive: true,
        isFavorite: true,
        courtName: "Centre Court",
        orderOfPlay: 4,
        criticalMomentKind: "TB",
        criticalMomentHeadline: "Tie-break em andamento",
        matchDate: .now,
        lastUpdated: .now
    )
}

private extension Array where Element == FavoriteWidgetPlayer {
    func uniquedByID() -> [FavoriteWidgetPlayer] {
        var seen = Set<String>()
        var players: [FavoriteWidgetPlayer] = []
        for player in self where seen.insert(player.id).inserted {
            players.append(player)
        }
        return players
    }
}

private func shortName(_ name: String) -> String {
    let parts = name.split(separator: " ")
    guard parts.count > 1, let last = parts.last else { return name }
    return String(last)
}
