# Match Point Backend Proxy Contract

Production builds must not call API Tennis with a client-side API key. The app expects a backend proxy configured through:

- `MATCH_POINT_BACKEND_PROXY_URL`
- `MATCH_POINT_BACKEND_WEBSOCKET_URL`

## REST

The REST proxy should accept the same query shape the app uses for API Tennis, without `APIkey`:

```text
GET {MATCH_POINT_BACKEND_PROXY_URL}?method=get_livescore
GET {MATCH_POINT_BACKEND_PROXY_URL}?method=get_standings&event_type=ATP
GET {MATCH_POINT_BACKEND_PROXY_URL}?method=get_fixtures&date_start=YYYY-MM-DD&date_stop=YYYY-MM-DD
```

The backend injects the API Tennis key server-side and returns the API Tennis envelope unchanged:

```json
{
  "success": 1,
  "result": []
}
```

## WebSocket

The WebSocket proxy should accept the same filters without `APIkey`:

```text
wss://your-backend/live?timezone=America/New_York
wss://your-backend/live?timezone=America/New_York&match_key=123
```

The backend opens the upstream API Tennis WebSocket with the server-side API key and forwards match frames to the app.

## Security Requirements

- Store the API Tennis key only in server-side secrets.
- Never return the API Tennis key to the app.
- Rate-limit clients by user/device/IP.
- Log upstream errors without logging secrets.
- Validate allowed `method` values before proxying.

## Remote Push Device Token Endpoint

Configure this URL in the Alerts screen. The app sends APNs token lifecycle events with:

```http
POST /apns/device-token
Content-Type: application/json
```

```json
{
  "action": "register",
  "reason": "apns-token-registered",
  "deviceToken": "<apns-token>",
  "platform": "ios",
  "bundleIdentifier": "ALTB.Match-Point",
  "environment": "sandbox",
  "registeredForRemoteNotifications": true
}
```

`action` is either `register` or `unregister`.

The backend should:

- Upsert tokens by `deviceToken` + `bundleIdentifier` + `environment`.
- Mark tokens disabled on `unregister`.
- Stop sending pushes to disabled tokens.
- Remove or disable tokens when APNs reports an invalid token.
- Never send notification content unless the user has opted in.

## Social Moderation Endpoints

Sensitive moderation must run on backend/Cloud Functions, not directly in the
iOS client. The app may submit a report, but hiding/pinning content requires a
moderator/admin role on the backend.

```http
POST /social/moderation/report
Content-Type: application/json
```

```json
{
  "postID": "<post-id>",
  "matchKey": "<match-id>",
  "reason": "user-report",
  "userRecordName": "<icloud-user-record>",
  "createdAt": "<iso-date>"
}
```

```http
POST /social/moderation/action
Authorization: Bearer <moderator-token>
Content-Type: application/json
```

```json
{
  "postID": "<post-id>",
  "matchKey": "<match-id>",
  "action": "pin",
  "actorRecordName": "<moderator-user-record>",
  "createdAt": "<iso-date>"
}
```

Backend requirements:

- Validate moderator/admin roles server-side.
- Store an audit event for every report and moderation action.
- Never auto-hide solely from client-side report counts.
- Apply `pin`, `unpin`, `hide`, and `unhide` only after authorization.
- Keep moderation logs immutable or append-only in production.

## Live Ingestion + Server-Authoritative Push

The backend maintains its own match state, score history, and push queue —
the iOS client is no longer the source of truth for live pushes. Production
proxies MUST feed the ingest endpoint on every meaningful match frame.

```http
POST /ingest/snapshot
Authorization: Bearer <moderator-token>
Content-Type: application/json
```

```json
{
  "source": "api-tennis-ws",
  "snapshot": {
    "matchKey": "<external match key>",
    "tournamentKey": "<optional tournament key>",
    "player1": "<player 1 name>",
    "player2": "<player 2 name>",
    "status": "live",
    "serverName": "<player currently serving>",
    "score": "6-4, 3-2",
    "gameScore": "40-30",
    "pointScore": "40-30",
    "setNumber": 2,
    "breakPoint": true,
    "favoritePlayerKeys": ["<external player key>"],
    "capturedAt": "<iso-date>"
  }
}
```

Response:

```json
{
  "ok": true,
  "result": {
    "changed": true,
    "matchKey": "<external match key>",
    "revision": 7,
    "events": [
      { "kind": "break_point", "priority": "high", "recipients": 3 }
    ]
  }
}
```

Backend guarantees:

- Deduplicate by stable snapshot hash — repeat frames don't produce duplicate
  history rows or duplicate pushes.
- Append every non-duplicate frame to an immutable audit log
  (`GET /matches/:key/score-history`).
- Decide pushes server-side. The device does not choose *whether* to send an
  alert — it only chooses whether to *display* one (respecting opt-in). Push
  rules currently cover `match_started`, `match_finished`, `break_point`,
  `break_point_cleared`, `tiebreak_started`, `set_completed`, and
  `favorite_alert`.
- Retry transient dispatcher failures up to 3 times before marking dead.

The APNs dispatcher is pluggable. The reference implementation ships a no-op
logger (`liveIngestionService.noopDispatcher`); production replaces it with
an HTTP/2 APNs client authenticated by a `.p8` team key.

## Server-Authoritative Bets

Local `PointBet` records are for UI continuity only. Production social ranking
and balance must be settled by backend.

```http
POST /social/bets/register
Content-Type: application/json
```

```json
{
  "betID": "<uuid>",
  "userRecordName": "<icloud-user-record>",
  "matchKey": "<match-id>",
  "selection": "<selection>",
  "kind": "<bet-kind>",
  "stake": 50,
  "payout": 90,
  "integrityHash": "<sha256>",
  "createdAt": "<iso-date>"
}
```

```http
POST /social/bets/settle
Authorization: Bearer <moderator-token>
Content-Type: application/json
```

```json
{
  "betID": "<uuid>",
  "status": "won",
  "integrityHash": "<sha256>",
  "serverSettlementID": "<settlement-id>"
}
```

Backend requirements:

- Verify `integrityHash` before settlement.
- Reject client-side balance mutations as authoritative.
- Apply balance deltas once, server-side.
- Store append-only audit events for registration and settlement.
- Expose leaderboard from server-side balances, not local `UserProfile.points`.
