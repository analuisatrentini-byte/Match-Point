import { decide } from "./pushDecisionEngine.js";

/// Orchestrates the four moving parts that turn a raw match frame into a
/// (possibly empty) set of enqueued push events:
///
///   1. `MatchSnapshotStore.ingest` deduplicates by content hash. If the
///      frame is byte-identical to the last one, nothing else happens.
///   2. `ScoreHistoryStore.record` appends an immutable audit row for every
///      non-duplicate frame.
///   3. `pushDecisionEngine.decide` diffs previous vs current and produces
///      any events the rules recognize.
///   4. `PushEventQueue.enqueueMany` persists the events so the drain worker
///      can dispatch them independently of the ingest path.
///
/// The service also owns the periodic drain loop: it starts a `setInterval`
/// that pulls the queue and hands each event to the configured dispatcher
/// (APNs sender in production, no-op logger in dev).
export class LiveIngestionService {
    constructor({ snapshots, scoreHistory, queue, dispatcher, drainIntervalMs = 5_000 }) {
        this.snapshots = snapshots;
        this.scoreHistory = scoreHistory;
        this.queue = queue;
        this.dispatcher = dispatcher ?? noopDispatcher;
        this.drainIntervalMs = drainIntervalMs;
        this.stats = {
            framesReceived: 0,
            framesAccepted: 0,
            framesDeduped: 0,
            eventsEnqueued: 0,
            eventsSent: 0,
            eventsDead: 0,
            lastFrameAt: null,
            lastDrainAt: null
        };
        this.timer = null;
    }

    /// Processes one incoming match frame end-to-end. Returns a summary the
    /// caller can echo back to the ingest client for debugging: which events
    /// were produced, whether the frame was deduped, and the current revision.
    async ingestFrame(frame, { source = "ingest" } = {}) {
        this.stats.framesReceived += 1;
        this.stats.lastFrameAt = new Date().toISOString();

        const { current, previous, changed } = await this.snapshots.ingest(frame);
        if (!changed) {
            this.stats.framesDeduped += 1;
            return { changed: false, matchKey: current.matchKey, revision: current.revision, events: [] };
        }

        this.stats.framesAccepted += 1;

        await this.scoreHistory.record({ current, previous, source });

        const events = decide({ previous, current });
        if (events.length > 0) {
            await this.queue.enqueueMany(events);
            this.stats.eventsEnqueued += events.length;
        }

        return {
            changed: true,
            matchKey: current.matchKey,
            revision: current.revision,
            events: events.map((event) => ({ kind: event.kind, priority: event.priority, recipients: event.recipients.length }))
        };
    }

    /// Manual drain — the server exposes this so operators/tests can flush
    /// the queue without waiting on the periodic timer.
    async drainOnce() {
        const result = await this.queue.drain((event) => this.dispatcher(event));
        this.stats.eventsSent += result.sent.length;
        this.stats.eventsDead += result.failed.length;
        this.stats.lastDrainAt = new Date().toISOString();
        return result;
    }

    /// Boots the periodic drain loop. Safe to call more than once — additional
    /// calls become no-ops. The interval is unref'd so it doesn't hold the
    /// process open by itself.
    startDrainLoop() {
        if (this.timer) return;
        this.timer = setInterval(() => {
            this.drainOnce().catch((error) => {
                // Never let a drain failure crash the loop — log and move on.
                console.error("push-queue drain failed", error.message);
            });
        }, this.drainIntervalMs);
        this.timer.unref?.();
    }

    stopDrainLoop() {
        if (this.timer) {
            clearInterval(this.timer);
            this.timer = null;
        }
    }

    async health() {
        const [snapshotStats, historyStats, queueStats] = await Promise.all([
            this.snapshots.stats(),
            this.scoreHistory.stats(),
            this.queue.stats()
        ]);
        return {
            ingest: this.stats,
            snapshots: snapshotStats,
            scoreHistory: historyStats,
            queue: queueStats
        };
    }
}

/// Default dispatcher used when no APNs sender is configured. Logs the event
/// summary to stdout and reports success — production deployments replace
/// this with a real APNs client (HTTP/2 + `.p8` key), a webhook forwarder,
/// or any other transport. The queue does not care what transport is used;
/// it only cares that `{ ok: true }` (or a `{ ok: false, reason }`) comes back.
export async function noopDispatcher(event) {
    console.log(
        "[push]",
        event.kind,
        event.matchKey,
        `recipients=${event.recipients.length}`,
        event.payload?.headline ?? ""
    );
    return { ok: true, receipt: `noop:${event.id}` };
}
