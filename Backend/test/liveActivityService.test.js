import test from 'node:test';
import assert from 'node:assert/strict';
import { LiveActivityService, mergeState } from '../src/liveActivityService.js';

const state = {player1SetsWon: 0, player2SetsWon: 0, currentSetIndex: 0,
    setScores: [{player1Games: '4', player2Games: '3'}], pointScore: '15-30', gameScore: '4-3',
    serverIsPlayerOne: true, status: 'Ao vivo', isLive: true, lastUpdated: 0};

test('partial frames preserve scores; completed frames end without counting current set', () => {
    const partial = mergeState(state, {pointScore: '30-30', status: 'live'});
    assert.equal(partial.gameScore, '4-3');
    assert.deepEqual(partial.setScores, state.setScores);
    const final = mergeState(partial, {setScores: [{number:1,player1Games:'6',player2Games:'4'},{number:2,player1Games:'3',player2Games:'6'},{number:3,player1Games:'7',player2Games:'6'}], status: 'completed'});
    assert.equal(final.player1SetsWon, 2);
    assert.equal(final.player2SetsWon, 1);
    assert.equal(final.isLive, false);
    assert.equal(final.status, 'Finalizada');
});

test('live activity sends ActivityKit payload and removes registration only on successful end', async () => {
    const queries = [];
    const pool = { query: async (query, params) => {
        queries.push({query, params});
        if (query.startsWith('SELECT')) return {rows: [{activity_id:'a', token:'abcd', bundle_identifier:'app', environment:'sandbox', content_state: state}]};
        return {rows: []};
    }};
    const calls = [];
    const dispatcher = {sendToRecipient: async (event, recipient) => { calls.push({event, recipient}); return {ok:true}; }};
    const service = new LiveActivityService({pool, dispatcher, bundleIdentifier: 'app'});
    await service.update({matchKey: 'm', status:'completed', setScores:[{number:1,player1Games:'6',player2Games:'4'},{number:2,player1Games:'6',player2Games:'3'}]});
    assert.equal(calls[0].event.notification.aps.event, 'end');
    assert.equal(calls[0].event.notification.aps['content-state'].player1SetsWon, 2);
    assert.ok(queries.some(q => q.query.startsWith('DELETE')));
});

test('registration requires secret and app bundle identity', async () => {
    const pool = {query: async () => ({rows:[{activity_id:'a'}]})};
    const service = new LiveActivityService({pool, dispatcher:{}, bundleIdentifier:'app'});
    await assert.rejects(service.register({action:'register', activityId:'a', registrationSecret:'x'.repeat(32), matchKey:'m', token:'a'.repeat(64), bundleIdentifier:'wrong', environment:'sandbox', contentState:state}), {statusCode:400});
});

test('a partial later set keeps previously known completed sets', () => {
    const initial = {...state, setScores: [{player1Games: '6', player2Games: '4'}, {player1Games:'2', player2Games:'2'}]};
    const result = mergeState(initial, {setScores: [{number: 2, player1Games: '3', player2Games:'2'}]});
    assert.deepEqual(result.setScores, [{player1Games:'6', player2Games:'4'}, {player1Games:'3', player2Games:'2'}]);
    assert.equal(result.player1SetsWon, 1);
});

test('REST reconciliation only ends explicitly completed registered matches', async () => {
    const {reconcileLiveActivities} = await import('../src/liveActivityReconciler.js');
    const pool = {query: async () => ({rows:[{match_key:'m'}, {match_key:'missing'}]})};
    const updates = [];
    const service = {update: async frame => updates.push(frame)};
    const fetchImpl = async () => ({ok:true, json:async () => ({success:1, result:[
        {event_key:'m', event_status:'Finished', event_final_result:'2-0', scores:[{score_set:'1', score_first:'6', score_second:'4'}, {score_set:'2', score_first:'6', score_second:'2'}]},
        {event_key:'other', event_status:'Finished'}
    ]})});
    await reconcileLiveActivities({pool, service, fetchImpl, env:{API_TENNIS_KEY:'test'}, now:new Date('2026-11-14T12:00:00Z')});
    assert.equal(updates.length, 1);
    assert.equal(updates[0].score, '6-4 6-2');
    assert.equal(updates[0].status, 'completed');
});

test('REST reconciliation keeps activities on provider errors or missing fixtures', async () => {
    const {reconcileLiveActivities} = await import('../src/liveActivityReconciler.js');
    const pool = {query: async () => ({rows:[{match_key:'m'}]})};
    const updates = [];
    const options = {pool, service:{update:async frame => updates.push(frame)}, env:{API_TENNIS_KEY:'test'}};
    await assert.rejects(reconcileLiveActivities({...options, fetchImpl:async () => ({ok:false, status:503})}));
    await reconcileLiveActivities({...options, fetchImpl:async () => ({ok:true, json:async () => ({success:1, result:[]})})});
    assert.equal(updates.length, 0);
});

function subscriptionPool(count = 1) {
    const rows = Array.from({length: count}, (_, index) => ({activity_id: `activity-${index}`, token: `token-${index}`,
        match_key: 'match', bundle_identifier: 'app', environment: 'production', content_state: structuredClone(state)}));
    return {rows, query: async (sql, params = []) => {
        if (sql.startsWith('SELECT')) return {rows: rows.filter(row => row.match_key === params[0]).map(row => structuredClone(row))};
        if (sql.startsWith('UPDATE')) {
            const row = rows.find(row => row.activity_id === params[1] && row.token === params[2]);
            if (row) row.content_state = JSON.parse(params[0]);
        }
        if (sql.startsWith('DELETE')) {
            const index = rows.findIndex(row => row.activity_id === params[0] && row.token === params[1]);
            if (index >= 0) rows.splice(index, 1);
        }
        return {rows: []};
    }};
}

function testClock() {
    let time = Date.parse('2026-11-22T12:00:00Z');
    return {now: () => time, wait: async ms => { time += ms; }, advance: ms => { time += ms; }};
}
const turn = () => new Promise(resolve => setImmediate(resolve));

test('a slow subscriber does not block other subscribers for the same match', async () => {
    const pool = subscriptionPool(3);
    let release;
    const blocked = new Promise(resolve => {release = resolve;});
    const sent = [];
    const service = new LiveActivityService({pool, concurrency: 2, ...testClock(), dispatcher: {sendToRecipient: async (_, recipient) => {
        sent.push(recipient.deviceToken);
        if (recipient.deviceToken === 'token-0') await blocked;
        return {ok: true};
    }}});
    const operation = service.update({matchKey:'match', status:'live', pointScore:'30-30'});
    await turn();
    assert.deepEqual(sent, ['token-0', 'token-1', 'token-2']);
    release();
    await operation;
    service.stop();
});

test('bursts coalesce obsolete points while retaining sparse numbered sets', async () => {
    const pool = subscriptionPool();
    const sent = [];
    let release;
    const blocked = new Promise(resolve => {release = resolve;});
    const service = new LiveActivityService({pool, ...testClock(), dispatcher: {sendToRecipient: async event => {
        sent.push(event.notification.aps);
        if (sent.length === 1) await blocked;
        return {ok: true};
    }}});
    const first = service.update({matchKey:'match', status:'live', pointScore:'30-30'});
    await turn();
    const second = service.update({matchKey:'match', status:'live', gameScore:'6-4', setScores:[{number:1, player1Games:'6', player2Games:'4'}], pointScore:'0-0'});
    const third = service.update({matchKey:'match', status:'live', gameScore:'1-0', setScores:[{number:2, player1Games:'1', player2Games:'0'}], pointScore:'15-0'});
    release();
    await Promise.all([first, second, third]);
    assert.equal(sent.length, 2);
    assert.deepEqual(sent[1]['content-state'].setScores, [{player1Games:'6', player2Games:'4'}, {player1Games:'1', player2Games:'0'}]);
    assert.equal(sent[1]['content-state'].pointScore, '15-0');
    assert.equal(service.health().framesCoalesced, 2);
    service.stop();
});

test('unchanged provider frames do not exhaust APNs budget; heartbeat has low priority', async () => {
    const pool = subscriptionPool();
    const clock = testClock();
    const sent = [];
    const service = new LiveActivityService({pool, ...clock, dispatcher:{sendToRecipient:async event => {sent.push(event); return {ok:true};}}});
    await service.update({matchKey:'match', status:'live', pointScore:'30-30'});
    await service.update({matchKey:'match', status:'live', pointScore:'30-30'});
    assert.equal(sent.length, 1);
    clock.advance(61_000);
    await service.update({matchKey:'match', status:'live', pointScore:'30-30'});
    assert.equal(sent.length, 2);
    assert.equal(sent[0].priority, 'high');
    assert.equal(sent[1].priority, 'normal');
    assert.equal(sent[1].notification.aps['stale-date'] - sent[1].notification.aps.timestamp, 90);
    service.stop();
});

test('old REST responses cannot roll back a newer WebSocket frame', async () => {
    const pool = subscriptionPool();
    const sent = [];
    const service = new LiveActivityService({pool, ...testClock(), dispatcher:{sendToRecipient:async event => {sent.push(event); return {ok:true};}}});
    await service.update({matchKey:'match', status:'live', pointScore:'40-30', capturedAt:'2026-11-22T12:00:02Z'});
    await service.update({matchKey:'match', status:'live', pointScore:'15-30', capturedAt:'2026-11-22T12:00:01Z'});
    assert.equal(sent.length, 1);
    assert.equal(pool.rows[0].content_state.pointScore, '40-30');
    assert.equal(service.health().outdatedFrames, 1);
    service.stop();
});

test('failed pushes retain partial data and retry automatically without another provider frame', async () => {
    const pool = subscriptionPool();
    const clock = testClock();
    const sent = [];
    let retried;
    const retryCompleted = new Promise(resolve => {retried = resolve;});
    const service = new LiveActivityService({pool, ...clock, retryDelayMs: 5, dispatcher:{sendToRecipient:async event => {
        sent.push(event);
        if (sent.length === 1) return {ok:false, reason:'temporary unavailable'};
        retried();
        return {ok:true};
    }}});
    try {
        await service.update({matchKey:'match', status:'live', gameScore:'6-4', setScores:[{number:1, player1Games:'6', player2Games:'4'}]});
        assert.equal(pool.rows[0].content_state.setScores[0].player1Games, '6');
        await Promise.race([retryCompleted, new Promise((_, reject) => setTimeout(() => reject(new Error('automatic retry did not run')), 1000))]);
        await turn();
        assert.equal(sent.length, 2);
        assert.equal(sent[1].notification.aps['content-state'].player1SetsWon, 1);
        assert.equal(service.health().retryingMatches, 0);
    } finally {service.stop();}
});

test('final failure keeps subscription until successful automatic end; final cannot become live again', async () => {
    const pool = subscriptionPool();
    const sent = [];
    let retried;
    const completed = new Promise(resolve => {retried = resolve;});
    const service = new LiveActivityService({pool, ...testClock(), retryDelayMs:5, dispatcher:{sendToRecipient:async event => {
        sent.push(event);
        if (sent.length === 1) return {ok:false, reason:'temporary unavailable'};
        retried(); return {ok:true};
    }}});
    try {
        await service.update({matchKey:'match', status:'completed', setScores:[{number:1, player1Games:'6', player2Games:'4'}]});
        assert.equal(pool.rows.length, 1);
        const final = mergeState(pool.rows[0].content_state, {status:'live', pointScore:'0-0', gameScore:'1-0', setScores:[{number:1, player1Games:'1', player2Games:'0'}]});
        assert.equal(final.isLive, false);
        assert.equal(final.setScores[0].player1Games, '6');
        await Promise.race([completed, new Promise((_, reject) => setTimeout(() => reject(new Error('end retry did not run')), 1000))]);
        await turn();
        assert.equal(pool.rows.length, 0);
        assert.equal(sent[1].notification.aps.event, 'end');
        assert.equal(sent[1].notification.aps['dismissal-date'] - sent[1].notification.aps.timestamp, 30);
        assert.equal(sent[1].priority, 'high');
    } finally {service.stop();}
});

test('whole-second APNs timestamps increase using real clock boundaries and preserve source age', async () => {
    const pool = subscriptionPool();
    const clock = testClock();
    const sent = [];
    const service = new LiveActivityService({pool, ...clock, dispatcher:{sendToRecipient:async event => {sent.push(event.notification.aps); return {ok:true};}}});
    await service.update({matchKey:'match', status:'live', pointScore:'30-30', capturedAt:'2026-11-22T11:59:50Z'});
    await service.update({matchKey:'match', status:'live', pointScore:'40-30', capturedAt:'2026-11-22T11:59:51Z'});
    assert.equal(sent[1].timestamp, sent[0].timestamp + 1);
    assert.equal(sent[1].timestamp, Math.floor(clock.now() / 1000));
    assert.equal(sent[1]['content-state'].lastUpdated, Date.parse('2026-11-22T11:59:51Z') / 1000 - 978307200);
    assert.equal(sent[1]['stale-date'], Date.parse('2026-11-22T11:59:51Z') / 1000 + 90);
    service.stop();
});

test('REST with provider lag is suppressed while the stream is fresh, then recovers during silence', async () => {
    const pool = subscriptionPool();
    const clock = testClock();
    const sent = [];
    const service = new LiveActivityService({pool, ...clock, dispatcher:{sendToRecipient:async event => {sent.push(event.notification.aps); return {ok:true};}}});
    await service.update({matchKey:'match', status:'live', pointScore:'40-30', capturedAt:'2026-11-22T12:00:00Z'});
    await service.update({matchKey:'match', status:'live', pointScore:'15-30', capturedAt:'2026-11-22T12:00:01Z', source:'rest-reconciliation'});
    assert.equal(sent.length, 1);
    assert.equal(service.health().fallbackFramesSuppressed, 1);
    clock.advance(31_000);
    await service.update({matchKey:'match', status:'live', pointScore:'0-15', gameScore:'5-3', capturedAt:'2026-11-22T12:00:31Z', source:'rest-reconciliation'});
    assert.equal(sent.length, 2);
    assert.equal(sent[1]['content-state'].pointScore, '0-15');
    await service.update({matchKey:'match', status:'completed', capturedAt:'2026-11-22T12:00:32Z', source:'rest-reconciliation'});
    assert.equal(sent[2].event, 'end');
    service.stop();
});

test('unchanged stream heartbeats do not indefinitely suppress REST progress', async () => {
    const pool = subscriptionPool();
    const clock = testClock();
    const sent = [];
    const service = new LiveActivityService({pool, ...clock, dispatcher:{sendToRecipient:async event => {sent.push(event.notification.aps); return {ok:true};}}});
    await service.update({matchKey:'match', status:'live', pointScore:'30-30', capturedAt:'2026-11-22T12:00:00Z'});
    clock.advance(20_000);
    await service.update({matchKey:'match', status:'live', pointScore:'30-30', capturedAt:'2026-11-22T12:00:20Z'});
    clock.advance(11_000);
    await service.update({matchKey:'match', status:'live', pointScore:'40-30', capturedAt:'2026-11-22T12:00:31Z', source:'rest-reconciliation'});
    assert.equal(sent.length, 2);
    assert.equal(sent[1]['content-state'].pointScore, '40-30');
    clock.advance(1000);
    await service.update({matchKey:'match', status:'live', pointScore:'30-30', capturedAt:'2026-11-22T12:00:32Z'});
    assert.equal(sent.length, 2);
    assert.equal(pool.rows[0].content_state.pointScore, '40-30');
    service.stop();
});

test('confirmed final marker survives delivery failure but is not sent to ActivityKit or trusted from clients', async () => {
    const pool = subscriptionPool();
    const sent = [];
    const service = new LiveActivityService({pool, ...testClock(), retryDelayMs:10000, dispatcher:{sendToRecipient:async event => {sent.push(event); return {ok:false};}}});
    try {
        await service.update({matchKey:'match', status:'completed'});
        assert.equal(pool.rows[0].content_state._terminalConfirmed, true);
        assert.equal(sent[0].notification.aps['content-state']._terminalConfirmed, undefined);
    } finally {service.stop();}
    let registration;
    const registering = new LiveActivityService({pool:{query:async (_, params) => {registration = JSON.parse(params[6]); return {rows:[{activity_id:'a'}]};}}, dispatcher:{}, bundleIdentifier:'app'});
    await registering.register({action:'register', activityId:'a', registrationSecret:'x'.repeat(32), matchKey:'m', token:'a'.repeat(64), bundleIdentifier:'app', environment:'production', contentState:{...state, _terminalConfirmed:true}});
    assert.equal(registration._terminalConfirmed, undefined);
    registering.stop();
});

test('team activity preserves actual result through sparse individual placeholders', () => {
    const initial = {...state, teamScore:[2,1]};
    const partial = mergeState(initial, {status:'live', setScores:[{number:1,player1Games:'0',player2Games:'0'}], pointScore:'0-0', gameScore:'0-0'});
    assert.deepEqual(partial.teamScore, [2,1]);
    assert.deepEqual(partial.setScores, []);
    assert.equal(partial.pointScore, '');
    assert.equal(partial.gameScore, '');
    const final = mergeState(partial, {status:'completed', isTeamTie:true, teamScore:[4,0]});
    assert.deepEqual(final.teamScore, [4,0]);
    assert.equal(final.isLive, false);
    assert.equal(final.serverIsPlayerOne, null);
});
