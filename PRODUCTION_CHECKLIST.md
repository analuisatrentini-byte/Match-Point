# Match Point Production Checklist

## Apple Developer

- Enable iCloud capability for the app identifier.
- Add CloudKit service.
- Register the container `iCloud.ALTB.Match-Point`.
- Create development and distribution provisioning profiles with iCloud enabled.
- Verify push notification capability if remote pushes are used.
- Request and validate CarPlay entitlement before relying on CarPlay in production.

## CloudKit

- Run the app on a real device signed with the correct profile.
- Create one comment, poll, leaderboard sync, and private prediction record.
- Confirm record types exist in CloudKit Dashboard:
  - `SocialPost`
  - `MatchPoll`
  - `LeaderboardEntry`
  - `PointBet`
  - `PollVote`
  - `SocialReport`
- Test with at least two iCloud accounts.
- Validate public database reads/writes.
- Validate private database bet sync.
- Promote schema from Development to Production before App Store/TestFlight production use.

## API

- Choose the final live tennis provider.
- Configure the production API key in the Provider screen.
- Run provider health check for tournaments, players/rankings, and live matches.
- Validate live match data fields:
  - set score
  - game score
  - point score
  - server
  - status
  - completed match state
- Confirm whether point-by-point data is available.
- Document rate limits, cost tier, and fallback behavior.

## App Store / TestFlight

- Test onboarding, favorites, Live Tracker, Match Point social, predictions, profile, and Provider readiness.
- Verify notification permission prompt timing.
- Verify iCloud account unavailable state.
- Verify empty/loading/error states without an API key.
- Add privacy copy for CloudKit/user-generated content.
- Add moderation policy for comments/reports.
- Prepare screenshots from a real iPhone or reliable simulator.
- Submit internal TestFlight first, then external beta.

## Beta / TestFlight Plan

- Internal beta 1: founder/device-only smoke test with mock data and one real API key.
- Internal beta 2: CloudKit test with at least two iCloud accounts.
- External beta 1: 20-50 tennis fans, one tournament week, feedback on Live Tracker and Match Point social.
- External beta 2: 100+ users if CloudKit, ranking, and moderation stay stable.
- Launch candidate: freeze schema, promote CloudKit schema, capture App Store screenshots, and rerun full QA pass.

## QA Pass

- iPhone small screen.
- iPhone Pro/Max.
- Light and dark mode.
- Slow network / no network.
- No iCloud account.
- Fresh install.
- Returning user with existing favorites.
- Multiple live favorite matches.
- Finished match retained briefly in Live Tracker.
- Social comments, replies, reports, pinned posts.
- Prediction settlement after match completion.
