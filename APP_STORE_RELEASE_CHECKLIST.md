# Match Point App Store Release Checklist

Last updated: 2026-10-01

## Build Quality

- [ ] Run a clean Release build in Xcode with the production bundle identifier.
- [ ] Confirm Xcode shows zero errors and review any remaining warnings.
- [ ] Run unit tests: `xcodebuild test -project "Match Point.xcodeproj" -scheme "Match Point" -destination "platform=iOS Simulator,name=iPhone 16"`.
- [ ] Test on a real iPhone with notifications, widgets, Live Activity, background refresh, and deep links.
- [ ] Archive with a distribution profile and confirm the signed app entitlement has `aps-environment = production`.
- [ ] Test a fresh install with production backend configured: app should load through the backend proxy and must not request API Tennis directly.
- [ ] Test production backend configured: sync tournaments, rankings, live matches, calendar, widgets, alerts, and Match Brain.

## Backend Production Gate

- [ ] `GET /production/readiness` returns ready for live data validation.
- [ ] `GET /production/contract` returns the expected data-plane contract.
- [ ] Backend has `API_TENNIS_KEY` only in server secrets/env vars.
- [ ] Backend rate limit, cache, stale fallback, and logs are enabled.
- [ ] APNs credentials are configured before enabling remote push for public users.
- [ ] Production APNs environment is used for App Store/TestFlight builds; development push tokens stay limited to Debug/local testing.
- [ ] Redis/Postgres are configured if using durable push queue and live ingestion.

## Privacy

- [ ] `PrivacyInfo.xcprivacy` is included in the app target resources.
- [ ] In-app privacy policy matches the manifest:
  - Name: display name/profile name.
  - Email Address: email account login and recovery.
  - User ID: username, account ID, and Sign in with Apple user identity.
  - Other User Content: social posts and polls.
  - Device ID: APNs token for notifications.
  - Product Interaction: favorites, predictions, ranking/score, and app interactions.
  - UserDefaults accessed for app functionality reason `CA92.1`.
- [ ] App Store Connect privacy labels match the same categories, mark them as linked to the user where account/profile features apply, and mark tracking as `No`.
- [ ] Privacy policy support/contact URL is available before submission.
- [ ] Data export and account/data deletion screens are reachable from Settings.

## Screenshots

- [ ] Capture iPhone 6.7-inch screenshots:
  - Match Brain recommendation.
  - Meu jogador/radar.
  - Match detail/live score.
  - Favorites calendar.
  - Widget configuration or widget preview.
- [ ] Capture iPhone 6.5/5.5-inch screenshots if App Store Connect requires them for selected markets.
- [ ] Keep screenshots free of fake betting claims, real-money language, secrets, or test backend URLs.

## Monetization

- [ ] Decide before submission: free, paid upfront, or subscription.
- [ ] If subscription is enabled, add StoreKit products, paywall copy, restore purchases, terms link, and cancellation guidance.
- [ ] If no monetization yet, remove or avoid paywall/subscription copy in App Store metadata.
- [ ] Responsible gambling language must remain clear if prediction/betting-style features are visible.

## App Review Metadata

- [ ] App name, subtitle, keywords, promotional text, and description focus on "personal tennis radar for favorite players".
- [ ] Review notes explain:
  - API key is server-side only.
  - Live tennis data is served through the production backend proxy.
  - Widgets and notifications use favorite-player snapshots.
- [ ] Provide an App Review account/instructions if login is required to access core flows.
- [ ] Age rating reflects social content, predictions, and any betting-adjacent wording.

## Device Test Script

- [ ] Install fresh build on device.
- [ ] Complete onboarding and choose 3-5 favorite players.
- [ ] Configure backend URL.
- [ ] Sync data.
- [ ] Add "Meu jogador" widget and select a favorite player.
- [ ] Confirm widget opens direct player detail and match widget opens direct match detail.
- [ ] Enable notifications and trigger/simulate an upcoming/live alert.
- [ ] Confirm alert opens direct match detail.
- [ ] Toggle spoiler-free mode and verify completed scores are hidden in app/widgets/alerts.
- [ ] Open Observability and confirm widget, alert, calendar, and Match Brain return counters move.
