//
//  Models.swift
//  Match Point
//
//  Created by Ana Luisa Bittencourt on 26/03/26.
//

import Foundation
import CryptoKit
import SwiftData

/// Single source of truth for ATP vs WTA across the codebase. Previously each
/// model declared its own `Tour` enum (Tournament.Tour, RankingEntry.Tour) and
/// Player used a free-standing `isWTA: Bool`. Aliasing them all to this enum
/// removes the divergence path where two providers disagree on a player's tour
/// and the app silently keeps the last-written boolean instead of a typed value.
nonisolated enum MatchPointTour: String, Codable, CaseIterable {
    case atp = "ATP"
    case wta = "WTA"

    init(isWTA: Bool) {
        self = isWTA ? .wta : .atp
    }

    var isWTA: Bool { self == .wta }
}

@Model
final class Player {
    typealias Tour = MatchPointTour

    var id: UUID
    /// `.unique` enforces a single non-nil row per externalKey at the store
    /// level. Nil keys (locally-created stubs from the WebSocket path before a
    /// REST sync populates real IDs) are allowed — Core Data/SwiftData treat
    /// multiple nils as distinct.
    @Attribute(.unique) var externalKey: String?
    var name: String
    var nationality: String
    var isWTA: Bool
    var birthDate: Date?
    var isFavorite: Bool

    /// Typed accessor mirroring the same enum used by Tournament and
    /// RankingEntry. Backed by the stored `isWTA` boolean — no migration
    /// needed, but call sites can write `player.tour == .wta` instead of
    /// `player.isWTA` and stay consistent across the three models.
    var tour: MatchPointTour {
        get { MatchPointTour(isWTA: isWTA) }
        set { isWTA = newValue.isWTA }
    }

    // Inverse-side declarations: SwiftData picks up the to-one fields on the child
    // models (RankingEntry.player, TennisMatch.player1/2, PointBet.player) through
    // these properties and keeps the back-references consistent.
    // Deleting a player cascades rankings (a ranking without a player is meaningless)
    // but only nullifies match/bet links so historical records keep their shape.
    @Relationship(deleteRule: .cascade, inverse: \RankingEntry.player) var rankings: [RankingEntry] = []
    @Relationship(deleteRule: .nullify, inverse: \TennisMatch.player1) var matchesAsPlayer1: [TennisMatch] = []
    @Relationship(deleteRule: .nullify, inverse: \TennisMatch.player2) var matchesAsPlayer2: [TennisMatch] = []
    // Doubles partners: without these inverses SwiftData wouldn't nullify the
    // TennisMatch reference when the partner player is deleted, leaving the
    // match pointing at a tombstoned object. The keypath on the TennisMatch
    // side already declares the to-one rule.
    @Relationship(deleteRule: .nullify, inverse: \TennisMatch.player1Partner) var matchesAsPartner1: [TennisMatch] = []
    @Relationship(deleteRule: .nullify, inverse: \TennisMatch.player2Partner) var matchesAsPartner2: [TennisMatch] = []
    @Relationship(deleteRule: .nullify, inverse: \PointBet.player) var bets: [PointBet] = []

    init(
        id: UUID = UUID(),
        externalKey: String? = nil,
        name: String,
        nationality: String,
        isWTA: Bool,
        birthDate: Date? = nil,
        isFavorite: Bool = false
    ) {
        self.id = id
        self.externalKey = externalKey
        self.name = name
        self.nationality = nationality
        self.isWTA = isWTA
        self.birthDate = birthDate
        self.isFavorite = isFavorite
    }
}

@Model
final class Tournament {
    typealias Tour = MatchPointTour

    var id: UUID
    @Attribute(.unique) var externalKey: String?
    var name: String
    var city: String
    var country: String
    var surface: String
    var tourRaw: String
    var startDate: Date
    var endDate: Date
    var isFavorite: Bool

    // Relationships
    // Deleting a tournament leaves matches in place (they may have already been
    // played and have meaningful historical data); the tournament reference just
    // goes nil so the UI shows "TBD" for the venue.
    @Relationship(deleteRule: .nullify, inverse: \TennisMatch.tournament) var matches: [TennisMatch] = []

    var tour: Tour {
        get { Tour(rawValue: tourRaw) ?? .atp }
        set { tourRaw = newValue.rawValue }
    }

    /// True when this tournament is one of the four Grand Slams. Checks both
    /// well-known canonical substrings and the external ID against a set of
    /// known API keys, so name formatting changes (year suffixes, capitalization
    /// drift) don't silently break best-of-five and points logic.
    var isMajor: Bool {
        let lower = name.lowercased()
        let nameMatch = lower.contains("australian open")
            || lower.contains("roland garros")
            || lower.contains("roland-garros")
            || lower.contains("french open")
            || lower.contains("wimbledon")
            || lower.contains("us open")
        if nameMatch { return true }
        // Fall back to known external IDs supplied by api-tennis.com.
        if let key = externalKey {
            return Tournament.majorExternalKeys.contains(key)
        }
        return false
    }

    /// Known external keys for Grand Slam tournaments as returned by api-tennis.com.
    /// Extend when new key formats are observed in API responses.
    static let majorExternalKeys: Set<String> = [
        "australian_open", "roland_garros", "wimbledon", "us_open",
        "australian-open", "roland-garros", "us-open"
    ]

    init(
        id: UUID = UUID(),
        externalKey: String? = nil,
        name: String,
        city: String,
        country: String,
        surface: String,
        tour: Tour,
        startDate: Date,
        endDate: Date,
        isFavorite: Bool = false
    ) {
        self.id = id
        self.externalKey = externalKey
        self.name = name
        self.city = city
        self.country = country
        self.surface = surface
        self.tourRaw = tour.rawValue
        self.startDate = startDate
        self.endDate = endDate
        self.isFavorite = isFavorite
    }
}

@Model
final class TennisMatch {
    var id: UUID
    /// Backing storage retains the legacy column name `externalID` so existing
    /// installs don't trigger a SwiftData migration. New call sites should
    /// prefer the unified `externalKey` accessor below, which matches the name
    /// used by Player, Tournament and RankingEntry.
    @Attribute(.unique) var externalID: String?
    var date: Date
    var status: String
    var isLive: Bool
    var lastUpdatedAt: Date?
    var serverName: String
    var pointScore: String
    var gameScore: String
    var liveTimelinePayload: String
    var isFavorite: Bool

    // Relationships
    // tournament/player1/player2 are the to-one side. Inverse paths are declared
    // on Tournament.matches and Player.matchesAsPlayer1/2 to keep the back-pointers in sync.
    @Relationship var tournament: Tournament?
    @Relationship var player1: Player?
    @Relationship var player2: Player?
    @Relationship(deleteRule: .nullify) var player1Partner: Player?
    @Relationship(deleteRule: .nullify) var player2Partner: Player?

    // User-generated artifacts must outlive the match they referenced.
    // The provider occasionally purges/renames matches (data corrections,
    // walkovers reclassified, duplicate rows merged) and the previous cascade
    // rule wiped the user's bet history, posts and polls along with them.
    // `.nullify` keeps the records alive with `match == nil`; UI surfaces fall
    // back to the cached selection/title strings already stored on each entity.
    // SocialRetentionService still prunes truly stale orphans on its own clock.
    @Relationship(deleteRule: .nullify, inverse: \PointBet.match) var bets: [PointBet] = []
    @Relationship(deleteRule: .nullify, inverse: \SocialPost.match) var posts: [SocialPost] = []
    @Relationship(deleteRule: .nullify, inverse: \MatchPoll.match) var polls: [MatchPoll] = []

    var score: String

    init(
        id: UUID = UUID(),
        externalID: String? = nil,
        date: Date,
        status: String = "Scheduled",
        isLive: Bool = false,
        lastUpdatedAt: Date? = nil,
        serverName: String = "",
        pointScore: String = "",
        gameScore: String = "",
        liveTimelinePayload: String = "",
        isFavorite: Bool = false,
        tournament: Tournament? = nil,
        player1: Player? = nil,
        player2: Player? = nil,
        player1Partner: Player? = nil,
        player2Partner: Player? = nil,
        score: String = ""
    ) {
        self.id = id
        self.externalID = externalID
        self.date = date
        self.status = status
        self.isLive = isLive
        self.lastUpdatedAt = lastUpdatedAt
        self.serverName = serverName
        self.pointScore = pointScore
        self.gameScore = gameScore
        self.liveTimelinePayload = liveTimelinePayload
        self.isFavorite = isFavorite
        self.tournament = tournament
        self.player1 = player1
        self.player2 = player2
        self.player1Partner = player1Partner
        self.player2Partner = player2Partner
        self.score = score
    }

    /// Unified alias for `externalID`. Kept as a computed property so the
    /// SwiftData column stays named `externalID` (no migration cost) while
    /// every other model — Player, Tournament, RankingEntry — and any new
    /// consumer can read/write through the consistent `externalKey` name.
    var externalKey: String? {
        get { externalID }
        set { externalID = newValue }
    }
}

@Model
final class RankingEntry {
    typealias Tour = MatchPointTour

    var id: UUID
    @Attribute(.unique) var externalKey: String?
    @Relationship(deleteRule: .nullify) var player: Player?
    var rank: Int
    var points: Int
    var tourRaw: String

    var tour: Tour {
        get { Tour(rawValue: tourRaw) ?? .atp }
        set { tourRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        externalKey: String? = nil,
        player: Player? = nil,
        rank: Int,
        points: Int,
        tour: Tour
    ) {
        self.id = id
        self.externalKey = externalKey
        self.player = player
        self.rank = rank
        self.points = points
        self.tourRaw = tour.rawValue
    }
}

@Model
final class UserProfile {
    var id: UUID
    /// Stable identifier the user keeps across re-installs and device sync. nil
    /// today (no auth/iCloud account), reserved so a future Sign-in-with-Apple
    /// or CloudKit hook can backfill without another schema migration.
    var externalKey: String?
    var displayName: String
    var avatarSymbol: String
    var points: Int
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        externalKey: String? = nil,
        displayName: String = "Match Point Fan",
        avatarSymbol: String = "person.crop.circle.fill",
        points: Int = 1_000,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.externalKey = externalKey
        self.displayName = displayName
        self.avatarSymbol = avatarSymbol
        self.points = points
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

@Model
final class PointBet {
    var id: UUID
    @Relationship var match: TennisMatch?
    @Relationship var player: Player?
    var kindRaw: String
    var selection: String
    var stake: Int
    var payout: Int
    var statusRaw: String
    var targetSetIndex: Int?
    var predictedScore: String
    var performanceRuleRaw: String
    var integrityHash: String
    var settlementAuthorityRaw: String
    var serverSettlementID: String?
    var serverSettlementStatusRaw: String
    var createdAt: Date
    var settledAt: Date?

    var kind: BetKind {
        get { BetKind(rawValue: kindRaw) ?? .matchWinner }
        set { kindRaw = newValue.rawValue }
    }

    var status: BetStatus {
        get { BetStatus(rawValue: statusRaw) ?? .open }
        set { statusRaw = newValue.rawValue }
    }

    var performanceRule: BetPerformanceRule {
        get { BetPerformanceRule(rawValue: performanceRuleRaw) ?? .straightSets }
        set { performanceRuleRaw = newValue.rawValue }
    }

    var settlementAuthority: BetSettlementAuthority {
        get { BetSettlementAuthority(rawValue: settlementAuthorityRaw) ?? .localPendingServer }
        set { settlementAuthorityRaw = newValue.rawValue }
    }

    var serverSettlementStatus: ServerSettlementStatus {
        get { ServerSettlementStatus(rawValue: serverSettlementStatusRaw) ?? .pending }
        set { serverSettlementStatusRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        match: TennisMatch? = nil,
        player: Player? = nil,
        kind: BetKind = .matchWinner,
        selection: String,
        stake: Int,
        payout: Int,
        status: BetStatus = .open,
        targetSetIndex: Int? = nil,
        predictedScore: String = "",
        performanceRule: BetPerformanceRule = .straightSets,
        integrityHash: String = "",
        settlementAuthority: BetSettlementAuthority = .localPendingServer,
        serverSettlementID: String? = nil,
        serverSettlementStatus: ServerSettlementStatus = .pending,
        createdAt: Date = .now,
        settledAt: Date? = nil
    ) {
        self.id = id
        self.match = match
        self.player = player
        self.kindRaw = kind.rawValue
        self.selection = selection
        self.stake = stake
        self.payout = payout
        self.statusRaw = status.rawValue
        self.targetSetIndex = targetSetIndex
        self.predictedScore = predictedScore
        self.performanceRuleRaw = performanceRule.rawValue
        self.integrityHash = integrityHash.isEmpty
            ? Self.makeIntegrityHash(
                id: id,
                matchKey: match?.externalID,
                playerKey: player?.externalKey,
                tournamentKey: match?.tournament?.externalKey,
                kind: kind,
                selection: selection,
                stake: stake,
                payout: payout,
                createdAt: createdAt
            )
            : integrityHash
        self.settlementAuthorityRaw = settlementAuthority.rawValue
        self.serverSettlementID = serverSettlementID
        self.serverSettlementStatusRaw = serverSettlementStatus.rawValue
        self.createdAt = createdAt
        self.settledAt = settledAt
    }

    static func makeIntegrityHash(
        id: UUID,
        matchKey: String?,
        playerKey: String?,
        tournamentKey: String? = nil,
        kind: BetKind,
        selection: String,
        stake: Int,
        payout: Int,
        createdAt: Date
    ) -> String {
        let source = [
            id.uuidString,
            matchKey ?? "",
            playerKey ?? "",
            tournamentKey ?? "",
            kind.rawValue,
            selection,
            String(stake),
            String(payout),
            ISO8601DateFormatter().string(from: createdAt)
        ].joined(separator: "|")

        let digest = SHA256.hash(data: Data(source.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Recomputes the hash from the current state. Used to compare against the
    /// stored value and detect mutations to immutable fields (stake, payout,
    /// selection, kind) that happened outside the controlled creation path.
    func currentIntegrityHash() -> String {
        Self.makeIntegrityHash(
            id: id,
            matchKey: match?.externalID,
            playerKey: player?.externalKey,
            tournamentKey: match?.tournament?.externalKey,
            kind: kind,
            selection: selection,
            stake: stake,
            payout: payout,
            createdAt: createdAt
        )
    }

    /// True when the stored hash still matches the current bet shape. If false,
    /// either someone mutated a write-once field after placement or the persisted
    /// hash was corrupted — callers should refuse to credit / sync and surface
    /// it for audit.
    var hasValidIntegrity: Bool {
        !integrityHash.isEmpty && integrityHash == currentIntegrityHash()
    }
}

nonisolated enum BetKind: String, Codable, CaseIterable, Identifiable {
    case matchWinner = "Vencedor da partida"
    case setWinner = "Vencedor do set"
    case finalScore = "Placar"
    case playerPerformance = "Performance"
    case tieBreakPlayed = "Terá tie-break"
    case totalSets = "Quantos sets"
    case holdServe = "Confirma o saque"
    case firstBreak = "Quem quebra primeiro"
    case nextGameWinner = "Próximo game"

    var id: String { rawValue }
}

nonisolated enum BetStatus: String, Codable, CaseIterable {
    case open = "Aberta"
    case won = "Ganhou"
    case lost = "Perdeu"
    case void = "Cancelada"
}

nonisolated enum BetSettlementAuthority: String, Codable, CaseIterable {
    case localPendingServer = "Local pending server"
    case serverAuthoritative = "Server authoritative"
    case serverRejected = "Server rejected"
}

nonisolated enum ServerSettlementStatus: String, Codable, CaseIterable {
    case pending = "Pending"
    case accepted = "Accepted"
    case settled = "Settled"
    case rejected = "Rejected"
}

nonisolated enum BetPerformanceRule: String, Codable, CaseIterable, Identifiable {
    case straightSets = "Vence em sets diretos"
    case comebackWin = "Vira depois de perder o 1º set"
    case decisiveSetPlayed = "Leva a partida ao set decisivo"

    var id: String { rawValue }
}

@Model
final class SocialPost {
    var id: UUID
    @Relationship(deleteRule: .nullify) var match: TennisMatch?
    var authorName: String
    var body: String
    var likes: Int
    var replyCount: Int
    var eventKey: String?
    var parentPostID: String?
    var reportCount: Int
    var isHidden: Bool
    var isPinned: Bool
    var createdAt: Date

    init(
        id: UUID = UUID(),
        match: TennisMatch? = nil,
        authorName: String,
        body: String,
        likes: Int = 0,
        replyCount: Int = 0,
        eventKey: String? = nil,
        parentPostID: String? = nil,
        reportCount: Int = 0,
        isHidden: Bool = false,
        isPinned: Bool = false,
        createdAt: Date = .now
    ) {
        self.id = id
        self.match = match
        self.authorName = authorName
        self.body = body
        self.likes = likes
        self.replyCount = replyCount
        self.eventKey = eventKey
        self.parentPostID = parentPostID
        self.reportCount = reportCount
        self.isHidden = isHidden
        self.isPinned = isPinned
        self.createdAt = createdAt
    }
}

@Model
final class MatchPoll {
    var id: UUID
    @Relationship(deleteRule: .nullify) var match: TennisMatch?
    var question: String
    var optionOne: String
    var optionTwo: String
    var optionThree: String
    var votesOne: Int
    var votesTwo: Int
    var votesThree: Int
    var createdAt: Date
    var cloudRecordID: String?

    init(
        id: UUID = UUID(),
        match: TennisMatch? = nil,
        question: String,
        optionOne: String,
        optionTwo: String,
        optionThree: String = "",
        votesOne: Int = 0,
        votesTwo: Int = 0,
        votesThree: Int = 0,
        createdAt: Date = .now,
        cloudRecordID: String? = nil
    ) {
        self.id = id
        self.match = match
        self.question = question
        self.optionOne = optionOne
        self.optionTwo = optionTwo
        self.optionThree = optionThree
        self.votesOne = votesOne
        self.votesTwo = votesTwo
        self.votesThree = votesThree
        self.createdAt = createdAt
        self.cloudRecordID = cloudRecordID
    }
}

enum ShareTextFactory {
    static func match(_ match: TennisMatch) -> String {
        let title = "\(match.player1TeamName) vs \(match.player2TeamName)"
        let tournament = match.tournament?.name ?? String(localized: "Torneio")
        let date = match.date.formatted(date: .abbreviated, time: .shortened)
        let status = match.status.isEmpty ? statusLabel(for: match) : match.status
        let scoreLine = match.score.isEmpty ? "" : "\n\(String(localized: "Placar")): \(match.score)"

        return String(
            format: String(localized: "Estou acompanhando %@ no Match Point.\n%@ • %@ • %@%@"),
            locale: .current,
            title,
            tournament,
            date,
            status,
            scoreLine
        )
    }

    static func prediction(_ bet: PointBet) -> String {
        let matchTitle = bet.match.map { "\($0.player1TeamName) vs \($0.player2TeamName)" } ?? String(localized: "Partida")
        let stakeLine = String(
            format: String(localized: "%d pts simbólicos • retorno possível %d pts"),
            locale: .current,
            bet.stake,
            bet.payout
        )

        return String(
            format: String(localized: "Minha previsão no Match Point\n%@\n%@\n%@\nStatus: %@"),
            locale: .current,
            matchTitle,
            bet.kind.rawValue,
            "\(bet.selection) • \(stakeLine)",
            bet.status.rawValue
        )
    }

    private static func statusLabel(for match: TennisMatch) -> String {
        if match.isLive { return String(localized: "Ao vivo") }
        if match.isUpcoming { return String(localized: "Próxima") }
        if match.isCompleted { return String(localized: "Finalizada") }
        return String(localized: "Status pendente")
    }
}
