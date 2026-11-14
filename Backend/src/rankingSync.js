import { createHash, randomUUID } from 'node:crypto';
import { buildAPITennisURL } from './apiTennisProxy.js';

// An hourly schedule can be delayed by the scheduler. After three hours
// without an accepted provider response, or a failed latest attempt, clients
// must not record the retained snapshot as a successful fresh sync.
export function rankingSnapshotIsStale(row, now = Date.now()) {
  const lastSuccess = row?.last_success_at == null ? NaN : new Date(row.last_success_at).getTime();
  return Boolean(row?.last_error) || !Number.isFinite(lastSuccess) || now - lastSuccess > 3 * 60 * 60 * 1000;
}

// API Tennis does not currently provide an official publication date in the
// standings payload. The hash identifies content, not official freshness.
export function validateStandings(payload, tour, previousCount = 0) {
  if (payload?.success !== 1 || !Array.isArray(payload.result) || !payload.result.length) throw new Error('Empty or unsuccessful standings response');
  const ids = new Set();
  const rows = payload.result.map((row) => {
    const id = String(row.player_key ?? '').trim();
    const rank = Number(row.place), points = Number(row.points);
    if (!id || row.place == null || row.points == null || String(row.place).trim() === '' || String(row.points).trim() === '' || !String(row.player ?? '').trim() || !Number.isInteger(rank) || rank < 1 || !Number.isInteger(points) || points < 0 || (row.league && row.league.toUpperCase() !== tour)) throw new Error('Invalid standings row');
    if (ids.has(id)) throw new Error('Duplicate player in standings');
    ids.add(id);
    return { ...row, player_key: id, place: rank, points: String(points) };
  }).sort((a, b) => a.player_key.localeCompare(b.player_key));
  if (previousCount && rows.length * 2 < previousCount) throw new Error('Suspiciously incomplete standings response');
  const hash = createHash('sha256').update(JSON.stringify(rows)).digest('hex');
  return { rows, hash };
}

export async function syncRankingTour({ pool, tour, env = process.env, fetchImpl = fetch, now = () => new Date(), leaseToken = null }) {
  if (!pool || !['ATP', 'WTA'].includes(tour)) throw new Error('Database and valid tour required');
  const started = now();
  await pool.query(`INSERT INTO ranking_snapshots (tour, last_attempt_at) VALUES ($1,$2)
    ON CONFLICT (tour) DO UPDATE SET last_attempt_at = GREATEST(ranking_snapshots.last_attempt_at, EXCLUDED.last_attempt_at)`, [tour, started]);
  try {
    const previous = await pool.query('SELECT row_count, snapshot FROM ranking_snapshots WHERE tour=$1', [tour]);
    const url = buildAPITennisURL(`/tennis?method=get_standings&event_type=${tour}`, env);
    const response = await fetchImpl(url, { headers: { accept: 'application/json' }, signal: AbortSignal.timeout(30000) });
    if (!response.ok) throw new Error(`Provider HTTP ${response.status}`);
    const payload = await response.json();
    if (payload?.success === 1 && Array.isArray(payload.result)) {
      await pool.query('UPDATE ranking_snapshots SET last_provider_success_at=$2 WHERE tour=$1 AND (last_provider_success_at IS NULL OR last_provider_success_at <= $2)', [tour, now()]);
    }
    const { rows, hash } = validateStandings(payload, tour, previous.rows[0]?.row_count ?? 0);
    const oldRows = previous.rows[0]?.snapshot?.result ?? [];
    const old = new Map(oldRows.map(row => [String(row.player_key), row]));
    const incoming = new Set(rows.map(row => row.player_key));
    const changes = { added: 0, removed: 0, rank: 0, points: 0 };
    for (const row of rows) {
      const prior = old.get(row.player_key);
      if (!prior) changes.added++;
      else {
        if (Number(prior.place) !== row.place) changes.rank++;
        if (Number(prior.points) !== Number(row.points)) changes.points++;
      }
    }
    for (const id of old.keys()) if (!incoming.has(id)) changes.removed++;
    const finished = now();
    // One statement publishes the whole JSON snapshot and its metadata atomically.
    // A late response cannot replace a newer attempt's accepted snapshot.
    const result = await pool.query(`UPDATE ranking_snapshots SET
      snapshot = $2::jsonb, row_count = $3, version = $4,
      last_success_at = $5, last_changed_at = CASE WHEN version IS DISTINCT FROM $4 THEN $5 ELSE last_changed_at END,
      last_error = NULL, accepted_attempt_at = $6
      WHERE tour = $1 AND (accepted_attempt_at IS NULL OR accepted_attempt_at <= $6)
        AND ($7::text IS NULL OR EXISTS (SELECT 1 FROM ranking_sync_lease
          WHERE name = 'rankings' AND token = $7 AND expires_at > clock_timestamp()))
      RETURNING version`, [tour, JSON.stringify({ success: 1, result: rows }), rows.length, hash, finished, started, leaseToken]);
    if (result.rowCount !== 1) throw new Error('Ranking snapshot was not published: lease expired or a newer attempt won');
    // pool.query resolves after its autonomous statement has committed.
    console.info(JSON.stringify({ event: 'ranking_sync_success', tour, count: rows.length, version: hash, changes, published: true }));
    return { tour, count: rows.length, version: hash, published: true };
  } catch (error) {
    await pool.query('UPDATE ranking_snapshots SET last_error=$2 WHERE tour=$1 AND last_attempt_at=$3', [tour, String(error.message).slice(0, 300), started]).catch(() => {});
    console.error(JSON.stringify({ event: 'ranking_sync_failure', tour, error: error.message }));
    throw error;
  }
}

export async function syncAllRankings(options) {
  const results = await Promise.allSettled(['ATP', 'WTA'].map(tour => syncRankingTour({ ...options, tour })));
  if (results.some(result => result.status === 'rejected')) throw new AggregateError(results.filter(r => r.status === 'rejected').map(r => r.reason), 'Ranking sync failed');
  return results.map(result => result.value);
}

// A bounded database lease avoids holding a Postgres transaction open during
// provider network calls and works with PgBouncer transaction pooling. The
// publishing query fences expired/replaced tokens, so a late process cannot
// overwrite a newer sync. Every entry point must use this wrapper.
export async function syncAllRankingsWithLock({ pool, ...options }) {
  return withRankingSyncLease(pool, token => syncAllRankings({ ...options, pool, leaseToken: token }));
}

async function withRankingSyncLease(pool, operation) {
  if (!pool) throw new Error('Database required');
  const token = randomUUID();
  const lease = await pool.query(`INSERT INTO ranking_sync_lease (name, token, expires_at)
    VALUES ('rankings', $1, clock_timestamp() + interval '3 minutes')
    ON CONFLICT (name) DO UPDATE SET token = EXCLUDED.token, expires_at = EXCLUDED.expires_at
    WHERE ranking_sync_lease.expires_at <= clock_timestamp()
    RETURNING token`, [token]);
  if (lease.rowCount !== 1) return { locked: true };
  try {
    const results = await operation(token);
    return { locked: false, results };
  } finally {
    await pool.query("DELETE FROM ranking_sync_lease WHERE name = 'rankings' AND token = $1", [token]).catch(error => {
      console.error(JSON.stringify({ event: 'ranking_sync_lease_release_failed', error: error.message }));
    });
  }
}

// Recheck after acquiring the shared lease: another process may already have
// refreshed the data since the HTTP request read the stale snapshot. A failed
// request is retried at most once every 15 minutes per tour, even after restart.
// This is a fallback for active users, not a replacement for a scheduler.
export async function syncDueRankingsWithLock({ pool, ...options }) {
  return withRankingSyncLease(pool, async token => {
    const due = await pool.query(`SELECT tours.tour FROM (VALUES ('ATP'), ('WTA')) AS tours(tour)
      LEFT JOIN ranking_snapshots AS s ON s.tour = tours.tour
      WHERE (s.last_success_at IS NULL OR s.last_success_at < clock_timestamp() - interval '3 hours' OR s.last_error IS NOT NULL)
        AND (s.last_attempt_at IS NULL OR s.last_attempt_at < clock_timestamp() - interval '15 minutes')`);
    const tours = due.rows.map(row => row.tour).filter(tour => tour === 'ATP' || tour === 'WTA');
    const results = await Promise.allSettled(tours.map(tour => syncRankingTour({ ...options, pool, tour, leaseToken: token })));
    if (results.some(result => result.status === 'rejected')) {
      throw new AggregateError(results.filter(result => result.status === 'rejected').map(result => result.reason), 'Demand ranking sync failed');
    }
    return results.map(result => result.value);
  });
}

// Multiple simultaneous page requests share one background task. The database
// lease and persisted cooldown protect across instances and restarts.
export function createDemandRankingRefresh({ pool, sync = syncDueRankingsWithLock, log = console.error, now = Date.now }) {
  let inFlight = null;
  let lastStartedAt = null;
  return () => {
    if (!pool || inFlight) return inFlight;
    const currentTime = now();
    // Avoid repeated lease writes for public requests while the persisted
    // provider cooldown prevents a new sync. Database protection remains
    // authoritative across instances and after a restart.
    if (lastStartedAt !== null && currentTime >= lastStartedAt && currentTime - lastStartedAt < 30_000) return null;
    lastStartedAt = currentTime;
    inFlight = Promise.resolve().then(() => sync({ pool }))
      .catch(error => { log(JSON.stringify({ event: 'ranking_demand_sync_failure', error: error.message })); })
      .finally(() => { inFlight = null; });
    return inFlight;
  };
}
