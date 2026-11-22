import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import test from 'node:test';
import { ApiTennisWebSocketIngester, frameToSnapshot } from '../src/ingesters/apiTennisWebSocketIngester.js';

class Socket extends EventEmitter {
    static instances = [];
    constructor(url) { super(); this.url = url; this.pings = 0; Socket.instances.push(this); }
    ping() { this.pings++; if (this.autoPong) this.emit('pong'); }
    terminate() { this.terminated = true; }
    close() { this.closed = true; }
}

function ingester(options = {}) {
    return new ApiTennisWebSocketIngester({
        ingestionService: { ingestFrame: async () => {} }, WebSocketClass: Socket,
        connectTimeoutMs: 15, heartbeatIntervalMs: 20, heartbeatTimeoutMs: 10,
        silenceTimeoutMs: 90, minBackoffMs: 5, maxBackoffMs: 30, ...options
    });
}

test('a handshake that never opens is closed and fails within the deadline', async t => {
    t.mock.timers.enable({ apis: ['setTimeout', 'setInterval', 'Date'], now: 0 });
    const client = ingester();
    const connection = client._connectOnce(Socket);
    const socket = Socket.instances.at(-1);
    const failed = assert.rejects(connection, /connection timed out/);
    t.mock.timers.tick(15);
    await failed;
    assert.equal(socket.terminated, true);
    assert.equal(client.stats.connected, false);
});

test('a half-open connection without pong is recycled automatically', async t => {
    t.mock.timers.enable({ apis: ['setTimeout', 'setInterval', 'Date'], now: 0 });
    const client = ingester();
    const connection = client._connectOnce(Socket);
    const socket = Socket.instances.at(-1);
    socket.emit('open');
    assert.equal(client.stats.connected, true);
    const failed = assert.rejects(connection, /heartbeat timed out/);
    t.mock.timers.tick(20);
    assert.equal(socket.pings, 1);
    t.mock.timers.tick(10);
    await failed;
    assert.equal(client.stats.watchdogReconnects, 1);
    assert.equal(socket.terminated, true);
});

test('a responsive socket with a silent match stream is resubscribed', async t => {
    t.mock.timers.enable({ apis: ['setTimeout', 'setInterval', 'Date'], now: 0 });
    const client = ingester();
    const connection = client._connectOnce(Socket);
    const socket = Socket.instances.at(-1);
    socket.autoPong = true;
    socket.emit('open');
    const failed = assert.rejects(connection, /stream went silent/);
    for (let i = 0; i < 9; i++) t.mock.timers.tick(10);
    await failed;
    assert.ok(client.stats.lastHeartbeatAt);
    assert.equal(client.stats.watchdogReconnects, 1);
});

test('failed old sockets cannot forward frames after a replacement', async () => {
    const frames = [];
    const client = ingester({ ingestionService: { ingestFrame: async frame => frames.push(frame) } });
    const connection = client._connectOnce(Socket);
    const socket = Socket.instances.at(-1);
    socket.emit('open');
    const failed = assert.rejects(connection, /connection reset/);
    socket.emit('error', new Error('connection reset'));
    socket.emit('message', JSON.stringify({ event_key: 'old', event_live: '1' }));
    await failed;
    assert.equal(frames.length, 0);
    assert.equal(socket.terminated, true);
});

test('stop completes a connection without waiting for a provider close event', async () => {
    const client = ingester();
    const connection = client._connectOnce(Socket);
    const socket = Socket.instances.at(-1);
    socket.emit('open');
    client.stop();
    await connection;
    assert.equal(socket.terminated, true);
    assert.equal(client.stats.connected, false);
});

test('transient policy/server closes reconnect while confirmed bad credentials stop', async t => {
    t.mock.timers.enable({ apis: ['setTimeout', 'setInterval', 'Date'], now: 0 });
    const client = ingester();
    await client.start();
    let socket = Socket.instances.at(-1);
    socket.emit('open');
    socket.emit('close', 1011, Buffer.from('server unavailable'));
    await Promise.resolve();
    t.mock.timers.tick(5);
    await Promise.resolve();
    assert.equal(client.stats.reconnects, 1);
    assert.equal(client.stats.connections, 2);
    socket = Socket.instances.at(-1);
    socket.emit('unexpected-response', null, { statusCode: 403, resume() {} });
    await Promise.resolve();
    assert.equal(client._running, false);
    assert.equal(client.stats.lastError, 'WebSocket handshake rejected: 403');
    client.stop();
});

test('provider terminal states override a lingering live flag, including retirement and walkover', () => {
    for (const status of ['Finished', 'Completed', 'Retired', 'RET.', 'W.O.', 'Walkover', 'Cancelled', 'Abandoned']) {
        assert.equal(frameToSnapshot({ event_key: 'm', event_status: status, event_live: '1' }).status, 'completed', status);
    }
    for (const status of ['Set 1', 'Set 4', 'Set 5', 'Tie Break', 'Match Tie Break']) {
        assert.equal(frameToSnapshot({ event_key: 'm', event_status: status }).status, 'live', status);
    }
    assert.equal(frameToSnapshot({ event_key: 'm', event_live: true }).status, 'live');
    assert.equal(frameToSnapshot({ event_key: 'm', event_break_point: '0' }).breakPoint, false);
    assert.equal(frameToSnapshot({ event_key: 'm', event_break_point: '1' }).breakPoint, true);
});

test('numbered scores and binary messages preserve every match in a provider batch', async () => {
    const frames = [];
    const client = ingester({ ingestionService: { ingestFrame: async frame => frames.push(frame) } });
    const connection = client._connectOnce(Socket);
    const socket = Socket.instances.at(-1);
    socket.emit('open');
    const message = Buffer.from(JSON.stringify({ result: [
        { event_key: 'a', event_status: 'Set 4', scores: [{ score_set: '2', score_first: '3', score_second: '6' }, { score_set: '1', score_first: '6', score_second: '4' }] },
        { event_key: 'b', event_status: 'Finished' }
    ] }));
    socket.emit('message', message);
    await Promise.resolve();
    assert.deepEqual(frames.map(frame => frame.matchKey), ['a', 'b']);
    assert.equal(frames[0].score, '6-4 3-6');
    assert.equal(frames[1].status, 'completed');
    client.stop();
    await connection;
});
