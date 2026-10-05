import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { dirname } from "node:path";
import { fileURLToPath } from "node:url";

const defaultStorePath = new URL("../data/push-queue.json", import.meta.url);

/// FIFO queue of push events persisted to disk. Enqueue is O(1) amortized;
/// dequeue is O(1). The worker calls `drain` to consume everything currently
/// pending, sends each event through a dispatcher, and marks results back
/// into the store. Failed sends are re-queued with an incremented `attempts`
/// counter so a downstream outage doesn't drop notifications.
export class PushEventQueue {
    constructor(storePath = process.env.PUSH_EVENT_QUEUE_STORE ?? defaultStorePath) {
        this.storePath = storePath instanceof URL ? fileURLToPath(storePath) : storePath;
    }

    async enqueueMany(events) {
        if (!events || events.length === 0) return [];
        const database = await this.readDatabase();
        const now = new Date().toISOString();
        const enqueued = events.map((event, offset) => ({
            id: `pe:${Date.now()}:${database.stats.enqueued + offset}`,
            enqueuedAt: now,
            attempts: 0,
            state: "pending",
            ...event
        }));
        database.pending.push(...enqueued);
        database.stats.enqueued += enqueued.length;
        await this.writeDatabase(database);
        return enqueued;
    }

    /// Consumes every pending event and hands it to `dispatcher(event)`. The
    /// dispatcher must return `{ ok: true }` for success, `{ ok: false, reason }`
    /// for a transient failure (event stays queued, attempts++), or throw
    /// synchronously for a permanent failure (event moves to `dead`).
    async drain(dispatcher, { maxAttempts = 3 } = {}) {
        const database = await this.readDatabase();
        const pending = database.pending;
        database.pending = [];
        const sent = [];
        const failed = [];

        for (const event of pending) {
            try {
                const result = await dispatcher(event);
                if (result?.ok) {
                    const settled = {
                        ...event,
                        state: "sent",
                        sentAt: new Date().toISOString(),
                        deliveryReceipt: result.receipt ?? null
                    };
                    database.sent.push(settled);
                    database.stats.sent += 1;
                    sent.push(settled);
                } else {
                    const attempts = event.attempts + 1;
                    if (attempts >= maxAttempts) {
                        const dead = {
                            ...event,
                            state: "dead",
                            failedAt: new Date().toISOString(),
                            lastFailureReason: result?.reason ?? "unknown"
                        };
                        database.dead.push(dead);
                        database.stats.dead += 1;
                        failed.push(dead);
                    } else {
                        database.pending.push({ ...event, attempts, state: "pending", lastFailureReason: result?.reason ?? "unknown" });
                    }
                }
            } catch (error) {
                const dead = {
                    ...event,
                    state: "dead",
                    failedAt: new Date().toISOString(),
                    lastFailureReason: error.message ?? "throw"
                };
                database.dead.push(dead);
                database.stats.dead += 1;
                failed.push(dead);
            }
        }

        // Retain only the tail of the "sent" log so the queue file doesn't
        // grow unbounded — 500 rows is plenty for an in-progress debugging
        // view and still small enough to load into memory each drain.
        if (database.sent.length > 500) {
            database.sent = database.sent.slice(-500);
        }
        if (database.dead.length > 500) {
            database.dead = database.dead.slice(-500);
        }

        await this.writeDatabase(database);
        return { sent, failed, pending: database.pending.length };
    }

    async snapshot() {
        const database = await this.readDatabase();
        return {
            pending: database.pending.length,
            sent: database.sent.length,
            dead: database.dead.length,
            stats: database.stats
        };
    }

    async listPending({ limit = 50 } = {}) {
        const database = await this.readDatabase();
        return database.pending.slice(0, limit);
    }

    async stats() {
        const database = await this.readDatabase();
        return {
            enqueued: database.stats.enqueued,
            sent: database.stats.sent,
            dead: database.stats.dead,
            pending: database.pending.length
        };
    }

    async readDatabase() {
        try {
            const raw = await readFile(this.storePath, "utf8");
            return JSON.parse(raw);
        } catch (error) {
            if (error.code === "ENOENT") {
                return {
                    pending: [],
                    sent: [],
                    dead: [],
                    stats: { enqueued: 0, sent: 0, dead: 0 }
                };
            }
            throw error;
        }
    }

    async writeDatabase(database) {
        await mkdir(dirname(this.storePath), { recursive: true });
        const temporaryPath = `${this.storePath}.tmp`;
        await writeFile(temporaryPath, JSON.stringify(database, null, 2));
        await rename(temporaryPath, this.storePath);
    }
}
