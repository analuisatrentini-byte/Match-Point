import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import test from "node:test";

import { BetSettlementStore } from "../src/betSettlementStore.js";

test("social leaderboard is derived from settled server bets", async () => {
  const dir = await mkdtemp(join(tmpdir(), "match-point-leaderboard-"));
  try {
    const store = new BetSettlementStore(join(dir, "bets.json"));

    await store.syncProfile({
      userRecordName: "user-a",
      displayName: "Ana",
      avatarSymbol: "bolt.fill",
      points: 99_999
    });
    await store.register({
      betID: "bet-1",
      userRecordName: "user-a",
      displayName: "Ana",
      avatarSymbol: "bolt.fill",
      matchKey: "match-1",
      selection: "Player A",
      kind: "winner",
      stake: 50,
      payout: 90,
      integrityHash: "hash-1",
      createdAt: "2026-07-12T14:00:00Z"
    });
    await store.register({
      betID: "bet-2",
      userRecordName: "user-a",
      displayName: "Ana",
      avatarSymbol: "bolt.fill",
      matchKey: "match-2",
      selection: "Player B",
      kind: "winner",
      stake: 30,
      payout: 60,
      integrityHash: "hash-2",
      createdAt: "2026-07-12T15:00:00Z"
    });

    await store.settle({
      betID: "bet-1",
      status: "won",
      integrityHash: "hash-1",
      serverSettlementID: "settled-1",
      actor: "admin"
    });
    await store.settle({
      betID: "bet-2",
      status: "lost",
      integrityHash: "hash-2",
      serverSettlementID: "settled-2",
      actor: "admin"
    });

    const leaderboard = await store.leaderboard({ currentUserRecordName: "user-a" });
    assert.equal(leaderboard.length, 1);
    assert.equal(leaderboard[0].displayName, "Ana");
    assert.equal(leaderboard[0].points, 1060);
    assert.equal(leaderboard[0].wins, 1);
    assert.equal(leaderboard[0].losses, 1);
    assert.equal(leaderboard[0].currentStreak, 0);
    assert.equal(leaderboard[0].isCurrentUser, true);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
