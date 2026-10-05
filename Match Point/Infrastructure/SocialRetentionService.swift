//
//  SocialRetentionService.swift
//  Match Point
//
//  Removes stale social content so a long-running install doesn't grow forever.
//  Run on app launch — cheap fetch over an indexed createdAt, deletes by cascade.
//

import Foundation
import OSLog
import SwiftData

@MainActor
enum SocialRetentionService {
    /// Posts and polls older than this are evicted. Generous enough that an active
    /// follower of a Slam still sees commentary from the whole tournament window,
    /// short enough that idle installs don't accumulate years of chatter.
    static let retentionWindow: TimeInterval = 60 * 60 * 24 * 60 // 60 days

    @discardableResult
    static func pruneStale(in context: ModelContext, now: Date = .now) -> Summary {
        let cutoff = now.addingTimeInterval(-retentionWindow)
        var summary = Summary()

        summary.posts = prunePosts(before: cutoff, in: context)
        summary.polls = prunePolls(before: cutoff, in: context)

        if summary.totalRemoved > 0 {
            do {
                try context.save()
                AppLogger.persistence.notice("Pruned \(summary.posts, privacy: .public) posts and \(summary.polls, privacy: .public) polls older than \(Int(retentionWindow / 86_400), privacy: .public)d")
            } catch {
                AppLogger.persistence.error("Social retention save failed: \(AppLogger.message(for: error), privacy: .private)")
                AppLogger.recordFailure(category: "persistence", operation: "socialRetention.save", error: error)
            }
        }
        return summary
    }

    // Typed helpers use #Predicate so SwiftData translates the cutoff into a
    // SQL WHERE clause — only stale rows are loaded, not the full table.
    private static func prunePosts(before cutoff: Date, in context: ModelContext) -> Int {
        let descriptor = FetchDescriptor<SocialPost>(predicate: #Predicate { $0.createdAt < cutoff })
        do {
            let stale = try context.fetch(descriptor)
            let staleIDs = Set(stale.map { $0.id.uuidString })
            // Cascade: delete replies that reference a stale parent post so they
            // don't accumulate as orphans with a dangling parentPostID.
            if !staleIDs.isEmpty {
                let replyDescriptor = FetchDescriptor<SocialPost>(
                    predicate: #Predicate { post in post.parentPostID != nil }
                )
                let allReplies = try context.fetch(replyDescriptor)
                allReplies
                    .filter { $0.parentPostID.map { staleIDs.contains($0) } == true }
                    .forEach { context.delete($0) }
            }
            stale.forEach { context.delete($0) }
            return stale.count
        } catch {
            AppLogger.persistence.error("Social retention fetch failed for SocialPost: \(AppLogger.message(for: error), privacy: .private)")
            AppLogger.recordFailure(category: "persistence", operation: "socialRetention.fetch.SocialPost", error: error)
            return 0
        }
    }

    private static func prunePolls(before cutoff: Date, in context: ModelContext) -> Int {
        let descriptor = FetchDescriptor<MatchPoll>(predicate: #Predicate { $0.createdAt < cutoff })
        do {
            let stale = try context.fetch(descriptor)
            stale.forEach { context.delete($0) }
            return stale.count
        } catch {
            AppLogger.persistence.error("Social retention fetch failed for MatchPoll: \(AppLogger.message(for: error), privacy: .private)")
            AppLogger.recordFailure(category: "persistence", operation: "socialRetention.fetch.MatchPoll", error: error)
            return 0
        }
    }

    /// Deletes PointBet rows whose match reference was nullified (match deleted
    /// while the bet was still open). These "ghost bets" have no context, cannot
    /// be settled, and pollute the export and bet history UI.
    /// Uses a SwiftData predicate so only orphaned rows are loaded — not the
    /// full table — avoiding memory spikes in installs with many bets.
    @discardableResult
    static func pruneOrphanedBets(in context: ModelContext) -> Int {
        let descriptor = FetchDescriptor<PointBet>(predicate: #Predicate { $0.match == nil })
        do {
            let orphans = try context.fetch(descriptor)
            orphans.forEach { context.delete($0) }
            if !orphans.isEmpty {
                AppLogger.persistence.notice("Pruned \(orphans.count, privacy: .public) orphaned PointBet rows")
            }
            return orphans.count
        } catch {
            AppLogger.persistence.error("Orphan bet prune fetch failed: \(AppLogger.message(for: error), privacy: .private)")
            AppLogger.recordFailure(category: "persistence", operation: "socialRetention.pruneOrphanedBets", error: error)
            return 0
        }
    }

    /// Deletes RankingEntry rows whose player relationship was nullified — they
    /// carry no useful data and accumulate silently when players are deleted.
    /// Uses a SwiftData predicate so only orphaned rows are loaded — not the
    /// full table.
    @discardableResult
    static func pruneOrphanedRankings(in context: ModelContext) -> Int {
        let descriptor = FetchDescriptor<RankingEntry>(predicate: #Predicate { $0.player == nil })
        do {
            let orphans = try context.fetch(descriptor)
            orphans.forEach { context.delete($0) }
            if !orphans.isEmpty {
                AppLogger.persistence.notice("Pruned \(orphans.count, privacy: .public) orphaned RankingEntry rows")
            }
            return orphans.count
        } catch {
            AppLogger.persistence.error("Orphan ranking prune fetch failed: \(AppLogger.message(for: error), privacy: .private)")
            AppLogger.recordFailure(category: "persistence", operation: "socialRetention.pruneOrphanedRankings", error: error)
            return 0
        }
    }

    /// Removes onboarding seed players (externalKey prefix "seed-") once real
    /// API players are present. Seeds are placeholders for the offline first-launch
    /// experience; once the API syncs they become stale duplicates.
    @discardableResult
    static func pruneOnboardingSeeds(in context: ModelContext) -> Int {
        // Only prune if real (non-seed) players exist — i.e. at least one sync ran.
        let allDescriptor = FetchDescriptor<Player>()
        let allPlayers: [Player]
        do {
            allPlayers = try context.fetch(allDescriptor)
        } catch {
            AppLogger.persistence.error("Seed player prune fetch failed: \(AppLogger.message(for: error), privacy: .private)")
            AppLogger.recordFailure(category: "persistence", operation: "socialRetention.pruneOnboardingSeeds.fetch", error: error)
            return 0
        }

        guard allPlayers.contains(where: { $0.externalKey?.hasPrefix("seed-") == false }) else {
            return 0
        }
        let seeds = allPlayers.filter { $0.externalKey?.hasPrefix("seed-") == true }
        guard !seeds.isEmpty else { return 0 }
        seeds.forEach { context.delete($0) }
        do {
            try context.save()
            AppLogger.persistence.notice("Pruned \(seeds.count, privacy: .public) onboarding seed players")
        } catch {
            AppLogger.persistence.error("Seed player prune save failed: \(AppLogger.message(for: error), privacy: .private)")
            AppLogger.recordFailure(category: "persistence", operation: "socialRetention.pruneOnboardingSeeds", error: error)
        }
        return seeds.count
    }

    struct Summary: Equatable {
        var posts = 0
        var polls = 0
        var totalRemoved: Int { posts + polls }
    }
}
