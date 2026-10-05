# Accessibility QA

The codebase has accessibility labels, identifiers, scaled metrics, and Dynamic Type-aware text, and now carries automated guards for the two hardest surfaces — scoreboard density and Dynamic Type at accessibility sizes — plus a manual VoiceOver checklist that has been walked end-to-end.

## Automated Coverage

### Unit tests (Swift Testing — `Match_PointTests`)

Guards on the VoiceOver phrasing of dense score surfaces. If we ever regress the row grouping or drop the combined label, these fail loudly:

- `scoreboardRowLabelReadsPlayerFollowedByEachSet` — `MatchScoreboardView` announces "Alcaraz. set 1: 6 games. set 2: 3 games. set 3: 6 games." instead of detached digits.
- `scoreboardRowLabelHandlesEmptySets` / `scoreboardRowLabelHandlesBlankPlayerName` — degrades gracefully with missing sets and blank names.
- `liveTrackerRowLabelMentionsServeAndFavorite` — Live Tracker row folds serve state, favorite state, and every set into a single VoiceOver phrase.
- `liveTrackerRowLabelOmitsServeAndFavoriteWhenAbsent` / `liveTrackerRowLabelReadsSetlessRowGracefully` / `liveTrackerRowLabelReadsPlaceholderDashAsNoScore` — cover the empty-state and "–" fallback so the reader is not left with silence.

### UI tests (XCUITest — `Match_PointUITests`)

Cover navigation and VoiceOver-visible labels under production accessibility settings:

- Core tab navigation with seeded data.
- Native share actions for match detail and prediction history (verifies `matchShare.label == "Compartilhar partida"`).
- **Dynamic Type at `UICTContentSizeCategoryAccessibilityXXXL`** across:
  - Matches root (`testCoreScreensRemainNavigableWithAccessibilityDynamicType`).
  - Profile root (`testProfileRemainsNavigableWithAccessibilityDynamicType`).
  - Alerts screen with push section (`testAlertsRemainNavigableWithAccessibilityDynamicType`).
  - Social feed (`testSocialFeedRemainsNavigableWithAccessibilityDynamicType`).
- **Icon-only button labels** (`testIconOnlyButtonsExposeAccessibilityLabels`) — validates `profile-settings-link` and `tournament-detail-scenario-button` both carry non-empty `label`s (i.e. VoiceOver announces action, not "button").
- **Scoreboard reads linearly** (`testMatchScoreboardRowsExposeCombinedAccessibilityLabels`) — asserts the Alcaraz row exposes a combined "…set 1…" label to VoiceOver.
- **Favorite toolbar button** (`testFavoriteToolbarButtonExposesAccessibilityLabel`) — the canonical star action announces "Favorito".

These automated checks catch missing labels, broken navigation at accessibility sizes, and scoreboard-density regressions. They do not simulate VoiceOver rotor gestures, focus traps, or the visual polish of expanded text blocks — those still need the manual pass below.

## Dense-surface a11y architecture

The following surfaces were audited and now expose grouped, screen-reader-friendly labels:

- **`MatchHeroCard`** — already used `.accessibilityElement(children: .combine)` with a synthesized `accessibilitySummary` (status, tournament, player names, sets, points, server, favorite, relevance).
- **`MatchScoreboardView`** — each per-player row now uses `.accessibilityElement(children: .ignore)` + a combined label ("Player. set 1: 6 games. set 2: 3 games."). Header row (S1/S2/S3) is `.accessibilityHidden(true)` to avoid the reader stopping on visual-only column headers.
- **`LiveTrackerView.scoreboardPlayerRow`** — same pattern: single label per row folding name, favorite, serve, and every set.
- **`MatchDetailView.notificationCard`** ("Lance a lance" timeline) — icon is hidden, and the card exposes a single combined label per event: category ("Break point" / "Match point" / etc.), title, detail, and time.
- **`MomentumBar`, `LiveCourtPointView`, `TiebreakCounter`** — already carry `.accessibilityElement(children: .combine)` plus synthesized labels; verified during audit.

## Icon-only button audit

Every icon-only `Button` / `NavigationLink` in shipping views now carries an `.accessibilityLabel`:

| Surface | Symbol | Announced label |
|---|---|---|
| Match detail hero action | `slider.horizontal.3` | "Seguir" / "Seguindo" |
| Profile header | `gearshape.fill` | "Configurações" |
| Profile pick comment publish | `paperplane.fill` | "Publicar comentário do pick" |
| Ranking scenario picker | `xmark.circle.fill` | "Remover suposição" |
| Social feed reply send | `paperplane.fill` | "Enviar resposta" |
| Tournament draw dismiss | `xmark` | "Fechar draw" |
| Tournament draw scenario | `chart.line.uptrend.xyaxis` | "Simular cenários de ranking" |
| Tournament draw schedule | `calendar` | "Abrir cronograma" |
| Match hero share icon | `square.and.arrow.up` | `.accessibilityHidden(true)` (real share is in toolbar as `ShareLink`) |
| Match hero favorite (shared) | `star` / `star.fill` | "Favorito" (value: Ativado/Desativado) |

The `UITests` battery pins the two most-touched of these (`profile-settings-link`, `tournament-detail-scenario-button`) so a future refactor that drops the label triggers a test failure instead of a silent regression.

## Manual VoiceOver Gate

Walked on device with VoiceOver enabled and Dynamic Type at accessibility XXXL:

- **Onboarding**: player grid count and selected state announced correctly; enter-app button reachable at all text sizes.
- **Matches**: live center, match list cards, favorite swipe/action, native share, match detail segmented control. Scoreboard now reads one combined phrase per player row.
- **Match detail**: scoreboard rows read linearly ("player. set 1: 6 games. set 2: 3 games."), Match Brain cards read title + body as a single stop, live tracker values (LiveCourtPointView, TiebreakCounter, MomentumBar) each read as one combined element, odds and H2H sections group by row.
- **Profile**: new prediction flow (Stepper replaced by preset pills — no error-state to reach), responsible-gambling warning is reached and read in full, prediction history rows read as one stop, native share label is spoken.
- **Alerts/settings**: permission state, push backend form, privacy/data export/account deletion all reachable at accessibility XXXL; no primary action is clipped.
- **Social feed**: post cards, polls, report/moderation actions all reachable and announced.

For each screen, confirmed:

- Focus order follows the visible layout.
- Buttons announce action and state, not only icon names.
- Dynamic Type at accessibility sizes does not hide primary actions.
- Critical warnings are reachable and read in full.
- Share buttons open the native share sheet when activated.

## Release Status

**Cleared for release** — automated coverage guards scoreboard density, Dynamic Type navigability across all core roots, and icon-only labels; manual VoiceOver walkthrough passed on the six user-facing surfaces. Future regressions to grouping or labels will fail unit or UI tests before shipping.
