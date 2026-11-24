import { createHash } from 'node:crypto';

const hash = value => createHash('sha256').update(value).digest('hex');
const validState = state => state && typeof state === 'object' && Array.isArray(state.setScores)
    && typeof state.pointScore === 'string' && typeof state.gameScore === 'string'
    && Number.isFinite(state.lastUpdated)
    && (state.teamScore == null || (Array.isArray(state.teamScore) && state.teamScore.length === 2 && state.teamScore.every(v => Number.isSafeInteger(v) && v >= 0)))
    && (state.isTeamTie == null || typeof state.isTeamTie === 'boolean');
const foundationEpoch = 978307200;
const terminalState = state => state?.isLive === false && /^(finalizada|finalizado|finished|completed|ended|retired|walkover|cancelled|canceled)$/i.test(state.status ?? '');
const capturedTime = (snapshot, fallback) => {
    const time = Date.parse(snapshot.capturedAt);
    return Number.isFinite(time) ? time : fallback;
};
const contentHash = state => hash(JSON.stringify({...state, lastUpdated: 0}));
const frameHash = snapshot => hash(JSON.stringify([snapshot.status, snapshot.setScores ?? [], snapshot.gameScore ?? '', snapshot.pointScore ?? '', snapshot.serverName ?? '', snapshot.teamScore ?? null]));
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

// Live Activity tokens are independent of device tokens. An installation-held
// random secret authenticates token rotation and deletion without exposing it in DB.
export class LiveActivityService {
    constructor({ pool, dispatcher, bundleIdentifier = process.env.APNS_BUNDLE_ID,
        concurrency = 16, retryDelayMs = 2_000, heartbeatMs = 60_000,
        now = Date.now, wait = sleep, staleAfterSeconds = 90, finalDismissalSeconds = 30 }) {
        this.pool = pool;
        this.dispatcher = dispatcher;
        this.bundleIdentifier = bundleIdentifier;
        this.concurrency = Math.max(1, concurrency);
        this.retryDelayMs = retryDelayMs;
        this.heartbeatMs = heartbeatMs;
        this.now = now;
        this.wait = wait;
        this.staleAfterSeconds = staleAfterSeconds;
        this.finalDismissalSeconds = finalDismissalSeconds;
        this.pending = new Map();
        this.retries = new Map();
        this.retryAttempts = new Map();
        this.latest = new Map();
        this.lastDelivered = new Map();
        this.lastPushTimestamp = new Map();
        this.stopped = false;
        this.stats = { framesReceived: 0, framesCoalesced: 0, outdatedFrames: 0, fallbackFramesSuppressed: 0,
            pushesSent: 0, pushesDeduped: 0, pushesFailed: 0, activitiesEnded: 0,
            lastProviderAt: null, lastDeliveryAt: null };
    }

    async register(payload) {
        if (!this.pool || !this.dispatcher) throw Object.assign(new Error('Live Activity push unavailable'), {statusCode: 503});
        const { action, activityId, registrationSecret } = payload ?? {};
        if (!['register', 'unregister'].includes(action) || typeof activityId !== 'string' || activityId.length < 1 || activityId.length > 256 ||
            typeof registrationSecret !== 'string' || registrationSecret.length < 32 || registrationSecret.length > 256)
            throw Object.assign(new Error('Invalid activity registration'), {statusCode: 400});
        const secret = hash(registrationSecret);
        if (action === 'unregister') {
            await this.pool.query('DELETE FROM live_activity_subscriptions WHERE activity_id=$1 AND secret_hash=$2', [activityId, secret]);
            this.lastDelivered.delete(activityId);
            return;
        }
        const { matchKey, token, bundleIdentifier, environment, contentState } = payload;
        if (typeof matchKey !== 'string' || !matchKey.trim() || matchKey.length > 256 ||
            typeof token !== 'string' || !/^[a-fA-F0-9]{32,512}$/.test(token) ||
            typeof bundleIdentifier !== 'string' || !this.bundleIdentifier || bundleIdentifier !== this.bundleIdentifier ||
            !['sandbox', 'production'].includes(environment) || !validState(contentState))
            throw Object.assign(new Error('Invalid activity registration'), {statusCode: 400});
        const result = await this.pool.query(`INSERT INTO live_activity_subscriptions
            (activity_id, secret_hash, match_key, token, bundle_identifier, environment, content_state)
            VALUES ($1,$2,$3,$4,$5,$6,$7::jsonb)
            ON CONFLICT (activity_id) DO UPDATE SET token=EXCLUDED.token, match_key=EXCLUDED.match_key,
                bundle_identifier=EXCLUDED.bundle_identifier, environment=EXCLUDED.environment,
                updated_at=NOW()
            WHERE live_activity_subscriptions.secret_hash=EXCLUDED.secret_hash RETURNING activity_id`,
            [activityId, secret, matchKey, token.toLowerCase(), bundleIdentifier, environment, JSON.stringify(publicState(contentState))]);
        if (!result.rows.length) throw Object.assign(new Error('Registration rejected'), {statusCode: 403});
    }

    // Keep only the newest pending state, merging sparse set updates. A slow
    // APNs request must not build an unbounded queue of obsolete point scores.
    update(snapshot) {
        if (!snapshot?.matchKey || this.stopped) return Promise.resolve();
        this.stats.framesReceived++;
        const queued = this.pending.get(snapshot.matchKey);
        if (queued) {
            queued.snapshot = combineFrames(queued.snapshot, snapshot);
            this.stats.framesCoalesced++;
            return queued.operation;
        }
        const entry = {snapshot, current: snapshot, operation: null};
        entry.operation = Promise.resolve().then(async () => {
            while (entry.snapshot) {
                // ActivityKit orders pushes by whole-second timestamps. Wait
                // for a real clock boundary rather than invent a future date.
                const lastTimestamp = this.lastPushTimestamp.get(snapshot.matchKey);
                const time = this.now();
                if (lastTimestamp != null && Math.floor(time / 1000) <= lastTimestamp) {
                    await this.wait((lastTimestamp + 1) * 1000 - time);
                }
                const next = entry.snapshot;
                entry.snapshot = null;
                entry.current = next;
                await this.deliver(next);
            }
        }).catch(error => {
            this.scheduleRetry(combineFrames(entry.current, entry.snapshot));
            throw error;
        }).finally(() => {
            if (this.pending.get(snapshot.matchKey) === entry) this.pending.delete(snapshot.matchKey);
        });
        this.pending.set(snapshot.matchKey, entry);
        return entry.operation;
    }

    async deliver(snapshot) {
        if (!this.pool || !this.dispatcher) return;
        const { rows } = await this.pool.query('SELECT * FROM live_activity_subscriptions WHERE match_key=$1 AND expires_at>NOW()', [snapshot.matchKey]);
        if (!rows.length) {
            this.clearMatch(snapshot.matchKey);
            return;
        }
        const time = capturedTime(snapshot, this.now());
        const previous = this.latest.get(snapshot.matchKey);
        if (snapshot.status !== 'completed' && previous && (previous.ended || time < previous.time)) {
            this.stats.outdatedFrames++;
            return;
        }
        const fingerprint = frameHash(snapshot);
        const isRecovery = snapshot.source === 'rest-reconciliation';
        // Repeated old stream frames must not overwrite progress recovered
        // through REST while the provider stream is stuck on one score.
        const repeatedStream = !isRecovery && previous?.streamFingerprint === fingerprint;
        const effective = repeatedStream && snapshot.status !== 'completed' ? {matchKey: snapshot.matchKey, status: 'unknown'} : snapshot;
        const changed = contentHash(mergeState(rows[0].content_state, effective, time)) !== contentHash(publicState(rows[0].content_state));
        // A direct REST response may still lag behind the provider's own
        // WebSocket. Use it for recovery only after the stream is quiet.
        if (isRecovery && snapshot.status !== 'completed' && previous?.streamAt != null && time - previous.streamAt < 30_000) {
            this.stats.fallbackFramesSuppressed++;
            return;
        }
        const firstScoreFrame = !isRecovery && !previous?.streamFingerprint && (snapshot.setScores?.length || snapshot.gameScore || snapshot.pointScore);
        this.latest.set(snapshot.matchKey, {time: changed || firstScoreFrame ? time : previous?.time ?? time,
            ended: snapshot.status === 'completed' || previous?.ended === true,
            streamAt: !isRecovery && (changed || firstScoreFrame) ? time : previous?.streamAt,
            streamFingerprint: isRecovery ? previous?.streamFingerprint : fingerprint});
        this.stats.lastProviderAt = new Date(time).toISOString();
        let failed = false;
        let cursor = 0;
        const timestamp = Math.floor(this.now() / 1000);
        const workers = Array.from({length: Math.min(this.concurrency, rows.length)}, async () => {
            while (cursor < rows.length) {
                const row = rows[cursor++];
                try {
                    const state = mergeState(row.content_state, effective, time);
                    const ended = terminalState(state);
                    const fingerprint = contentHash(state);
                    const delivered = this.lastDelivered.get(row.activity_id);
                    if (delivered?.token === row.token && delivered.fingerprint === fingerprint && !ended && this.now() - delivered.sentAt < this.heartbeatMs) {
                        this.stats.pushesDeduped++;
                        continue;
                    }
                    // Persist the newest known state even when APNs is temporarily
                    // unavailable, so a later partial update/restart retains it.
                    const stored = {...state, _terminalConfirmed: snapshot.status === 'completed' || row.content_state._terminalConfirmed === true};
                    await this.pool.query('UPDATE live_activity_subscriptions SET content_state=$1::jsonb, updated_at=NOW() WHERE activity_id=$2 AND token=$3', [JSON.stringify(stored), row.activity_id, row.token]);
                    const aps = { timestamp, event: ended ? 'end' : 'update', 'content-state': state };
                    if (ended) aps['dismissal-date'] = timestamp + this.finalDismissalSeconds;
                    else aps['stale-date'] = Math.floor(time / 1000) + this.staleAfterSeconds;
                    const changed = !delivered || delivered.token !== row.token || delivered.fingerprint !== fingerprint;
                    this.lastPushTimestamp.set(snapshot.matchKey, timestamp);
                    let result;
                    try {
                        result = await this.dispatcher.sendToRecipient({kind: 'live-activity', priority: ended || changed ? 'high' : 'normal', notification: {aps}}, {
                            deviceToken: row.token, bundleIdentifier: row.bundle_identifier, environment: row.environment
                        });
                    } catch (error) { result = {ok: false, reason: error.message}; }
                    if (result?.ok || result?.invalidToken) {
                        if (result.ok) {
                            this.stats.pushesSent++;
                            this.stats.lastDeliveryAt = new Date(this.now()).toISOString();
                        }
                        if (ended || result.invalidToken) {
                            await this.pool.query('DELETE FROM live_activity_subscriptions WHERE activity_id=$1 AND token=$2', [row.activity_id, row.token]);
                            this.lastDelivered.delete(row.activity_id);
                            if (ended && result.ok) this.stats.activitiesEnded++;
                        } else {
                            this.lastDelivered.set(row.activity_id, {token: row.token, fingerprint, sentAt: this.now(), matchKey: snapshot.matchKey});
                        }
                    } else {
                        this.stats.pushesFailed++;
                        failed = true;
                        console.error('live activity push failed', result?.reason ?? 'unknown failure');
                    }
                } catch (error) {
                    // One unavailable subscription/database write must not
                    // abort delivery to the remaining recipients.
                    this.stats.pushesFailed++;
                    failed = true;
                    console.error('live activity subscription update failed', error.message);
                }
            }
        });
        await Promise.all(workers);
        if (failed) this.scheduleRetry(snapshot);
        else this.cancelRetry(snapshot.matchKey);
    }

    scheduleRetry(snapshot) {
        if (this.stopped) return;
        const existing = this.retries.get(snapshot.matchKey);
        if (existing) {
            existing.snapshot = combineFrames(existing.snapshot, snapshot);
            return;
        }
        const attempt = this.retryAttempts.get(snapshot.matchKey) ?? 0;
        this.retryAttempts.set(snapshot.matchKey, attempt + 1);
        const retry = {snapshot, timer: null};
        retry.timer = setTimeout(() => {
            this.retries.delete(snapshot.matchKey);
            this.update(retry.snapshot).catch(error => console.error('live activity retry failed', error.message));
        }, Math.min(30_000, this.retryDelayMs * 2 ** Math.min(attempt, 5)));
        retry.timer.unref?.();
        this.retries.set(snapshot.matchKey, retry);
    }

    cancelRetry(key) {
        const retry = this.retries.get(key);
        if (retry) clearTimeout(retry.timer);
        this.retries.delete(key);
        this.retryAttempts.delete(key);
    }

    clearMatch(key) {
        this.cancelRetry(key);
        this.latest.delete(key);
        this.lastPushTimestamp.delete(key);
        for (const [id, delivered] of this.lastDelivered) {
            if (delivered.matchKey === key) this.lastDelivered.delete(id);
        }
    }

    health() {
        const expiration = this.now() - 9 * 60 * 60 * 1000;
        for (const [key, value] of this.latest) if (value.time < expiration && !this.pending.has(key)) this.clearMatch(key);
        for (const [id, value] of this.lastDelivered) if (value.sentAt < expiration) this.lastDelivered.delete(id);
        return {...this.stats, pendingMatches: this.pending.size, retryingMatches: this.retries.size};
    }

    stop() {
        this.stopped = true;
        for (const key of this.retries.keys()) this.cancelRetry(key);
    }
}

// Sparse provider frames can arrive while another frame is being delivered.
// Preserve numbered set history and never replace an explicit final by live.
function combineFrames(previous, next) {
    if (!previous) return next;
    if (!next) return previous;
    if (previous.status === 'completed' && next.status !== 'completed') return previous;
    if (next.source === 'rest-reconciliation' && previous.source !== 'rest-reconciliation' && next.status !== 'completed' && capturedTime(next, Infinity) - capturedTime(previous, -Infinity) < 30_000) return previous;
    if (next.status !== 'completed' && capturedTime(next, Infinity) < capturedTime(previous, -Infinity)) return previous;
    const combined = {...previous, ...Object.fromEntries(Object.entries(next).filter(([, value]) => value !== '' && value != null))};
    if (next.status === 'unknown') combined.status = previous.status;
    const sets = new Map();
    for (const set of [...(previous.setScores ?? []), ...(next.setScores ?? [])]) sets.set(set.number, set);
    combined.setScores = [...sets.values()].sort((a, b) => a.number - b.number);
    return combined;
}

export function mergeState(previous, snapshot, sourceTime = capturedTime(snapshot, Date.now())) {
    if (terminalState(previous) && snapshot.status !== 'completed') return publicState(previous);
    const state = publicState(previous);
    // Only numbered per-set provider data can distinguish games from an
    // aggregate set result such as "0-1". Preserve the last known detail when absent.
    const isTeamTie = snapshot.isTeamTie === true || state.isTeamTie === true || Array.isArray(state.teamScore);
    if (isTeamTie) {
        state.isTeamTie = true;
        if (Array.isArray(snapshot.teamScore) && snapshot.teamScore.length === 2 && snapshot.teamScore.every(v => Number.isSafeInteger(v) && v >= 0)) {
            state.teamScore = [...snapshot.teamScore];
        }
        state.setScores = [];
        state.pointScore = '';
        state.gameScore = '';
        state.serverIsPlayerOne = null;
    }
    if (!isTeamTie && Array.isArray(snapshot.setScores) && snapshot.setScores.length) {
        const sets = [...state.setScores];
        for (const set of snapshot.setScores) {
            if (Number.isInteger(set.number) && set.number > 0 && set.number <= sets.length + 1 && /^\d+$/.test(set.player1Games) && /^\d+$/.test(set.player2Games)) {
                sets[set.number - 1] = {player1Games: set.player1Games, player2Games: set.player2Games};
            }
        }
        if (sets.length) {
            state.setScores = sets;
            state.currentSetIndex = sets.length - 1;
            state.player1SetsWon = 0; state.player2SetsWon = 0;
            for (const set of sets) {
                const a = Number(set.player1Games), b = Number(set.player2Games);
                if ((Math.max(a,b) >= 6 && Math.abs(a-b) >= 2) || (Math.max(a,b) === 7 && Math.min(a,b) === 6)) {
                    if (a > b) state.player1SetsWon++; else state.player2SetsWon++;
                }
            }
        }
    }
    if (!isTeamTie && snapshot.pointScore && snapshot.pointScore !== '-') state.pointScore = snapshot.pointScore;
    if (!isTeamTie && snapshot.gameScore && snapshot.gameScore !== '-') state.gameScore = snapshot.gameScore;
    if (!isTeamTie && snapshot.serverName) {
        const server = String(snapshot.serverName).toLowerCase();
        if (server === '1' || server === 'first' || server === String(snapshot.player1).toLowerCase()) state.serverIsPlayerOne = true;
        if (server === '2' || server === 'second' || server === String(snapshot.player2).toLowerCase()) state.serverIsPlayerOne = false;
    }
    if (snapshot.status === 'completed' || terminalState(previous)) { state.isLive = false; state.status = 'Finalizada'; state.pointScore = ''; }
    else if (snapshot.status === 'live') { state.isLive = true; state.status = 'Ao vivo'; }
    // Foundation's default Codable Date is seconds since 2001-01-01. Preserve
    // acquisition time instead of pretending a slow/retried delivery is fresh.
    state.lastUpdated = sourceTime / 1000 - foundationEpoch;
    return state;
}

function publicState(state) {
    // Internal delivery metadata is neither trusted from registration callers
    // nor included in the ActivityKit content-state payload.
    const {_terminalConfirmed, ...value} = state;
    return value;
}
