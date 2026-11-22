import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { generateKeyPairSync } from 'node:crypto';
import test from 'node:test';
import { ApnsDispatcher } from '../src/dispatchers/apnsDispatcher.js';

class Request extends EventEmitter {
    setEncoding() {}
    write(data) { this.payload = data; }
    end() { this.onEnd?.(this); }
    close() { this.closed = true; this.emit('close'); }
}
class Dispatcher extends ApnsDispatcher {
    constructor(options = {}) {
        super({ keyPath: 'unused-test-key', keyId: 'test', teamId: 'test', requestTimeoutMs: 10, ...options });
        this.request = new Request();
        this.session = {
            request: headers => { this.headers = headers; return this.request; },
            destroy() { this.destroyed = true; }
        };
    }
    getSession(host) { this._sessions.set(host, this.session); return this.session; }
    async getProviderToken() { return 'test-provider-token'; }
}
const recipient = { deviceToken: 'test-device-token', bundleIdentifier: 'ALTB.Match-Point', environment: 'sandbox' };

test('important scores and end events use immediate delivery while routine refreshes remain low priority', async () => {
    for (const [event, expected] of [
        [{ kind: 'live-activity', priority: 'high', notification: { aps: { event: 'update' } } }, '10'],
        [{ kind: 'live-activity', notification: { aps: { event: 'update' } } }, '5'],
        [{ kind: 'live-activity', notification: { aps: { event: 'end' } } }, '10']
    ]) {
        const dispatcher = new Dispatcher();
        dispatcher.request.onEnd = request => { request.emit('response', { ':status': 200 }); request.emit('end'); };
        assert.equal((await dispatcher.sendToRecipient(event, recipient)).ok, true);
        assert.equal(dispatcher.headers['apns-priority'], expected);
        assert.equal(dispatcher.headers['apns-topic'], 'ALTB.Match-Point.push-type.liveactivity');
        assert.equal(dispatcher.headers['apns-push-type'], 'liveactivity');
        const retention = Number(dispatcher.headers['apns-expiration']) - Math.floor(Date.now() / 1000);
        assert.ok(event.notification.aps.event === 'end' ? retention >= 14399 : retention >= 59);
    }
});

test('a stalled APNs stream times out and discards the broken session so later scores can proceed', async t => {
    t.mock.timers.enable({ apis: ['setTimeout', 'Date'], now: 0 });
    const dispatcher = new Dispatcher();
    const response = dispatcher.sendToRecipient({ kind: 'live-activity', notification: { aps: { event: 'update' } } }, recipient);
    await Promise.resolve();
    t.mock.timers.tick(10);
    const result = await response;
    assert.equal(result.ok, false);
    assert.match(result.reason, /timed out/);
    assert.equal(dispatcher.session.destroyed, true);
    assert.equal(dispatcher.request.closed, true);
    assert.equal(dispatcher._sessions.size, 0);
});

test('a stream closed before its complete response is a retryable failure', async () => {
    const dispatcher = new Dispatcher();
    dispatcher.request.onEnd = request => request.emit('close');
    const result = await dispatcher.sendToRecipient({ kind: 'live-activity', notification: { aps: { event: 'end' } } }, recipient);
    assert.equal(result.ok, false);
    assert.match(result.reason, /before response completed/);
});

test('an old session close does not remove a replacement session', () => {
    const dispatcher = new Dispatcher();
    const old = { destroy() { this.destroyed = true; } };
    const replacement = { destroy() { this.destroyed = true; } };
    dispatcher._sessions.set('api.push.apple.com', replacement);
    dispatcher.dropSession('api.push.apple.com', old);
    assert.equal(dispatcher._sessions.get('api.push.apple.com'), replacement);
    assert.equal(replacement.destroyed, undefined);
});

test('APNs invalid-token errors are distinguished from transient service errors', async () => {
    for (const [status, reason, invalid] of [[410, 'Unregistered', true], [503, 'ServiceUnavailable', false]]) {
        const dispatcher = new Dispatcher();
        dispatcher.request.onEnd = request => {
            request.emit('response', { ':status': status });
            request.emit('data', JSON.stringify({ reason }));
            request.emit('end');
        };
        const result = await dispatcher.sendToRecipient({ kind: 'live-activity', notification: { aps: { event: 'update' } } }, recipient);
        assert.equal(result.ok, false);
        assert.equal(result.invalidToken, invalid);
    }
});

test('concurrent requests share one provider JWT refresh rather than rotating it for every match', async () => {
    const dispatcher = new ApnsDispatcher({ keyPath: 'unused-test-key', keyId: 'test', teamId: 'test' });
    const { privateKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
    let keyLoads = 0;
    dispatcher.loadKey = async () => { keyLoads++; await Promise.resolve(); return privateKey; };
    const tokens = await Promise.all(Array.from({ length: 20 }, () => dispatcher.getProviderToken(1000)));
    assert.equal(keyLoads, 1);
    assert.equal(new Set(tokens).size, 1);
    assert.equal(await dispatcher.getProviderToken(2000), tokens[0]);
    assert.equal(keyLoads, 1);
});
