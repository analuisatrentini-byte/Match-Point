import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import test from "node:test";

import { DeviceTokenStore } from "../src/deviceTokenStore.js";
import { LiveIngestionService } from "../src/liveIngestionService.js";
import { MatchSnapshotStore } from "../src/matchSnapshotStore.js";
import { PushEventQueue } from "../src/pushEventQueue.js";
import { ScoreHistoryStore } from "../src/scoreHistoryStore.js";

test("live ingestion dedupes snapshots and dispatches to subscribed favorite devices", async () => {
  const dir = await mkdtemp(join(tmpdir(), "match-point-backend-"));
  try {
    const tokens = new DeviceTokenStore(join(dir, "device-tokens.json"));
    const snapshots = new MatchSnapshotStore(join(dir, "match-snapshots.json"));
    const scoreHistory = new ScoreHistoryStore(join(dir, "score-history.json"));
    const queue = new PushEventQueue(join(dir, "push-queue.json"));
    const delivered = [];

    await tokens.upsert({
      action: "register",
      reason: "test",
      deviceToken: "abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd",
      platform: "ios",
      bundleIdentifier: "ALTB.Match-Point",
      environment: "sandbox",
      registeredForRemoteNotifications: true,
      subscription: {
        favorites: {
          players: [{ id: "sinner", name: "Jannik Sinner", kind: "player" }],
          matches: [],
          tournaments: []
        }
      }
    });

    const service = new LiveIngestionService({
      snapshots,
      scoreHistory,
      queue,
      dispatcher: async (event) => {
        const resolvedRecipients = await tokens.resolveRecipients(event.recipients);
        delivered.push({ ...event, resolvedRecipients });
        return { ok: true, receipt: `test:${resolvedRecipients.length}` };
      }
    });

    const first = await service.ingestFrame({
      matchKey: "match-1",
      tournamentKey: "wimbledon",
      player1: "Carlos Alcaraz",
      player2: "Jannik Sinner",
      player1Key: "alcaraz",
      player2Key: "sinner",
      status: "live",
      score: "6-4",
      gameScore: "4-3",
      pointScore: "30-40",
      breakPoint: true,
      capturedAt: "2026-07-12T14:00:00Z"
    }, { source: "unit" });

    const duplicate = await service.ingestFrame({
      matchKey: "match-1",
      tournamentKey: "wimbledon",
      player1: "Carlos Alcaraz",
      player2: "Jannik Sinner",
      player1Key: "alcaraz",
      player2Key: "sinner",
      status: "live",
      score: "6-4",
      gameScore: "4-3",
      pointScore: "30-40",
      breakPoint: true,
      capturedAt: "2026-07-12T14:00:05Z"
    }, { source: "unit" });

    assert.equal(first.changed, true);
    assert.equal(duplicate.changed, false);
    assert.equal((await scoreHistory.history("match-1")).length, 1);

    const drained = await service.drainOnce();
    assert.equal(drained.sent.length, 3);
    assert.equal(delivered.length, 3);
    assert.ok(delivered.every((event) => event.resolvedRecipients.length === 1));
    assert.ok(delivered.some((event) => event.kind === "match_started"));
    assert.ok(delivered.some((event) => event.kind === "break_point"));
    assert.ok(delivered.some((event) => event.kind === "favorite_alert"));
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
