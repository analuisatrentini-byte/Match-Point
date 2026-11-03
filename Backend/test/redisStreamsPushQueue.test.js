import assert from "node:assert/strict";
import test from "node:test";

import { LiveIngestionService } from "../src/liveIngestionService.js";
import { RedisStreamsPushQueue } from "../src/queue/redisStreamsPushQueue.js";

test("Redis queue reports health before first frame and after a successful dispatch", async () => {
  const queue = new RedisStreamsPushQueue(fakeRedis());
  const service = new LiveIngestionService({
    snapshots: { async stats() { return { matches: 0 }; } },
    scoreHistory: { async stats() { return { records: 0 }; } },
    queue,
    dispatcher: async () => ({ ok: true, receipt: "test-delivered" })
  });

  assert.deepEqual((await service.health()).queue, {
    enqueued: 0, sent: 0, dead: 0, pending: 0
  });

  await queue.enqueueMany([{ kind: "match_started", matchKey: "match-1" }]);
  const result = await service.drainOnce();
  assert.equal(result.sent.length, 1);
  assert.equal(result.sent[0].deliveryReceipt, "test-delivered");
  assert.deepEqual(await queue.stats(), {
    enqueued: 1, sent: 1, dead: 0, pending: 1
  });
  const health = await service.health();
  assert.equal(health.queue.sent, 1);
  assert.equal(health.ingest.eventsSent, 1);
  assert.deepEqual((await queue.snapshot()).stats, {
    enqueued: 1, sent: 1, dead: 0
  });
});

test("Redis queue keeps failure counters observable for rejected and thrown dispatches", async () => {
  const queue = new RedisStreamsPushQueue(fakeRedis());
  await queue.enqueueMany([
    { kind: "match_started", matchKey: "rejected" },
    { kind: "match_finished", matchKey: "thrown" }
  ]);

  const result = await queue.drain(async (event) => {
    if (event.matchKey === "thrown") throw new Error("transport failed");
    return { ok: false, reason: "recipient rejected" };
  }, { maxAttempts: 1 });

  assert.equal(result.failed.length, 2);
  assert.deepEqual(await queue.stats(), {
    enqueued: 2, sent: 0, dead: 2, pending: 2
  });
  assert.equal((await queue.snapshot()).dead, 2);
});

function fakeRedis() {
  const streams = new Map();
  const cursors = new Map();
  let sequence = 0;
  return {
    async xgroup() { return "OK"; },
    async xadd(stream, ...args) {
      const entries = streams.get(stream) ?? [];
      const id = `${++sequence}-0`;
      entries.push([id, args.slice(-2)]);
      streams.set(stream, entries);
      return id;
    },
    async xreadgroup(...args) {
      const stream = args.at(-2);
      const entries = streams.get(stream) ?? [];
      const unread = entries.slice(cursors.get(stream) ?? 0);
      cursors.set(stream, entries.length);
      return unread.length ? [[stream, unread]] : null;
    },
    async xack() { return 1; },
    // Acknowledged entries remain in the stream; the current queue's pending
    // metric uses XLEN, so preserve that existing behavior in this test double.
    async xlen(stream) { return (streams.get(stream) ?? []).length; }
  };
}
