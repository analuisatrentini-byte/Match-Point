//
//  LiveActivityController.swift
//  Match Point
//
//  Owns the lifecycle of Live Activities for tennis matches.
//  Starts an activity when a match goes live, updates it on each WebSocket frame,
//  and ends it once the match is no longer live.
//

import Foundation
import OSLog
import SwiftData

#if canImport(ActivityKit) && os(iOS)
import ActivityKit

@MainActor
final class LiveActivityController {
    static let shared = LiveActivityController()

    private var activeActivities: [String: Activity<MatchActivityAttributes>] = [:]
    private let maximumTrackedLiveActivities = 1

    private init() {
        reattachExistingActivities()
    }

    private func reattachExistingActivities() {
        guard #available(iOS 16.2, *) else { return }
        for activity in Activity<MatchActivityAttributes>.activities {
            activeActivities[activity.attributes.matchID] = activity
        }
    }

    func handle(match: TennisMatch, rankings: [RankingEntry]) {
        guard #available(iOS 16.2, *) else { return }
        reattachExistingActivities()
        MatchWidgetSnapshotStore.shared.update(match: match, rankings: rankings)
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let key = activityKey(for: match)
        // Build a rank lookup map once so makeAttributes doesn't do two O(N)
        // linear searches over the rankings array per match.
        let rankByPlayerID: [UUID: Int] = Dictionary(
            uniqueKeysWithValues: rankings.compactMap { entry -> (UUID, Int)? in
                guard let id = entry.player?.id else { return nil }
                return (id, entry.rank)
            }
        )

        if match.isLive {
            let attributes = makeAttributes(for: match, key: key, rankByPlayerID: rankByPlayerID)
            let state = makeState(for: match)
            if let existing = activeActivities[key] {
                Task {
                    await existing.update(ActivityContent(state: state, staleDate: nil))
                }
            } else {
                guard activeActivities.count < maximumTrackedLiveActivities else {
                    endActivities(excluding: [key], dismissalPolicy: .immediate)
                    return
                }

                do {
                    let activity = try Activity<MatchActivityAttributes>.request(
                        attributes: attributes,
                        content: ActivityContent(state: state, staleDate: nil),
                        pushType: nil
                    )
                    activeActivities[key] = activity
                    ProductAnalyticsStore.shared.record(
                        ProductAnalyticsEventName.liveActivityStarted,
                        properties: ["matchID": key]
                    )
                } catch {
                    AppLogger.live.error("LiveActivity start failed: \(AppLogger.message(for: error), privacy: .private)")
                }
            }
        } else if let existing = activeActivities[key] {
            let finalState = makeState(for: match)
            Task {
                await existing.end(
                    ActivityContent(state: finalState, staleDate: nil),
                    dismissalPolicy: .after(.now + 60 * 2)
                )
            }
            activeActivities.removeValue(forKey: key)
        }
    }

    func endAll() {
        guard #available(iOS 16.2, *) else { return }
        endActivities(excluding: [], dismissalPolicy: .immediate)
    }

    /// Ends any tracked activity whose key is not present in `liveMatchKeys`.
    /// Called after each REST live-match sync to clear activities for matches
    /// that completed and dropped off the live endpoint while the app was
    /// backgrounded (they never trigger `handle(match:)` since the REST response
    /// no longer includes them).
    func endStaleActivities(keepingKeys liveMatchKeys: Set<String>) {
        guard #available(iOS 16.2, *) else { return }
        let stale = activeActivities.keys.filter { !liveMatchKeys.contains($0) }
        for key in stale {
            if let activity = activeActivities.removeValue(forKey: key) {
                Task {
                    await activity.end(
                        ActivityContent(state: activity.content.state, staleDate: nil),
                        dismissalPolicy: .after(.now + 60 * 2)
                    )
                }
            }
        }
    }

    private func endActivities(
        excluding retainedKeys: Set<String>,
        dismissalPolicy: ActivityUIDismissalPolicy
    ) {
        guard #available(iOS 16.2, *) else { return }
        let activitiesToEnd = activeActivities.filter { key, _ in !retainedKeys.contains(key) }
        for (key, activity) in activitiesToEnd {
            let content = ActivityContent(state: activity.content.state, staleDate: nil)
            Task { await activity.end(content, dismissalPolicy: dismissalPolicy) }
            activeActivities.removeValue(forKey: key)
        }
    }

    private func activityKey(for match: TennisMatch) -> String {
        if let external = match.externalID, !external.isEmpty {
            return external
        }
        return match.id.uuidString
    }

    private func makeAttributes(
        for match: TennisMatch,
        key: String,
        rankByPlayerID: [UUID: Int]
    ) -> MatchActivityAttributes {
        let p1Rank = match.player1.flatMap { rankByPlayerID[$0.id] }
        let p2Rank = match.player2.flatMap { rankByPlayerID[$0.id] }

        let roundLabel: String
        if let tournament = match.tournament {
            roundLabel = MatchRoundResolver.roundLabel(for: match, allMatches: tournament.matches)
        } else {
            roundLabel = ""
        }

        return MatchActivityAttributes(
            matchID: key,
            tournamentName: match.tournament?.name ?? "",
            roundLabel: roundLabel,
            surface: match.tournament?.surface ?? "",
            player1Name: match.player1?.name ?? "Player 1",
            player2Name: match.player2?.name ?? "Player 2",
            player1Rank: p1Rank,
            player2Rank: p2Rank,
            player1Flag: CountryFlag.emoji(for: match.player1?.nationality ?? ""),
            player2Flag: CountryFlag.emoji(for: match.player2?.nationality ?? ""),
            slamTheme: SlamSeason.current(for: .now)?.rawValue ?? ""
        )
    }

    private func makeState(for match: TennisMatch) -> MatchActivityAttributes.MatchState {
        let scoreboard = MatchScoreboardData(score: match.score)

        var p1Sets = 0
        var p2Sets = 0
        var setStates: [MatchActivityAttributes.MatchState.SetScore] = []
        for set in scoreboard.sets {
            let p1 = Int(set.player1Games) ?? 0
            let p2 = Int(set.player2Games) ?? 0
            if p1 > p2 { p1Sets += 1 } else if p2 > p1 { p2Sets += 1 }
            setStates.append(.init(player1Games: set.player1Games, player2Games: set.player2Games))
        }

        let serverIsPlayerOne: Bool?
        if match.serverName.isEmpty {
            serverIsPlayerOne = nil
        } else if let name = match.player1?.name, match.serverName.localizedCaseInsensitiveContains(name) || name.localizedCaseInsensitiveContains(match.serverName) {
            serverIsPlayerOne = true
        } else if let name = match.player2?.name, match.serverName.localizedCaseInsensitiveContains(name) || name.localizedCaseInsensitiveContains(match.serverName) {
            serverIsPlayerOne = false
        } else {
            serverIsPlayerOne = nil
        }

        return MatchActivityAttributes.MatchState(
            player1SetsWon: p1Sets,
            player2SetsWon: p2Sets,
            currentSetIndex: max(0, scoreboard.sets.count - 1),
            setScores: setStates,
            pointScore: match.pointScore,
            gameScore: match.gameScore,
            serverIsPlayerOne: serverIsPlayerOne,
            status: match.status,
            isLive: match.isLive,
            lastUpdated: match.lastUpdatedAt ?? .now
        )
    }
}

#else

@MainActor
final class LiveActivityController {
    static let shared = LiveActivityController()
    private init() {}

    func handle(match: TennisMatch, rankings: [RankingEntry]) {}
    func endAll() {}
    func endStaleActivities(keepingKeys liveMatchKeys: Set<String>) {}
}

#endif
