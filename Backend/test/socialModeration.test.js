import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import test from "node:test";

import { SocialModerationStore } from "../src/socialModerationStore.js";

test("social moderation queue audit rules and bans are server authoritative", async () => {
  const dir = await mkdtemp(join(tmpdir(), "match-point-moderation-"));
  try {
    const store = new SocialModerationStore(join(dir, "moderation.json"));

    await store.report({
      postID: "post-1",
      matchKey: "match-1",
      reason: "spam",
      userRecordName: "user-a",
      createdAt: "2026-08-11T10:00:00.000Z"
    });
    await store.report({
      postID: "post-1",
      matchKey: "match-1",
      reason: "abuse",
      userRecordName: "user-b",
      createdAt: "2026-08-11T10:01:00.000Z"
    });
    await store.report({
      postID: "post-2",
      matchKey: "match-2",
      reason: "spam",
      userRecordName: "user-c",
      createdAt: "2026-08-11T10:02:00.000Z"
    });

    await store.moderate({
      postID: "post-1",
      matchKey: "match-1",
      action: "hide",
      actorRecordName: "moderator-1",
      actorRole: "admin"
    });
    await store.updateRules({
      rules: ["Sem spam.", "Sem ataques pessoais."],
      actorRecordName: "moderator-1",
      actorRole: "admin"
    });
    await store.banUser({
      userRecordName: "user-b",
      reason: "abuse",
      isActive: true,
      actorRecordName: "moderator-1",
      actorRole: "admin"
    });

    const queue = await store.queue();
    assert.equal(queue[0].postID, "post-1");
    assert.equal(queue[0].reportCount, 2);
    assert.equal(queue[0].moderation.isHidden, true);

    const audit = await store.audit();
    assert.ok(audit.some((event) => event.type === "moderation-action" && event.action === "hide"));
    assert.ok(audit.some((event) => event.type === "community-rules-update"));
    assert.ok(audit.some((event) => event.type === "user-ban" && event.userRecordName === "user-b"));

    assert.deepEqual(await store.rules(), ["Sem spam.", "Sem ataques pessoais."]);
    await assert.rejects(
      () => store.report({
        postID: "post-3",
        reason: "spam",
        userRecordName: "user-b"
      }),
      /User is banned/
    );
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
