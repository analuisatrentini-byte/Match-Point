export function officialRankingReadiness(env = process.env) {
  const endpointConfigured = Boolean(validURL(env.OFFICIAL_RANKING_PROJECTION_URL, ["https"]));
  const apiKeyConfigured = Boolean((env.OFFICIAL_RANKING_API_KEY ?? "").trim());

  return {
    endpointConfigured,
    apiKeyConfigured,
    readyForOfficialProjection: endpointConfigured && apiKeyConfigured
  };
}

export function buildOfficialRankingProjectionURL(incomingURL, env = process.env) {
  const base = validURL(env.OFFICIAL_RANKING_PROJECTION_URL, ["https"]);
  if (!base) {
    throw httpError(503, "OFFICIAL_RANKING_PROJECTION_URL must be an https URL");
  }

  const source = new URL(incomingURL, "http://match-point.local");
  for (const key of ["tour", "tournament_key", "player_key"]) {
    const value = source.searchParams.get(key)?.trim();
    if (value) {
      base.searchParams.set(key, value);
    }
  }
  return base;
}

export async function handleOfficialRankingProjection(request, response, { env = process.env, fetchImpl = fetch } = {}) {
  const key = (env.OFFICIAL_RANKING_API_KEY ?? "").trim();
  if (!key) {
    throw httpError(503, "OFFICIAL_RANKING_API_KEY is not configured");
  }

  const target = buildOfficialRankingProjectionURL(request.url, env);
  const timeoutMs = Number(env.OFFICIAL_RANKING_TIMEOUT_MS ?? 12_000);
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), Math.max(timeoutMs, 1_000));

  try {
    const upstream = await fetchImpl(target, {
      method: "GET",
      headers: {
        "accept": "application/json",
        "authorization": `Bearer ${key}`,
        "user-agent": "MatchPointBackend/official-ranking-projection"
      },
      signal: controller.signal
    });
    const body = await upstream.text();
    response.writeHead(upstream.status, {
      "content-type": upstream.headers.get("content-type") ?? "application/json; charset=utf-8",
      "cache-control": "no-store"
    });
    response.end(body);
  } catch (error) {
    if (error.name === "AbortError") {
      throw httpError(504, "Official ranking projection request timed out");
    }
    throw error;
  } finally {
    clearTimeout(timer);
  }
}

function validURL(raw, allowedSchemes) {
  try {
    if (!raw) return null;
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
