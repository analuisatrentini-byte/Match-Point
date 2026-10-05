import http from "node:http";
import { DeviceTokenStore } from "./deviceTokenStore.js";
import { DeviceRegistry } from "./subscriptions/deviceRegistry.js";
import { SocialModerationStore } from "./socialModerationStore.js";
import { BetSettlementStore } from "./betSettlementStore.js";
import { MatchSnapshotStore } from "./matchSnapshotStore.js";
import { ScoreHistoryStore } from "./scoreHistoryStore.js";
import { PushEventQueue } from "./pushEventQueue.js";
import { LiveIngestionService } from "./liveIngestionService.js";
import { noopDispatcher } from "./liveIngestionService.js";
import { ApnsDispatcher } from "./dispatchers/apnsDispatcher.js";
import { getPostgresPool } from "./db/postgresPool.js";
import { getRedisClient } from "./db/redisClient.js";
import { PostgresMatchSnapshotStore } from "./stores/postgresMatchSnapshotStore.js";
import { PostgresScoreHistoryStore } from "./stores/postgresScoreHistoryStore.js";
import { RedisStreamsPushQueue } from "./queue/redisStreamsPushQueue.js";
import { ApiTennisWebSocketIngester } from "./ingesters/apiTennisWebSocketIngester.js";
import { AuthStore } from "./authStore.js";
import {
  apiTennisDataPlaneContract,
  apiTennisProxyStats,
  apiTennisWebSocketURL,
  handleAPITennisProxy,
  productionReadiness
} from "./apiTennisProxy.js";
import { handleOfficialRankingProjection, officialRankingReadiness } from "./officialRankingProjection.js";

const port = Number(process.env.PORT ?? 8787);
const postgresPool = getPostgresPool();
const redisClient = getRedisClient();
const store = postgresPool ? new DeviceRegistry({ pool: postgresPool }) : new DeviceTokenStore();
const socialModerationStore = new SocialModerationStore();
const betSettlementStore = new BetSettlementStore();
const matchSnapshotStore = postgresPool ? new PostgresMatchSnapshotStore(postgresPool) : new MatchSnapshotStore();
const scoreHistoryStore = postgresPool ? new PostgresScoreHistoryStore(postgresPool) : new ScoreHistoryStore();
const pushEventQueue = redisClient ? new RedisStreamsPushQueue(redisClient) : new PushEventQueue();
const pushDispatcher = createPushDispatcher(store);
const authStore = new AuthStore({ pool: postgresPool });

// The dispatcher is intentionally pluggable — production installs replace
// the default no-op with a real APNs sender (HTTP/2 + `.p8`). The queue does
// not know or care what transport is used; the ingestion service just needs
// a callable that returns `{ ok }`.
const liveIngestionService = new LiveIngestionService({
  snapshots: matchSnapshotStore,
  scoreHistory: scoreHistoryStore,
  queue: pushEventQueue,
  dispatcher: pushDispatcher,
  drainIntervalMs: Number(process.env.PUSH_DRAIN_INTERVAL_MS ?? 5_000)
});
liveIngestionService.startDrainLoop();
const apiTennisIngester = createApiTennisIngester(liveIngestionService);
apiTennisIngester?.start().catch((error) => {
  console.error("api-tennis ingester failed to start", error.message);
});

// Rate limit: protects every non-/health endpoint against floods from a single
// IP. Sliding window — each request older than `windowMs` is dropped from the
// counter so legitimate bursts don't get permanently punished.
const rateLimiter = createRateLimiter({
  windowMs: Number(process.env.RATE_LIMIT_WINDOW_MS ?? 60_000),
  max: Number(process.env.RATE_LIMIT_MAX ?? 60)
});

// CORS: defaults to "no cross-origin" — set ALLOWED_ORIGINS (comma-separated)
// only for the origins you actually serve. The iOS client itself does not
// trigger CORS, but a misconfigured web debug tool would.
const allowedOrigins = parseAllowedOrigins(process.env.ALLOWED_ORIGINS);

const server = http.createServer(async (request, response) => {
  try {
    applyCORSHeaders(request, response);

    if (request.method === "OPTIONS") {
      response.writeHead(204);
      return response.end();
    }

    if (request.method === "GET" && request.url === "/health") {
      const stats = await store.stats();
      const moderation = await socialModerationStore.stats();
      const bets = await betSettlementStore.stats();
      const auth = await authStore.stats();
      const ingestion = await liveIngestionService.health();
      return sendJSON(response, 200, {
        ok: true,
        readiness: productionReadiness(),
        stats,
        moderation,
        bets,
        auth,
        ingestion,
        apiTennisIngester: apiTennisIngester?.stats ?? null,
        apiTennisProxy: apiTennisProxyStats(),
        officialRanking: officialRankingReadiness()
      });
    }

    if (request.method === "GET" && request.url === "/production/readiness") {
      return sendJSON(response, 200, {
        ok: true,
        readiness: productionReadiness(),
        apiTennisProxy: apiTennisProxyStats(),
        officialRanking: officialRankingReadiness()
      });
    }

    if (request.method === "GET" && request.url === "/production/contract") {
      return sendJSON(response, 200, {
        ok: true,
        contract: apiTennisDataPlaneContract
      });
    }

    if (!rateLimiter.allow(clientIP(request))) {
      response.setHeader("retry-after", String(Math.ceil(rateLimiter.windowMs / 1000)));
      return sendJSON(response, 429, { ok: false, error: "Too many requests" });
    }

    if (request.method === "GET" && new URL(request.url, "http://localhost").pathname === "/tennis") {
      return handleAPITennisProxy(request, response);
    }

    if (request.method === "GET" && new URL(request.url, "http://localhost").pathname === "/rankings/live-projection") {
      return handleOfficialRankingProjection(request, response);
    }

    if (request.method === "POST" && request.url === "/auth/apple") {
      const result = await authStore.signInWithApple(await readJSON(request));
      return sendJSON(response, 200, { ok: true, result });
    }

    if (request.method === "POST" && request.url === "/auth/email/signup") {
      const result = await authStore.signUpWithEmail(await readJSON(request));
      return sendJSON(response, 201, { ok: true, result });
    }

    if (request.method === "POST" && request.url === "/auth/email/login") {
      const result = await authStore.loginWithEmail(await readJSON(request));
      return sendJSON(response, 200, { ok: true, result });
    }

    if (request.method === "POST" && request.url === "/auth/email/recovery/request") {
      const result = await authStore.requestPasswordRecovery(await readJSON(request));
      return sendJSON(response, 200, {
        ok: true,
        result: {
          ...result,
          message: "Se a conta existir, um código de recuperação será enviado."
        }
      });
    }

    if (request.method === "POST" && request.url === "/auth/email/recovery/reset") {
      const result = await authStore.resetPassword(await readJSON(request));
      return sendJSON(response, 200, { ok: true, result });
    }

    if (request.method === "POST" && request.url === "/auth/delete") {
      const result = await authStore.deleteAccountForSession(authorizationBearer(request));
      return sendJSON(response, 200, { ok: true, result });
    }

    if (request.method === "POST" && request.url === "/apns/device-token") {
      const payload = validatePayload(await readJSON(request));
      const token = payload.action === "register"
        ? await store.upsert(payload)
        : await store.revoke(payload);

      return sendJSON(response, 200, {
        ok: true,
        action: payload.action,
        token
      });
    }

    if (request.method === "POST" && request.url === "/social/moderation/report") {
      const payload = validateReportPayload(await readJSON(request));
      const result = await socialModerationStore.report(payload);
      return sendJSON(response, 200, { ok: true, result });
    }

    if (request.method === "POST" && request.url === "/social/moderation/action") {
      const actorRole = authorizeModerator(request);
      const payload = validateModerationActionPayload(await readJSON(request), actorRole);
      const result = await socialModerationStore.moderate(payload);
      return sendJSON(response, 200, { ok: true, result });
    }

    if (request.method === "GET" && new URL(request.url, "http://localhost").pathname === "/social/moderation/queue") {
      authorizeModerator(request);
      const url = new URL(request.url, "http://localhost");
      const limit = Number.parseInt(url.searchParams.get("limit") ?? "100", 10);
      const queue = await socialModerationStore.queue({ limit: Number.isInteger(limit) ? limit : 100 });
      return sendJSON(response, 200, { ok: true, queue });
    }

    if (request.method === "GET" && new URL(request.url, "http://localhost").pathname === "/social/moderation/audit") {
      authorizeModerator(request);
      const url = new URL(request.url, "http://localhost");
      const limit = Number.parseInt(url.searchParams.get("limit") ?? "100", 10);
      const audit = await socialModerationStore.audit({ limit: Number.isInteger(limit) ? limit : 100 });
      return sendJSON(response, 200, { ok: true, audit });
    }

    if (request.method === "GET" && request.url === "/social/moderation/rules") {
      authorizeModerator(request);
      const rules = await socialModerationStore.rules();
      return sendJSON(response, 200, { ok: true, rules });
    }

    if (request.method === "POST" && request.url === "/social/moderation/rules") {
      const actorRole = authorizeModerator(request);
      const payload = validateCommunityRulesPayload(await readJSON(request), actorRole);
      const rules = await socialModerationStore.updateRules(payload);
      return sendJSON(response, 200, { ok: true, rules });
    }

    if (request.method === "POST" && request.url === "/social/moderation/ban") {
      const actorRole = authorizeModerator(request);
      const payload = validateBanPayload(await readJSON(request), actorRole, true);
      const ban = await socialModerationStore.banUser(payload);
      return sendJSON(response, 200, { ok: true, ban });
    }

    if (request.method === "POST" && request.url === "/social/moderation/unban") {
      const actorRole = authorizeModerator(request);
      const payload = validateBanPayload(await readJSON(request), actorRole, false);
      const ban = await socialModerationStore.banUser(payload);
      return sendJSON(response, 200, { ok: true, ban });
    }

    if (request.method === "POST" && request.url === "/social/bets/register") {
      const payload = validateBetRegistrationPayload(await readJSON(request));
      const result = await betSettlementStore.register(payload);
      return sendJSON(response, 200, { ok: true, result: publicBet(result) });
    }

    if (request.method === "POST" && request.url === "/social/leaderboard/profile") {
      const payload = validateLeaderboardProfilePayload(await readJSON(request));
      const result = await betSettlementStore.syncProfile(payload);
      return sendJSON(response, 200, { ok: true, result: publicLeaderboardProfile(result) });
    }

    if (request.method === "GET" && new URL(request.url, "http://localhost").pathname === "/social/leaderboard") {
      const url = new URL(request.url, "http://localhost");
      const limit = Number.parseInt(url.searchParams.get("limit") ?? "50", 10);
      const currentUserRecordName = optionalString(url.searchParams.get("userRecordName")) ?? "";
      const leaderboard = await betSettlementStore.leaderboard({
        limit: Number.isInteger(limit) ? limit : 50,
        currentUserRecordName
      });
      return sendJSON(response, 200, { ok: true, leaderboard });
    }

    if (request.method === "POST" && request.url === "/social/bets/settle") {
      const actorRole = authorizeModerator(request);
      const payload = validateBetSettlementPayload(await readJSON(request), actorRole);
      const result = await betSettlementStore.settle(payload);
      return sendJSON(response, 200, { ok: true, result: publicBet(result) });
    }

    if (request.method === "POST" && request.url === "/ingest/snapshot") {
      // Snapshot ingest is authoritative — only trusted proxies (or the API
      // Tennis WebSocket forwarder) should call it. Same admin token guards
      // moderation actions and bet settlement; the intent is the same:
      // server-side authority beats client-side claims.
      authorizeModerator(request);
      const payload = validateSnapshotPayload(await readJSON(request));
      const result = await liveIngestionService.ingestFrame(payload.snapshot, { source: payload.source });
      return sendJSON(response, 200, { ok: true, result });
    }

    if (request.method === "POST" && request.url === "/ingest/drain") {
      authorizeModerator(request);
      const result = await liveIngestionService.drainOnce();
      return sendJSON(response, 200, { ok: true, result: { sent: result.sent.length, failed: result.failed.length, pending: result.pending } });
    }

    if (request.method === "GET" && request.url.startsWith("/matches/") && request.url.endsWith("/score-history")) {
      const matchKey = extractMatchKey(request.url);
      const history = await scoreHistoryStore.history(matchKey);
      return sendJSON(response, 200, { ok: true, matchKey, events: history });
    }

    if (request.method === "GET" && request.url === "/push/queue") {
      authorizeModerator(request);
      const snapshot = await pushEventQueue.snapshot();
      const pending = await pushEventQueue.listPending({ limit: 50 });
      return sendJSON(response, 200, { ok: true, snapshot, pending });
    }

    return sendJSON(response, 404, { ok: false, error: "Not found" });
  } catch (error) {
    const statusCode = error.statusCode ?? 500;
    return sendJSON(response, statusCode, {
      ok: false,
      error: statusCode >= 500 ? "Internal server error" : error.message
    });
  }
});

server.listen(port, () => {
  console.log(`Match Point backend listening on http://localhost:${port}`);
});

function parseAllowedOrigins(raw) {
  if (!raw) return new Set();
  return new Set(
    raw
      .split(",")
      .map(value => value.trim())
      .filter(Boolean)
  );
}

function applyCORSHeaders(request, response) {
  const origin = request.headers.origin;
  if (!origin) return;
  if (!allowedOrigins.has(origin)) return;
  response.setHeader("access-control-allow-origin", origin);
  response.setHeader("access-control-allow-methods", "GET, POST, OPTIONS");
  response.setHeader("access-control-allow-headers", "content-type, authorization");
  response.setHeader("access-control-max-age", "600");
  response.setHeader("vary", "Origin");
}

function clientIP(request) {
  // Trust the closest proxy hop only. If you put this behind a CDN, terminate
  // X-Forwarded-For at the edge and read it from a single trusted header.
  const forwarded = request.headers["x-forwarded-for"];
  if (typeof forwarded === "string" && forwarded.length > 0) {
    return forwarded.split(",")[0].trim();
  }
  return request.socket.remoteAddress ?? "unknown";
}

function createRateLimiter({ windowMs, max }) {
  const hits = new Map();

  // Periodic sweep so the Map doesn't grow without bound from clients that
  // never come back. Cheap relative to the request hot path.
  const sweepHandle = setInterval(() => {
    const cutoff = Date.now() - windowMs;
    for (const [ip, timestamps] of hits) {
      const fresh = timestamps.filter(ts => ts > cutoff);
      if (fresh.length === 0) {
        hits.delete(ip);
      } else {
        hits.set(ip, fresh);
      }
    }
  }, Math.max(windowMs, 30_000));
  sweepHandle.unref?.();

  return {
    windowMs,
    allow(ip) {
      const now = Date.now();
      const cutoff = now - windowMs;
      const existing = hits.get(ip) ?? [];
      const fresh = existing.filter(ts => ts > cutoff);
      if (fresh.length >= max) {
        hits.set(ip, fresh);
        return false;
      }
      fresh.push(now);
      hits.set(ip, fresh);
      return true;
    }
  };
}

function validatePayload(payload) {
  const action = requireString(payload.action, "action");
  if (!["register", "unregister"].includes(action)) {
    throw badRequest("action must be register or unregister");
  }

  const deviceToken = requireString(payload.deviceToken, "deviceToken");
  if (!/^[a-fA-F0-9]{32,256}$/.test(deviceToken)) {
    throw badRequest("deviceToken must be a hex APNs token");
  }

  return {
    action,
    reason: optionalString(payload.reason) ?? "unspecified",
    deviceToken: deviceToken.toLowerCase(),
    platform: optionalString(payload.platform) ?? "ios",
    bundleIdentifier: requireString(payload.bundleIdentifier, "bundleIdentifier"),
    environment: optionalString(payload.environment) ?? "production",
    registeredForRemoteNotifications: Boolean(payload.registeredForRemoteNotifications),
    subscription: validateSubscription(payload.subscription)
  };
}

function validateSubscription(subscription) {
  if (subscription == null) return null;
  if (typeof subscription !== "object" || Array.isArray(subscription)) {
    throw badRequest("subscription must be an object");
  }
  return {
    schemaVersion: Number.isInteger(subscription.schemaVersion) ? subscription.schemaVersion : 1,
    preferences: objectOrEmpty(subscription.preferences),
    favorites: validateFavorites(subscription.favorites),
    eventRules: Array.isArray(subscription.eventRules) ? subscription.eventRules.filter((rule) => rule && typeof rule === "object") : [],
    backendDataPlane: subscription.backendDataPlane && typeof subscription.backendDataPlane === "object"
      ? subscription.backendDataPlane
      : null
  };
}

function validateFavorites(favorites) {
  const value = favorites && typeof favorites === "object" ? favorites : {};
  return {
    players: validateFavoriteList(value.players),
    matches: validateFavoriteList(value.matches),
    tournaments: validateFavoriteList(value.tournaments)
  };
}

function validateFavoriteList(values) {
  if (!Array.isArray(values)) return [];
  return values
    .map((entry) => {
      if (!entry || typeof entry !== "object") return null;
      const id = optionalString(entry.id);
      if (!id) return null;
      return {
        id,
        name: optionalString(entry.name) ?? "",
        kind: optionalString(entry.kind) ?? ""
      };
    })
    .filter(Boolean)
    .slice(0, 500);
}

function objectOrEmpty(value) {
  return value && typeof value === "object" && !Array.isArray(value) ? value : {};
}

function createPushDispatcher(tokenStore) {
  const downstream = makeDownstreamDispatcher();
  return async (event) => {
    const resolvedRecipients = await tokenStore.resolveRecipients(event.recipients);
    const result = await downstream.dispatch({ ...event, resolvedRecipients });
    if (Array.isArray(result?.invalidRecipients)) {
      await Promise.all(result.invalidRecipients.map((recipient) => tokenStore.deactivateDeviceToken({
        ...recipient,
        reason: "apns-invalid-token"
      })));
    }
    return result;
  };
}

function makeDownstreamDispatcher() {
  if (process.env.APNS_KEY_PATH && process.env.APNS_KEY_ID && process.env.APNS_TEAM_ID) {
    return new ApnsDispatcher();
  }
  return { dispatch: noopDispatcher };
}

function createApiTennisIngester(ingestionService) {
  if (process.env.START_API_TENNIS_INGESTER !== "true") {
    return null;
  }
  return new ApiTennisWebSocketIngester({
    ingestionService,
    url: apiTennisWebSocketURL()
  });
}

function validateBetRegistrationPayload(payload) {
  return {
    betID: requireString(payload.betID, "betID"),
    userRecordName: requireString(payload.userRecordName, "userRecordName"),
    displayName: optionalString(payload.displayName),
    avatarSymbol: optionalString(payload.avatarSymbol),
    matchKey: optionalString(payload.matchKey) ?? "",
    selection: requireString(payload.selection, "selection"),
    kind: requireString(payload.kind, "kind"),
    stake: requireInteger(payload.stake, "stake"),
    payout: requireInteger(payload.payout, "payout"),
    integrityHash: requireString(payload.integrityHash, "integrityHash"),
    createdAt: optionalString(payload.createdAt) ?? new Date().toISOString()
  };
}

function validateLeaderboardProfilePayload(payload) {
  return {
    userRecordName: requireString(payload.userRecordName, "userRecordName"),
    displayName: optionalString(payload.displayName) ?? "Fan",
    avatarSymbol: optionalString(payload.avatarSymbol) ?? "person.crop.circle.fill"
  };
}

function validateBetSettlementPayload(payload, actorRole) {
  const status = requireString(payload.status, "status");
  if (!["won", "lost", "void"].includes(status)) {
    throw badRequest("status must be won, lost, or void");
  }

  return {
    betID: requireString(payload.betID, "betID"),
    status,
    integrityHash: requireString(payload.integrityHash, "integrityHash"),
    serverSettlementID: optionalString(payload.serverSettlementID) ?? `settle:${payload.betID}:${Date.now()}`,
    actor: actorRole
  };
}

function publicBet(bet) {
  return {
    betID: bet.betID,
    status: bet.status,
    serverSettlementID: bet.serverSettlementID ?? null,
    balanceDelta: bet.balanceDelta ?? 0,
    balanceApplied: Boolean(bet.balanceApplied),
    integrityHash: bet.integrityHash
  };
}

function publicLeaderboardProfile(profile) {
  return {
    userRecordName: profile.userRecordName,
    displayName: profile.displayName,
    avatarSymbol: profile.avatarSymbol,
    updatedAt: profile.updatedAt
  };
}

function validateSnapshotPayload(payload) {
  if (!payload || typeof payload !== "object") {
    throw badRequest("payload must be an object");
  }
  const snapshot = payload.snapshot ?? payload;
  if (!snapshot || typeof snapshot !== "object") {
    throw badRequest("snapshot is required");
  }
  return {
    snapshot,
    source: optionalString(payload.source) ?? "ingest"
  };
}

function extractMatchKey(url) {
  // /matches/<key>/score-history — strip the fixed prefix/suffix and validate.
  const prefix = "/matches/";
  const suffix = "/score-history";
  if (!url.startsWith(prefix) || !url.endsWith(suffix)) {
    throw badRequest("Malformed match history URL");
  }
  const key = decodeURIComponent(url.slice(prefix.length, url.length - suffix.length));
  if (key === "" || key.includes("/")) {
    throw badRequest("Invalid match key");
  }
  return key;
}

function validateReportPayload(payload) {
  return {
    postID: requireString(payload.postID, "postID"),
    matchKey: optionalString(payload.matchKey) ?? "",
    reason: optionalString(payload.reason) ?? "user-report",
    userRecordName: requireString(payload.userRecordName, "userRecordName"),
    createdAt: optionalString(payload.createdAt) ?? new Date().toISOString()
  };
}

function validateModerationActionPayload(payload, actorRole) {
  const action = requireString(payload.action, "action");
  if (!["pin", "unpin", "hide", "unhide"].includes(action)) {
    throw badRequest("action must be pin, unpin, hide, or unhide");
  }

  return {
    postID: requireString(payload.postID, "postID"),
    matchKey: optionalString(payload.matchKey) ?? "",
    action,
    actorRecordName: requireString(payload.actorRecordName, "actorRecordName"),
    actorRole,
    createdAt: optionalString(payload.createdAt) ?? new Date().toISOString()
  };
}

function validateCommunityRulesPayload(payload, actorRole) {
  if (!Array.isArray(payload.rules)) {
    throw badRequest("rules must be an array");
  }

  const rules = payload.rules
    .map((rule) => optionalString(rule))
    .filter(Boolean)
    .slice(0, 20);

  if (rules.length === 0) {
    throw badRequest("rules cannot be empty");
  }

  return {
    rules,
    actorRecordName: requireString(payload.actorRecordName, "actorRecordName"),
    actorRole,
    createdAt: optionalString(payload.createdAt) ?? new Date().toISOString()
  };
}

function validateBanPayload(payload, actorRole, isActive) {
  return {
    userRecordName: requireString(payload.userRecordName, "userRecordName"),
    reason: optionalString(payload.reason) ?? (isActive ? "moderation-ban" : "moderation-unban"),
    isActive,
    actorRecordName: requireString(payload.actorRecordName, "actorRecordName"),
    actorRole,
    createdAt: optionalString(payload.createdAt) ?? new Date().toISOString()
  };
}

function authorizeModerator(request) {
  const expectedToken = process.env.MODERATION_ADMIN_TOKEN;
  if (!expectedToken) {
    throw unauthorized("MODERATION_ADMIN_TOKEN is not configured");
  }

  const authorization = request.headers.authorization ?? "";
  const token = authorization.startsWith("Bearer ") ? authorization.slice("Bearer ".length) : "";
  if (token !== expectedToken) {
    throw unauthorized("Moderator token is invalid");
  }

  return process.env.MODERATION_ADMIN_ROLE ?? "admin";
}

function authorizationBearer(request) {
  const authorization = request.headers.authorization ?? "";
  return authorization.startsWith("Bearer ") ? authorization.slice("Bearer ".length).trim() : "";
}

function requireString(value, field) {
  if (typeof value !== "string" || value.trim() === "") {
    throw badRequest(`${field} is required`);
  }
  return value.trim();
}

function optionalString(value) {
  return typeof value === "string" && value.trim() !== "" ? value.trim() : undefined;
}

function requireInteger(value, field) {
  if (!Number.isInteger(value)) {
    throw badRequest(`${field} must be an integer`);
  }
  return value;
}

function badRequest(message) {
  const error = new Error(message);
  error.statusCode = 400;
  return error;
}

function unauthorized(message) {
  const error = new Error(message);
  error.statusCode = 401;
  return error;
}

async function readJSON(request) {
  const chunks = [];
  let size = 0;

  for await (const chunk of request) {
    size += chunk.length;
    if (size > 131_072) {
      throw badRequest("Payload too large");
    }
    chunks.push(chunk);
  }

  try {
    return JSON.parse(Buffer.concat(chunks).toString("utf8"));
  } catch {
    throw badRequest("Invalid JSON");
  }
}

function sendJSON(response, statusCode, body) {
  response.writeHead(statusCode, {
    "content-type": "application/json; charset=utf-8",
    "cache-control": "no-store"
  });
  response.end(JSON.stringify(body));
}
