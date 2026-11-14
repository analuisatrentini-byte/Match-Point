import test from 'node:test';
import assert from 'node:assert/strict';
import { rankingSnapshotIsStale, validateStandings, syncRankingTour, syncAllRankings } from '../src/rankingSync.js';
const row = (id, rank, points, league = 'ATP') => ({ player_key: id, player: `Player ${id}`, place: rank, points, league });
const payload = rows => ({ success: 1, result: rows });
function store() {
  const data = new Map();
  return { data, async query(sql, args) {
    const [tour] = args;
    if (sql.startsWith('INSERT')) { const r = data.get(tour) ?? {}; r.lastAttempt = args[1]; data.set(tour, r); return { rows: [], rowCount: 1 }; }
    if (sql.startsWith('SELECT')) { const r = data.get(tour); return { rows: r ? [r] : [] }; }
    if (sql.includes('snapshot =')) { const r = data.get(tour); if (r.accepted && r.accepted > args[5]) return { rows: [], rowCount: 0 }; Object.assign(r, { snapshot: JSON.parse(args[1]), row_count: args[2], version: args[3], accepted: args[5] }); return { rows: [{ version: args[3] }], rowCount: 1 }; }
    if (sql.startsWith('UPDATE')) { if (sql.includes('last_provider_success_at')) return { rows: [] }; data.get(tour).error = args[1]; return { rows: [] }; }
    throw Error('unexpected query');
  }};
}
const env = { API_TENNIS_KEY: 'test-key' };
const fetchRows = rows => async () => ({ ok: true, json: async () => payload(rows) });
test('retained rankings are stale after failed attempts or missed scheduled updates', () => {
  const now = Date.parse('2026-11-13T12:00:00Z');
  assert.equal(rankingSnapshotIsStale({last_success_at: new Date(now - 60 * 60 * 1000), last_error: null}, now), false);
  assert.equal(rankingSnapshotIsStale({last_success_at: new Date(now - 60 * 60 * 1000), last_error: 'provider unavailable'}, now), true);
  assert.equal(rankingSnapshotIsStale({last_success_at: new Date(now - 3 * 60 * 60 * 1000 - 1), last_error: null}, now), true);
  assert.equal(rankingSnapshotIsStale({last_success_at: null, last_error: null}, now), true);
  assert.equal(rankingSnapshotIsStale({last_success_at: 'invalid', last_error: null}, now), true);
});
test('hash is stable across order and changes with ranking values', () => {
  const a = row('a',1,100), b = row('b',2,90);
  assert.equal(validateStandings(payload([a,b]), 'ATP').hash, validateStandings(payload([b,a]), 'ATP').hash);
  assert.notEqual(validateStandings(payload([a,b]), 'ATP').hash, validateStandings(payload([row('a',2,80),b]), 'ATP').hash);
});
test('rejects duplicates, invalid rows, wrong tour and suspicious truncation', () => {
  for (const rows of [[row('a',1,2), row('a',2,3)], [row('a',0,2)], [row('a',1,2,'WTA')]]) assert.throws(() => validateStandings(payload(rows), 'ATP'));
  assert.throws(() => validateStandings(payload([row('a',1,2)]), 'ATP', 4));
});
test('replacement handles additions and removals without modifying the other tour', async () => {
  const db = store();
  await syncRankingTour({ pool: db, tour: 'ATP', env, fetchImpl: fetchRows([row('a',1,100), row('b',2,90)]) });
  await syncRankingTour({ pool: db, tour: 'WTA', env, fetchImpl: fetchRows([row('w',1,80,'WTA')]) });
  await syncRankingTour({ pool: db, tour: 'ATP', env, fetchImpl: fetchRows([row('a',2,80), row('c',1,110)]) });
  assert.deepEqual(db.data.get('ATP').snapshot.result.map(r => r.player_key), ['a','c']);
  assert.equal(db.data.get('ATP').snapshot.result[0].points, '80');
  assert.equal(db.data.get('WTA').snapshot.result[0].player_key, 'w');
});
test('invalid response and provider failures preserve valid snapshot', async () => {
  const db = store();
  await syncRankingTour({ pool: db, tour:'ATP', env, fetchImpl:fetchRows([row('a',1,100),row('b',2,90)]) });
  const original = db.data.get('ATP').version;
  await assert.rejects(syncRankingTour({ pool:db,tour:'ATP',env,fetchImpl:fetchRows([row('x',0,3)]) }));
  await assert.rejects(syncRankingTour({ pool:db,tour:'ATP',env,fetchImpl:async () => { throw Error('offline'); } }));
  assert.equal(db.data.get('ATP').version, original);
});
test('failure in one circuit does not prevent success in the other', async () => {
  const db = store();
  await assert.rejects(syncAllRankings({ pool:db, env, fetchImpl:async url => url.searchParams.get('event_type') === 'ATP' ? ({ ok:false, status:503 }) : ({ ok:true, json:async()=>payload([row('w',1,10,'WTA')]) }) }));
  assert.equal(db.data.get('WTA').row_count, 1);
});
