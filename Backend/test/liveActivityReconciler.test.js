import test from 'node:test';
import assert from 'node:assert/strict';
import {reconcileLiveActivities, startLiveActivityReconciliation} from '../src/liveActivityReconciler.js';
const pool = {query: async () => ({rows:[{match_key:'tracked'}]})};
const env = {API_TENNIS_KEY:'test'};
const response = result => ({ok:true, json:async () => ({success:1, result})});
const live = {event_key:'tracked', event_status:'Set 1', event_live:'1', scores:[{score_set:'1', score_first:'5', score_second:'3'}], event_point_result:'15-30'};
const finished = {...live, event_status:'Finished', event_live:'0', scores:[{score_set:'1', score_first:'6', score_second:'3'}]};

test('server recovery refreshes live scores without an app or WebSocket frame', async () => {
    const updates = [], paths = [];
    const result = await reconcileLiveActivities({pool, env, service:{update:async value => updates.push(value)}, fetchImpl:async url => {
        paths.push(url.searchParams.get('method'));
        return response([live]);
    }});
    assert.deepEqual(paths, ['get_livescore']);
    assert.equal(updates[0].gameScore, '5-3');
    assert.equal(updates[0].pointScore, '15-30');
    assert.deepEqual(result, {subscriptions:1, live:1, ended:0});
});

test('a lost terminal WebSocket frame is recovered explicitly from fixtures', async () => {
    const updates = [];
    const result = await reconcileLiveActivities({pool, env, service:{update:async value => updates.push(value)}, fetchImpl:async url => response(url.searchParams.get('method') === 'get_livescore' ? [] : [finished])});
    assert.equal(updates.length, 1);
    assert.equal(updates[0].status, 'completed');
    assert.equal(result.ended, 1);
});

test('one endpoint failure does not discard a final result from another endpoint', async () => {
    const updates = [];
    await assert.rejects(reconcileLiveActivities({pool, env, service:{update:async value => updates.push(value)}, fetchImpl:async url => {
        if (url.searchParams.get('method') === 'get_livescore') return {ok:false, status:503};
        return response([finished]);
    }}), /503/);
    assert.equal(updates.length, 1);
    assert.equal(updates[0].status, 'completed');
});

test('empty, scheduled, malformed and failed responses never manufacture a completed match', async () => {
    const updates = [];
    const service = {update:async value => updates.push(value)};
    await reconcileLiveActivities({pool, env, service, fetchImpl:async () => response([])});
    await reconcileLiveActivities({pool, env, service, fetchImpl:async () => response([{event_key:'tracked', event_status:'Scheduled'}])});
    await assert.rejects(reconcileLiveActivities({pool, env, service, fetchImpl:async () => ({ok:true, json:async () => ({success:0})})}));
    assert.deepEqual(updates, []);
});

test('fixture lookups use New York calendar dates around UTC midnight', async () => {
    const dates = [];
    await reconcileLiveActivities({pool, env, now:new Date('2026-11-22T01:00:00Z'), service:{update:async () => {}}, fetchImpl:async url => {
        if (url.searchParams.get('method') === 'get_fixtures') dates.push(url.searchParams.get('date_start'));
        return response([]);
    }});
    assert.deepEqual(dates.sort(), ['2026-11-20', '2026-11-21']);
});

test('no subscriptions means no provider polling', async () => {
    let requests = 0;
    await reconcileLiveActivities({pool:{query:async () => ({rows:[]})}, env, service:{}, fetchImpl:async () => {requests++; return response([]);}});
    assert.equal(requests, 0);
});

test('REST acquisition time is request start rather than delayed response completion', async () => {
    const updates = [];
    let responseAt;
    await reconcileLiveActivities({pool, env, service:{update:async value => updates.push(value)}, fetchImpl:async () => {
        await new Promise(resolve => setTimeout(resolve, 20));
        responseAt = Date.now();
        return response([live]);
    }});
    assert.ok(Date.parse(updates[0].capturedAt) < responseAt);
});

test('recovery starts immediately and does not overlap a slow provider request', async () => {
    let release;
    const gate = new Promise(resolve => {release = resolve;});
    let requests = 0;
    const stop = startLiveActivityReconciliation({pool, env, service:{update:async () => {}}, fetchImpl:async () => {
        requests++;
        await gate;
        return response([live]);
    }}, 5);
    try {
        await new Promise(resolve => setTimeout(resolve, 25));
        assert.equal(requests, 1);
        assert.equal(stop.health().running, true);
        release();
        await new Promise(resolve => setImmediate(resolve));
        assert.ok(stop.health().lastSuccessAt);
    } finally {release(); stop();}
});

test('a persisted server-confirmed end is replayed after restart even if the API omits the match', async () => {
    const updates = [];
    let requests = 0;
    const result = await reconcileLiveActivities({pool:{query:async () => ({rows:[{match_key:'tracked', content_state:{
        _terminalConfirmed:true, isLive:false, status:'Finalizada', lastUpdated:Date.parse('2026-11-22T12:00:00Z')/1000-978307200,
        gameScore:'6-4', setScores:[{player1Games:'6', player2Games:'4'}]
    }}]})}, env, service:{update:async value => updates.push(value)}, fetchImpl:async () => {requests++; return response([]);}});
    assert.equal(requests, 0);
    assert.equal(updates.length, 1);
    assert.equal(updates[0].status, 'completed');
    assert.equal(updates[0].capturedAt, '2026-11-22T12:00:00.000Z');
    assert.equal(updates[0].setScores[0].number, 1);
    assert.equal(result.ended, 1);
});

test('a client-provided final status alone cannot trigger replay for other subscriptions', async () => {
    const updates = [];
    await reconcileLiveActivities({pool:{query:async () => ({rows:[{match_key:'tracked', content_state:{isLive:false, status:'Finalizada'}}]})}, env,
        service:{update:async value => updates.push(value)}, fetchImpl:async () => response([])});
    assert.deepEqual(updates, []);
});
