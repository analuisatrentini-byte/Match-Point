import assert from "node:assert/strict";
import test from "node:test";

import {
  apiTennisCacheTTL,
  apiTennisDataPlaneContract,
  buildAPITennisURL,
  handleAPITennisProxy,
  normalizeAPITennisWebSocketClose,
  productionReadiness
} from "../src/apiTennisProxy.js";

test("recent fixtures use a short cache in the provider timezone, including midnight and DST", () => {
  const url = (start, stop = start) => new URL(`https://example.test/tennis?method=get_fixtures&date_start=${start}&date_stop=${stop}`);
  const now = new Date("2026-11-23T02:00:00Z"); // Still November 22 in New York.
  assert.equal(apiTennisCacheTTL(url("2026-11-22"), {}, now), 15_000);
  assert.equal(apiTennisCacheTTL(url("2026-11-21"), {}, now), 15_000);
  assert.equal(apiTennisCacheTTL(url("2026-11-23"), {}, now), 300_000);
  assert.equal(apiTennisCacheTTL(url("2026-10-01"), {}, now), 300_000);
  assert.equal(apiTennisCacheTTL(url("2026-11-20", "2026-11-25"), {}, now), 15_000);
  const afterDST = new Date("2026-03-09T04:30:00Z");
  assert.equal(apiTennisCacheTTL(url("2026-03-08"), {}, afterDST), 15_000);
  assert.equal(apiTennisCacheTTL(url("2026-03-07"), {}, afterDST), 300_000);
  assert.equal(apiTennisCacheTTL(url("2026-11-22"), { API_TENNIS_FIXTURE_CACHE_TTL_MS: "1000" }, now), 1000);
});

test("expired recent fixture cache fetches the completed result instead of replaying live data", async () => {
  const request = makeRequest("/tennis?method=get_fixtures&test_cache=finish");
  const env = { API_TENNIS_KEY: "test", API_TENNIS_CURRENT_FIXTURE_CACHE_TTL_MS: "1", API_TENNIS_PROXY_RATE_LIMIT_DISABLED: "true" };
  let calls = 0;
  const fetchImpl = async () => new Response(JSON.stringify({ success: 1, result: [{event_status: ++calls === 1 ? "Set 2" : "Finished"}] }), { status: 200 });
  await handleAPITennisProxy(request, makeResponse(), { env, fetchImpl });
  await new Promise(resolve => setTimeout(resolve, 10));
  const response = makeResponse();
  await handleAPITennisProxy(request, response, { env, fetchImpl });
  assert.equal(calls, 2);
  assert.equal(JSON.parse(response.body).result[0].event_status, "Finished");
  assert.equal(response.headers["x-match-point-cache"], "MISS");
});

test("API Tennis proxy builds upstream URL with server-side key only", () => {
  const url = buildAPITennisURL(
    "/tennis?method=get_livescore&timezone=America/New_York&APIkey=client-leak",
    {
      API_TENNIS_KEY: "server-key",
      API_TENNIS_REST_URL: "https://api.api-tennis.com/tennis/"
    }
  );

  assert.equal(url.origin, "https://api.api-tennis.com");
  assert.equal(url.pathname, "/tennis/");
  assert.equal(url.searchParams.get("method"), "get_livescore");
  assert.equal(url.searchParams.get("timezone"), "America/New_York");
  assert.equal(url.searchParams.get("APIkey"), "server-key");
});

test("API Tennis proxy rejects unknown methods", () => {
  assert.throws(
    () => buildAPITennisURL("/tennis?method=get_account", { API_TENNIS_KEY: "server-key" }),
    /Unsupported API Tennis method/
  );
});

test("production readiness separates data validation from full push readiness", () => {
  const partial = productionReadiness({
    API_TENNIS_KEY: "server-key"
  });
  assert.equal(partial.readyForLiveDataValidation, true);
  assert.equal(partial.readyForAlwaysOnLiveIngestion, false);
  assert.equal(partial.readyForProductionPush, false);

  const complete = productionReadiness({
    API_TENNIS_KEY: "server-key",
    START_API_TENNIS_INGESTER: "true",
    APNS_KEY_PATH: "/secure/AuthKey.p8",
    APNS_KEY_ID: "KEY123",
    APNS_TEAM_ID: "TEAM123",
    DATABASE_URL: "postgres://example",
    REDIS_URL: "redis://example"
  });
  assert.equal(complete.readyForLiveDataValidation, true);
  assert.equal(complete.readyForAlwaysOnLiveIngestion, true);
  assert.equal(complete.readyForProductionPush, true);
});

test("production contract documents the REST data plane", () => {
  assert.equal(apiTennisDataPlaneContract.restProxy.path, "/tennis");
  assert.ok(apiTennisDataPlaneContract.restProxy.allowedMethods.includes("get_livescore"));
  assert.equal(apiTennisDataPlaneContract.restProxy.secretPolicy, "server-side-api-key-only");
});

test("WebSocket proxy replaces reserved peer close codes with a valid close code", () => {
  assert.deepEqual(normalizeAPITennisWebSocketClose(1006, "socket ended"), {
    code: 1000,
    reason: Buffer.from("socket ended")
  });
  assert.equal(normalizeAPITennisWebSocketClose(1011, "upstream-error").code, 1011);
  assert.equal(normalizeAPITennisWebSocketClose(4001, "custom").code, 4001);
});

test("WebSocket proxy truncates close reasons to the protocol byte limit", () => {
  const close = normalizeAPITennisWebSocketClose(1000, "é".repeat(100));
  assert.equal(close.code, 1000);
  assert.ok(close.reason.byteLength <= 123);
  assert.equal(close.reason.toString("utf8"), "é".repeat(61));
});

test("API Tennis proxy caches successful upstream responses", async () => {
  let fetchCount = 0;
  const request = makeRequest("/tennis?method=get_livescore&timezone=America/New_York&test_cache=hit");
  const env = {
    API_TENNIS_KEY: "server-key",
    API_TENNIS_LIVE_CACHE_TTL_MS: "60000",
    API_TENNIS_PROXY_RATE_LIMIT_DISABLED: "true"
  };

  const fetchImpl = async () => {
    fetchCount += 1;
    return new Response(JSON.stringify({ ok: true, fetchCount }), {
      status: 200,
      headers: { "content-type": "application/json" }
    });
  };

  const first = makeResponse();
  await handleAPITennisProxy(request, first, { env, fetchImpl });
  const second = makeResponse();
  await handleAPITennisProxy(request, second, { env, fetchImpl });

  assert.equal(fetchCount, 1);
  assert.equal(first.statusCode, 200);
  assert.equal(second.statusCode, 200);
  assert.equal(second.headers["x-match-point-cache"], "HIT");
  assert.deepEqual(JSON.parse(second.body), { ok: true, fetchCount: 1 });
});

test("API Tennis proxy serves stale cache when upstream is unavailable", async () => {
  const request = makeRequest("/tennis?method=get_standings&event_type=ATP&test_cache=stale");
  const env = {
    API_TENNIS_KEY: "server-key",
    API_TENNIS_REFERENCE_CACHE_TTL_MS: "1",
    API_TENNIS_STALE_FALLBACK_TTL_MS: "60000",
    API_TENNIS_PROXY_RATE_LIMIT_DISABLED: "true"
  };

  const first = makeResponse();
  await handleAPITennisProxy(request, first, {
    env,
    fetchImpl: async () => new Response(JSON.stringify({ result: [{ player_name: "Cached" }] }), {
      status: 200,
      headers: { "content-type": "application/json" }
    })
  });

  await new Promise(resolve => setTimeout(resolve, 5));

  const second = makeResponse();
  await handleAPITennisProxy(request, second, {
    env,
    fetchImpl: async () => new Response("quota", { status: 429 })
  });

  assert.equal(second.statusCode, 200);
  assert.equal(second.headers["x-match-point-cache"], "STALE");
  assert.equal(second.headers["x-match-point-fallback"], "upstream-status");
  assert.deepEqual(JSON.parse(second.body), { result: [{ player_name: "Cached" }] });
});

test("API Tennis proxy applies dedicated provider rate limit", async () => {
  const env = {
    API_TENNIS_KEY: "server-key",
    API_TENNIS_PROXY_RATE_LIMIT_WINDOW_MS: "60000",
    API_TENNIS_PROXY_RATE_LIMIT_MAX: "1",
    API_TENNIS_PROXY_CACHE_DISABLED: "true"
  };

  const first = makeResponse();
  await handleAPITennisProxy(
    makeRequest("/tennis?method=get_livescore&rate_limit=one", "203.0.113.10"),
    first,
    {
      env,
      fetchImpl: async () => new Response("{}", { status: 200, headers: { "content-type": "application/json" } })
    }
  );

  const second = makeResponse();
  await handleAPITennisProxy(
    makeRequest("/tennis?method=get_livescore&rate_limit=two", "203.0.113.10"),
    second,
    {
      env,
      fetchImpl: async () => new Response("{}", { status: 200, headers: { "content-type": "application/json" } })
    }
  );

  assert.equal(first.statusCode, 200);
  assert.equal(second.statusCode, 429);
});

test("API Tennis proxy forwards the upstream retry-after on a rate limit", async () => {
  const response = makeResponse();
  await handleAPITennisProxy(makeRequest("/tennis?method=get_standings&event_type=ATP&test_retry=forward"), response, {
    env: { API_TENNIS_KEY: "server-key", API_TENNIS_PROXY_RATE_LIMIT_DISABLED: "true", API_TENNIS_PROXY_CACHE_DISABLED: "true" },
    fetchImpl: async () => new Response("quota", { status: 429, headers: { "retry-after": "120" } })
  });
  assert.equal(response.statusCode, 429);
  assert.equal(response.headers["retry-after"], "120");
});

function makeRequest(url, ip = "127.0.0.1") {
  return {
    url,
    headers: { "x-forwarded-for": ip },
    socket: { remoteAddress: ip }
  };
}

function makeResponse() {
  return {
    statusCode: 0,
    headers: {},
    body: "",
    writeHead(statusCode, headers = {}) {
      this.statusCode = statusCode;
      this.headers = Object.fromEntries(
        Object.entries(headers).map(([key, value]) => [key.toLowerCase(), String(value)])
      );
    },
    end(body = "") {
      this.body = String(body);
    }
  };
}


test("concurrent identical requests share one upstream response and recover after failure", async () => {
  const env = { API_TENNIS_KEY: "test-key", API_TENNIS_PROXY_RATE_LIMIT_DISABLED: "true", API_TENNIS_PROXY_CACHE_DISABLED: "true" };
  const request = makeRequest("/tennis?method=get_livescore&test_cache=concurrent");
  let calls = 0;
  let fail = false;
  const fetchImpl = async () => {
    calls++;
    await new Promise(resolve => setTimeout(resolve, 15));
    if (fail) throw new Error("offline");
    return new Response(JSON.stringify({ result: [1] }), { status: 200 });
  };
  const responses = Array.from({ length: 10 }, () => makeResponse());
  await Promise.all(responses.map(response => handleAPITennisProxy(request, response, { env, fetchImpl })));
  assert.equal(calls, 1);
  assert.ok(responses.every(response => response.statusCode === 200));
  fail = true;
  await assert.rejects(handleAPITennisProxy(request, makeResponse(), { env, fetchImpl }), /offline/);
  fail = false;
  await handleAPITennisProxy(request, makeResponse(), { env, fetchImpl });
  assert.equal(calls, 3);
});
