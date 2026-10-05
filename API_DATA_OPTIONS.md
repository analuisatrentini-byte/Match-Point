# Tennis live data options

Last checked: 2026-05-30.

## Recommendation

Use the current provider adapter as the stable integration boundary and prioritize API Tennis or AllSportsAPI for the first production live-score experience. Both align with the app's existing API-Tennis/WebSocket architecture and support tennis-specific live score use cases without requiring an enterprise sales cycle.

Avoid scraping official sites or consumer apps. It is brittle, can violate terms, and is not a scalable source for live in-app experiences.

## Options

| Provider | Fit | Pricing signal | Notes |
| --- | --- | --- | --- |
| API Tennis | Strong fit for the current codebase | Public docs show REST endpoints and WebSocket live documentation, but pricing was not clearly published in the checked docs. | The app already supports `api.api-tennis.com` REST plus `wss://wss.api-tennis.com/live`; keep it as the primary live provider when the account key supports WebSocket. |
| AllSportsAPI Tennis | Strong MVP alternative | Plans shown at $59/month ATP, $82/month worldwide, $111/month ultimate with WebSockets Live. | Good match for live score, point-by-point, player statistics, rankings, and WebSocket live needs. |
| Goalserve Tennis | Stable paid feed | Tennis package shown at $150/month, $900/6 months, $1500/12 months. | Broader paid data feed with live score, point-by-point, stats, profiles, rankings, odds, JSON/XML. Good fallback if the product needs more packaged coverage. |
| Sportradar Tennis | Enterprise/media-grade | Pricing generally sales-led; public docs emphasize RESTful B2B API and coverage tiers rather than self-serve price. | Best for licensed, commercial-grade data and deep stats. Likely overkill for an early consumer MVP unless rights/compliance needs are strict. |
| RapidAPI wrappers for Flashscore/Sofascore/LiveScore | Useful for experimentation | Pricing varies per RapidAPI listing. | Keep behind the existing `RapidAPITennisProvider` parser profile. Treat as less stable because response shape and upstream availability can change. |

## Integration notes

- Keep live-score ingestion in `TennisAPI` and `DataSyncService`; do not let views call provider-specific APIs directly.
- Use WebSocket for live cards when available; fall back to REST polling with caching/backoff for RapidAPI-style providers.
- Preserve `externalKey` and `externalID` as the identity layer for idempotent upserts.
- Normalize dates through `TennisAPIConfiguration.timeZone` with `en_US_POSIX`.
- Do not expose raw provider errors to the user. Continue translating through `UserFacingSyncFeedback`.

## CarPlay assessment

CarPlay is possible only as a dedicated CarPlay scene/template experience, not by reusing the normal SwiftUI tab directly. The live tracker card should first be split into a small view model containing players, score, set/game, status, and freshness. A future CarPlay target can render that same state with CarPlay-safe list/grid templates and strict distraction limits. Interactive betting, comments, and polls should stay out of CarPlay.

Sources checked:
- API Tennis documentation: https://api-tennis.com/documentation
- AllSportsAPI Tennis: https://allsportsapi.com/tennis-api
- Goalserve Tennis pricing: https://www.goalserve.com/enivacy-policy/sport-data-feeds/tennis-api/prices
- Sportradar Tennis docs: https://developer.sportradar.com/tennis/docs/ig-api-basics
