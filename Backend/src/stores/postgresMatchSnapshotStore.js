import { hashSnapshot } from "../matchSnapshotStore.js";

/// Postgres-backed match snapshot store with the SAME interface as the JSON
/// store. The factory picks between them at boot; nothing above this layer
/// knows which backend is in use.
///
/// Dedup happens with an INSERT ... ON CONFLICT ... DO NOTHING RETURNING trick:
/// if the incoming hash is byte-equal to the last hash for the same match_key,
/// nothing is written and we return `changed: false` immediately.
export class PostgresMatchSnapshotStore {
    constructor(pool) {
        this.pool = pool;
    }

    async ingest(snapshot) {
        const normalized = normalize(snapshot);
        const hash = hashSnapshot(normalized);

        const previousResult = await this.pool.query(
            "SELECT * FROM match_snapshots WHERE match_key = $1",
            [normalized.matchKey]
        );
        const previous = previousResult.rows[0] ? rowToSnapshot(previousResult.rows[0]) : null;
        if (previous && previous.hash === hash) {
            return { current: previous, previous, changed: false };
        }

        const nextRevision = (previous?.revision ?? 0) + 1;
        const upsertResult = await this.pool.query(
            `INSERT INTO match_snapshots (
                match_key, tournament_key, player1, player2, player1_key, player2_key, status, server_name,
                score, game_score, point_score, set_number, break_point,
                favorite_player_keys, hash, revision, captured_at, first_seen_at, last_seen_at
             ) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17, NOW(), NOW())
             ON CONFLICT (match_key) DO UPDATE SET
                tournament_key = EXCLUDED.tournament_key,
                player1 = EXCLUDED.player1,
                player2 = EXCLUDED.player2,
                player1_key = EXCLUDED.player1_key,
                player2_key = EXCLUDED.player2_key,
                status = EXCLUDED.status,
                server_name = EXCLUDED.server_name,
                score = EXCLUDED.score,
                game_score = EXCLUDED.game_score,
                point_score = EXCLUDED.point_score,
                set_number = EXCLUDED.set_number,
                break_point = EXCLUDED.break_point,
                favorite_player_keys = EXCLUDED.favorite_player_keys,
                hash = EXCLUDED.hash,
                revision = EXCLUDED.revision,
                captured_at = EXCLUDED.captured_at,
                last_seen_at = NOW()
             RETURNING *`,
            [
                normalized.matchKey,
                normalized.tournamentKey,
                normalized.player1,
                normalized.player2,
                normalized.player1Key,
                normalized.player2Key,
                normalized.status,
                normalized.serverName,
                normalized.score,
                normalized.gameScore,
                normalized.pointScore,
                normalized.setNumber,
                normalized.breakPoint,
                normalized.favoritePlayerKeys,
                hash,
                nextRevision,
                normalized.capturedAt
            ]
        );
        const current = rowToSnapshot(upsertResult.rows[0]);
        return { current, previous, changed: true };
    }

    async get(matchKey) {
        const result = await this.pool.query(
            "SELECT * FROM match_snapshots WHERE match_key = $1",
            [matchKey]
        );
        return result.rows[0] ? rowToSnapshot(result.rows[0]) : null;
    }

    async list({ limit = 100 } = {}) {
        const result = await this.pool.query(
            "SELECT * FROM match_snapshots ORDER BY last_seen_at DESC LIMIT $1",
            [limit]
        );
        return result.rows.map(rowToSnapshot);
    }

    async stats() {
        const result = await this.pool.query(
            `SELECT COUNT(*)::INT AS unique_matches,
                    COALESCE(SUM(revision), 0)::INT AS ingested,
                    COUNT(*) FILTER (WHERE status = 'live')::INT AS live_matches
               FROM match_snapshots`
        );
        const row = result.rows[0] ?? {};
        return {
            uniqueMatches: row.unique_matches ?? 0,
            ingested: row.ingested ?? 0,
            liveMatches: row.live_matches ?? 0
        };
    }
}

function normalize(snapshot) {
    if (!snapshot || typeof snapshot !== "object") throw badRequest("snapshot must be an object");
    if (typeof snapshot.matchKey !== "string" || snapshot.matchKey.trim() === "") {
        throw badRequest("snapshot.matchKey is required");
    }
    return {
        matchKey: snapshot.matchKey.trim(),
        tournamentKey: snapshot.tournamentKey ?? "",
        player1: snapshot.player1 ?? "",
        player2: snapshot.player2 ?? "",
        player1Key: snapshot.player1Key ?? "",
        player2Key: snapshot.player2Key ?? "",
        status: normalizeStatus(snapshot.status),
        serverName: snapshot.serverName ?? "",
        score: snapshot.score ?? "",
        gameScore: snapshot.gameScore ?? "",
        pointScore: snapshot.pointScore ?? "",
        setNumber: Number.isInteger(snapshot.setNumber) ? snapshot.setNumber : null,
        breakPoint: Boolean(snapshot.breakPoint),
        favoritePlayerKeys: Array.isArray(snapshot.favoritePlayerKeys)
            ? snapshot.favoritePlayerKeys.filter((value) => typeof value === "string")
            : [],
        capturedAt: snapshot.capturedAt ?? new Date().toISOString()
    };
}

function normalizeStatus(value) {
    const raw = typeof value === "string" ? value.trim().toLowerCase() : "";
    if (["live", "upcoming", "completed", "finished"].includes(raw)) {
        return raw === "finished" ? "completed" : raw;
    }
    return "unknown";
}

function rowToSnapshot(row) {
    return {
        matchKey: row.match_key,
        tournamentKey: row.tournament_key,
        player1: row.player1,
        player2: row.player2,
        player1Key: row.player1_key ?? "",
        player2Key: row.player2_key ?? "",
        status: row.status,
        serverName: row.server_name,
        score: row.score,
        gameScore: row.game_score,
        pointScore: row.point_score,
        setNumber: row.set_number,
        breakPoint: row.break_point,
        favoritePlayerKeys: row.favorite_player_keys ?? [],
        hash: row.hash,
        revision: row.revision,
        capturedAt: (row.captured_at instanceof Date ? row.captured_at.toISOString() : row.captured_at),
        firstSeenAt: (row.first_seen_at instanceof Date ? row.first_seen_at.toISOString() : row.first_seen_at),
        lastSeenAt: (row.last_seen_at instanceof Date ? row.last_seen_at.toISOString() : row.last_seen_at)
    };
}

function badRequest(message) {
    const error = new Error(message);
    error.statusCode = 400;
    return error;
}
