/// Lazy-loaded Postgres pool. `pg` is an optional dependency — the JSON-file
/// stores are the default for dev, and the pool is only initialized when the
/// operator opts in via `DATABASE_URL`. Import is dynamic so a fresh clone
/// works without `npm install`.

let cachedPool = null;
let cachedModule = null;

async function loadPgModule() {
    if (cachedModule) return cachedModule;
    try {
        cachedModule = await import("pg");
        return cachedModule;
    } catch (error) {
        const message = "pg module not installed — run `npm install pg` or unset DATABASE_URL";
        const wrapped = new Error(message);
        wrapped.cause = error;
        throw wrapped;
    }
}

/// Returns a shared pool if `DATABASE_URL` is set, or `null` if the operator
/// has not opted in. All Postgres-backed stores call this once at
/// construction — they degrade gracefully if it returns `null`.
export function getPostgresPool() {
    if (cachedPool) return cachedPool;
    if (!process.env.DATABASE_URL) return null;

    // Sync accessor: schedule the async load but return a proxy that queues
    // until the pool is ready. The stores await `query` so the extra tick is
    // invisible.
    cachedPool = createLazyPool();
    return cachedPool;
}

function createLazyPool() {
    let realPool = null;
    let loadPromise = null;

    async function ensurePool() {
        if (realPool) return realPool;
        if (!loadPromise) {
            loadPromise = (async () => {
                const { default: pg } = await loadPgModule();
                const pool = new pg.Pool({
                    connectionString: process.env.DATABASE_URL,
                    max: Number(process.env.PG_POOL_MAX ?? 10),
                    idleTimeoutMillis: 30_000
                });
                pool.on("error", (error) => {
                    console.error("postgres pool error", error.message);
                });
                realPool = pool;
                return pool;
            })();
        }
        return loadPromise;
    }

    return {
        async query(text, params) {
            const pool = await ensurePool();
            return pool.query(text, params);
        },
        async end() {
            if (realPool) {
                await realPool.end();
                realPool = null;
                loadPromise = null;
            }
        }
    };
}
