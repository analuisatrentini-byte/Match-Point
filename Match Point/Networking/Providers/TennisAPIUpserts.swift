import Foundation
import OSLog
import SwiftData

extension Player {
    /// Inserts a name-only Player stub. The WebSocket path uses this when frames
    /// arrive before the REST `upsert(from: PlayerDTO)` has populated full
    /// metadata — REST upsert later overwrites nationality/tour by externalKey.
    @MainActor
    static func insertStub(named name: String, in context: ModelContext) -> Player {
        let player = Player(name: name, nationality: "UNK", isWTA: false)
        context.insert(player)
        return player
    }
}

extension Tournament {
    /// Inserts a tournament stub with placeholder city/country/surface. Used by
    /// the live WebSocket path where frames only ship a tournament name.
    @MainActor
    static func insertStub(named name: String, on date: Date, in context: ModelContext) -> Tournament {
        let tournament = Tournament(
            name: name,
            city: "TBD",
            country: "TBD",
            surface: "Unknown",
            tour: .atp,
            startDate: date,
            endDate: date
        )
        context.insert(tournament)
        return tournament
    }

    @MainActor
    static func upsert(from dto: TournamentDTO, in context: ModelContext) -> Tournament {
        let externalKey = dto.id
        let fetch = FetchDescriptor<Tournament>(predicate: #Predicate { $0.externalKey == externalKey })

        if let existing = existingTournament(matching: fetch, in: context, externalKey: externalKey) {
            existing.name = dto.name
            existing.city = dto.city
            existing.country = dto.country
            existing.surface = dto.surface
            existing.tour = Tournament.Tour(rawValue: dto.tour.uppercased()) ?? .atp
            existing.startDate = dto.startDate
            existing.endDate = dto.endDate
            return existing
        }

        let model = Tournament(
            externalKey: dto.id,
            name: dto.name,
            city: dto.city,
            country: dto.country,
            surface: dto.surface,
            tour: Tournament.Tour(rawValue: dto.tour.uppercased()) ?? .atp,
            startDate: dto.startDate,
            endDate: dto.endDate
        )
        context.insert(model)
        return model
    }

    @MainActor
    private static func existingTournament(
        matching descriptor: FetchDescriptor<Tournament>,
        in context: ModelContext,
        externalKey: String
    ) -> Tournament? {
        do {
            let matches = try context.fetch(descriptor)
            if matches.count > 1 {
                AppLogger.persistence.warning("Duplicate tournaments found for externalKey \(externalKey, privacy: .public). Keeping first and deleting extras.")
                matches.dropFirst().forEach(context.delete)
            }
            return matches.first
        } catch {
            AppLogger.persistence.error("Tournament upsert fetch failed for \(externalKey, privacy: .public): \(AppLogger.message(for: error), privacy: .private)")
            AppLogger.recordFailure(category: "persistence", operation: "Tournament.upsert.fetch", error: error)
            return nil
        }
    }
}

extension Player {
    @MainActor
    static func upsert(from dto: PlayerDTO, in context: ModelContext) -> Player {
        let externalKey = dto.id
        let fetch = FetchDescriptor<Player>(predicate: #Predicate { $0.externalKey == externalKey })

        if let existing = existingPlayer(matching: fetch, in: context, externalKey: externalKey) {
            existing.name = dto.name
            existing.nationality = dto.nationality
            existing.isWTA = dto.tour.caseInsensitiveCompare("WTA") == .orderedSame
            existing.birthDate = dto.birthDate
            return existing
        }

        let model = Player(
            externalKey: dto.id,
            name: dto.name,
            nationality: dto.nationality,
            isWTA: dto.tour.caseInsensitiveCompare("WTA") == .orderedSame,
            birthDate: dto.birthDate
        )
        context.insert(model)
        return model
    }

    @MainActor
    private static func existingPlayer(
        matching descriptor: FetchDescriptor<Player>,
        in context: ModelContext,
        externalKey: String
    ) -> Player? {
        do {
            let matches = try context.fetch(descriptor)
            if matches.count > 1 {
                AppLogger.persistence.warning("Duplicate players found for externalKey \(externalKey, privacy: .public). Keeping first and deleting extras.")
                matches.dropFirst().forEach(context.delete)
            }
            return matches.first
        } catch {
            AppLogger.persistence.error("Player upsert fetch failed for \(externalKey, privacy: .public): \(AppLogger.message(for: error), privacy: .private)")
            AppLogger.recordFailure(category: "persistence", operation: "Player.upsert.fetch", error: error)
            return nil
        }
    }
}

extension RankingEntry {
    @MainActor
    static func upsert(from dto: RankingEntryDTO, playersById: [String: Player], in context: ModelContext) -> RankingEntry {
        let externalKey = dto.id
        let fetch = FetchDescriptor<RankingEntry>(predicate: #Predicate { $0.externalKey == externalKey })

        if let existing = existingRankingEntry(matching: fetch, in: context, externalKey: externalKey) {
            existing.player = playersById[dto.playerId]
            existing.rank = dto.rank
            existing.points = dto.points
            existing.tour = RankingEntry.Tour(rawValue: dto.tour.uppercased()) ?? .atp
            return existing
        }

        let model = RankingEntry(
            externalKey: dto.id,
            player: playersById[dto.playerId],
            rank: dto.rank,
            points: dto.points,
            tour: RankingEntry.Tour(rawValue: dto.tour.uppercased()) ?? .atp
        )
        context.insert(model)
        return model
    }

    @MainActor
    private static func existingRankingEntry(
        matching descriptor: FetchDescriptor<RankingEntry>,
        in context: ModelContext,
        externalKey: String
    ) -> RankingEntry? {
        do {
            let matches = try context.fetch(descriptor)
            if matches.count > 1 {
                AppLogger.persistence.warning("Duplicate ranking entries found for externalKey \(externalKey, privacy: .public). Keeping first and deleting extras.")
                matches.dropFirst().forEach(context.delete)
            }
            return matches.first
        } catch {
            AppLogger.persistence.error("Ranking upsert fetch failed for \(externalKey, privacy: .public): \(AppLogger.message(for: error), privacy: .private)")
            AppLogger.recordFailure(category: "persistence", operation: "RankingEntry.upsert.fetch", error: error)
            return nil
        }
    }
}

extension TennisMatch {
    /// Returns an existing live match either by `externalID` or by the
    /// (player1, player2, startOfDay) tuple — same logic the WebSocket path uses
    /// to merge inbound frames into an already-fetched REST row.
    @MainActor
    static func findLive(
        externalID: String?,
        player1: Player,
        player2: Player,
        on date: Date,
        in context: ModelContext
    ) -> TennisMatch? {
        if let externalID, !externalID.isEmpty {
            let descriptor = FetchDescriptor<TennisMatch>(predicate: #Predicate<TennisMatch> { match in
                match.externalID == externalID
            })
            do {
                if let match = try context.fetch(descriptor).first {
                    return match
                }
            } catch {
                AppLogger.persistence.error("Live match fetch by externalID failed: \(AppLogger.message(for: error), privacy: .private)")
                AppLogger.recordFailure(category: "persistence", operation: "TennisMatch.findLive.externalID", error: error)
            }
        }

        do {
            let player1ID = player1.id
            let player2ID = player2.id
            let startOfDay = Calendar.current.startOfDay(for: date)
            let endOfDay = Calendar.current.date(byAdding: .day, value: 1, to: startOfDay) ?? date
            let descriptor = FetchDescriptor<TennisMatch>(predicate: #Predicate<TennisMatch> { match in
                match.date >= startOfDay &&
                match.date < endOfDay &&
                match.player1?.id == player1ID &&
                match.player2?.id == player2ID
            })
            if let match = try context.fetch(descriptor).first {
                return match
            }
        } catch {
            AppLogger.persistence.error("Live match fetch by participants failed: \(AppLogger.message(for: error), privacy: .private)")
            AppLogger.recordFailure(category: "persistence", operation: "TennisMatch.findLive.players", error: error)
        }
        return nil
    }

    /// Inserts a `isLive = true` stub for an incoming WebSocket frame. Fields
    /// (score, status, serverName, etc.) are written by the caller after insert.
    @MainActor
    static func insertLiveStub(
        externalID: String?,
        player1: Player,
        player2: Player,
        on date: Date,
        in context: ModelContext
    ) -> TennisMatch {
        let match = TennisMatch(
            externalID: externalID,
            date: date,
            status: "Live",
            isLive: true,
            lastUpdatedAt: .now,
            serverName: "",
            pointScore: "",
            gameScore: "",
            player1: player1,
            player2: player2
        )
        context.insert(match)
        return match
    }

    @MainActor
    static func upsert(from dto: MatchDTO, playersById: [String: Player], tournamentsById: [String: Tournament], in context: ModelContext) -> TennisMatch {
        let externalID = dto.id
        let fetch = FetchDescriptor<TennisMatch>(predicate: #Predicate { $0.externalID == externalID })

        if let existing = existingMatch(matching: fetch, in: context, externalID: externalID) {
            let previousSnapshot = AlertEventEngine.shared.snapshotForStoredMatch(existing)
            existing.date = dto.date
            existing.tournament = dto.tournamentId.flatMap { tournamentsById[$0] }
            existing.player1 = playersById[dto.player1Id]
            existing.player2 = playersById[dto.player2Id]
            existing.score = dto.score
            existing.status = dto.status
            existing.isLive = dto.isLive
            existing.lastUpdatedAt = .now
            existing.serverName = dto.serverName
            existing.pointScore = dto.pointScore
            existing.gameScore = dto.gameScore
            existing.registerLiveTimelineEvent(pointWinnerName: dto.pointWinnerName)
            existing.registerLiveTimelineEvents(dto.livePoints)
            existing.updateAdvancedStatsSnapshot(dto.advancedStats)
            existing.updateOrderOfPlaySnapshot(dto.orderOfPlay)
            Task {
                await AlertEventEngine.shared.processMatchUpdate(existing, previous: previousSnapshot)
            }
            return existing
        }

        let model = TennisMatch(
            externalID: dto.id,
            date: dto.date,
            status: dto.status,
            isLive: dto.isLive,
            lastUpdatedAt: .now,
            serverName: dto.serverName,
            pointScore: dto.pointScore,
            gameScore: dto.gameScore,
            liveTimelinePayload: "",
            tournament: dto.tournamentId.flatMap { tournamentsById[$0] },
            player1: playersById[dto.player1Id],
            player2: playersById[dto.player2Id],
            score: dto.score
        )
        context.insert(model)
        model.registerLiveTimelineEvent(pointWinnerName: dto.pointWinnerName)
        model.registerLiveTimelineEvents(dto.livePoints)
        model.updateAdvancedStatsSnapshot(dto.advancedStats)
        model.updateOrderOfPlaySnapshot(dto.orderOfPlay)
        Task {
            await AlertEventEngine.shared.processMatchUpdate(model, previous: nil)
        }
        return model
    }

    @MainActor
    private static func existingMatch(
        matching descriptor: FetchDescriptor<TennisMatch>,
        in context: ModelContext,
        externalID: String
    ) -> TennisMatch? {
        do {
            let matches = try context.fetch(descriptor)
            if matches.count > 1 {
                AppLogger.persistence.warning("Duplicate matches found for externalID \(externalID, privacy: .public). Keeping first and deleting extras.")
                matches.dropFirst().forEach(context.delete)
            }
            return matches.first
        } catch {
            AppLogger.persistence.error("Match upsert fetch failed for \(externalID, privacy: .public): \(AppLogger.message(for: error), privacy: .private)")
            AppLogger.recordFailure(category: "persistence", operation: "TennisMatch.upsert.fetch", error: error)
            return nil
        }
    }
}
