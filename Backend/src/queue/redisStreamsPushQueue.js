/// Redis Streams-backed push queue with the SAME interface as the JSON queue.
///
/// - Enqueue: XADD to `push:events`.
/// - Drain: XREADGROUP against a consumer group so multiple workers can share
///   the stream; XACK after successful dispatch. Failed dispatches are XADD'd
///   back with an incremented `attempts` field until they hit `maxAttempts`,
///   after which they XADD to `push:events:dead` and are XACK'd from the
///   main stream. This gives us at-least-once delivery with a dead-letter tail.
///
/// The XADD MAXLEN cap keeps the stream from growing unbounded — the cap is
/// approximate (MAXLEN ~) so old entries drop only when convenient for Redis.
export class RedisStreamsPushQueue {
    constructor(client, {
        stream = process.env.PUSH_STREAM ?? "push:events",
        deadStream = process.env.PUSH_STREAM_DEAD ?? "push:events:dead",
        group = process.env.PUSH_CONSUMER_GROUP ?? "match-point",
        consumer = process.env.PUSH_CONSUMER ?? `worker-${process.pid}`,
        maxLen = Number(process.env.PUSH_STREAM_MAXLEN ?? 10_000)
    } = {}) {
        this.client = client;
        this.stream = stream;
        this.deadStream = deadStream;
        this.group = group;
        this.consumer = consumer;
        this.maxLen = maxLen;
        this.stats = { enqueued: 0, sent: 0, dead: 0 };
        this.groupReady = false;
    }

    async ensureGroup() {
        if (this.groupReady) return;
        try {
            await this.client.xgroup("CREATE", this.stream, this.group, "$", "MKSTREAM");
        } catch (error) {
            // BUSYGROUP means the group already exists — the very outcome we want.
            if (!String(error.message ?? "").includes("BUSYGROUP")) throw error;
        }
        this.groupReady = true;
    }

    async enqueueMany(events) {
        if (!events || events.length === 0) return [];
        await this.ensureGroup();
        const enqueued = [];
        for (const event of events) {
            const payload = JSON.stringify({ ...event, attempts: 0, state: "pending", enqueuedAt: new Date().toISOString() });
            const id = await this.client.xadd(this.stream, "MAXLEN", "~", String(this.maxLen), "*", "event", payload);
            enqueued.push({ ...event, id, attempts: 0, state: "pending" });
        }
        this.stats.enqueued += enqueued.length;
        return enqueued;
    }

    async drain(dispatcher, { maxAttempts = 3, batchSize = 32 } = {}) {
        await this.ensureGroup();
        const rows = await this.client.xreadgroup(
            "GROUP", this.group, this.consumer,
            "COUNT", String(batchSize),
            "STREAMS", this.stream, ">"
        );
        if (!rows || rows.length === 0) return { sent: [], failed: [], pending: 0 };

        const sent = [];
        const failed = [];
        for (const [, entries] of rows) {
            for (const [id, fields] of entries) {
                const event = parseEntry(fields);
                if (!event) {
                    await this.client.xack(this.stream, this.group, id);
                    continue;
                }
                try {
                    const result = await dispatcher({ ...event, id });
                    if (result?.ok) {
                        await this.client.xack(this.stream, this.group, id);
                        sent.push({ ...event, id, state: "sent", sentAt: new Date().toISOString(), deliveryReceipt: result.receipt ?? null });
                        this.stats.sent += 1;
                    } else {
                        const attempts = (event.attempts ?? 0) + 1;
                        if (attempts >= maxAttempts) {
                            await this.client.xadd(this.deadStream, "MAXLEN", "~", String(this.maxLen), "*", "event", JSON.stringify({ ...event, attempts, state: "dead", lastFailureReason: result?.reason ?? "unknown", failedAt: new Date().toISOString() }));
                            await this.client.xack(this.stream, this.group, id);
                            this.stats.dead += 1;
                            failed.push({ ...event, state: "dead" });
                        } else {
                            await this.client.xadd(this.stream, "MAXLEN", "~", String(this.maxLen), "*", "event", JSON.stringify({ ...event, attempts, state: "pending", lastFailureReason: result?.reason ?? "unknown" }));
                            await this.client.xack(this.stream, this.group, id);
                        }
                    }
                } catch (error) {
                    await this.client.xadd(this.deadStream, "MAXLEN", "~", String(this.maxLen), "*", "event", JSON.stringify({ ...event, state: "dead", lastFailureReason: error.message ?? "throw", failedAt: new Date().toISOString() }));
                    await this.client.xack(this.stream, this.group, id);
                    this.stats.dead += 1;
                    failed.push({ ...event, state: "dead" });
                }
            }
        }
        return { sent, failed, pending: await this.pendingCount() };
    }

    async pendingCount() {
        return this.client.xlen(this.stream);
    }

    async snapshot() {
        return {
            pending: await this.pendingCount(),
            sent: this.stats.sent,
            dead: this.stats.dead,
            stats: { ...this.stats }
        };
    }

    async listPending() {
        // Streams are opaque without XRANGE; expose stats only. Operators use
        // redis-cli XRANGE for deeper inspection — mirroring the JSON queue's
        // `listPending` here would require XRANGE + parse, which is fine but
        // not needed by any current caller.
        return [];
    }

    async stats() {
        return { ...this.stats, pending: await this.pendingCount() };
    }
}

function parseEntry(fields) {
    // XREADGROUP returns fields as a flat array [key, value, key, value, ...].
    for (let i = 0; i < fields.length; i += 2) {
        if (fields[i] === "event") {
            try {
                return JSON.parse(fields[i + 1]);
            } catch {
                return null;
            }
        }
    }
    return null;
}
