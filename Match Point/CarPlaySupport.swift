import Foundation
import OSLog
import SwiftData

#if canImport(CarPlay) && canImport(UIKit)
import CarPlay
import UIKit

private enum CarPlayProductionReadiness {
    static let refreshInterval: TimeInterval = 30
    static let maxRootItems = 8
    static let maxDetailRows = 9

    static func logConnection() {
        AppLogger.product.notice("CarPlay connected. Production release still requires approved CarPlay entitlement, real-device validation, template review, and App Store approval.")
    }
}

@MainActor
final class CarPlaySceneDelegate: NSObject, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?
    private var modelContainer: ModelContainer?
    private var refreshTimer: Timer?
    private var activeSnapshots: [CarPlayMatchSnapshot] = []

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController,
        to window: CPWindow
    ) {
        CarPlayProductionReadiness.logConnection()
        self.interfaceController = interfaceController
        interfaceController.prefersDarkUserInterfaceStyle = true
        do {
            modelContainer = try ModelContainer(
                for: MatchPointModelSchema.schema,
                configurations: [ModelConfiguration(schema: MatchPointModelSchema.schema, isStoredInMemoryOnly: false)]
            )
        } catch {
            AppLogger.persistence.error("CarPlay ModelContainer failed: \(AppLogger.message(for: error), privacy: .private)")
            AppLogger.recordFailure(category: "persistence", operation: "carPlay.modelContainer", error: error)
        }
        refreshRootTemplate(animated: false)
        startRefreshTimer()
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnect interfaceController: CPInterfaceController,
        from window: CPWindow
    ) {
        refreshTimer?.invalidate()
        refreshTimer = nil
        self.interfaceController = nil
        modelContainer = nil
        activeSnapshots = []
    }

    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: CarPlayProductionReadiness.refreshInterval, repeats: true) { [weak self] _ in
            let delegate = self
            Task { @MainActor in
                delegate?.refreshRootTemplate(animated: false)
            }
        }
    }

    private func refreshRootTemplate(animated: Bool) {
        guard let interfaceController else { return }

        activeSnapshots = loadSnapshots()
        let template = makeRootTemplate()
        interfaceController.setRootTemplate(template, animated: animated, completion: nil)
    }

    private func loadSnapshots() -> [CarPlayMatchSnapshot] {
        guard let modelContainer else { return [] }

        let context = ModelContext(modelContainer)
        let matches = fetch(
            FetchDescriptor<TennisMatch>(sortBy: [SortDescriptor(\.date, order: .reverse)]),
            in: context,
            reason: "carPlay.fetchMatches"
        )
        let rankings = fetch(
            FetchDescriptor<RankingEntry>(sortBy: [SortDescriptor(\.rank)]),
            in: context,
            reason: "carPlay.fetchRankings"
        )
        let players = fetch(
            FetchDescriptor<Player>(sortBy: [SortDescriptor(\.name)]),
            in: context,
            reason: "carPlay.fetchPlayers"
        )
        let favoritePlayerIDs = Set(players.filter(\.isFavorite).map(\.id))
        let activeMatches = LiveTrackerBuilder.activeTrackers(matches: matches, favoritePlayerIDs: favoritePlayerIDs, rankings: rankings)

        if activeMatches.isEmpty {
            return LiveTrackerBuilder
                .upcomingFavoriteMatch(matches: matches, favoritePlayerIDs: favoritePlayerIDs)
                .map { [CarPlayMatchSnapshot(match: $0, allMatches: matches, rankings: rankings)] } ?? []
        }

        return activeMatches
            .prefix(CarPlayProductionReadiness.maxRootItems)
            .map { CarPlayMatchSnapshot(match: $0, allMatches: matches, rankings: rankings) }
    }

    private func fetch<T: PersistentModel>(_ descriptor: FetchDescriptor<T>, in context: ModelContext, reason: String) -> [T] {
        do {
            return try context.fetch(descriptor)
        } catch {
            AppLogger.persistence.error("CarPlay fetch failed during \(reason, privacy: .public): \(AppLogger.message(for: error), privacy: .private)")
            AppLogger.recordFailure(category: "persistence", operation: reason, error: error)
            return []
        }
    }

    private func makeRootTemplate() -> CPListTemplate {
        let items: [CPListItem]

        if activeSnapshots.isEmpty {
            items = [
                CPListItem(
                    text: "Nenhum favorito ao vivo",
                    detailText: "Siga jogadores no iPhone para ver placares aqui."
                )
            ]
            items.first?.isEnabled = false
        } else {
            items = activeSnapshots.map(makeMatchItem)
        }

        let sectionTitle = activeSnapshots.contains(where: \.isLive) ? "Ao vivo" : "Próximo favorito"
        let template = CPListTemplate(
            title: "Match Point",
            sections: [CPListSection(items: items, header: sectionTitle, sectionIndexTitle: nil)]
        )

        template.trailingNavigationBarButtons = [
            CPBarButton(title: "Atualizar") { [weak self] _ in
                Task { @MainActor in
                    self?.refreshRootTemplate(animated: false)
                }
            }
        ]

        return template
    }

    private func makeMatchItem(_ snapshot: CarPlayMatchSnapshot) -> CPListItem {
        let item = CPListItem(text: snapshot.title, detailText: snapshot.summary)
        item.accessoryType = .disclosureIndicator
        item.handler = { [weak self] _, completion in
            Task { @MainActor in
                self?.pushDetail(for: snapshot)
                completion()
            }
        }
        return item
    }

    private func pushDetail(for snapshot: CarPlayMatchSnapshot) {
        guard let interfaceController else { return }

        let rows = snapshot.detailRows.prefix(CarPlayProductionReadiness.maxDetailRows).map { row in
            let item = CPListItem(text: row.title, detailText: row.value)
            item.isEnabled = false
            return item
        }

        let template = CPListTemplate(
            title: snapshot.shortTitle,
            sections: [CPListSection(items: rows, header: snapshot.statusLabel, sectionIndexTitle: nil)]
        )
        template.trailingNavigationBarButtons = [
            CPBarButton(title: "Atualizar") { [weak self] _ in
                Task { @MainActor in
                    self?.refreshRootTemplate(animated: false)
                }
            }
        ]

        interfaceController.pushTemplate(template, animated: true, completion: nil)
    }
}

struct CarPlayMatchSnapshot: Identifiable {
    struct DetailRow {
        let title: String
        let value: String
    }

    let id: UUID
    let shortTitle: String
    let title: String
    let summary: String
    let statusLabel: String
    let isLive: Bool
    let detailRows: [DetailRow]

    init(match: TennisMatch, allMatches: [TennisMatch], rankings: [RankingEntry]) {
        let player1Name = match.player1?.name ?? "TBD"
        let player2Name = match.player2?.name ?? "TBD"
        let intelligence = MatchIntelligence(match: match, rankings: rankings, allMatches: allMatches)
        let score = match.score.isEmpty ? "Sem placar" : match.score
        let game = match.gameScore.isEmpty ? "Game não informado" : match.gameScore
        let point = match.pointScore.isEmpty ? "Ponto não informado" : match.pointScore
        let server = match.serverName.isEmpty ? "Saque indefinido" : match.serverName
        let status = match.status.isEmpty ? (match.isLive ? "Ao vivo" : "Agendada") : match.status
        let orderOfPlay = match.orderOfPlaySnapshot
        let court = Self.courtDisplay(for: orderOfPlay)
        let criticalMoment = Self.criticalMoment(for: match, intelligence: intelligence)

        self.id = match.id
        self.shortTitle = "\(Self.lastName(player1Name)) vs \(Self.lastName(player2Name))"
        self.title = "\(player1Name) vs \(player2Name)"
        self.summary = [criticalMoment, score, court ?? game]
            .compactMap { $0 }
            .joined(separator: " • ")
        self.statusLabel = match.isLive ? "AO VIVO" : (match.isCompleted ? "FINAL" : "PRÓXIMA")
        self.isLive = match.isLive
        var rows = [
            DetailRow(title: "Placar", value: score),
            DetailRow(title: "Status", value: status),
            DetailRow(title: "Set/Rodada", value: intelligence.roundLabel),
            DetailRow(title: "Game atual", value: game),
            DetailRow(title: "Ponto", value: point),
            DetailRow(title: "Saque", value: server),
            DetailRow(title: "Break point", value: intelligence.breakPointLabel),
            DetailRow(title: "Torneio", value: match.tournament?.name ?? "Torneio"),
            DetailRow(title: "Atualização", value: match.lastUpdatedAt?.formatted(date: .omitted, time: .standard) ?? "Sem timestamp")
        ]
        if let court {
            rows.insert(DetailRow(title: "Quadra", value: court), at: 3)
        } else if match.isUpcoming || match.isLive {
            rows.insert(DetailRow(title: "Quadra", value: "Quadra ainda não confirmada"), at: 3)
        }
        self.detailRows = rows
    }

    private static func lastName(_ name: String) -> String {
        name.split(separator: " ").last.map(String.init) ?? name
    }

    private static func courtDisplay(for orderOfPlay: MatchOrderOfPlaySnapshot?) -> String? {
        guard let orderOfPlay, orderOfPlay.isUsable else { return nil }
        if let order = orderOfPlay.order {
            return "\(orderOfPlay.courtName) #\(order)"
        }
        return orderOfPlay.courtName
    }

    private static func criticalMoment(for match: TennisMatch, intelligence: MatchIntelligence) -> String? {
        guard match.isLive else { return nil }
        if intelligence.breakPointLabel != "Sem break point" {
            return intelligence.breakPointLabel
        }
        let normalizedStatus = match.status.lowercased()
        if normalizedStatus.contains("match point") || normalizedStatus.contains("matchpoint") {
            return "Match point"
        }
        if normalizedStatus.contains("set point") || normalizedStatus.contains("setpoint") {
            return "Set point"
        }
        if match.isInTiebreak {
            return "Tie-break"
        }
        return nil
    }
}

enum MatchPointModelSchema {
    // Single source of truth for the schema lives in MatchPointSchemaV1.
    // Anyone bumping the schema should update that file + register a stage in
    // MatchPointMigrationPlan, not redefine the model list here.
    static let schema = Schema(versionedSchema: MatchPointSchemaV1.self)
}
#else
enum MatchPointModelSchema {
    static let schema = Schema(versionedSchema: MatchPointSchemaV1.self)
}
#endif
