import Foundation

// MARK: - Cloud Social DTOs and State
//
// Pure value types consumed by views (`SocialFeedView`, `ProfileView`, etc.)
// and by the `CloudSocialBackend` repository. Splitting them out of the
// backend file makes it easier to spot which surface the UI actually depends
// on without having to scroll past 700 lines of CloudKit plumbing.

enum CloudBackendState: Equatable {
    case idle
    case loading
    case ready
    case unavailable(String)

    var label: String {
        switch self {
        case .idle:
            return "Cloud idle"
        case .loading:
            return "Sincronizando iCloud"
        case .ready:
            return "iCloud conectado"
        case .unavailable(let message):
            return message
        }
    }
}

struct CloudSocialPost: Identifiable, Equatable {
    let id: String
    let matchKey: String
    let matchTitle: String
    /// User-supplied display string. NOT trustworthy as identity — clients can
    /// send any value. Use `authorRecordName` (verified by CloudKit's record
    /// owner) for moderation, reporting, and any identity check.
    let authorName: String
    /// CloudKit `userRecordName` of the post's authenticated author. Verified
    /// against `record.creatorUserRecordID` on read; empty when CloudKit failed
    /// to attribute the record (treat such posts as untrusted).
    let authorRecordName: String
    let body: String
    let likes: Int
    let replyCount: Int
    let eventKey: String?
    let parentPostID: String?
    let reportCount: Int
    let isHidden: Bool
    let isPinned: Bool
    let createdAt: Date

    /// True when the user-supplied display name matches CloudKit's verified
    /// owner record name. False means a client wrote a forged `authorName`.
    var hasVerifiedIdentity: Bool {
        !authorRecordName.isEmpty
    }
}

struct CloudMatchPoll: Identifiable, Equatable {
    let id: String
    let matchKey: String
    let matchTitle: String
    let question: String
    let optionOne: String
    let optionTwo: String
    let optionThree: String
    let votesOne: Int
    let votesTwo: Int
    let votesThree: Int
    let createdAt: Date

    var totalVotes: Int {
        votesOne + votesTwo + votesThree
    }
}

struct CloudLeaderboardEntry: Identifiable, Equatable {
    let id: String
    let displayName: String
    let avatarSymbol: String
    let points: Int
    /// Settled bets won by this tipster. Zero on rows persisted before the
    /// tipster fields were added to the LeaderboardEntry record type.
    let wins: Int
    /// Settled bets lost by this tipster. Same backward-compatibility note as
    /// `wins`.
    let losses: Int
    /// Most recent consecutive wins (`PredictionStats.currentStreak`). Surfacing
    /// streak turns the ranking from "who has the most points right now" into
    /// "who is hot right now", which is the real engagement loop.
    let currentStreak: Int
    let updatedAt: Date
    let isCurrentUser: Bool

    var settled: Int { wins + losses }

    var winRate: Double {
        guard settled > 0 else { return 0 }
        return Double(wins) / Double(settled)
    }

    /// "—" for tipsters with no settled bets so the row doesn't say "0%" and
    /// look like a permanent loser.
    var winRateText: String {
        guard settled > 0 else { return "—" }
        return "\(Int(winRate * 100))%"
    }
}

enum CloudLeaderboardSource: Equatable {
    case none
    case backendAuthoritative
    case cloudKitFallback

    var label: String {
        switch self {
        case .none:
            return "Não carregado"
        case .backendAuthoritative:
            return "Ranking oficial"
        case .cloudKitFallback:
            return "Ranking local"
        }
    }

    var isProductionGrade: Bool {
        self == .backendAuthoritative
    }
}

/// Local-side projection of the tipster fields, computed from the user's
/// `PredictionStats` and handed to `CloudSocialBackend.syncProfile(_:performance:)`
/// when publishing the leaderboard row. Kept as a tiny value type instead of
/// pulling `PredictionStats` into the cloud layer (which doesn't otherwise know
/// anything about `PointBet`).
struct CloudTipsterPerformance: Equatable {
    let wins: Int
    let losses: Int
    let currentStreak: Int
}

nonisolated struct CloudModerationQueueItem: Identifiable, Decodable, Equatable {
    nonisolated struct ModerationState: Decodable, Equatable {
        let postID: String
        let matchKey: String?
        let isPinned: Bool
        let isHidden: Bool
        let updatedAt: String?
    }

    let postID: String
    let matchKey: String
    let reportCount: Int
    let latestReason: String
    let latestReportAt: String?
    let moderation: ModerationState?

    var id: String { postID }
}

nonisolated struct CloudModerationAuditEvent: Identifiable, Decodable, Equatable {
    let id: String
    let type: String
    let postID: String?
    let action: String?
    let userRecordName: String?
    let reason: String?
    let actor: String?
    let role: String?
    let createdAt: String?
}

nonisolated struct CloudModerationBan: Decodable, Equatable {
    let userRecordName: String
    let reason: String
    let isActive: Bool
    let actor: String?
    let role: String?
    let updatedAt: String?
}
