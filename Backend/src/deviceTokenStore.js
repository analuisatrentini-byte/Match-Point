import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { dirname } from "node:path";
import { fileURLToPath } from "node:url";

const defaultStorePath = new URL("../data/device-tokens.json", import.meta.url);

export class DeviceTokenStore {
  constructor(storePath = process.env.APNS_DEVICE_TOKEN_STORE ?? defaultStorePath) {
    this.storePath = storePath instanceof URL ? fileURLToPath(storePath) : storePath;
  }

  async upsert(payload) {
    const database = await this.readDatabase();
    const key = this.keyFor(payload);
    const now = new Date().toISOString();
    const existing = database.tokens[key] ?? {};

    database.tokens[key] = {
      ...existing,
      deviceToken: payload.deviceToken,
      platform: payload.platform,
      bundleIdentifier: payload.bundleIdentifier,
      environment: payload.environment,
      active: true,
      firstSeenAt: existing.firstSeenAt ?? now,
      lastSeenAt: now,
      revokedAt: null,
      lastReason: payload.reason,
      subscription: normalizeSubscription(payload.subscription),
      subscriptions: selectorsFromSubscription(payload.subscription)
    };

    await this.writeDatabase(database);
    return this.publicToken(database.tokens[key]);
  }

  async revoke(payload) {
    const database = await this.readDatabase();
    const key = this.keyFor(payload);
    const now = new Date().toISOString();
    const existing = database.tokens[key];

    if (!existing) {
      database.tokens[key] = {
        deviceToken: payload.deviceToken,
        platform: payload.platform,
        bundleIdentifier: payload.bundleIdentifier,
        environment: payload.environment,
        active: false,
        firstSeenAt: now,
        lastSeenAt: now,
        revokedAt: now,
        lastReason: payload.reason,
        subscription: normalizeSubscription(payload.subscription),
        subscriptions: selectorsFromSubscription(payload.subscription)
      };
    } else {
      database.tokens[key] = {
        ...existing,
        active: false,
        lastSeenAt: now,
        revokedAt: now,
        lastReason: payload.reason
      };
    }

    await this.writeDatabase(database);
    return this.publicToken(database.tokens[key]);
  }

  async stats() {
    const database = await this.readDatabase();
    const tokens = Object.values(database.tokens);
    return {
      total: tokens.length,
      active: tokens.filter((token) => token.active).length,
      revoked: tokens.filter((token) => !token.active).length,
      subscribed: tokens.filter((token) => token.active && (token.subscriptions?.length ?? 0) > 0).length
    };
  }

  async resolveRecipients(selectors) {
    const wanted = new Set((selectors ?? []).map(selectorKey).filter(Boolean));
    if (wanted.size === 0) return [];

    const database = await this.readDatabase();
    const recipientsByKey = new Map();
    for (const token of Object.values(database.tokens)) {
      if (!token.active) continue;
      const subscriptions = token.subscriptions ?? selectorsFromSubscription(token.subscription);
      const matches = subscriptions.some((subscription) => wanted.has(selectorKey(subscription)));
      if (!matches) continue;

      const recipientKey = this.keyFor(token);
      recipientsByKey.set(recipientKey, {
        deviceToken: token.deviceToken,
        bundleIdentifier: token.bundleIdentifier,
        environment: token.environment
      });
    }
    return Array.from(recipientsByKey.values());
  }

  async deactivateDeviceToken({ deviceToken, bundleIdentifier, environment = "production", platform = "ios", reason = "invalid-token" }) {
    const database = await this.readDatabase();
    const key = this.keyFor({ deviceToken, bundleIdentifier, environment, platform });
    const existing = database.tokens[key];
    if (!existing) return false;
    database.tokens[key] = {
      ...existing,
      active: false,
      revokedAt: new Date().toISOString(),
      lastReason: reason
    };
    await this.writeDatabase(database);
    return true;
  }

  keyFor(payload) {
    return [
      payload.bundleIdentifier,
      payload.environment,
      payload.platform,
      payload.deviceToken
    ].join(":");
  }

  publicToken(token) {
    return {
      active: token.active,
      platform: token.platform,
      bundleIdentifier: token.bundleIdentifier,
      environment: token.environment,
      tokenSuffix: token.deviceToken.slice(-8),
      firstSeenAt: token.firstSeenAt,
      lastSeenAt: token.lastSeenAt,
      revokedAt: token.revokedAt,
      subscriptions: token.subscriptions ?? []
    };
  }

  async readDatabase() {
    try {
      const raw = await readFile(this.storePath, "utf8");
      return JSON.parse(raw);
    } catch (error) {
      if (error.code === "ENOENT") {
        return { tokens: {} };
      }
      throw error;
    }
  }

  async writeDatabase(database) {
    await mkdir(dirname(this.storePath), { recursive: true });
    const temporaryPath = `${this.storePath}.tmp`;
    const targetPath = this.storePath;
    await writeFile(temporaryPath, JSON.stringify(database, null, 2));
    await rename(temporaryPath, targetPath);
  }
}

export function selectorsFromSubscription(subscription) {
  if (!subscription || typeof subscription !== "object") return [];
  const favorites = subscription.favorites ?? {};
  const selectors = [];

  for (const match of favorites.matches ?? []) {
    const matchKey = cleanID(match?.id);
    if (matchKey) selectors.push({ type: "match", matchKey });
  }
  for (const tournament of favorites.tournaments ?? []) {
    const tournamentKey = cleanID(tournament?.id);
    if (tournamentKey) selectors.push({ type: "tournament", tournamentKey });
  }
  for (const player of favorites.players ?? []) {
    const playerKey = cleanID(player?.id);
    if (playerKey) selectors.push({ type: "favorite-player", playerKey });
  }

  return dedupeSelectors(selectors);
}

function normalizeSubscription(subscription) {
  if (!subscription || typeof subscription !== "object") return null;
  return {
    schemaVersion: Number.isInteger(subscription.schemaVersion) ? subscription.schemaVersion : 1,
    preferences: subscription.preferences ?? {},
    favorites: subscription.favorites ?? { players: [], matches: [], tournaments: [] },
    eventRules: Array.isArray(subscription.eventRules) ? subscription.eventRules : [],
    backendDataPlane: subscription.backendDataPlane ?? null
  };
}

function dedupeSelectors(selectors) {
  const byKey = new Map();
  for (const selector of selectors) {
    const key = selectorKey(selector);
    if (key) byKey.set(key, selector);
  }
  return Array.from(byKey.values());
}

function selectorKey(selector) {
  if (!selector || typeof selector !== "object") return "";
  switch (selector.type) {
    case "match":
      return selector.matchKey ? `match:${selector.matchKey}` : "";
    case "tournament":
      return selector.tournamentKey ? `tournament:${selector.tournamentKey}` : "";
    case "favorite-player":
      return selector.playerKey ? `favorite-player:${selector.playerKey}` : "";
    default:
      return "";
  }
}

function cleanID(value) {
  return typeof value === "string" && value.trim() !== "" ? value.trim() : "";
}
