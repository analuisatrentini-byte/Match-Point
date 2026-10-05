import Foundation
import OSLog
import SwiftData

#if canImport(BackgroundTasks) && os(iOS)
import BackgroundTasks
#endif

/// Pure description of what a BG refresh tick should do. Separating this from
/// the imperative `handle(task:)` shell lets unit tests cover the priority
/// rules (skip when WebSocket owns the writer, no-op when the container has
/// been torn down, etc.) without spinning up a real `BGTaskScheduler`.
enum BackgroundSyncDecision: Equatable {
    case skip(reason: SkipReason)
    case run(tasks: Set<SyncTask>)

    enum SkipReason: Equatable {
        /// A foreground WebSocket session is mutating the model context.
        case liveStreamActive
        /// The container provider returned nil — the persistence store is
        /// gone (app being torn down) so there's nowhere to write.
        case noContainer
        /// AutoSyncTracker rate-limited every subtask.
        case noWorkScheduled
    }

    enum SyncTask: Hashable {
        case liveMatches
        case tournaments
    }
}

enum BackgroundSyncScheduler {
    static let refreshTaskIdentifier = "ALTB.Match-Point.refresh"
    private static let earliestBeginInterval: TimeInterval = 15 * 60

    /// Pure decision function — testable without BGTaskScheduler / SwiftData.
    /// Order of precedence:
    /// 1. `liveStreamActive` short-circuits everything (single-writer guarantee).
    /// 2. No container → no-op.
    /// 3. AutoSyncTracker per-subtask flags decide which sync work to run.
    static func decideBackgroundSync(
        liveStreamActive: Bool,
        containerAvailable: Bool,
        shouldSyncLiveMatches: Bool,
        shouldSyncTournaments: Bool
    ) -> BackgroundSyncDecision {
        if liveStreamActive {
            return .skip(reason: .liveStreamActive)
        }
        if !containerAvailable {
            return .skip(reason: .noContainer)
        }
        var tasks: Set<BackgroundSyncDecision.SyncTask> = []
        if shouldSyncLiveMatches { tasks.insert(.liveMatches) }
        if shouldSyncTournaments { tasks.insert(.tournaments) }
        if tasks.isEmpty {
            return .skip(reason: .noWorkScheduled)
        }
        return .run(tasks: tasks)
    }

    // The container is captured at registration time so the BG task can build
    // a fresh @MainActor ModelContext without going through SwiftUI's
    // environment.
    @MainActor private static var containerProvider: (@MainActor () -> ModelContainer?)?

    @MainActor
    static func register(containerProvider: @escaping @MainActor () -> ModelContainer?) {
        #if canImport(BackgroundTasks) && os(iOS)
        Self.containerProvider = containerProvider
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshTaskIdentifier, using: nil) { task in
            guard let appRefreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handle(task: appRefreshTask)
        }
        #endif
    }

    static func scheduleNext() {
        #if canImport(BackgroundTasks) && os(iOS)
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: earliestBeginInterval)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            AppLogger.sync.error("BGTaskScheduler submit failed: \(AppLogger.message(for: error), privacy: .private)")
        }
        #endif
    }

    #if canImport(BackgroundTasks) && os(iOS)
    private static func handle(task: BGAppRefreshTask) {
        let work = Task {
            do {
                return try await SyncCoordinator.shared.runMainActor {
                    scheduleNext()
                    let container = containerProvider?()
                    let decision = decideBackgroundSync(
                        liveStreamActive: LiveMatchActivityFlag.isActive,
                        containerAvailable: container != nil,
                        shouldSyncLiveMatches: AutoSyncTracker.shouldSync(.liveMatches),
                        shouldSyncTournaments: AutoSyncTracker.shouldSync(.tournaments)
                    )
                    switch decision {
                    case .skip(reason: .noContainer):
                        return false
                    case .skip:
                        // .liveStreamActive / .noWorkScheduled are healthy
                        // no-ops, not failures.
                        return true
                    case .run(let tasks):
                        guard let container else { return false }
                        let context = ModelContext(container)
                        let service = DataSyncService(context: context)
                        var success = true
                        do {
                            if tasks.contains(.liveMatches) {
                                try await service.syncLiveMatches()
                                AutoSyncTracker.markSynced(.liveMatches)
                            }
                            if tasks.contains(.tournaments) {
                                try await service.syncTournaments()
                                AutoSyncTracker.markSynced(.tournaments)
                            }
                        } catch {
                            success = false
                            AppLogger.sync.error("Background sync failed: \(AppLogger.message(for: error), privacy: .private)")
                            AppLogger.recordFailure(category: "sync", operation: "background.refresh", error: error)
                        }
                        // Force UserDefaults to flush any pending writes before
                        // the background task is torn down by the OS. Without
                        // this the alert snapshots written by processMatchUpdate
                        // can be lost if the process is suspended immediately
                        // after setTaskCompleted.
                        let flushed = UserDefaults.standard.synchronize()
                        if !flushed {
                            AppLogger.sync.warning("UserDefaults.synchronize() returned false during BGTask — snapshots may not have been persisted to disk")
                        }
                        return success
                    }
                }
            } catch {
                return false
            }
        }

        task.expirationHandler = {
            work.cancel()
        }

        Task {
            let success = await work.value
            task.setTaskCompleted(success: success)
        }
    }
    #endif
}

/// Cheap @MainActor flag the WebSocket service flips while it owns the live
/// stream. Read by BGTaskScheduler before kicking a sync to avoid two writers.
@MainActor
enum LiveMatchActivityFlag {
    private(set) static var isActive: Bool = false

    static func setActive(_ active: Bool) {
        isActive = active
    }
}
