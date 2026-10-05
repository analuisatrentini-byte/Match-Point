# Refactor Plan

The largest Swift files were split by feature domain in build-verified steps.

## Target Structure

- `Match Point/Matches/`
  - `MatchesView.swift`
  - `MatchHeroCard.swift`
  - `MatchDetailView.swift`
  - `MatchTimelineAndScoreboard.swift`
  - `MatchIntelligenceCore.swift`
  - `BetSettlementEngine.swift`
- `Match Point/Social/`
  - `SocialViews.swift`
  - `SocialEventGenerator.swift`
- `Match Point/Profile/`
  - `PlayersView.swift`
  - `FavoritesView.swift`
  - `ProfileView.swift`
  - `PlayerDetailView.swift`
- `Match Point/Providers/`
  - `TennisDTOs.swift`
  - `TennisAPIUpserts.swift`
- `Match Point/Ranking/`
  - `RankingsView.swift`
  - `RankingProjectionEngine.swift`
- `Match Point/Live/`
  - `LiveTrackerView.swift`
- `Match Point/ForYou/`
  - `ForYouView.swift`
  - `FeedInsights.swift`
- `Match Point/Tournaments/`
  - `ToursView.swift`
  - `TournamentDetailView.swift`
- `Match Point/Shared/`
  - `FavoriteButton.swift`
  - `SyncFeedbackBanner.swift`
- `Match Point/Preferences/`
  - `ExperiencePreferences.swift`

## Safe Order

1. Done: moved `LiveTrackerView` from `Views.swift` to `Live/LiveTrackerView.swift`.
2. Done: moved top-level tab views out of `Views.swift` by domain.
3. Done: moved detail views and scoreboard/timeline helpers out of `DetailViews.swift`.
4. Done: moved feed, ranking, betting and social intelligence out of `MatchIntelligence.swift`.
5. Done: moved API DTOs and SwiftData upserts out of `TennisAPI.swift`.
6. Done: promoted shared UI helpers that were previously private in large files.
7. Done: build passed after the split.

## Guardrails

- Do not rename public SwiftData models during this refactor.
- Do not change `@Query` predicates while moving files.
- Keep `@MainActor` behavior unchanged.
- Add one focused test before moving any non-view business logic.
