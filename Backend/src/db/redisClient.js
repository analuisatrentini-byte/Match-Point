/// Lazy-loaded Redis client. `ioredis` is optional — the JSON-file push queue
/// is the default for dev, and Redis is only initialized when
/// `REDIS_URL` is set. Import is dynamic so a fresh clone works without
/// `npm install`.

let cachedClient = null;

async function loadIoredis() {
    try {
        const module = await import("ioredis");
        return module.default ?? module.Redis ?? module;
    } catch (error) {
        const wrapped = new Error("ioredis module not installed — run `npm install ioredis` or unset REDIS_URL");
        wrapped.cause = error;
        throw wrapped;
    }
}

/// Returns a shared Redis client if `REDIS_URL` is set, or `null` otherwise.
/// The client is lazy-created on the first command.
export function getRedisClient() {
    if (!process.env.REDIS_URL) return null;
    if (cachedClient) return cachedClient;

    let realClient = null;
    let loadPromise = null;

    async function ensureClient() {
        if (realClient) return realClient;
        if (!loadPromise) {
            loadPromise = (async () => {
                const Redis = await loadIoredis();
                const client = new Redis(process.env.REDIS_URL, {
                    maxRetriesPerRequest: 3,
                    enableAutoPipelining: true
                });
                client.on("error", (error) => {
                    console.error("redis client error", error.message);
                });
                realClient = client;
                return client;
            })();
        }
        return loadPromise;
    }

    // Proxy the small subset the queue needs. Keeps the surface area minimal
    // — future consumers add methods here rather than importing ioredis
    // directly (which would break the lazy contract).
    cachedClient = {
        async xadd(...args) { return (await ensureClient()).xadd(...args); },
        async xreadgroup(...args) { return (await ensureClient()).xreadgroup(...args); },
        async xack(...args) { return (await ensureClient()).xack(...args); },
        async xlen(...args) { return (await ensureClient()).xlen(...args); },
        async xgroup(...args) { return (await ensureClient()).xgroup(...args); },
        async xtrim(...args) { return (await ensureClient()).xtrim(...args); },
        async quit() {
            if (realClient) {
                await realClient.quit();
                realClient = null;
                loadPromise = null;
            }
        }
    };
    return cachedClient;
}
