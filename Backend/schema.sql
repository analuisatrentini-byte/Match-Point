-- Match Point backend schema.
--
-- Applied by `npm run migrate` (see scripts/migrate.js). Idempotent: every
-- statement uses IF NOT EXISTS so re-running is safe.

-- Live "current state" per match. `hash` is the dedup key computed by the
-- ingest layer — see matchSnapshotStore.js#hashSnapshot.
CREATE TABLE IF NOT EXISTS match_snapshots (
    match_key             TEXT PRIMARY KEY,
    tournament_key        TEXT NOT NULL DEFAULT '',
    player1               TEXT NOT NULL DEFAULT '',
    player2               TEXT NOT NULL DEFAULT '',
    player1_key           TEXT NOT NULL DEFAULT '',
    player2_key           TEXT NOT NULL DEFAULT '',
    status                TEXT NOT NULL DEFAULT 'unknown',
    server_name           TEXT NOT NULL DEFAULT '',
    score                 TEXT NOT NULL DEFAULT '',
    game_score            TEXT NOT NULL DEFAULT '',
    point_score           TEXT NOT NULL DEFAULT '',
    set_number            INT,
    break_point           BOOLEAN NOT NULL DEFAULT FALSE,
    favorite_player_keys  TEXT[] NOT NULL DEFAULT '{}',
    hash                  TEXT NOT NULL,
    revision              INT NOT NULL DEFAULT 0,
    captured_at           TIMESTAMPTZ NOT NULL,
    first_seen_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_seen_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS match_snapshots_status_idx ON match_snapshots (status);
CREATE INDEX IF NOT EXISTS match_snapshots_last_seen_idx ON match_snapshots (last_seen_at DESC);
ALTER TABLE match_snapshots ADD COLUMN IF NOT EXISTS player1_key TEXT NOT NULL DEFAULT '';
ALTER TABLE match_snapshots ADD COLUMN IF NOT EXISTS player2_key TEXT NOT NULL DEFAULT '';

-- Append-only audit trail. `id` is a bigserial so rows keep insertion order
-- even if the wall clock moves; `previous_hash` chains rows for tamper checks.
CREATE TABLE IF NOT EXISTS score_history (
    id             BIGSERIAL PRIMARY KEY,
    match_key      TEXT NOT NULL REFERENCES match_snapshots(match_key) ON DELETE CASCADE,
    revision       INT NOT NULL,
    source         TEXT NOT NULL DEFAULT 'ingest',
    status         TEXT NOT NULL,
    score          TEXT NOT NULL,
    game_score     TEXT NOT NULL,
    point_score    TEXT NOT NULL,
    server_name    TEXT NOT NULL,
    player1_key    TEXT NOT NULL DEFAULT '',
    player2_key    TEXT NOT NULL DEFAULT '',
    set_number     INT,
    break_point    BOOLEAN NOT NULL,
    hash           TEXT NOT NULL,
    previous_hash  TEXT,
    previous_status TEXT,
    captured_at    TIMESTAMPTZ NOT NULL,
    recorded_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS score_history_match_idx ON score_history (match_key, id);
ALTER TABLE score_history ADD COLUMN IF NOT EXISTS player1_key TEXT NOT NULL DEFAULT '';
ALTER TABLE score_history ADD COLUMN IF NOT EXISTS player2_key TEXT NOT NULL DEFAULT '';

-- Device tokens + per-token subscriptions. `subscriptions` is a JSONB array of
-- `{ type, matchKey?, tournamentKey?, playerKey? }` selectors, matching the
-- shape emitted by pushDecisionEngine.recipientsForMatch.
CREATE TABLE IF NOT EXISTS device_registry (
    id                BIGSERIAL PRIMARY KEY,
    device_token      TEXT NOT NULL,
    bundle_identifier TEXT NOT NULL,
    environment       TEXT NOT NULL DEFAULT 'production',
    platform          TEXT NOT NULL DEFAULT 'ios',
    user_record_name  TEXT,
    subscriptions     JSONB NOT NULL DEFAULT '[]'::JSONB,
    active            BOOLEAN NOT NULL DEFAULT TRUE,
    first_seen_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_seen_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (bundle_identifier, environment, platform, device_token)
);
CREATE INDEX IF NOT EXISTS device_registry_active_idx ON device_registry (active) WHERE active;
CREATE INDEX IF NOT EXISTS device_registry_subscriptions_gin ON device_registry USING GIN (subscriptions jsonb_path_ops);

-- User auth. Email/password users are first-party Match Point accounts; Apple
-- users store only Apple's stable subject identifier. Passwords and recovery
-- codes are scrypt hashes, never plaintext.
CREATE TABLE IF NOT EXISTS auth_users (
    id             TEXT PRIMARY KEY,
    provider       TEXT NOT NULL CHECK (provider IN ('email', 'apple')),
    email          TEXT NOT NULL DEFAULT '',
    username       TEXT NOT NULL,
    display_name   TEXT NOT NULL,
    apple_user_id  TEXT NOT NULL DEFAULT '',
    apple_revoke_token TEXT NOT NULL DEFAULT '',
    password_hash  TEXT NOT NULL DEFAULT '',
    created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
ALTER TABLE auth_users ADD COLUMN IF NOT EXISTS apple_revoke_token TEXT NOT NULL DEFAULT '';
CREATE UNIQUE INDEX IF NOT EXISTS auth_users_email_idx ON auth_users (email) WHERE email <> '';
CREATE UNIQUE INDEX IF NOT EXISTS auth_users_username_idx ON auth_users (username);
CREATE UNIQUE INDEX IF NOT EXISTS auth_users_apple_user_id_idx ON auth_users (apple_user_id) WHERE apple_user_id <> '';

CREATE TABLE IF NOT EXISTS auth_sessions (
    token       TEXT PRIMARY KEY,
    user_id     TEXT NOT NULL REFERENCES auth_users(id) ON DELETE CASCADE,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at  TIMESTAMPTZ NOT NULL
);
CREATE INDEX IF NOT EXISTS auth_sessions_user_idx ON auth_sessions (user_id);
CREATE INDEX IF NOT EXISTS auth_sessions_expires_idx ON auth_sessions (expires_at);

CREATE TABLE IF NOT EXISTS auth_recovery_codes (
    user_id     TEXT PRIMARY KEY REFERENCES auth_users(id) ON DELETE CASCADE,
    code_hash   TEXT NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at  TIMESTAMPTZ NOT NULL
);
