//
//  MatchWidgetSnapshotStore.swift
//  Match Point
//
//  Writes lightweight match snapshots for fixed WidgetKit widgets.
//

import Foundation
import OSLog
import SwiftData

#if canImport(WidgetKit)
import WidgetKit
#endif

private enum MatchWidgetSharedStorage {
    static let appGroupID = "group.ALTB.Match-Point"
    static let snapshotKey = "match-point.widget.match-snapshots"
    static let playerRankingSnapshotKey = "match-point.widget.player-ranking-snapshots"
    static let widgetKind = "MatchPointScoreWidget"
    static let favoritePlayerWidgetKind = "MatchPointFavoritePlayerWidget"
    static let todayWidgetKind = "MatchPointTodayBriefingWidget"
    static let playerRankingWidgetKind = "MatchPointPlayerRankingWidget"

    static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroupID) ?? .standard
    }
}

nonisolated private struct MatchWidgetSnapshot: Codable, Identifiable {
    nonisolated struct SetScore: Codable {
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

nonisolated private struct PlayerRankingWidgetSnapshot: Codable, Identifiable {
    var id: String
    var playerName: String
    var countryCode: String
    var countryFlag: String
    var rank: Int
    var points: Int
    var tourRaw: String
    var isFavorite: Bool
    var lastUpdated: Date
}

@MainActor
final class MatchWidgetSnapshotStore {
    static let shared = MatchWidgetSnapshotStore()
    private static let topRankingLimitPerTour = 100

    private init() {}

    func update(match: TennisMatch, rankings: [RankingEntry]) {
        var snapshots = loadSnapshots()
        let key = snapshotKey(for: match)
        snapshots.removeAll { $0.id == key }

        if match.isLive || isFavoriteContext(match) {
            snapshots.append(makeSnapshot(for: match, key: key, rankings: rankings))
        }

        saveAndReload(trimmed(snapshots))
    }

    func replaceLiveMatches(_ matches: [TennisMatch], rankings: [RankingEntry]) {
        let liveKeys = Set(matches.map(snapshotKey(for:)))
        var snapshots = loadSnapshots().filter { snapshot in
            !snapshot.isLive || liveKeys.contains(snapshot.id)
        }

        for match in matches {
            let key = snapshotKey(for: match)
            snapshots.removeAll { $0.id == key }
            snapshots.append(makeSnapshot(for: match, key: key, rankings: rankings))
        }

        saveAndReload(trimmed(snapshots))
    }

    func replaceRelevantMatches(_ matches: [TennisMatch], rankings: [RankingEntry]) {
        let relevant = matches.filter { match in
            match.isLive || isFavoriteContext(match)
        }
        let relevantKeys = Set(relevant.map(snapshotKey(for:)))
        var snapshots = loadSnapshots().filter { snapshot in
            snapshot.isLive && !relevantKeys.contains(snapshot.id)
        }

        for match in relevant {
            let key = snapshotKey(for: match)
            snapshots.removeAll { $0.id == key }
            snapshots.append(makeSnapshot(for: match, key: key, rankings: rankings))
        }

        saveAndReload(trimmed(snapshots))
    }

    func replaceTopRankingPlayers(_ rankings: [RankingEntry]) {
        let snapshots = topRankingPlayerSnapshots(from: rankings)
        do {
            let data = try JSONEncoder().encode(snapshots)
            MatchWidgetSharedStorage.defaults.set(data, forKey: MatchWidgetSharedStorage.playerRankingSnapshotKey)
        } catch {
            AppLogger.persistence.error("Player ranking widget snapshot encode failed: \(AppLogger.message(for: error), privacy: .private)")
            AppLogger.recordFailure(category: "widget", operation: "savePlayerRankings.encode", error: error)
            return
        }

        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadTimelines(ofKind: MatchWidgetSharedStorage.playerRankingWidgetKind)
        #endif
    }

    private func isFavoriteContext(_ match: TennisMatch) -> Bool {
        match.isFavorite || match.player1?.isFavorite == true || match.player2?.isFavorite == true || match.tournament?.isFavorite == true
    }

    private func topRankingPlayerSnapshots(from rankings: [RankingEntry]) -> [PlayerRankingWidgetSnapshot] {
        MatchPointTour.allCases.flatMap { tour in
            rankings
                .filter { entry in
                    guard entry.tour == tour, entry.rank > 0, entry.rank <= Self.topRankingLimitPerTour else {
                        return false
                    }
                    return entry.player != nil
                }
                .sorted { lhs, rhs in
                    if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
                    return (lhs.player?.name ?? "") < (rhs.player?.name ?? "")
                }
                .prefix(Self.topRankingLimitPerTour)
                .compactMap { entry in
                    guard let player = entry.player else { return nil }
                    return PlayerRankingWidgetSnapshot(
                        id: "\(tour.rawValue)-\(player.externalKey ?? player.id.uuidString)",
                        playerName: player.name,
                        countryCode: player.nationality,
                        countryFlag: CountryFlag.emoji(for: player.nationality),
                        rank: entry.rank,
                        points: entry.points,
                        tourRaw: tour.rawValue,
                        isFavorite: player.isFavorite,
                        lastUpdated: .now
                    )
                }
        }
    }

    private func makeSnapshot(for match: TennisMatch, key: String, rankings: [RankingEntry]) -> MatchWidgetSnapshot {
        let scoreboard = MatchScoreboardData(score: match.score)
        let hideResultSpoilers = shouldHideResultSpoilers(for: match)
        let setScores = scoreboard.sets.map {
            MatchWidgetSnapshot.SetScore(
                player1Games: hideResultSpoilers ? "-" : $0.player1Games,
                player2Games: hideResultSpoilers ? "-" : $0.player2Games
            )
        }

        let setWins = scoreboard.sets.reduce(into: (player1: 0, player2: 0)) { result, set in
            let p1 = Int(set.player1Games) ?? 0
            let p2 = Int(set.player2Games) ?? 0
            if p1 > p2 {
                result.player1 += 1
            } else if p2 > p1 {
                result.player2 += 1
            }
        }

        let roundLabel: String
        if let tournament = match.tournament {
            roundLabel = MatchRoundResolver.roundLabel(for: match, allMatches: tournament.matches)
        } else {
            roundLabel = ""
        }

        let orderOfPlay = match.orderOfPlaySnapshot
        let criticalMoment = criticalMoment(for: match, rankings: rankings)

        return MatchWidgetSnapshot(
            id: key,
            tournamentName: match.tournament?.name ?? "Match Point",
            roundLabel: roundLabel,
            surface: match.tournament?.surface ?? "",
            player1Name: match.player1?.name ?? "Player 1",
            player2Name: match.player2?.name ?? "Player 2",
            player1ID: match.player1?.id.uuidString,
            player2ID: match.player2?.id.uuidString,
            player1Flag: CountryFlag.emoji(for: match.player1?.nationality ?? ""),
            player2Flag: CountryFlag.emoji(for: match.player2?.nationality ?? ""),
            player1Rank: rank(for: match.player1, in: rankings),
            player2Rank: rank(for: match.player2, in: rankings),
            player1SetsWon: setWins.player1,
            player2SetsWon: setWins.player2,
            setScores: setScores,
            pointScore: match.pointScore,
            gameScore: match.gameScore,
            serverName: match.serverName,
            status: hideResultSpoilers ? "Disponível sem spoilers" : match.status,
            isLive: match.isLive,
            isFavorite: isFavoriteContext(match),
            courtName: orderOfPlay?.courtName,
            orderOfPlay: orderOfPlay?.order,
            criticalMomentKind: criticalMoment?.kind,
            criticalMomentHeadline: criticalMoment?.headline,
            matchDate: match.date,
            lastUpdated: match.lastUpdatedAt ?? .now
        )
    }

    private func criticalMoment(for match: TennisMatch, rankings: [RankingEntry]) -> (kind: String, headline: String)? {
        guard match.isLive else {
            if match.isUpcoming, isFavoriteContext(match) {
                return ("NEXT", "Próximo favorito")
            }
            return nil
        }

        let allMatches = match.tournament?.matches ?? []
        let intelligence = MatchIntelligence(match: match, rankings: rankings, allMatches: allMatches)
        if intelligence.breakPointLabel != "Sem break point" {
            return ("BP", intelligence.breakPointLabel)
        }

        let normalizedStatus = match.status.lowercased()
        if normalizedStatus.contains("match point") || normalizedStatus.contains("matchpoint") {
            return ("MP", "Match point")
        }
        if normalizedStatus.contains("set point") || normalizedStatus.contains("setpoint") {
            return ("SP", "Set point")
        }
        if match.isInTiebreak {
            return ("TB", "Tie-break")
        }
        if match.pointScore.contains("40-40") || match.pointScore.localizedCaseInsensitiveContains("deuce") {
            return ("DEUCE", "Iguais no game")
        }

        return nil
    }

    private func rank(for player: Player?, in rankings: [RankingEntry]) -> Int? {
        guard let player else { return nil }
        return rankings.first(where: { $0.player?.id == player.id })?.rank
    }

    private func shouldHideResultSpoilers(for match: TennisMatch) -> Bool {
        let widgetDefaults = MatchWidgetSharedStorage.defaults
        let showWidgetResultSpoilers = widgetDefaults.object(forKey: "match-point.widgets.show-result-spoilers") == nil
            ? true
            : widgetDefaults.bool(forKey: "match-point.widgets.show-result-spoilers")
        let appSpoilerFreeMode = UserDefaults.standard.data(forKey: "match-point.experience-preferences")
            .flatMap { try? JSONDecoder().decode(ExperiencePreferences.self, from: $0) }?
            .spoilerFreeMode == true
        return match.isCompleted && (!showWidgetResultSpoilers || appSpoilerFreeMode)
    }

    private func snapshotKey(for match: TennisMatch) -> String {
        if let externalID = match.externalID, !externalID.isEmpty {
            return externalID
        }
        return match.id.uuidString
    }

    private func trimmed(_ snapshots: [MatchWidgetSnapshot]) -> [MatchWidgetSnapshot] {
        let cutoff = Date().addingTimeInterval(-60 * 60 * 24)
        let futureCutoff = Date().addingTimeInterval(60 * 60 * 24 * 14)
        return snapshots
            .filter { $0.lastUpdated >= cutoff }
            .filter { snapshot in
                guard let matchDate = snapshot.matchDate else { return true }
                return snapshot.isLive || matchDate <= futureCutoff
            }
            .sorted { lhs, rhs in
                if lhs.isLive != rhs.isLive { return lhs.isLive && !rhs.isLive }
                if lhs.isFavorite != rhs.isFavorite { return lhs.isFavorite && !rhs.isFavorite }
                let lhsDate = lhs.matchDate ?? lhs.lastUpdated
                let rhsDate = rhs.matchDate ?? rhs.lastUpdated
                if lhsDate >= .now, rhsDate >= .now, lhsDate != rhsDate { return lhsDate < rhsDate }
                if lhs.lastUpdated != rhs.lastUpdated { return lhs.lastUpdated > rhs.lastUpdated }
                return lhs.id < rhs.id
            }
            .prefix(8)
            .map { $0 }
    }

    private func loadSnapshots() -> [MatchWidgetSnapshot] {
        guard let data = MatchWidgetSharedStorage.defaults.data(forKey: MatchWidgetSharedStorage.snapshotKey) else {
            return []
        }
        do {
            return try JSONDecoder().decode([MatchWidgetSnapshot].self, from: data)
        } catch {
            AppLogger.persistence.error("Widget snapshot decode failed: \(AppLogger.message(for: error), privacy: .private)")
            AppLogger.recordFailure(category: "widget", operation: "loadSnapshots.decode", error: error)
            return []
        }
    }

    private func saveAndReload(_ snapshots: [MatchWidgetSnapshot]) {
        do {
            let data = try JSONEncoder().encode(snapshots)
            MatchWidgetSharedStorage.defaults.set(data, forKey: MatchWidgetSharedStorage.snapshotKey)
        } catch {
            AppLogger.persistence.error("Widget snapshot encode failed: \(AppLogger.message(for: error), privacy: .private)")
            AppLogger.recordFailure(category: "widget", operation: "saveAndReload.encode", error: error)
            // Do not reload the widget timeline if encoding failed — reloading
            // with stale shared storage causes the widget to display outdated
            // data without knowing it's invalid. The next successful save will
            // trigger a reload automatically.
            return
        }

        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadTimelines(ofKind: MatchWidgetSharedStorage.widgetKind)
        WidgetCenter.shared.reloadTimelines(ofKind: MatchWidgetSharedStorage.favoritePlayerWidgetKind)
        WidgetCenter.shared.reloadTimelines(ofKind: MatchWidgetSharedStorage.todayWidgetKind)
        #endif
    }
}
