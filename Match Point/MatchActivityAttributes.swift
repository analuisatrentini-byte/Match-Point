//
//  MatchActivityAttributes.swift
//  Match Point
//
//  Shared between the main app and the MatchPointLiveActivity widget extension.
//  The widget extension must include this file in its target membership.
//

import Foundation

#if canImport(ActivityKit) && os(iOS)
import ActivityKit

@available(iOS 16.2, *)
struct MatchActivityAttributes: ActivityAttributes {
    public typealias ContentState = MatchState

    public struct MatchState: Codable, Hashable {
        public var player1SetsWon: Int
        public var player2SetsWon: Int
        public var currentSetIndex: Int
        public var setScores: [SetScore]
        public var pointScore: String
        public var gameScore: String
        public var serverIsPlayerOne: Bool?
        public var status: String
        public var isLive: Bool
        public var lastUpdated: Date

        public struct SetScore: Codable, Hashable {
            public var player1Games: String
            public var player2Games: String

            public init(player1Games: String, player2Games: String) {
                self.player1Games = player1Games
                self.player2Games = player2Games
            }
        }

        public init(
            player1SetsWon: Int,
            player2SetsWon: Int,
            currentSetIndex: Int,
            setScores: [SetScore],
            pointScore: String,
            gameScore: String,
            serverIsPlayerOne: Bool?,
            status: String,
            isLive: Bool,
            lastUpdated: Date
        ) {
            self.player1SetsWon = player1SetsWon
            self.player2SetsWon = player2SetsWon
            self.currentSetIndex = currentSetIndex
            self.setScores = setScores
            self.pointScore = pointScore
            self.gameScore = gameScore
            self.serverIsPlayerOne = serverIsPlayerOne
            self.status = status
            self.isLive = isLive
            self.lastUpdated = lastUpdated
        }
    }

    public var matchID: String
    public var tournamentName: String
    public var roundLabel: String
    public var surface: String
    public var player1Name: String
    public var player2Name: String
    public var player1Rank: Int?
        public var player2Rank: Int?
        public var player1Flag: String
        public var player2Flag: String
        public var slamTheme: String?

        public init(
            matchID: String,
            tournamentName: String,
            roundLabel: String,
        surface: String,
        player1Name: String,
            player2Name: String,
            player1Rank: Int?,
            player2Rank: Int?,
            player1Flag: String = "",
            player2Flag: String = "",
            slamTheme: String? = nil
        ) {
            self.matchID = matchID
            self.tournamentName = tournamentName
            self.roundLabel = roundLabel
        self.surface = surface
        self.player1Name = player1Name
        self.player2Name = player2Name
        self.player1Rank = player1Rank
            self.player2Rank = player2Rank
            self.player1Flag = player1Flag
            self.player2Flag = player2Flag
            self.slamTheme = slamTheme
        }
    }

#endif
