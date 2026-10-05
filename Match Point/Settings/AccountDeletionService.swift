//
//  AccountDeletionService.swift
//  Match Point
//
//  Hard-deletes every piece of user-owned data so people can exercise LGPD Art. 18
//  ("right to erasure"). Touches SwiftData, UserDefaults that are user-scoped, and
//  the Keychain entry for the moderation admin token.
//

import Foundation
import SwiftData

@MainActor
enum AccountDeletionService {
    /// Returns a summary describing what was wiped. Throws if the SwiftData save fails
    /// — the caller surfaces that to the user instead of pretending success.
    ///
    /// The CloudKit wipe runs *before* the local wipe so a network failure aborts
    /// the whole operation. Otherwise we would silently leave the user's posts /
    /// bets / leaderboard entry orbiting iCloud after they exercised LGPD Art. 18.
    static func deleteAllUserData(
        context: ModelContext,
        cloudBackend: CloudSocialBackend? = nil,
        accountAuthService: AccountAuthService? = nil
    ) async throws -> Summary {
        var summary = Summary()

        let authService = accountAuthService ?? AccountAuthService()
        summary.backendAccountDeleted = try await authService.deleteRemoteAccountIfAuthenticated()

        if let cloudBackend {
            summary.cloudRecordsDeleted = try await cloudBackend.deleteAllCloudRecordsForCurrentUser()
        }

        summary.profiles = try delete(FetchDescriptor<UserProfile>(), in: context)
        summary.bets = try delete(FetchDescriptor<PointBet>(), in: context)
        summary.socialPosts = try delete(FetchDescriptor<SocialPost>(), in: context)
        summary.polls = try delete(FetchDescriptor<MatchPoll>(), in: context)

        // Favorite flags travel with the parent entity rather than as their own type,
        // so unset them instead of deleting the entity (which would also lose schedule
        // data the user might still want as a guest).
        summary.unfavoritedPlayers = try unfavoritePlayers(in: context)
        summary.unfavoritedMatches = try unfavoriteMatches(in: context)
        summary.unfavoritedTournaments = try unfavoriteTournaments(in: context)

        try context.save()

        clearUserScopedDefaults()
        clearModerationKeychainEntry()
        clearAccountKeychainEntries()

        return summary
    }

    private static func delete<T: PersistentModel>(_ descriptor: FetchDescriptor<T>, in context: ModelContext) throws -> Int {
        let items = try context.fetch(descriptor)
        for item in items {
            context.delete(item)
        }
        return items.count
    }

    private static func unfavoritePlayers(in context: ModelContext) throws -> Int {
        let descriptor = FetchDescriptor<Player>(predicate: #Predicate { $0.isFavorite })
        let items = try context.fetch(descriptor)
        for item in items { item.isFavorite = false }
        return items.count
    }

    private static func unfavoriteMatches(in context: ModelContext) throws -> Int {
        let descriptor = FetchDescriptor<TennisMatch>(predicate: #Predicate { $0.isFavorite })
        let items = try context.fetch(descriptor)
        for item in items { item.isFavorite = false }
        return items.count
    }

    private static func unfavoriteTournaments(in context: ModelContext) throws -> Int {
        let descriptor = FetchDescriptor<Tournament>(predicate: #Predicate { $0.isFavorite })
        let items = try context.fetch(descriptor)
        for item in items { item.isFavorite = false }
        return items.count
    }

    private static func clearUserScopedDefaults() {
        // Only user-personal preferences and caches. Provider config (API key, backend URL)
        // belongs to the install, not the user, so it stays.
        let keys = [
            "match-point.onboarding-completed",
            "match-point.experience-preferences",
            "match-point.alert-preferences",
            "match-point.account.provider",
            "match-point.account.apple-user-id",
            "match-point.account.apple-email",
            "match-point.account.apple-display-name",
            "match-point.account.email-id",
            "match-point.account.email",
            "match-point.account.username",
            "match-point.social.blocked-review-authors",
            AppLogger.failureMetricsKey,
            "match-point.social.moderation-admin-token" // legacy plaintext key
        ]
        for key in keys {
            UserDefaults.standard.removeObject(forKey: key)
        }
        // AutoSyncTracker timestamps — reset so the next launch syncs fresh.
        let syncScopes = ["tournaments", "playersAndRankings", "matches", "liveMatches", "fixtures"]
        for scope in syncScopes {
            UserDefaults.standard.removeObject(forKey: "match_point.auto_sync.\(scope)")
        }
    }

    private static func clearModerationKeychainEntry() {
        // Delegate to CloudSocialBackend so service/account constants stay in one place.
        CloudSocialBackend.deleteModerationAdminToken()
    }

    private static func clearAccountKeychainEntries() {
        AccountAuthService.clearSession()
        let keychain = KeychainSecretStore(service: "match-point.account")
        [
            "email-password-salt",
            "email-password-hash",
            "email-recovery-salt",
            "email-recovery-hash"
        ].forEach { keychain.delete(account: $0) }
    }

    struct Summary: Equatable {
        var profiles = 0
        var bets = 0
        var socialPosts = 0
        var polls = 0
        var unfavoritedPlayers = 0
        var unfavoritedMatches = 0
        var unfavoritedTournaments = 0
        var cloudRecordsDeleted = 0
        var backendAccountDeleted = false

        var totalDeleted: Int { profiles + bets + socialPosts + polls }
        var totalUnfavorited: Int { unfavoritedPlayers + unfavoritedMatches + unfavoritedTournaments }
    }
}
