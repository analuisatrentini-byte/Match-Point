import test from 'node:test';
import assert from 'node:assert/strict';
import { createDemandRankingRefresh, syncDueRankingsWithLock } from '../src/rankingSync.js';

function testDatabase() {
  let lease = null;
  let time = Date.parse('2026-11-13T12:00:00Z');
  const rows = new Map(['ATP', 'WTA'].map(tour => [tour, {
    last_success_at: new Date(time - 4 * 3600_000), last_attempt_at: null,
    last_error: null, row_count: 1,
    snapshot: { result: [{ player_key: tour, player: tour, place: 2, points: '2', league: tour }] }
  }]));
  return {
    rows,
    now: () => new Date(time),
    advance: ms => { time += ms; },
    async query(sql, args = []) {
      if (sql.startsWith('INSERT INTO ranking_sync_lease')) {
        if (lease) return { rows: [], rowCount: 0 };
        lease = args[0];
        return { rows: [{ token: lease }], rowCount: 1 };
      }
      if (sql.startsWith('DELETE FROM ranking_sync_lease')) {
        if (lease === args[0]) lease = null;
        return { rows: [] };
      }
      if (sql.startsWith('SELECT tours.tour')) {
        return { rows: ['ATP', 'WTA'].map(tour => [tour, rows.get(tour) || {}]).filter(([, r]) =>
          (!r.last_success_at || time - r.last_success_at.getTime() > 3 * 3600_000 || r.last_error) &&
          (!r.last_attempt_at || time - r.last_attempt_at.getTime() > 15 * 60_000)
        ).map(([tour]) => ({ tour })) };
      }
      const [tour] = args;
      let row = rows.get(tour);
      if (sql.startsWith('INSERT INTO ranking_snapshots')) {
        if (!row) { row = {}; rows.set(tour, row); }
        row.last_attempt_at = args[1]; return { rows: [] };
      }
      if (sql.startsWith('SELECT row_count')) return { rows: [row] };
      if (sql.includes('snapshot =')) {
        assert.equal(args[6], lease);
        Object.assign(row, { snapshot: JSON.parse(args[1]), row_count: args[2], last_success_at: args[4], last_error: null });
        return { rows: [{ version: args[3] }], rowCount: 1 };
      }
      if (sql.includes('SET last_error')) { row.last_error = args[1]; return { rows: [] }; }
      if (sql.startsWith('UPDATE')) return { rows: [] };
      throw Error('Unexpected query');
    }
  };
}
const env = { API_TENNIS_KEY: 'test' };
const response = tour => ({ ok: true, json: async () => ({ success: 1, result: [{ player_key: tour, player: tour, place: 1, points: '10', league: tour }] }) });

test('demand refresh coalesces requests and rechecks due tours after database lease', async () => {
  const db = testDatabase();
  let calls = 0, release;
  const gate = new Promise(resolve => { release = resolve; });
  const sync = ({ pool }) => syncDueRankingsWithLock({ pool, env, now: db.now, fetchImpl: async url => {
    calls++; await gate; return response(url.searchParams.get('event_type'));
  } });
  const refreshA = createDemandRankingRefresh({ pool: db, sync, now: () => db.now().getTime() });
  const refreshB = createDemandRankingRefresh({ pool: db, sync, now: () => db.now().getTime() });
  const first = refreshA();
  assert.equal(refreshA(), first);
  await new Promise(resolve => setImmediate(resolve));
  await refreshB(); // Separate instance cannot pass the database lease.
  assert.equal(calls, 2);
  release(); await first;
  // A later contender acquires the lease but sees freshly committed dates.
  db.advance(31_000);
  await refreshB();
  assert.equal(calls, 2);
  assert.equal(db.rows.get('ATP').snapshot.result[0].points, '10');
  assert.equal(db.rows.get('WTA').snapshot.result[0].place, 1);
});

test('request throttle prevents lease attempts after success or failure and permits later recovery', async () => {
  let time = 1_000, attempts = 0;
  const refresh = createDemandRankingRefresh({ pool: {}, now: () => time, log: () => {}, sync: async () => {
    attempts++;
    if (attempts === 1) throw new Error('database temporarily unavailable');
  } });
  await refresh();
  assert.equal(refresh(), null);
  time += 29_999;
  assert.equal(refresh(), null);
  assert.equal(attempts, 1);
  time++;
  await refresh();
  assert.equal(attempts, 2);
  assert.equal(refresh(), null);
  time += 30_000;
  await refresh();
  assert.equal(attempts, 3);
});

test('missing tour snapshot is recovered without re-fetching a fresh tour', async () => {
  const db = testDatabase();
  db.rows.delete('ATP');
  db.rows.get('WTA').last_success_at = db.now();
  const calls = [];
  const refresh = createDemandRankingRefresh({ pool: db, sync: ({ pool }) => syncDueRankingsWithLock({
    pool, env, now: db.now, fetchImpl: async url => {
      const tour = url.searchParams.get('event_type'); calls.push(tour); return response(tour);
    }
  }) });
  await refresh();
  assert.deepEqual(calls, ['ATP']);
  assert.equal(db.rows.get('ATP').snapshot.result[0].points, '10');
});

test('provider failure preserves its tour, enforces persisted cooldown, and retries after restart', async () => {
  const db = testDatabase();
  const calls = [];
  let failed = true;
  const sync = ({ pool }) => syncDueRankingsWithLock({ pool, env, now: db.now, fetchImpl: async url => {
    const tour = url.searchParams.get('event_type'); calls.push(tour);
    return tour === 'ATP' && failed ? { ok: false, status: 503 } : response(tour);
  } });
  await createDemandRankingRefresh({ pool: db, sync, log: () => {} })();
  assert.equal(db.rows.get('ATP').snapshot.result[0].points, '2');
  assert.equal(db.rows.get('WTA').snapshot.result[0].points, '10');
  assert.ok(db.rows.get('ATP').last_error);
  // Recreating the handler models a server restart; cooldown survives in DB.
  await createDemandRankingRefresh({ pool: db, sync, log: () => {} })();
  assert.equal(calls.length, 2);
  db.advance(16 * 60_000); failed = false;
  await createDemandRankingRefresh({ pool: db, sync, log: () => {} })();
  assert.deepEqual(calls, ['ATP', 'WTA', 'ATP']);
  assert.equal(db.rows.get('ATP').snapshot.result[0].points, '10');
  assert.equal(db.rows.get('ATP').last_error, null);
});
