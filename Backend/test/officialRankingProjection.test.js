import assert from "node:assert/strict";
import test from "node:test";

import {
  buildOfficialRankingProjectionURL,
  officialRankingReadiness
} from "../src/officialRankingProjection.js";

test("official ranking readiness requires endpoint and API key", () => {
  assert.equal(officialRankingReadiness({}).readyForOfficialProjection, false);
  assert.equal(officialRankingReadiness({
    OFFICIAL_RANKING_PROJECTION_URL: "https://rankings.example.com/live-projection"
  }).readyForOfficialProjection, false);
  assert.equal(officialRankingReadiness({
    OFFICIAL_RANKING_PROJECTION_URL: "https://rankings.example.com/live-projection",
    OFFICIAL_RANKING_API_KEY: "ranking-key"
  }).readyForOfficialProjection, true);
});

test("official ranking proxy accepts only https upstream URL", () => {
  assert.throws(
    () => buildOfficialRankingProjectionURL(
      "/rankings/live-projection?tour=ATP",
      { OFFICIAL_RANKING_PROJECTION_URL: "http://rankings.example.com/live-projection" }
    ),
    /OFFICIAL_RANKING_PROJECTION_URL must be an https URL/
  );
});

test("official ranking proxy forwards only allowlisted query parameters", () => {
  const url = buildOfficialRankingProjectionURL(
    "/rankings/live-projection?tour=ATP&tournament_key=wimbledon&player_key=p1&api_key=client-leak",
    {
      OFFICIAL_RANKING_PROJECTION_URL: "https://rankings.example.com/live-projection?format=match-point"
    }
  );

  assert.equal(url.origin, "https://rankings.example.com");
  assert.equal(url.pathname, "/live-projection");
  assert.equal(url.searchParams.get("format"), "match-point");
  assert.equal(url.searchParams.get("tour"), "ATP");
  assert.equal(url.searchParams.get("tournament_key"), "wimbledon");
  assert.equal(url.searchParams.get("player_key"), "p1");
  assert.equal(url.searchParams.has("api_key"), false);
});
