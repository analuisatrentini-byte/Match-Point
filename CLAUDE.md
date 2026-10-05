# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Test Commands

All commands run through Xcode CLI from the repo root:

```bash
# Build (simulator)
xcodebuild -project "Match Point.xcodeproj" \
  -scheme "Match Point" \
  -destination "platform=iOS Simulator,name=iPhone 16" \
  build

# Run unit tests
xcodebuild test \
  -project "Match Point.xcodeproj" \
  -scheme "Match Point" \
  -destination "platform=iOS Simulator,name=iPhone 16"

# Run a single named test (Swift Testing framework — use the test function name)
xcodebuild test \
  -project "Match Point.xcodeproj" \
  -scheme "Match Point" \
  -destination "platform=iOS Simulator,name=iPhone 16" \
  -only-testing "Match PointTests/Match_PointTests/tournamentAndMatchUpsertsUpdateExistingRecords"
```

Tests use the **Swift Testing** framework (`import Testing`, `@Test`, `#expect`), not XCTest. All `@Test` functions marked `@MainActor` must stay that way — they touch SwiftData and `AlertEventEngine.shared`.

## Architecture

### Data layer — SwiftData

Four `@Model` classes in `Models.swift`: `Player`, `Tournament`, `TennisMatch`, `RankingEntry`.

All models carry an `externalKey`/`externalID` string used for idempotent upserts. The upsert pattern lives as `static func upsert(from dto:, in context:) -> Model` extensions at the bottom of `TennisAPI.swift`. Every sync path goes through these — never construct and insert models directly from network data.

`TennisMatch` stores live telemetry inline as plain strings (`serverName`, `pointScore`, `gameScore`, `liveTimelinePayload`). The timeline payload is appended via `registerLiveTimelineEvent()` — a method on `TennisMatch` defined in `DetailViews.swift`.

### API layer — multi-provider adapter

`TennisAPI` is the public facade. It delegates to one of two internal providers, selected at init from `TennisAPIConfiguration.selectedProvider` (stored in UserDefaults):

- **`APITennisProvider`** — direct REST + WebSocket (`api.api-tennis.com`). The only provider that supports the WebSocket live stream. Expects `?method=…&APIkey=…` query params. Returns a typed `APIEnvelope<[T]>` wrapper.
- **`RapidAPITennisProvider`** — covers Flashscore, Sofascore, LiveScore, and TennisATPWTAITF (all via RapidAPI). Uses `X-RapidAPI-Key` / `X-RapidAPI-Host` headers. Returns freeform JSON parsed by `extractDictionaries(from:)` — a heuristic that walks arbitrary nested objects to find arrays of entity-like dictionaries. Per-provider key aliases are encoded as private `parserProfile` computed vars (e.g. `tournamentIDKeys`, `playerNameKeys`).

`TennisAPIConfiguration` is a pure `enum` namespace (no instances) backed entirely by UserDefaults. API keys and endpoint path overrides are read/written there; provider selection defaults to `.apiTennis`.

`APIClient` is a thin generic `URLSession` wrapper that JSON-decodes with `keyDecodingStrategy = .convertFromSnakeCase` and an ISO8601 date strategy.

### Sync orchestration

`DataSyncService` (`@MainActor final class`) wires `TennisAPI` → upsert extensions → `AlertEventEngine`. Three entry points: `syncTournaments()`, `syncPlayersAndRankings(tour:)`, `syncLiveMatches()`. It translates all errors into `UserFacingSyncFeedback` for display — never surface raw `Error` strings to the user.

`LiveMatchWebSocketService` (`@MainActor ObservableObject`) manages the WebSocket connection to `wss://wss.api-tennis.com/live`. Only works with the `.apiTennis` provider (it reads the API Tennis key directly). On each incoming frame it calls `fetchOrCreatePlayer/Tournament/Match` — creating stub records if the entity doesn't exist yet — then calls `AlertEventEngine.shared.processMatchUpdate(_:previous:)`.

### Intelligence & feed

`MatchIntelligence` (value type) computes a `relevanceScore` (0–120+) that drives the "For You" feed ordering. Score factors: live (+70), favorites (+40/35/25), upcoming proximity (+up to 24), top-10 ranking (+10 each player), break point active (+12).

`ForYouFeedBuilder.sections(matches:rankings:preferences:)` produces the sectioned feed: live → urgent → favorites → recommended. It applies `ExperiencePreferences.tourFilter` before scoring.

`MatchRoundResolver` infers round labels (Final/Semi-final/etc.) from a match's position in the date-sorted list of tournament matches — it does not use any round field from the API.

### Notifications

`AlertEventEngine` (singleton `@MainActor`) schedules and cancels `UNUserNotificationCenter` requests. Notification identifiers use prefixes:
- `match-point.alert.upcoming.*` — pre-match reminders, rescheduled on every sync
- `match-point.alert.event.*` — match-started / match-finished events
- `match-point.alert.snapshot.*` — UserDefaults keys storing the last known `MatchAlertSnapshot` per match

Notifications only fire when `preferences.notificationsEnabled`, the system authorization is `.authorized`, and the match relates to a favorited match/player/tournament.

`RemotePushManager` registers for APNs and is injected as `@UIApplicationDelegateAdaptor` on iOS (UIKit delegate) or a plain `@StateObject` on macOS.

### Preferences

Two singleton `ObservableObject` stores, both backed by UserDefaults JSON:
- `AlertPreferencesStore` — notification toggles and lead-time minutes
- `ExperiencePreferencesStore` — match/tour filters, favorites priority

Both are injected as `@EnvironmentObject` from `Match_PointApp` and consumed anywhere in the tree.

### Views

`ContentView` owns the 8-tab `TabView`. Views are split across three files:
- `Views.swift` — all top-level tab views (`MatchesView`, `ForYouView`, `ToursView`, `RankingsView`, `FavoritesView`, `PlayersView`) plus `MatchHeroCard`
- `DetailViews.swift` — `PlayerDetailView`, `TournamentDetailView`, `MatchDetailView` and their supporting data structures (`PlayerProfileInsights`, `MatchScoreboardData`, `MatchTimelineEvent`)
- `AlertsView.swift` — notification configuration UI
- `ProviderDiagnosticsView.swift` — provider selector, API key input, endpoint path overrides, health-check sync

`MatchesView` owns a `@StateObject private var wsService: LiveMatchWebSocketService` and drives the WebSocket connection lifetime.

## Key invariants

- **All SwiftData access is `@MainActor`**. Never fetch or mutate `ModelContext` off the main actor.
- **`externalKey`/`externalID` is the upsert identity**, not the SwiftData `id` UUID. Always match on the external key when deciding insert vs update.
- **Date parsing uses `en_US_POSIX` locale and `America/New_York` timezone** (`TennisAPIConfiguration.timeZone`). Use this everywhere you parse API date/time strings — mixing locales silently produces wrong dates.
- **WebSocket live updates and `DataSyncService` both call `AlertEventEngine.shared.processMatchUpdate`**. The engine reads `snapshotForStoredMatch` before the update and compares after — keep snapshot persistence in sync with any new match state you expose.
- **`RapidAPITennisProvider.extractDictionaries`** is deliberately greedy and heuristic. When adding support for a new provider, extend `directContainerKeys` and the `*Keys` computed vars rather than changing the core extraction logic.
