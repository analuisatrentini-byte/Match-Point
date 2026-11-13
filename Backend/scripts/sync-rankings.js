import { getPostgresPool } from '../src/db/postgresPool.js';
import { syncAllRankingsWithLock } from '../src/rankingSync.js';

const pool = getPostgresPool();
if (!pool) {
  console.error('DATABASE_URL is required for ranking sync');
  process.exitCode = 1;
} else {
  try { const result = await syncAllRankingsWithLock({ pool }); if (result.locked) throw new Error("Ranking sync already running"); }
  catch (error) { console.error(error.message); process.exitCode = 1; }
  finally { await pool.end(); }
}
