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

        summary.posts = pruneIfOlder(cutoff: cutoff, in: context, of: SocialPost.self) { $0.createdAt }
        summary.polls = pruneIfOlder(cutoff: cutoff, in: context, of: MatchPoll.self) { $0.createdAt }

        if summary.totalRemoved > 0 {
            do {
                try context.save()
                AppLogger.persistence.notice("Pruned \(summary.posts, privacy: .public) posts and \(summary.polls, privacy: .public) polls older than \(Int(retentionWindow / 86_400), privacy: .public)d")
            } catch {
                AppLogger.persistence.error("Social retention save failed: \(AppLogger.message(for: error), privacy: .public)")
                AppLogger.recordFailure(category: "persistence", operation: "socialRetention.save", error: error)
            }
        }
        return summary
    }

    private static func pruneIfOlder<T: PersistentModel>(
        cutoff: Date,
        in context: ModelContext,
        of: T.Type,
        date: (T) -> Date
    ) -> Int {
        let descriptor = FetchDescriptor<T>()
        do {
            let items = try context.fetch(descriptor)
            let stale = items.filter { date($0) < cutoff }
            for item in stale {
                context.delete(item)
            }
            return stale.count
        } catch {
            AppLogger.persistence.error("Social retention fetch failed for \(String(describing: T.self), privacy: .public): \(AppLogger.message(for: error), privacy: .public)")
            AppLogger.recordFailure(category: "persistence", operation: "socialRetention.fetch.\(String(describing: T.self))", error: error)
            return 0
        }
    }

    struct Summary: Equatable {
        var posts = 0
        var polls = 0
        var totalRemoved: Int { posts + polls }
    }
}
