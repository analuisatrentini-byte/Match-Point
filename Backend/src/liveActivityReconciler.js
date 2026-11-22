import { buildAPITennisURL } from './apiTennisProxy.js';
import { frameToSnapshot } from './ingesters/apiTennisWebSocketIngester.js';

// Poll only while subscriptions exist. This independent server-side recovery
// path keeps ActivityKit updated during a silent/disconnected provider stream,
// including its final frame, without waking the iOS app or using stale proxy data.
export async function reconcileLiveActivities({pool, service, fetchImpl = fetch, env = process.env, now = new Date()}) {
    if (!pool) return {subscriptions: 0, live: 0, ended: 0};
    const {rows} = await pool.query('SELECT match_key, content_state FROM live_activity_subscriptions WHERE expires_at>NOW()');
    const keys = new Set(rows.map(row => row.match_key));
    const result = {subscriptions: keys.size, live: 0, ended: 0};
    if (!keys.size) return result;
    for (const row of rows) {
        const state = row.content_state;
        if (!keys.has(row.match_key) || state?._terminalConfirmed !== true || state.isLive !== false ||
            !Number.isFinite(state.lastUpdated) || !Array.isArray(state.setScores)) continue;
        // Replay a server-confirmed end after a process crash or APNs outage,
        // even after the provider stops returning that match in its fixtures.
        await service.update({matchKey: row.match_key, status: 'completed', source: 'rest-reconciliation',
            capturedAt: new Date((state.lastUpdated + 978307200) * 1000).toISOString(),
            setScores: state.setScores.map((set, index) => ({...set, number: index + 1})), gameScore: state.gameScore});
        keys.delete(row.match_key);
        result.ended++;
    }
    if (!keys.size) return result;
    const errors = [];
    const load = async path => {
        const requestedAt = new Date().toISOString();
        const url = buildAPITennisURL(path, env);
        const response = await fetchImpl(url, {signal: AbortSignal.timeout(10000), headers: {accept: 'application/json', 'cache-control': 'no-cache'}});
        if (!response.ok) throw new Error(`Live Activity reconciliation HTTP ${response.status}`);
        const payload = await response.json();
        if (payload?.success !== 1 || !Array.isArray(payload.result)) throw new Error('Invalid Live Activity reconciliation response');
        return {fixtures: payload.result, requestedAt};
    };
    const apply = async ({fixtures, requestedAt}) => {
        for (const fixture of fixtures) {
            const snapshot = frameToSnapshot(fixture);
            if (!snapshot || !keys.has(snapshot.matchKey) || !['live', 'completed'].includes(snapshot.status)) continue;
            // Order a REST snapshot by request start. A response fetched before
            // a newer WebSocket update must not roll that update back.
            snapshot.capturedAt = requestedAt;
            snapshot.source = 'rest-reconciliation';
            await service.update(snapshot);
            if (snapshot.status === 'completed') result.ended++;
            else result.live++;
            keys.delete(snapshot.matchKey);
        }
    };
    try {
        await apply(await load('/tennis?method=get_livescore&timezone=America%2FNew_York'));
    } catch (error) { errors.push(error); }
    if (keys.size) {
        // Fixture dates must use the provider timezone, especially around UTC
        // midnight. Fetch both days concurrently so one outage doesn't hide a
        // valid final result returned by the other request.
        const today = providerDate(now);
        const loads = await Promise.allSettled([-1, 0].map(offset => {
            const date = new Date(Date.parse(`${today}T12:00:00Z`) + offset * 86400000).toISOString().slice(0, 10);
            return load(`/tennis?method=get_fixtures&date_start=${date}&date_stop=${date}&timezone=America%2FNew_York`);
        }));
        // Prefer today's result over yesterday's if a provider repeats an ID.
        for (const entry of loads.reverse()) {
            if (entry.status === 'fulfilled') await apply(entry.value);
            else errors.push(entry.reason);
        }
    }
    // Absence from both endpoints is not a terminal result. A partial failure
    // remains visible to monitoring even when other valid updates were applied.
    if (errors.length) throw new AggregateError(errors, errors.map(error => error.message).join('; '));
    return result;
}

function providerDate(date) {
    const parts = new Intl.DateTimeFormat('en-US', {timeZone: 'America/New_York', year: 'numeric', month: '2-digit', day: '2-digit'}).formatToParts(date);
    const value = type => parts.find(part => part.type === type).value;
    return `${value('year')}-${value('month')}-${value('day')}`;
}

export function startLiveActivityReconciliation(options, intervalMs = 30000) {
    let running = false;
    let stopped = false;
    const stats = {runs: 0, failures: 0, lastStartedAt: null, lastSuccessAt: null, lastErrorAt: null, lastError: null};
    const run = async () => {
        if (running || stopped) return;
        running = true;
        stats.runs++;
        stats.lastStartedAt = new Date().toISOString();
        try {
            await reconcileLiveActivities(options);
            stats.lastSuccessAt = new Date().toISOString();
            stats.lastError = null;
        } catch (error) {
            stats.failures++;
            stats.lastErrorAt = new Date().toISOString();
            // Messages contain status/validation errors, never provider URLs.
            stats.lastError = 'Provider reconciliation failed';
            console.error('live activity reconciliation failed', error.message);
        } finally { running = false; }
    };
    // Recovery begins on process startup; no need to wait a full interval after
    // a deployment/restart to restore existing subscriptions.
    void run();
    const timer = setInterval(run, intervalMs);
    timer.unref?.();
    const stop = () => { stopped = true; clearInterval(timer); };
    stop.health = () => ({...stats, running});
    return stop;
}
