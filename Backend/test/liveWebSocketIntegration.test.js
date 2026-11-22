import assert from 'node:assert/strict';
import { once } from 'node:events';
import test from 'node:test';
import { ApiTennisWebSocketIngester } from '../src/ingesters/apiTennisWebSocketIngester.js';
import { LiveActivityService } from '../src/liveActivityService.js';

test('a real provider socket reconnects and forwards the confirmed final without any app request', { timeout: 5000 }, async t => {
    let WebSocketServer;
    try { ({ WebSocketServer } = await import('ws')); }
    catch { t.skip('Optional ws dependency is not installed'); return; }
    const server = new WebSocketServer({ port: 0, host: '127.0.0.1' });
    await once(server, 'listening');
    let connections = 0;
    const received = [];
    const delivered = [];
    let subscription = {activity_id:'local-activity', match_key:'provider-match', token:'local-test-token',
        bundle_identifier:'test.app', environment:'sandbox', content_state:{
            player1SetsWon:0, player2SetsWon:0, currentSetIndex:0, setScores:[],
            pointScore:'', gameScore:'', serverIsPlayerOne:null, status:'Ao vivo', isLive:true, lastUpdated:0
        }};
    const pool = {query: async (sql, params) => {
        if (sql.startsWith('SELECT')) return {rows:subscription ? [structuredClone(subscription)] : []};
        if (sql.startsWith('UPDATE') && subscription) subscription.content_state = JSON.parse(params[0]);
        if (sql.startsWith('DELETE')) subscription = null;
        return {rows:[]};
    }};
    const activities = new LiveActivityService({pool, dispatcher:{sendToRecipient:async event => {
        delivered.push(event.notification.aps);
        return {ok:true};
    }}});
    let completed;
    const final = new Promise(resolve => { completed = resolve; });
    server.on('connection', socket => {
        connections++;
        if (connections === 1) {
            socket.send(JSON.stringify({ result: [{
                event_key: 'provider-match', event_status: 'Set 2', event_live: '1',
                scores: [{ score_set: '1', score_first: '6', score_second: '4' }, { score_set: '2', score_first: '5', score_second: '3' }],
                event_game_result: '40-15'
            }] }));
            // Abrupt upstream loss, with no foreground app to restart it.
            setTimeout(() => socket.terminate(), 20);
        } else {
            socket.send(JSON.stringify({ result: [{
                event_key: 'provider-match', event_status: 'Finished', event_live: '0',
                scores: [{ score_set: '1', score_first: '6', score_second: '4' }, { score_set: '2', score_first: '6', score_second: '3' }]
            }] }));
        }
    });
    const client = new ApiTennisWebSocketIngester({
        url: `ws://127.0.0.1:${server.address().port}/live`, apiKey: 'local-test-only',
        minBackoffMs: 5, maxBackoffMs: 10, connectTimeoutMs: 1000,
        heartbeatIntervalMs: 100, heartbeatTimeoutMs: 100, silenceTimeoutMs: 2000,
        ingestionService: { ingestFrame: async frame => {
            received.push(frame);
            await activities.update({...frame, source:'api-tennis-ws'});
            if (frame.status === 'completed') completed();
        } }
    });
    t.after(async () => {
        client.stop();
        activities.stop();
        for (const socket of server.clients) socket.terminate();
        await new Promise(resolve => server.close(resolve));
    });
    await client.start();
    await final;
    assert.equal(connections, 2);
    assert.equal(client.stats.reconnects, 1);
    assert.deepEqual(received.map(frame => frame.status), ['live', 'completed']);
    assert.equal(received.at(-1).score, '6-4 6-3');
    assert.equal(received.at(-1).matchKey, 'provider-match');
    assert.ok(client.stats.lastConnectedAt);
    assert.deepEqual(delivered.map(aps => aps.event), ['update', 'end']);
    assert.equal(delivered[0]['content-state'].gameScore, '5-3');
    assert.equal(delivered[0]['content-state'].pointScore, '40-15');
    assert.equal(delivered[1]['content-state'].isLive, false);
    assert.equal(delivered[1]['content-state'].player1SetsWon, 2);
    assert.equal(delivered[1]['content-state'].setScores[1].player1Games, '6');
    assert.equal(delivered[1]['dismissal-date'] - delivered[1].timestamp, 30);
    assert.ok(delivered[1].timestamp > delivered[0].timestamp);
    assert.equal(subscription, null);
});
