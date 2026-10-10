//
//  DataSyncService.swift
//  Match Point
//
//  Created by Ana Luisa Bittencourt on 26/03/26.
//

import Foundation
import OSLog
import SwiftData

enum DataSyncError: LocalizedError {
    case emptyResponse(String)
    case configuration(String)
    case rateLimited(String)
    case provider(String)

    var errorDescription: String? {
        switch self {
        case .emptyResponse(let context):
            return "A API respondeu sem dados para \(context)."
        case .configuration(let message), .rateLimited(let message), .provider(let message):
            return message
        }
    }
}

struct UserFacingSyncFeedback: Equatable {
    enum Kind {
        case configuration
        case rateLimited
        case empty
        case generic
    }

    let kind: Kind
    let title: String
    let message: String
    let recoverySuggestion: String
}

/// Self-describing errors that already know how to render themselves for the
/// user-facing sync feedback banner. Each concrete error type in the codebase
/// conforms to this so the central `DataSyncService.userFacingFeedback(for:)`
/// no longer has to rely on regex'ing `localizedDescription` to classify
/// faults — the type itself answers the question.
protocol UserPresentableError: Error {
    var userFacing: UserFacingSyncFeedback { get }
}

extension DataSyncError: UserPresentableError {
    var userFacing: UserFacingSyncFeedback {
        switch self {
        case .configuration(let message):
            return UserFacingSyncFeedback(
                kind: .configuration,
                title: "Sincronização indisponível",
                message: message,
                recoverySuggestion: "Tente novamente em instantes."
            )
        case .rateLimited(let message):
            return UserFacingSyncFeedback(
                kind: .rateLimited,
                title: "Muitas tentativas",
                message: message,
                recoverySuggestion: "Aguarde alguns minutos antes de tentar novamente."
            )
        case .emptyResponse(let context):
            return UserFacingSyncFeedback(
                kind: .empty,
                title: "Resposta vazia",
                message: "A API respondeu sem dados para \(context).",
                recoverySuggestion: "Confirme se o endpoint escolhido cobre esse dataset e se há dados disponíveis no momento."
            )
        case .provider(let message):
            return UserFacingSyncFeedback(
                kind: .generic,
                title: "Falha de sincronização",
                message: message,
                recoverySuggestion: "Tente novamente em instantes."
            )
        }
    }
}

struct ProductionDataHealthReport: Equatable {
    let tournamentsCount: Int
    let rankingsCount: Int
    let matchesCount: Int
    let liveMatchesCount: Int
    let pointTelemetryCount: Int
    let generatedAt: Date

    var hasRealData: Bool {
        tournamentsCount > 0 || rankingsCount > 0 || matchesCount > 0 || liveMatchesCount > 0
    }

    var hasPointByPointTelemetry: Bool {
        pointTelemetryCount > 0
    }

    var summary: String {
        [
            "\(tournamentsCount) torneios",
            "\(rankingsCount) rankings",
            "\(matchesCount) jogos",
            "\(liveMatchesCount) live",
            "\(pointTelemetryCount) com ponto a ponto"
        ].joined(separator: " • ")
    }
}

@MainActor
final class DataSyncService {
    private let api: any TennisAPIProviding
    private let context: ModelContext
    private let services: AppServices

    init(
        context: ModelContext,
        baseURL: URL? = nil,
        api: (any TennisAPIProviding)? = nil,
        services: AppServices? = nil
    ) {
        self.context = context
        self.api = api ?? TennisAPI(baseURL: baseURL)
        // `.live` is @MainActor-isolated; resolving the default inside the
        // body (which is @MainActor through the enclosing class) sidesteps
        // the isolation warning that a parameter default would trigger.
        self.services = services ?? .live
    }

    func syncTournaments(allowFallback: Bool = true) async throws {
        let dtos: [TournamentDTO]
        do {
            dtos = try await api.tournaments()
        } catch {
            guard allowFallback else { throw error }
            try await syncTournamentFallback(originalError: error)
            return
        }
        if dtos.isEmpty {
            guard allowFallback else { throw DataSyncError.emptyResponse("torneios") }
            try await syncTournamentFallback(originalError: DataSyncError.emptyResponse("torneios"))
            return
        }
        let mainCircuitTournaments = dtos.filter { dto in
            Tournament.isMainCircuitEventName(dto.name, tour: dto.tour)
        }
        guard !mainCircuitTournaments.isEmpty else {
            guard allowFallback else { throw DataSyncError.emptyResponse("torneios do circuito principal") }
            try await syncTournamentFallback(originalError: DataSyncError.emptyResponse("torneios do circuito principal"))
            return
        }
        try validate(mainCircuitTournaments, context: "torneios")
        for dto in mainCircuitTournaments {
            _ = Tournament.upsert(from: dto, in: context)
        }
        saveContext("syncTournaments")
    }

    func syncPlayersAndRankings(tour: String? = nil) async throws {
        if tour == nil {
            var failures: [Error] = []
            var successCount = 0
            for requestedTour in ["ATP", "WTA"] {
                do {
                    try await syncPlayersAndRankings(tour: requestedTour)
                    successCount += 1
                } catch {
                    failures.append(error)
                }
            }
            if successCount == 0 {
                throw failures.first ?? DataSyncError.emptyResponse("rankings")
            }
            return
        }

        var players: [PlayerDTO]
        do {
            players = try await api.players(tour: tour)
        } catch {
            try await syncPlayerFallback(originalError: error)
            return
        }
        if players.isEmpty {
            try await syncPlayerFallback(originalError: DataSyncError.emptyResponse("jogadores"))
            return
        }
        // Sanity cap: a real ranking list never exceeds a few thousand entries.
        // Without this, a misbehaving API returning tens of thousands of records
        // would cause an unbounded allocation loop on low-memory devices.
        let playerSanityLimit = 5_000
        if players.count > playerSanityLimit {
            AppLogger.api.warning("Player sync received \(players.count, privacy: .public) records; truncating to \(playerSanityLimit, privacy: .public)")
            players = Array(players.prefix(playerSanityLimit))
        }
        try validate(players, context: "jogadores")
        var playersById: [String: Player] = [:]
        let favoriteSnapshot = favoritePlayerIdentitySnapshot()
        for p in players {
            let model = Player.upsert(from: p, in: context)
            if isFavoritePlayer(p, in: favoriteSnapshot) {
                model.isFavorite = true
            }
            playersById[p.id] = model
        }
        if let rankings = await optionalAPICall("rankings \(tour ?? "default")", operation: { try await api.rankings(tour: tour) }), !rankings.isEmpty {
            for r in rankings {
                _ = RankingEntry.upsert(from: r, playersById: playersById, in: context)
            }
            let storedRankings = fetch(FetchDescriptor<RankingEntry>(), context: "widget ranking snapshots")
            services.widgetSnapshots.replaceTopRankingPlayers(storedRankings)
        }
        saveContext("syncPlayersAndRankings")
    }

    func syncFixtures(
        from startDate: Date = Date(),
        to endDate: Date = Date().addingTimeInterval(7 * 24 * 60 * 60),
        tournamentKey: String? = nil
    ) async throws {
        var relations = loadLocalRelationMaps()
        let fixtures = try await api.fixtures(from: startDate, to: endDate, tournamentKey: tournamentKey)
        _ = upsert(matches: fixtures, relations: &relations)
        saveContext("syncFixtures")
    }

    func headToHead(firstPlayerKey: String, secondPlayerKey: String) async throws -> [H2HMatchDTO] {
        try await api.headToHead(firstPlayerKey: firstPlayerKey, secondPlayerKey: secondPlayerKey)
    }

    func playerProfile(playerKey: String, tour: String? = nil) async throws -> PlayerProfileDTO? {
        try await api.playerProfile(playerKey: playerKey, tour: tour)
    }

    func odds(matchKey: String) async throws -> [OddsDTO] {
        try await api.odds(matchKey: matchKey)
    }

    func liveOdds(matchKey: String? = nil) async throws -> [LiveOddsDTO] {
        try await api.liveOdds(matchKey: matchKey)
    }

    func validateProductionDataFeed() async throws -> ProductionDataHealthReport {
        let tournaments = try await api.tournaments()
        let rankings = try await api.rankings(tour: nil)
        let fixtures = await optionalAPICall("production fixtures", operation: { try await api.fixtures(
            from: Date().addingTimeInterval(-24 * 60 * 60),
            to: Date().addingTimeInterval(7 * 24 * 60 * 60),
            tournamentKey: nil
        )}) ?? []
        let liveMatches = await optionalAPICall("production live matches", operation: { try await api.liveMatches() }) ?? []
        let allMatches = fixtures + liveMatches
        let pointTelemetryCount = allMatches.filter { match in
            !match.pointScore.isEmpty || match.pointWinnerName != nil || !match.livePoints.isEmpty
        }.count

        let report = ProductionDataHealthReport(
            tournamentsCount: tournaments.count,
            rankingsCount: rankings.count,
            matchesCount: allMatches.count,
            liveMatchesCount: liveMatches.count,
            pointTelemetryCount: pointTelemetryCount,
            generatedAt: .now
        )

        guard report.hasRealData else {
            throw DataSyncError.emptyResponse("health check de produção")
        }

        return report
    }

    func eventTypes() async throws -> [EventTypeDTO] {
        try await api.eventTypes()
    }

    func syncLiveMatches() async throws {
        let matches = try await api.liveMatches()
        try await syncLiveMatches(using: matches)
    }

    func syncLiveMatches(using matches: [MatchDTO]) async throws {
        // Skipping the upfront full-table scan of Players + Tournaments:
        // ensureRelations upserts lazily per key (indexed), building the map
        // as it goes. For live syncs (10–50 matches) this saves two O(N) fetches
        // with no correctness trade-off.
        var relations = RelationMaps(playersById: [:], tournamentsById: [:])
        let upsertedMatches = upsert(matches: matches, relations: &relations)

        let rankings = fetch(FetchDescriptor<RankingEntry>(), context: "live rankings")
        services.widgetSnapshots.replaceLiveMatches(upsertedMatches, rankings: rankings)
        let liveKeys = Set(upsertedMatches.map { $0.externalID ?? $0.id.uuidString })
        services.liveActivity.endStaleActivities(keepingKeys: liveKeys)
        for match in upsertedMatches {
            services.liveActivity.handle(match: match, rankings: rankings)
        }

        saveContext("syncLiveMatches")
    }

    func syncMatches(
        from startDate: Date = Date().addingTimeInterval(-24 * 60 * 60),
        to endDate: Date = Date().addingTimeInterval(7 * 24 * 60 * 60)
    ) async throws {
        var relations = loadLocalRelationMaps()
        var upsertedMatches: [TennisMatch] = []
        var capturedErrors: [Error] = []

        do {
            let fixtures = try await api.fixtures(from: startDate, to: endDate, tournamentKey: nil)
            upsertedMatches.append(contentsOf: upsert(matches: prioritizedFixtures(fixtures), relations: &relations))
        } catch {
            capturedErrors.append(error)
        }

        do {
            let liveMatches = try await api.liveMatches()
            upsertedMatches.append(contentsOf: upsert(matches: liveMatches, relations: &relations))
        } catch {
            capturedErrors.append(error)
        }

        let uniqueMatches = Array(Dictionary(grouping: upsertedMatches, by: \.id).compactMap { $0.value.first })
        guard !uniqueMatches.isEmpty else {
            if capturedErrors.count >= 2 {
                // Both fixtures and live endpoints failed — log all errors so the
                // second failure (often more informative) isn't silently dropped,
                // then throw the first to propagate a single error to the caller.
                for (i, err) in capturedErrors.enumerated() {
                    AppLogger.sync.error("syncMatches error[\(i, privacy: .public)]: \(AppLogger.message(for: err), privacy: .private)")
                }
                throw capturedErrors[0]
            } else if let singleError = capturedErrors.first {
                throw singleError
            }
            saveContext("syncMatches-empty")
            await services.alerts.refreshScheduledNotifications(in: context)
            return
        }

        let rankings = fetch(FetchDescriptor<RankingEntry>(), context: "syncMatches rankings")
        let liveMatches = uniqueMatches.filter(\.isLive)
        services.widgetSnapshots.replaceRelevantMatches(uniqueMatches, rankings: rankings)
        for match in liveMatches {
            services.liveActivity.handle(match: match, rankings: rankings)
        }
        saveContext("syncMatches")
        await services.alerts.refreshScheduledNotifications(in: context)
    }

    private struct RelationMaps {
        var playersById: [String: Player]
        var tournamentsById: [String: Tournament]
    }

    private struct SyncPriorityScope {
        var playerKeys: Set<String>
        var playerNames: Set<String>
    }

    private func prioritizedFixtures(_ matches: [MatchDTO]) -> [MatchDTO] {
        let scope = syncPriorityScope()
        guard !scope.playerKeys.isEmpty || !scope.playerNames.isEmpty else {
            return matches.filter { isPremiumTournament($0.tournamentName) }
        }

        return matches.filter { match in
            isPriorityMatch(match, scope: scope) || isPremiumTournament(match.tournamentName)
        }
    }

    private func syncPriorityScope() -> SyncPriorityScope {
        let players = fetch(FetchDescriptor<Player>(), context: "sync priority players")
        let rankings = fetch(FetchDescriptor<RankingEntry>(), context: "sync priority rankings")

        var playerKeys = Set<String>()
        var playerNames = Set<String>()

        for player in players where player.isFavorite {
            if let key = player.externalKey, !key.isEmpty {
                playerKeys.insert(key)
            }
            playerNames.insert(normalizedPlayerName(player.name))
        }

        for ranking in rankings where ranking.rank > 0 && ranking.rank <= 100 {
            guard let player = ranking.player else { continue }
            if let key = player.externalKey, !key.isEmpty {
                playerKeys.insert(key)
            }
            playerNames.insert(normalizedPlayerName(player.name))
        }

        return SyncPriorityScope(playerKeys: playerKeys, playerNames: playerNames)
    }

    private func isPriorityMatch(_ match: MatchDTO, scope: SyncPriorityScope) -> Bool {
        scope.playerKeys.contains(match.player1Id) ||
        scope.playerKeys.contains(match.player2Id) ||
        scope.playerNames.contains(normalizedPlayerName(match.player1Name)) ||
        scope.playerNames.contains(normalizedPlayerName(match.player2Name))
    }

    private func isPremiumTournament(_ name: String?) -> Bool {
        let normalized = normalizedTournamentNameForMatching(name)
        guard !normalized.isEmpty else { return false }

        let premiumTerms = [
            "grand slam",
            "australian open",
            "roland garros",
            "french open",
            "wimbledon",
            "us open",
            "masters 1000",
            "atp 1000",
            "wta 1000",
            "atp 500",
            "wta 500",
            "atp 250",
            "wta 250"
        ]
        return premiumTerms.contains { normalized.contains($0) }
    }

    private func normalizedTournamentNameForMatching(_ value: String?) -> String {
        (value ?? "")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func loadLocalRelationMaps() -> RelationMaps {
        let players = fetch(FetchDescriptor<Player>(), context: "relation players")
        let tournaments = fetch(FetchDescriptor<Tournament>(), context: "relation tournaments")
        let playersById = Dictionary(uniqueKeysWithValues: players.compactMap { player -> (String, Player)? in
            guard let key = player.externalKey, !key.isEmpty else { return nil }
            return (key, player)
        })
        let tournamentsById = Dictionary(uniqueKeysWithValues: tournaments.compactMap { tournament -> (String, Tournament)? in
            guard let key = tournament.externalKey, !key.isEmpty else { return nil }
            return (key, tournament)
        })

        return RelationMaps(playersById: playersById, tournamentsById: tournamentsById)
    }

    private func upsert(matches: [MatchDTO], relations: inout RelationMaps) -> [TennisMatch] {
        matches.map { match in
            ensureRelations(for: match, relations: &relations)
            return TennisMatch.upsert(
                from: match,
                playersById: relations.playersById,
                tournamentsById: relations.tournamentsById,
                in: context
            )
        }
    }

    private func fallbackMatches() async throws -> [MatchDTO] {
        var matches: [MatchDTO] = []
        var lastError: Error?

        do {
            matches.append(contentsOf: try await api.fixtures(
                from: Date().addingTimeInterval(-24 * 60 * 60),
                to: Date().addingTimeInterval(7 * 24 * 60 * 60),
                tournamentKey: nil
            ))
        } catch {
            lastError = error
        }

        do {
            matches.append(contentsOf: try await api.liveMatches())
        } catch {
            lastError = error
        }

        if matches.isEmpty, let lastError {
            throw lastError
        }
        return matches
    }

    private func syncTournamentFallback(originalError: Error) async throws {
        ProviderHealthTracker.shared.recordFallback(
            scope: .tournaments,
            reason: "Torneios via fallback (matches): \(ProviderHealthTracker.shortMessage(for: originalError))"
        )
        var relations = loadLocalRelationMaps()
        let fallbackMatches = try await fallbackMatches()
        _ = upsert(matches: fallbackMatches, relations: &relations)
        saveContext("syncTournamentFallback")
        if relations.tournamentsById.isEmpty {
            throw originalError
        }
    }

    private func syncPlayerFallback(originalError: Error) async throws {
        ProviderHealthTracker.shared.recordFallback(
            scope: .players,
            reason: "Players via fallback (matches): \(ProviderHealthTracker.shortMessage(for: originalError))"
        )
        var relations = loadLocalRelationMaps()
        let fallbackMatches = try await fallbackMatches()
        _ = upsert(matches: fallbackMatches, relations: &relations)
        saveContext("syncPlayerFallback")
        if relations.playersById.isEmpty {
            throw originalError
        }
    }

    private func ensureRelations(for match: MatchDTO, relations: inout RelationMaps) {
        if relations.playersById[match.player1Id] == nil {
            relations.playersById[match.player1Id] = Player.upsert(
                from: PlayerDTO(
                    id: match.player1Id,
                    name: match.player1Name,
                    nationality: match.player1Country,
                    tour: "ATP",
                    birthDate: nil
                ),
                in: context
            )
        }

        if relations.playersById[match.player2Id] == nil {
            relations.playersById[match.player2Id] = Player.upsert(
                from: PlayerDTO(
                    id: match.player2Id,
                    name: match.player2Name,
                    nationality: match.player2Country,
                    tour: "ATP",
                    birthDate: nil
                ),
                in: context
            )
        }

        guard let tournamentId = match.tournamentId, relations.tournamentsById[tournamentId] == nil else {
            return
        }

        relations.tournamentsById[tournamentId] = Tournament.upsert(
            from: TournamentDTO(
                id: tournamentId,
                name: normalizedTournamentName(match.tournamentName, fallbackId: tournamentId),
                city: "TBD",
                country: "TBD",
                surface: "Unknown",
                tour: "ATP",
                startDate: match.date,
                endDate: match.date.addingTimeInterval(7 * 24 * 60 * 60)
            ),
            in: context
        )
    }

    private func normalizedTournamentName(_ value: String?, fallbackId: String) -> String {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Torneio \(fallbackId)" : trimmed
    }

    private struct FavoritePlayerIdentitySnapshot {
        var externalKeys: Set<String>
        var normalizedNames: Set<String>
    }

    private func favoritePlayerIdentitySnapshot() -> FavoritePlayerIdentitySnapshot {
        let favoritePlayers = fetch(
            FetchDescriptor<Player>(predicate: #Predicate { $0.isFavorite }),
            context: "favorite players"
        )

        return FavoritePlayerIdentitySnapshot(
            externalKeys: Set(favoritePlayers.compactMap(\.externalKey)),
            normalizedNames: Set(favoritePlayers.map { normalizedPlayerName($0.name) }.filter { !$0.isEmpty })
        )
    }

    private func isFavoritePlayer(_ dto: PlayerDTO, in snapshot: FavoritePlayerIdentitySnapshot) -> Bool {
        snapshot.externalKeys.contains(dto.id) || snapshot.normalizedNames.contains(normalizedPlayerName(dto.name))
    }

    private func normalizedPlayerName(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func userFacingMessage(for error: Error) -> String {
        userFacingFeedback(for: error).message
    }

    func userFacingFeedback(for error: Error) -> UserFacingSyncFeedback {
        // Self-describing errors win — every typed error in the codebase now
        // owns its presentation copy via `UserPresentableError`. Fallthrough
        // heuristics below cover untyped errors (URLSession.NSError, decode
        // errors) that don't conform.
        if let presentable = error as? UserPresentableError {
            return presentable.userFacing
        }

        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let normalized = message.lowercased()

        if normalized.contains("backend proxy") || normalized.contains("missing api") || normalized.contains("missing rapidapi key") || normalized.contains("api key") {
            return UserFacingSyncFeedback(
                kind: .configuration,
                title: "Sincronização indisponível",
                message: "O serviço de dados do Match Point não está disponível no momento.",
                recoverySuggestion: Self.configurationRecoverySuggestion
            )
        }
        if normalized.contains("429") || normalized.contains("rate limit") || normalized.contains("quota") || normalized.contains("plan") {
            return UserFacingSyncFeedback(
                kind: .rateLimited,
                title: "Muitas tentativas",
                message: "O serviço recebeu muitas tentativas em pouco tempo.",
                recoverySuggestion: "Aguarde alguns minutos antes de tentar novamente."
            )
        }
        if normalized.contains("empty") || normalized.contains("sem dados") {
            return UserFacingSyncFeedback(
                kind: .empty,
                title: "Sem dados utilizáveis",
                message: "A API respondeu, mas sem dados utilizáveis para esta tela.",
                recoverySuggestion: "Tente sincronizar novamente mais tarde."
            )
        }

        return UserFacingSyncFeedback(
            kind: .generic,
            title: "Sync indisponível",
            message: "Não foi possível sincronizar agora. \(message)",
            recoverySuggestion: "Tente novamente em instantes."
        )
    }

    private func validate<T>(_ values: [T], context: String) throws {
        if values.isEmpty {
            throw DataSyncError.emptyResponse(context)
        }
    }

    private func saveContext(_ reason: String) {
        do {
            try context.save()
        } catch {
            AppLogger.persistence.error("SwiftData save failed during \(reason, privacy: .public): \(AppLogger.message(for: error), privacy: .private)")
            AppLogger.recordFailure(category: "persistence", operation: reason, error: error)
        }
    }

    private func fetch<T: PersistentModel>(_ descriptor: FetchDescriptor<T>, context reason: String) -> [T] {
        do {
            return try context.fetch(descriptor)
        } catch {
            AppLogger.persistence.error("SwiftData fetch failed during \(reason, privacy: .public): \(AppLogger.message(for: error), privacy: .private)")
            AppLogger.recordFailure(category: "persistence", operation: reason, error: error)
            return []
        }
    }

    private func optionalAPICall<T>(_ reason: String, operation: () async throws -> T) async -> T? {
        do {
            return try await operation()
        } catch {
            AppLogger.sync.error("Optional API call failed during \(reason, privacy: .public): \(AppLogger.message(for: error), privacy: .private)")
            AppLogger.recordFailure(category: "sync", operation: reason, error: error)
            return nil
        }
    }

    private static var configurationRecoverySuggestion: String {
        "Tente novamente em instantes."
    }
}
