const defaultRestBaseURL = "https://api.api-tennis.com/tennis/";
const defaultWebSocketURL = "wss://wss.api-tennis.com/live";
const proxyCache = new Map();
const proxyHits = new Map();
const proxyMetrics = {
  requests: 0,
  upstreamRequests: 0,
  cacheHits: 0,
  staleFallbacks: 0,
  rateLimited: 0,
  failures: 0
};

const allowedMethods = new Set([
  "get_events",
  "get_fixtures",
  "get_H2H",
  "get_live_odds",
  "get_livescore",
  "get_odds",
  "get_players",
  "get_standings",
  "get_tournaments"
]);

export const apiTennisDataPlaneContract = {
  schemaVersion: 1,
  restProxy: {
    path: "/tennis",
    allowedMethods: [...allowedMethods].sort(),
    secretPolicy: "server-side-api-key-only",
    cache: {
      liveSeconds: 5,
      fixturesSeconds: 300,
      rankingSeconds: 3600,
      staleFallbackSeconds: 900
    },
    rateLimit: {
      scope: "client-ip",
      defaultWindowMs: 60_000,
      defaultMax: 120
    }
  },
  websocket: {
    path: "/live",
    upstream: "api-tennis.websocket",
    secretPolicy: "server-side-api-key-only"
  },
  productionRequirements: [
    "API_TENNIS_KEY",
    "HTTPS backend URL configured in the app",
    "WSS backend URL configured in the app for live stream",
    "Redis/Postgres for durable production push and ingestion",
    "APNs credentials for remote push"
  ]
};

export function productionReadiness(env = process.env) {
  const apiKeyConfigured = Boolean(apiKey(env));
  const restProxyConfigured = Boolean(validURL(env.API_TENNIS_REST_URL ?? defaultRestBaseURL, ["https"]));
  const websocketConfigured = Boolean(validURL(env.API_TENNIS_WS_URL ?? defaultWebSocketURL, ["wss"]));
  const apnsConfigured = Boolean(env.APNS_KEY_PATH && env.APNS_KEY_ID && env.APNS_TEAM_ID);
  const postgresConfigured = Boolean(env.DATABASE_URL);
  const redisConfigured = Boolean(env.REDIS_URL);
  const ingesterEnabled = env.START_API_TENNIS_INGESTER === "true";

  return {
    apiTennis: {
      apiKeyConfigured,
      restProxyConfigured,
      websocketConfigured,
      ingesterEnabled
    },
    infrastructure: {
      apnsConfigured,
      postgresConfigured,
      redisConfigured
    },
    contract: {
      schemaVersion: apiTennisDataPlaneContract.schemaVersion,
      allowedMethodCount: allowedMethods.size,
      cacheEnabled: env.API_TENNIS_PROXY_CACHE_DISABLED !== "true",
      rateLimitEnabled: env.API_TENNIS_PROXY_RATE_LIMIT_DISABLED !== "true"
    },
    readyForLiveDataValidation: apiKeyConfigured && restProxyConfigured,
    readyForAlwaysOnLiveIngestion: apiKeyConfigured && websocketConfigured && ingesterEnabled,
    readyForProductionPush: apiKeyConfigured && websocketConfigured && ingesterEnabled && apnsConfigured && postgresConfigured && redisConfigured
  };
}

export function buildAPITennisURL(incomingURL, env = process.env) {
  const source = new URL(incomingURL, "http://match-point.local");
  const method = source.searchParams.get("method")?.trim() ?? "";
  if (!allowedMethods.has(method)) {
    throw httpError(400, "Unsupported API Tennis method");
  }

  const key = apiKey(env);
  if (!key) {
    throw httpError(503, "API_TENNIS_KEY is not configured");
  }

  const baseURL = env.API_TENNIS_REST_URL ?? defaultRestBaseURL;
  const target = validURL(baseURL, ["https"]);
  if (!target) {
    throw httpError(503, "API_TENNIS_REST_URL must be an https URL");
  }

  source.searchParams.forEach((value, name) => {
    if (name.toLowerCase() !== "apikey") {
      target.searchParams.append(name, value);
    }
  });
  target.searchParams.set("APIkey", key);
  return target;
}

export async function handleAPITennisProxy(request, response, { env = process.env, fetchImpl = fetch } = {}) {
  const target = buildAPITennisURL(request.url, env);
  proxyMetrics.requests += 1;

  if (!allowProxyRequest(request, env)) {
    proxyMetrics.rateLimited += 1;
    response.writeHead(429, {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
      "retry-after": String(Math.ceil(proxyRateLimitWindowMs(env) / 1000))
    });
    response.end(JSON.stringify({ ok: false, error: "Too many API Tennis proxy requests" }));
    logProxyEvent("rate_limited", request, target, { statusCode: 429 });
    return;
  }

  const cacheKey = cacheKeyFor(target);
  const cached = getCached(cacheKey, env);
  if (cached?.fresh) {
    proxyMetrics.cacheHits += 1;
    writeCachedResponse(response, cached.entry, "HIT");
    logProxyEvent("cache_hit", request, target, { statusCode: cached.entry.status, ageMs: Date.now() - cached.entry.storedAt });
    return;
  }

  const timeoutMs = Number(env.API_TENNIS_PROXY_TIMEOUT_MS ?? 12_000);
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), Math.max(timeoutMs, 1_000));

  try {
    proxyMetrics.upstreamRequests += 1;
    const upstream = await fetchImpl(target, {
      method: "GET",
      headers: {
        "accept": "application/json",
        "user-agent": "MatchPointBackend/api-tennis-proxy"
      },
      signal: controller.signal
    });
    const body = await upstream.text();
    const contentType = upstream.headers.get("content-type") ?? "application/json; charset=utf-8";

    if (upstream.ok && cacheEnabled(env)) {
      saveCached(cacheKey, {
        status: upstream.status,
        contentType,
        body,
        storedAt: Date.now()
      });
    } else if (isFallbackStatus(upstream.status)) {
      const stale = getCached(cacheKey, env, { allowStale: true });
      if (stale?.entry) {
        proxyMetrics.staleFallbacks += 1;
        writeCachedResponse(response, stale.entry, "STALE", "upstream-status");
        logProxyEvent("stale_fallback", request, target, {
          upstreamStatus: upstream.status,
          statusCode: stale.entry.status
        });
        return;
      }
    }

    response.writeHead(upstream.status, {
      "content-type": contentType,
      "cache-control": cacheControlFor(target.searchParams.get("method") ?? "", env),
      "x-match-point-cache": "MISS"
    });
    response.end(body);
    logProxyEvent("upstream_response", request, target, { statusCode: upstream.status });
  } catch (error) {
    const stale = getCached(cacheKey, env, { allowStale: true });
    if (stale?.entry) {
      proxyMetrics.staleFallbacks += 1;
      writeCachedResponse(response, stale.entry, "STALE", error.name === "AbortError" ? "timeout" : "error");
      logProxyEvent("stale_fallback", request, target, {
        reason: error.name === "AbortError" ? "timeout" : "error",
        statusCode: stale.entry.status
      });
      return;
    }
    proxyMetrics.failures += 1;
    if (error.name === "AbortError") {
      throw httpError(504, "API Tennis request timed out");
    }
    throw error;
  } finally {
    clearTimeout(timer);
  }
}

export function apiTennisProxyStats() {
  return {
    ...proxyMetrics,
    cacheEntries: proxyCache.size,
    rateLimitBuckets: proxyHits.size
  };
}

export function apiTennisWebSocketURL(env = process.env) {
  const target = validURL(env.API_TENNIS_WS_URL ?? defaultWebSocketURL, ["wss"]);
  return target?.toString();
}

function cacheEnabled(env) {
  return env.API_TENNIS_PROXY_CACHE_DISABLED !== "true";
}

function ttlForMethod(method, env) {
  switch (method) {
    case "get_livescore":
    case "get_live_odds":
      return Number(env.API_TENNIS_LIVE_CACHE_TTL_MS ?? 5_000);
    case "get_fixtures":
    case "get_H2H":
    case "get_odds":
      return Number(env.API_TENNIS_FIXTURE_CACHE_TTL_MS ?? 300_000);
    case "get_standings":
    case "get_players":
    case "get_tournaments":
    case "get_events":
      return Number(env.API_TENNIS_REFERENCE_CACHE_TTL_MS ?? 3_600_000);
    default:
      return 0;
  }
}

function staleTtlMs(env) {
  return Number(env.API_TENNIS_STALE_FALLBACK_TTL_MS ?? 900_000);
}

function getCached(cacheKey, env, options = {}) {
  if (!cacheEnabled(env)) return null;
  const entry = proxyCache.get(cacheKey);
  if (!entry) return null;
  const age = Date.now() - entry.storedAt;
  const method = entry.method ?? "";
  const fresh = age <= ttlForMethod(method, env);
  if (fresh) return { entry, fresh: true };
  if (options.allowStale && age <= ttlForMethod(method, env) + staleTtlMs(env)) {
    return { entry, fresh: false };
  }
  return null;
}

function saveCached(cacheKey, entry) {
  const url = new URL(cacheKey);
  proxyCache.set(cacheKey, {
    ...entry,
    method: url.searchParams.get("method") ?? ""
  });
}

function writeCachedResponse(response, entry, cacheStatus, reason = "") {
  response.writeHead(entry.status, {
    "content-type": entry.contentType,
    "cache-control": "no-store",
    "x-match-point-cache": cacheStatus,
    ...(reason ? { "x-match-point-fallback": reason } : {})
  });
  response.end(entry.body);
}

function cacheControlFor(method, env) {
  if (!cacheEnabled(env)) return "no-store";
  const ttlSeconds = Math.max(0, Math.floor(ttlForMethod(method, env) / 1000));
  return ttlSeconds > 0 ? `private, max-age=${ttlSeconds}` : "no-store";
}

function cacheKeyFor(target) {
  const copy = new URL(target.toString());
  copy.searchParams.delete("APIkey");
  copy.searchParams.sort();
  return copy.toString();
}

function isFallbackStatus(status) {
  return status === 429 || status >= 500;
}

function allowProxyRequest(request, env) {
  if (env.API_TENNIS_PROXY_RATE_LIMIT_DISABLED === "true") return true;
  const ip = clientIP(request);
  const now = Date.now();
  const windowMs = proxyRateLimitWindowMs(env);
  const max = Number(env.API_TENNIS_PROXY_RATE_LIMIT_MAX ?? 120);
  const cutoff = now - windowMs;
  const fresh = (proxyHits.get(ip) ?? []).filter((timestamp) => timestamp > cutoff);
  if (fresh.length >= max) {
    proxyHits.set(ip, fresh);
    return false;
  }
  fresh.push(now);
  proxyHits.set(ip, fresh);
  return true;
}

function proxyRateLimitWindowMs(env) {
  return Number(env.API_TENNIS_PROXY_RATE_LIMIT_WINDOW_MS ?? 60_000);
}

function clientIP(request) {
  const forwarded = request.headers?.["x-forwarded-for"];
  if (typeof forwarded === "string" && forwarded.length > 0) {
    return forwarded.split(",")[0].trim();
  }
  return request.socket?.remoteAddress ?? "unknown";
}

function logProxyEvent(event, request, target, details = {}) {
  const method = target.searchParams.get("method") ?? "unknown";
  console.info(JSON.stringify({
    event,
    scope: "api-tennis-proxy",
    method,
    path: new URL(request.url, "http://match-point.local").pathname,
    ...details
  }));
}

function apiKey(env) {
  return (env.API_TENNIS_KEY ?? env.MATCH_POINT_API_TENNIS_KEY ?? "").trim();
}

function validURL(raw, allowedSchemes) {
  try {
    const url = new URL(raw);
    if (!allowedSchemes.includes(url.protocol.replace(":", ""))) return null;
    if (!url.hostname) return null;
    return url;
  } catch {
    return null;
  }
}

function httpError(statusCode, message) {
  const error = new Error(message);
  error.statusCode = statusCode;
  return error;
}
