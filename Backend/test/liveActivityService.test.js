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
