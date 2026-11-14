import { createHash } from 'node:crypto';

const hash = value => createHash('sha256').update(value).digest('hex');
const validState = state => state && typeof state === 'object' && Array.isArray(state.setScores)
    && typeof state.pointScore === 'string' && typeof state.gameScore === 'string'
    && Number.isFinite(state.lastUpdated);

// Live Activity tokens are independent of device tokens. An installation-held
// random secret authenticates token rotation and deletion without exposing it in DB.
export class LiveActivityService {
    constructor({ pool, dispatcher, bundleIdentifier = process.env.APNS_BUNDLE_ID }) {
        this.pool = pool;
        this.dispatcher = dispatcher;
        this.bundleIdentifier = bundleIdentifier;
        this.pending = new Map();
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
            [activityId, secret, matchKey, token.toLowerCase(), bundleIdentifier, environment, JSON.stringify(contentState)]);
        if (!result.rows.length) throw Object.assign(new Error('Registration rejected'), {statusCode: 403});
    }

    // Serialize updates per match so asynchronous database/APNs work cannot
    // reorder provider frames. Failures do not break the next update.
    update(snapshot) {
        const previous = this.pending.get(snapshot.matchKey) ?? Promise.resolve();
        const operation = previous.catch(() => {}).then(() => this.deliver(snapshot));
        this.pending.set(snapshot.matchKey, operation);
        operation.finally(() => { if (this.pending.get(snapshot.matchKey) === operation) this.pending.delete(snapshot.matchKey); }).catch(() => {});
        return operation;
    }

    async deliver(snapshot) {
        if (!this.pool || !this.dispatcher) return;
        const { rows } = await this.pool.query('SELECT * FROM live_activity_subscriptions WHERE match_key=$1 AND expires_at>NOW()', [snapshot.matchKey]);
        for (const row of rows) {
            const state = mergeState(row.content_state, snapshot);
            const ended = snapshot.status === 'completed';
            const aps = { timestamp: Math.floor(Date.now() / 1000), event: ended ? 'end' : 'update', 'content-state': state };
            if (ended) aps['dismissal-date'] = aps.timestamp + 120;
            let result;
            for (let attempt = 0; attempt < 3; attempt++) {
                try {
                    result = await this.dispatcher.sendToRecipient({kind: 'live-activity', notification: {aps}}, {
                        deviceToken: row.token, bundleIdentifier: row.bundle_identifier, environment: row.environment
                    });
                } catch (error) { result = {ok: false, reason: error.message}; }
                if (result.ok || result.invalidToken) break;
                if (attempt < 2) await new Promise(resolve => setTimeout(resolve, 1000 * (attempt + 1)));
            }
            if (result.ok || result.invalidToken) {
                if (ended || result.invalidToken) {
                    await this.pool.query('DELETE FROM live_activity_subscriptions WHERE activity_id=$1 AND token=$2', [row.activity_id, row.token]);
                } else {
                    await this.pool.query('UPDATE live_activity_subscriptions SET content_state=$1::jsonb, updated_at=NOW() WHERE activity_id=$2 AND token=$3', [JSON.stringify(state), row.activity_id, row.token]);
                }
            } else {
                console.error('live activity push failed', result.reason);
            }
        }
    }
}

export function mergeState(previous, snapshot) {
    const state = { ...previous };
    // Only numbered per-set provider data can distinguish games from an
    // aggregate set result such as "0-1". Preserve the last known detail when absent.
    if (Array.isArray(snapshot.setScores) && snapshot.setScores.length) {
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
    if (snapshot.pointScore && snapshot.pointScore !== '-') state.pointScore = snapshot.pointScore;
    if (snapshot.gameScore && snapshot.gameScore !== '-') state.gameScore = snapshot.gameScore;
    if (snapshot.serverName) {
        const server = String(snapshot.serverName).toLowerCase();
        if (server === '1' || server === 'first' || server === String(snapshot.player1).toLowerCase()) state.serverIsPlayerOne = true;
        if (server === '2' || server === 'second' || server === String(snapshot.player2).toLowerCase()) state.serverIsPlayerOne = false;
    }
    if (snapshot.status === 'completed') { state.isLive = false; state.status = 'Finalizada'; state.pointScore = ''; }
    else if (snapshot.status === 'live') { state.isLive = true; state.status = 'Ao vivo'; }
    // Foundation's default Codable Date is seconds since 2001-01-01.
    state.lastUpdated = Date.now() / 1000 - 978307200;
    return state;
}
