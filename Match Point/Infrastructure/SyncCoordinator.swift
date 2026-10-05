import Foundation
import OSLog

/// Serializes the entry points that can dispatch a `DataSyncService` cycle so
/// that the WebSocket REST fallback and the BG App Refresh handler never write
/// to overlapping `ModelContext`s simultaneously. Foreground manual syncs
/// (onboarding, settings, pull-to-refresh) run on the @MainActor model context
/// already and skip the coordinator — they are user-initiated and bounded.
///
/// Each task waits for the previously enqueued task before starting, so two
/// `run(...)` calls from different actors produce a strict sequential order.
actor SyncCoordinator {
    static let shared = SyncCoordinator()

    private var lastTask: Task<Void, Never>?

    func runMainActor<T: Sendable>(_ work: @MainActor @Sendable @escaping () async throws -> T) async throws -> T {
        let previous = lastTask
        let task = Task<T, Error> { @MainActor in
            await previous?.value
            return try await work()
        }
        // The chain task only waits for `task` so subsequent enqueues serialize.
        // We deliberately don't rethrow here — the original caller already gets
        // the error via `task.value` below — but we DO record it so a silent
        // failure during a chained run shows up in the failure metrics instead
        // of being swallowed by `try?`.
        lastTask = Task {
            do {
                _ = try await task.value
            } catch {
                await MainActor.run {
                    AppLogger.sync.error("SyncCoordinator chained task failed: \(AppLogger.message(for: error), privacy: .private)")
                    AppLogger.recordFailure(category: "sync", operation: "syncCoordinator.chainedTask", error: error)
                }
            }
        }
        return try await task.value
    }
}
