import { buildAPITennisURL } from './apiTennisProxy.js';
import { frameToSnapshot } from './ingesters/apiTennisWebSocketIngester.js';

// Reconcile only explicit final results. Missing fixtures, stale caches and
// failed provider requests are never evidence that a match has ended.
export async function reconcileLiveActivities({pool, service, fetchImpl = fetch, env = process.env, now = new Date()}) {
    if (!pool) return;
    const {rows} = await pool.query('SELECT DISTINCT match_key FROM live_activity_subscriptions WHERE expires_at>NOW()');
    const keys = new Set(rows.map(row => row.match_key));
    if (!keys.size) return;
    for (const offset of [-1, 0]) {
        const date = new Date(now.getTime() + offset * 86400000).toISOString().slice(0, 10);
        const url = buildAPITennisURL(`/tennis?method=get_fixtures&date_start=${date}&date_stop=${date}&timezone=America%2FNew_York`, env);
        const response = await fetchImpl(url, {signal: AbortSignal.timeout(30000), headers: {accept: 'application/json'}});
        if (!response.ok) throw new Error(`Fixture reconciliation HTTP ${response.status}`);
        const payload = await response.json();
        if (payload?.success !== 1 || !Array.isArray(payload.result)) continue;
        for (const fixture of payload.result) {
            const snapshot = frameToSnapshot(fixture);
            if (snapshot && keys.has(snapshot.matchKey) && snapshot.status === 'completed') {
                await service.update(snapshot);
                keys.delete(snapshot.matchKey);
            }
        }
        if (!keys.size) break;
    }
}

export function startLiveActivityReconciliation(options, intervalMs = 120000) {
    let running = false;
    const timer = setInterval(async () => {
        if (running) return;
        running = true;
        try { await reconcileLiveActivities(options); }
        catch (error) { console.error('live activity reconciliation failed', error.message); }
        finally { running = false; }
    }, intervalMs);
    timer.unref?.();
    return () => clearInterval(timer);
}
