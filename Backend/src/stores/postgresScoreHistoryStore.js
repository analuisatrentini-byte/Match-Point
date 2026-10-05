/// Postgres-backed append-only audit log. Same shape as the JSON store:
/// `record(diff)` appends a row, `history(matchKey)` returns rows in
/// insertion order. `id` is a BIGSERIAL — order is preserved even when the
/// wall clock drifts.
export class PostgresScoreHistoryStore {
    constructor(pool) {
        this.pool = pool;
    }

    async record({ current, previous, source }) {
        if (!current || typeof current !== "object") throw badRequest("current snapshot is required");
        const result = await this.pool.query(
            `INSERT INTO score_history (
                match_key, revision, source, status, score, game_score,
                point_score, server_name, player1_key, player2_key, set_number, break_point,
                hash, previous_hash, previous_status, captured_at
             ) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16)
             RETURNING *`,
            [
                current.matchKey,
                current.revision,
                typeof source === "string" && source.length > 0 ? source : "ingest",
                current.status,
                current.score,
                current.gameScore,
                current.pointScore,
                current.serverName,
                current.player1Key,
                current.player2Key,
                current.setNumber,
                current.breakPoint,
                current.hash,
                previous?.hash ?? null,
                previous?.status ?? null,
                current.capturedAt
            ]
        );
        return rowToEvent(result.rows[0]);
    }

    async history(matchKey) {
        const result = await this.pool.query(
            "SELECT * FROM score_history WHERE match_key = $1 ORDER BY id ASC",
            [matchKey]
        );
        return result.rows.map(rowToEvent);
    }

    async stats() {
        const result = await this.pool.query("SELECT COUNT(*)::INT AS events FROM score_history");
        const row = result.rows[0] ?? {};
        return { recorded: row.events ?? 0, events: row.events ?? 0 };
    }
}

function rowToEvent(row) {
    return {
        id: `sh:${row.id}`,
        matchKey: row.match_key,
        revision: row.revision,
        source: row.source,
        recordedAt: row.recorded_at instanceof Date ? row.recorded_at.toISOString() : row.recorded_at,
        capturedAt: row.captured_at instanceof Date ? row.captured_at.toISOString() : row.captured_at,
        status: row.status,
        score: row.score,
        gameScore: row.game_score,
        pointScore: row.point_score,
        serverName: row.server_name,
        player1Key: row.player1_key ?? "",
        player2Key: row.player2_key ?? "",
        setNumber: row.set_number,
        breakPoint: row.break_point,
        hash: row.hash,
        previousHash: row.previous_hash,
        previousStatus: row.previous_status
    };
}

function badRequest(message) {
    const error = new Error(message);
    error.statusCode = 400;
    return error;
}
