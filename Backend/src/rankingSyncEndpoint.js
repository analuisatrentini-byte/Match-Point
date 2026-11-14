import { createHash, timingSafeEqual } from 'node:crypto';
import { syncAllRankingsWithLock } from './rankingSync.js';

// The dedicated token is never sent to the upstream provider or returned in
// responses. Require sufficient entropy and compare fixed-length digests.
export async function handleRankingSyncRequest({ authorization, pool, env = process.env, sync = syncAllRankingsWithLock }) {
  const secret = env.RANKING_SYNC_TOKEN;
  if (typeof secret !== 'string' || secret.length < 32) {
    return { status: 503, body: { ok: false, error: 'Ranking sync not configured' } };
  }
  const supplied = typeof authorization === 'string' && authorization.startsWith('Bearer ') ? authorization.slice(7) : '';
  const hash = value => createHash('sha256').update(value).digest();
  if (!timingSafeEqual(hash(secret), hash(supplied))) {
    return { status: 401, body: { ok: false, error: 'Unauthorized' } };
  }
  if (!pool) return { status: 503, body: { ok: false, error: 'Ranking database unavailable' } };
  try {
    const result = await sync({ pool, env });
    if (result.locked) return { status: 409, body: { ok: false, error: 'Ranking sync already running' } };
    return { status: 200, body: { ok: true, rankings: result.results } };
  } catch {
    return { status: 503, body: { ok: false, error: 'Ranking sync failed' } };
  }
}
