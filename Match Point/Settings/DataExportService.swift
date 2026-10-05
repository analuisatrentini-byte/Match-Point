//
//  DataExportService.swift
//  Match Point
//
//  Produces a JSON snapshot of everything the user owns so they can exercise
//  LGPD Art. 18 (data portability). Read-only; nothing is mutated.
//

import Foundation
import SwiftData

@MainActor
enum DataExportService {
    static let schemaVersion = 1

    static func makeExport(from context: ModelContext) throws -> Data {
        let payload = ExportPayload(
            schemaVersion: schemaVersion,
            exportedAt: .now,
            profile: try fetchProfile(in: context),
            favoritePlayers: try fetchFavoritePlayers(in: context),
            favoriteTournaments: try fetchFavoriteTournaments(in: context),
            favoriteMatches: try fetchFavoriteMatches(in: context),
            bets: try fetchBets(in: context),
            socialPosts: try fetchSocialPosts(in: context),
            polls: try fetchPolls(in: context)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(payload)
    }

    static func makeExportFileURL(data: Data) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        let filename = "match-point-export-\(formatter.string(from: .now)).json"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try data.write(to: url, options: .atomic)
        return url
    }

    private static func fetchProfile(in context: ModelContext) throws -> ExportProfile? {
        let descriptor = FetchDescriptor<UserProfile>()
        guard let profile = try context.fetch(descriptor).first else { return nil }
        return ExportProfile(
            displayName: profile.displayName,
            avatarSymbol: profile.avatarSymbol,
            points: profile.points,
            createdAt: profile.createdAt,
            updatedAt: profile.updatedAt
        )
    }

    private static func fetchFavoritePlayers(in context: ModelContext) throws -> [ExportPlayer] {
        let descriptor = FetchDescriptor<Player>(predicate: #Predicate { $0.isFavorite })
        let players = try context.fetch(descriptor)
        return players.map {
            ExportPlayer(
                name: $0.name,
                nationality: $0.nationality,
                tour: $0.isWTA ? "WTA" : "ATP",
                externalKey: $0.externalKey
            )
        }
    }

    private static func fetchFavoriteTournaments(in context: ModelContext) throws -> [ExportTournament] {
        let descriptor = FetchDescriptor<Tournament>(predicate: #Predicate { $0.isFavorite })
        let items = try context.fetch(descriptor)
        return items.map {
            ExportTournament(
                name: $0.name,
                city: $0.city,
                country: $0.country,
                surface: $0.surface,
                tour: $0.tourRaw,
                startDate: $0.startDate,
                endDate: $0.endDate,
                externalKey: $0.externalKey
            )
        }
    }

    private static func fetchFavoriteMatches(in context: ModelContext) throws -> [ExportMatch] {
        let descriptor = FetchDescriptor<TennisMatch>(predicate: #Predicate { $0.isFavorite })
        let items = try context.fetch(descriptor)
        return items.map {
            ExportMatch(
                date: $0.date,
                status: $0.status,
                score: $0.score,
                player1Name: $0.player1TeamName,
                player2Name: $0.player2TeamName,
                player1PartnerName: $0.player1Partner?.name,
                player2PartnerName: $0.player2Partner?.name,
                isDoubles: $0.isDoubles,
                tournamentName: $0.tournament?.name,
                externalID: $0.externalID
            )
        }
    }

    private static func fetchBets(in context: ModelContext) throws -> [ExportBet] {
        let descriptor = FetchDescriptor<PointBet>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        let items = try context.fetch(descriptor)
        return items.map {
            ExportBet(
                kind: $0.kindRaw,
                selection: $0.selection,
                stake: $0.stake,
                payout: $0.payout,
                status: $0.statusRaw,
                predictedScore: $0.predictedScore,
                createdAt: $0.createdAt,
                settledAt: $0.settledAt,
                matchExternalID: $0.match?.externalID,
                playerName: $0.player?.name
            )
        }
    }

    private static func fetchSocialPosts(in context: ModelContext) throws -> [ExportPost] {
        let descriptor = FetchDescriptor<SocialPost>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        let items = try context.fetch(descriptor)
        return items.map {
            ExportPost(
                authorName: $0.authorName,
                body: $0.body,
                likes: $0.likes,
                replyCount: $0.replyCount,
                createdAt: $0.createdAt,
                matchExternalID: $0.match?.externalID
            )
        }
    }

    private static func fetchPolls(in context: ModelContext) throws -> [ExportPoll] {
        let descriptor = FetchDescriptor<MatchPoll>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        let items = try context.fetch(descriptor)
        return items.map {
            ExportPoll(
                question: $0.question,
                optionOne: $0.optionOne,
                optionTwo: $0.optionTwo,
                optionThree: $0.optionThree,
                votesOne: $0.votesOne,
                votesTwo: $0.votesTwo,
                votesThree: $0.votesThree,
                createdAt: $0.createdAt,
                matchExternalID: $0.match?.externalID
            )
        }
    }
}

nonisolated private struct ExportPayload: Codable {
    let schemaVersion: Int
    let exportedAt: Date
    let profile: ExportProfile?
    let favoritePlayers: [ExportPlayer]
    let favoriteTournaments: [ExportTournament]
    let favoriteMatches: [ExportMatch]
    let bets: [ExportBet]
    let socialPosts: [ExportPost]
    let polls: [ExportPoll]
}

nonisolated private struct ExportProfile: Codable {
    let displayName: String
    let avatarSymbol: String
    let points: Int
    let createdAt: Date
    let updatedAt: Date
}

nonisolated private struct ExportPlayer: Codable {
    let name: String
    let nationality: String
    let tour: String
    let externalKey: String?
}

nonisolated private struct ExportTournament: Codable {
    let name: String
    let city: String
    let country: String
    let surface: String
    let tour: String
    let startDate: Date
    let endDate: Date
    let externalKey: String?
}

nonisolated private struct ExportMatch: Codable {
    let date: Date
    let status: String
    let score: String
    let player1Name: String
    let player2Name: String
    let player1PartnerName: String?
    let player2PartnerName: String?
    let isDoubles: Bool
    let tournamentName: String?
    let externalID: String?
}

nonisolated private struct ExportBet: Codable {
    let kind: String
    let selection: String
    let stake: Int
    let payout: Int
    let status: String
    let predictedScore: String
    let createdAt: Date
    let settledAt: Date?
    let matchExternalID: String?
    let playerName: String?
}

nonisolated private struct ExportPost: Codable {
    let authorName: String
    let body: String
    let likes: Int
    let replyCount: Int
    let createdAt: Date
    let matchExternalID: String?
}

nonisolated private struct ExportPoll: Codable {
    let question: String
    let optionOne: String
    let optionTwo: String
    let optionThree: String
    let votesOne: Int
    let votesTwo: Int
    let votesThree: Int
    let createdAt: Date
    let matchExternalID: String?
}
