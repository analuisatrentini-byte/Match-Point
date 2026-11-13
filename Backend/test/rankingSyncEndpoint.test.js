import test from 'node:test';
import assert from 'node:assert/strict';
import { handleRankingSyncRequest } from '../src/rankingSyncEndpoint.js';
import { syncAllRankingsWithLock } from '../src/rankingSync.js';

const env = { RANKING_SYNC_TOKEN: 'a'.repeat(48) };
const auth = `Bearer ${env.RANKING_SYNC_TOKEN}`;
const pool = {};

test('endpoint rejects missing and invalid credentials before invoking sync', async () => {
  let calls = 0;
  const sync = async () => { calls++; };
  assert.equal((await handleRankingSyncRequest({ pool, env: {}, authorization: auth, sync })).status, 503);
  assert.equal((await handleRankingSyncRequest({ pool, env, authorization: 'Bearer invalid', sync })).status, 401);
  assert.equal((await handleRankingSyncRequest({ pool, env, sync })).status, 401);
  assert.equal(calls, 0);
});
test('endpoint returns success, lock conflict and failure without leaking secrets', async () => {
  const success = await handleRankingSyncRequest({ pool, env, authorization: auth, sync: async () => ({ locked: false, results: [{ tour: 'ATP' }, { tour: 'WTA' }] }) });
  assert.equal(success.status, 200);
  assert.equal(success.body.rankings.length, 2);
  assert.equal((await handleRankingSyncRequest({ pool, env, authorization: auth, sync: async () => ({ locked: true }) })).status, 409);
  const failure = await handleRankingSyncRequest({ pool, env, authorization: auth, sync: async () => { throw Error(env.RANKING_SYNC_TOKEN); } });
  assert.equal(failure.status, 503);
  assert.equal(JSON.stringify(failure).includes(env.RANKING_SYNC_TOKEN), false);
  assert.equal((await handleRankingSyncRequest({ pool: null, env, authorization: auth })).status, 503);
});

function leaseStore({ failTour } = {}) {
  let token = null, expired = false;
  const rows = new Map();
  return {
    rows,
    expire() { expired = true; },
    async query(sql, args = []) {
      if (sql.startsWith('INSERT INTO ranking_sync_lease')) {
        if (token && !expired) return { rows: [], rowCount: 0 };
        token = args[0]; expired = false;
        return { rows: [{ token }], rowCount: 1 };
      }
      if (sql.startsWith('DELETE FROM ranking_sync_lease')) {
        if (token === args[0]) { token = null; expired = false; }
        return { rows: [], rowCount: 0 };
      }
      const [tour] = args;
      if (sql.startsWith('INSERT')) { if (!rows.has(tour)) rows.set(tour, {}); return { rows: [] }; }
      if (sql.startsWith('SELECT')) return { rows: [rows.get(tour) || {}] };
      if (sql.includes('snapshot =')) {
        if (tour === failTour) throw new Error('database write failed');
        if (args[6] && (args[6] !== token || expired)) return { rows: [], rowCount: 0 };
        Object.assign(rows.get(tour), { snapshot: JSON.parse(args[1]), row_count: args[2] });
        return { rows: [{ version: args[3] }], rowCount: 1 };
      }
      if (sql.startsWith('UPDATE')) return { rows: [] };
      throw Error('Unexpected query');
    }
  };
}
const validResponse = url => ({ ok: true, json: async () => ({ success: 1, result: [{ player_key: 'p', player: 'Name', place: 1, points: '1', league: url.searchParams.get('event_type') }] }) });
const apiEnv = { API_TENNIS_KEY: 'test' };

test('lease prevents overlapping attempts and is released after both circuits commit', async () => {
  const db = leaseStore();
  let finishFetch;
  const gate = new Promise(resolve => { finishFetch = resolve; });
  const first = syncAllRankingsWithLock({ pool: db, env: apiEnv, fetchImpl: async url => { await gate; return validResponse(url); } });
  await new Promise(resolve => setImmediate(resolve));
  assert.equal((await syncAllRankingsWithLock({ pool: db })).locked, true);
  finishFetch();
  assert.equal((await first).locked, false);
  assert.equal(db.rows.size, 2);
  assert.equal((await syncAllRankingsWithLock({ pool: db, env: apiEnv, fetchImpl: async url => validResponse(url) })).locked, false);
});

test('expired lease cannot publish stale snapshots or log success', async () => {
  const db = leaseStore();
  let releaseFetch;
  const gate = new Promise(resolve => { releaseFetch = resolve; });
  const messages = [];
  const original = console.info;
  console.info = message => messages.push(message);
  try {
    const sync = syncAllRankingsWithLock({ pool: db, env: apiEnv, fetchImpl: async url => { await gate; return validResponse(url); } });
    await new Promise(resolve => setImmediate(resolve));
    db.expire();
    releaseFetch();
    await assert.rejects(sync);
    assert.equal([...db.rows.values()].some(row => row.snapshot), false);
    assert.equal(messages.some(message => message.includes('ranking_sync_success')), false);
  } finally { console.info = original; }
});

for (const failedTour of ['ATP', 'WTA']) {
  for (const failureKind of ['provider', 'database']) {
    test(`${failureKind} failure in ${failedTour} preserves the other circuit and reports HTTP failure`, async () => {
      const db = leaseStore({ failTour: failureKind === 'database' ? failedTour : undefined });
      const fetchImpl = async url => failureKind === 'provider' && url.searchParams.get('event_type') === failedTour ? { ok: false, status: 503 } : validResponse(url);
      const result = await handleRankingSyncRequest({
        pool: db, env, authorization: auth,
        sync: ({ pool }) => syncAllRankingsWithLock({ pool, env: apiEnv, fetchImpl })
      });
      assert.equal(result.status, 503);
      assert.equal(db.rows.get(failedTour).snapshot, undefined);
      const successfulTour = failedTour === 'ATP' ? 'WTA' : 'ATP';
      assert.equal(db.rows.get(successfulTour).snapshot.result[0].league, successfulTour);
    });
  }
}
