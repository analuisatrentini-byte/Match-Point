/// Long-lived client for the API Tennis WebSocket stream.
///
/// The service is meant to run inside the same process as the ingest server
/// (or as a sidecar). It:
///   1. opens `wss://wss.api-tennis.com/live?APIkey=…` (or the URL the
///      operator provides via `API_TENNIS_WS_URL`),
///   2. parses each incoming frame into the snapshot shape our pipeline
///      expects (matchKey, status, score, breakPoint, …),
///   3. hands the snapshot to `liveIngestionService.ingestFrame(...)`.
///
/// Reconnection uses exponential backoff capped at 30s. Every reconnect
/// increments `stats.reconnects` so operators can spot instability. On
/// permanent auth errors (401/403 close frames) the loop stops.
///
/// `ws` is an optional dependency (see package.json). Import is dynamic so
/// a fresh clone works without `npm install`.
export class ApiTennisWebSocketIngester {
    constructor({
        ingestionService,
        url = process.env.API_TENNIS_WS_URL ?? "wss://wss.api-tennis.com/live",
        apiKey = process.env.API_TENNIS_KEY,
        timezone = process.env.API_TENNIS_TIMEZONE ?? "America/New_York",
        minBackoffMs = 1_000,
        maxBackoffMs = 30_000,
        source = "api-tennis-ws"
    } = {}) {
        this.ingestionService = ingestionService;
        this.url = url;
        this.apiKey = apiKey;
        this.timezone = timezone;
        this.minBackoffMs = minBackoffMs;
        this.maxBackoffMs = maxBackoffMs;
        this.source = source;
        this.stats = {
            connections: 0,
            reconnects: 0,
            framesReceived: 0,
            framesForwarded: 0,
            framesInvalid: 0,
            lastFrameAt: null,
            lastErrorAt: null,
            lastError: null
        };
        this._running = false;
        this._socket = null;
        this._backoffMs = this.minBackoffMs;
    }

    /// Boots the connect+read loop. Idempotent — calling again while running
    /// is a no-op. Doesn't throw; connection errors go through the reconnect
    /// path so a transient DNS failure doesn't kill the ingest server.
    async start() {
        if (this._running) return;
        if (!this.url) {
            throw new Error("API_TENNIS_WS_URL is required to start the ingester");
        }
        this._running = true;
        this._loop().catch((error) => {
            this.stats.lastError = error.message;
            this.stats.lastErrorAt = new Date().toISOString();
            console.error("api-tennis ingester loop crashed", error);
            this._running = false;
        });
    }

    stop() {
        this._running = false;
        if (this._socket) {
            try { this._socket.close(); } catch { /* ignore */ }
            this._socket = null;
        }
    }

    async _loop() {
        const WebSocket = await loadWebSocket();
        while (this._running) {
            try {
                await this._connectOnce(WebSocket);
                if (!this._running) break;
                await sleep(this._backoffMs);
                this.stats.reconnects += 1;
                this._backoffMs = Math.min(this.maxBackoffMs, this._backoffMs * 2);
            } catch (error) {
                this.stats.lastError = error.message;
                this.stats.lastErrorAt = new Date().toISOString();
                if (isFatalAuthError(error)) {
                    console.error("api-tennis ingester giving up — auth failure:", error.message);
                    this._running = false;
                    return;
                }
                console.error("api-tennis ingester connect failed:", error.message);
                await sleep(this._backoffMs);
                this._backoffMs = Math.min(this.maxBackoffMs, this._backoffMs * 2);
            }
        }
    }

    _connectOnce(WebSocket) {
        return new Promise((resolve, reject) => {
            const url = this._buildUrl();
            const socket = new WebSocket(url);
            this._socket = socket;
            this.stats.connections += 1;

            socket.on("open", () => {
                this._backoffMs = this.minBackoffMs;
            });

            socket.on("message", (data) => {
                this.stats.framesReceived += 1;
                this.stats.lastFrameAt = new Date().toISOString();
                let payload;
                try {
                    payload = JSON.parse(typeof data === "string" ? data : data.toString("utf8"));
                } catch {
                    this.stats.framesInvalid += 1;
                    return;
                }
                const frames = extractFrames(payload);
                for (const frame of frames) {
                    const snapshot = frameToSnapshot(frame);
                    if (!snapshot) {
                        this.stats.framesInvalid += 1;
                        continue;
                    }
                    this.ingestionService
                        .ingestFrame(snapshot, { source: this.source })
                        .then(() => { this.stats.framesForwarded += 1; })
                        .catch((error) => {
                            this.stats.lastError = error.message;
                            this.stats.lastErrorAt = new Date().toISOString();
                        });
                }
            });

            socket.on("close", (code, reason) => {
                if (code >= 4000 || code === 1008 || code === 1011) {
                    // 4xxx are provider-specific; 1008 policy violation, 1011 server error.
                    // Treat these as fatal auth-ish errors so the loop stops retrying.
                    const error = new Error(`ws closed ${code}: ${reason?.toString?.("utf8") ?? ""}`);
                    error.fatalAuth = code === 1008 || (typeof reason === "string" && reason.toLowerCase().includes("auth"));
                    return reject(error);
                }
                resolve();
            });

            socket.on("error", (error) => {
                this.stats.lastError = error.message;
                this.stats.lastErrorAt = new Date().toISOString();
                reject(error);
            });
        });
    }

    _buildUrl() {
        const url = new URL(this.url);
        if (this.apiKey && !url.searchParams.has("APIkey")) {
            url.searchParams.set("APIkey", this.apiKey);
        }
        if (!url.searchParams.has("timezone")) {
            url.searchParams.set("timezone", this.timezone);
        }
        return url.toString();
    }
}

async function loadWebSocket() {
    if (typeof globalThis.WebSocket === "function") {
        // Wrap the global WebSocket in a minimal EventEmitter-shaped adapter so
        // the connect loop can use the same `on(event, cb)` API as `ws`.
        return class extends WebSocketAdapter {};
    }
    try {
        const module = await import("ws");
        return module.default ?? module.WebSocket ?? module;
    } catch (error) {
        const wrapped = new Error("ws module not installed — run `npm install ws` or unset API_TENNIS_WS_URL");
        wrapped.cause = error;
        throw wrapped;
    }
}

/// Minimal wrapper making the built-in `WebSocket` (Node 22+ / undici) look
/// like the `ws` package. Only the four events the ingester listens to are
/// implemented; anything else is caller error.
class WebSocketAdapter {
    constructor(url) {
        this._native = new globalThis.WebSocket(url);
    }
    on(eventName, callback) {
        switch (eventName) {
            case "open":
                this._native.addEventListener("open", () => callback());
                return;
            case "message":
                this._native.addEventListener("message", (event) => callback(event.data));
                return;
            case "close":
                this._native.addEventListener("close", (event) => callback(event.code, event.reason));
                return;
            case "error":
                this._native.addEventListener("error", () => callback(new Error("websocket error")));
                return;
            default:
                return;
        }
    }
    close() { this._native.close(); }
}

/// API Tennis pushes an array-of-matches on every tick. Different WSS servers
/// wrap it differently; this function accepts the two common shapes:
///
///     { result: [ { ... }, ... ] }        // envelope
///     [ { ... }, { ... } ]                 // flat array
///     { ... }                              // single object
///
function extractFrames(payload) {
    if (Array.isArray(payload)) return payload;
    if (payload && Array.isArray(payload.result)) return payload.result;
    if (payload && typeof payload === "object") return [payload];
    return [];
}

/// Best-effort mapping from a raw API Tennis frame to our snapshot shape.
/// Field names use API Tennis conventions (`event_key`, `event_status`, etc).
/// Unknown / empty fields fall back to safe defaults so a partial frame still
/// produces a usable snapshot instead of being dropped.
function frameToSnapshot(frame) {
    if (!frame || typeof frame !== "object") return null;
    const matchKey = String(frame.event_key ?? frame.matchKey ?? frame.match_key ?? "").trim();
    if (matchKey === "") return null;
    const status = String(frame.event_status ?? frame.status ?? "").trim().toLowerCase();

    return {
        matchKey,
        tournamentKey: String(frame.tournament_key ?? frame.tournamentKey ?? "").trim(),
        player1: frame.event_first_player ?? frame.player1 ?? "",
        player2: frame.event_second_player ?? frame.player2 ?? "",
        player1Key: String(frame.first_player_key ?? frame.event_first_player_key ?? frame.player1Key ?? "").trim(),
        player2Key: String(frame.second_player_key ?? frame.event_second_player_key ?? frame.player2Key ?? "").trim(),
        status: mapStatus(status, frame.event_live === "1" || frame.event_live === 1),
        serverName: frame.event_serve ?? frame.serverName ?? "",
        score: frame.event_final_result ?? frame.event_game_result ?? frame.score ?? "",
        gameScore: frame.event_game_result ?? frame.gameScore ?? "",
        pointScore: frame.event_serve_point ?? frame.pointScore ?? "",
        setNumber: parseIntOrNull(frame.event_set_number ?? frame.setNumber),
        breakPoint: Boolean(frame.event_break_point) || String(frame.event_break_point ?? "").toLowerCase() === "true",
        favoritePlayerKeys: Array.isArray(frame.favoritePlayerKeys) ? frame.favoritePlayerKeys : [],
        capturedAt: new Date().toISOString()
    };
}

function mapStatus(raw, liveFlag) {
    if (liveFlag) return "live";
    if (!raw) return "unknown";
    if (raw.includes("live") || raw === "set 1" || raw === "set 2" || raw === "set 3") return "live";
    if (raw.includes("final") || raw.includes("finished") || raw.includes("ended")) return "completed";
    if (raw.includes("upcoming") || raw.includes("scheduled")) return "upcoming";
    return "unknown";
}

function parseIntOrNull(value) {
    const parsed = Number.parseInt(value, 10);
    return Number.isFinite(parsed) ? parsed : null;
}

function isFatalAuthError(error) {
    return Boolean(error?.fatalAuth) || String(error?.message ?? "").toLowerCase().includes("auth");
}

function sleep(ms) {
    return new Promise((resolve) => setTimeout(resolve, ms).unref?.() ?? setTimeout(resolve, ms));
}
