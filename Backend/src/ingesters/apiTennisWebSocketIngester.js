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
        connectTimeoutMs = 15_000,
        heartbeatIntervalMs = 20_000,
        heartbeatTimeoutMs = 10_000,
        silenceTimeoutMs = 90_000,
        WebSocketClass = null,
        source = "api-tennis-ws"
    } = {}) {
        this.ingestionService = ingestionService;
        this.url = url;
        this.apiKey = apiKey;
        this.timezone = timezone;
        this.minBackoffMs = minBackoffMs;
        this.maxBackoffMs = maxBackoffMs;
        this.connectTimeoutMs = connectTimeoutMs;
        this.heartbeatIntervalMs = heartbeatIntervalMs;
        this.heartbeatTimeoutMs = heartbeatTimeoutMs;
        this.silenceTimeoutMs = silenceTimeoutMs;
        this.WebSocketClass = WebSocketClass;
        this.source = source;
        this.stats = {
            connections: 0,
            reconnects: 0,
            framesReceived: 0,
            framesForwarded: 0,
            framesInvalid: 0,
            watchdogReconnects: 0,
            connected: false,
            lastConnectedAt: null,
            lastHeartbeatAt: null,
            lastFrameAt: null,
            lastErrorAt: null,
            lastError: null
        };
        this._running = false;
        this._socket = null;
        this._backoffMs = this.minBackoffMs;
        this._generation = 0;
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
        const generation = ++this._generation;
        this._loop(generation).catch((error) => {
            if (generation !== this._generation) return;
            this.stats.lastError = error.message;
            this.stats.lastErrorAt = new Date().toISOString();
            console.error("api-tennis ingester loop crashed", error);
            this._running = false;
        });
    }

    stop() {
        this._running = false;
        this._generation += 1;
        this._cancelReconnect?.();
        this._cancelConnection?.();
    }

    async _loop(generation) {
        const WebSocket = this.WebSocketClass ?? await loadWebSocket();
        while (this._running && generation === this._generation) {
            try {
                await this._connectOnce(WebSocket);
            } catch (error) {
                if (!this._running || generation !== this._generation) break;
                this.stats.lastError = error.message;
                this.stats.lastErrorAt = new Date().toISOString();
                if (isFatalAuthError(error)) {
                    console.error("api-tennis ingester giving up — auth failure:", error.message);
                    this._running = false;
                    return;
                }
                console.error("api-tennis ingester connect failed:", error.message);
            }
            if (!this._running || generation !== this._generation) break;
            await this._waitForReconnect(this._backoffMs);
            if (!this._running || generation !== this._generation) break;
            this.stats.reconnects += 1;
            this._backoffMs = Math.min(this.maxBackoffMs, this._backoffMs * 2);
        }
    }

    _waitForReconnect(ms) {
        return new Promise(resolve => {
            const complete = () => { clearTimeout(timer); this._cancelReconnect = null; resolve(); };
            const timer = setTimeout(complete, ms);
            timer.unref?.();
            this._cancelReconnect = complete;
        });
    }

    _connectOnce(WebSocket) {
        return new Promise((resolve, reject) => {
            const url = this._buildUrl();
            const socket = new WebSocket(url);
            this._socket = socket;
            this.stats.connections += 1;
            let settled = false;
            let opened = false;
            let lastFrameAt = Date.now();
            let awaitingPongAt = null;
            let lastPingAt = 0;
            let heartbeatTimer;
            const finish = (error) => {
                if (settled) return;
                settled = true;
                clearTimeout(connectTimer);
                clearInterval(heartbeatTimer);
                if (this._socket === socket) {
                    this._socket = null;
                    this._cancelConnection = null;
                    this.stats.connected = false;
                }
                // A rejected/half-open socket must not continue forwarding old
                // frames after its replacement has connected.
                try { if (socket.terminate) socket.terminate(); else socket.close(); } catch { /* already closed */ }
                if (error) reject(error); else resolve();
            };
            this._cancelConnection = () => finish();
            const connectTimer = setTimeout(() => finish(new Error("WebSocket connection timed out")), this.connectTimeoutMs);
            connectTimer.unref?.();

            socket.on("open", () => {
                if (settled) return;
                opened = true;
                clearTimeout(connectTimer);
                this._backoffMs = this.minBackoffMs;
                this.stats.connected = true;
                this.stats.lastConnectedAt = new Date().toISOString();
                lastFrameAt = Date.now();
                heartbeatTimer = setInterval(() => {
                    const now = Date.now();
                    const missingPong = awaitingPongAt !== null && now - awaitingPongAt >= this.heartbeatTimeoutMs;
                    if (missingPong || now - lastFrameAt >= this.silenceTimeoutMs) {
                        this.stats.watchdogReconnects += 1;
                        finish(new Error(missingPong ? "WebSocket heartbeat timed out" : "WebSocket match stream went silent"));
                        return;
                    }
                    if (typeof socket.ping === "function" && awaitingPongAt === null && now - lastPingAt >= this.heartbeatIntervalMs) {
                        lastPingAt = now;
                        awaitingPongAt = now;
                        try { socket.ping(); } catch (error) { finish(error); }
                    }
                }, Math.min(this.heartbeatIntervalMs, this.heartbeatTimeoutMs));
                heartbeatTimer.unref?.();
            });
            socket.on("pong", () => {
                if (!settled) {
                    awaitingPongAt = null;
                    this.stats.lastHeartbeatAt = new Date().toISOString();
                }
            });

            socket.on("message", (data) => {
                if (settled || !opened) return;
                lastFrameAt = Date.now();
                this.stats.framesReceived += 1;
                this.stats.lastFrameAt = new Date().toISOString();
                let payload;
                try {
                    payload = JSON.parse(typeof data === "string" ? data : Buffer.from(data).toString("utf8"));
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
                const detail = reason?.toString?.("utf8") ?? "";
                const error = new Error(`ws closed ${code}: ${detail}`);
                error.fatalAuth = /unauthori[sz]ed|forbidden|invalid[ _-]*(api[ _-]*)?key|authentication failed/i.test(detail);
                finish(error);
            });

            socket.on("unexpected-response", (_request, response) => {
                const error = new Error(`WebSocket handshake rejected: ${response.statusCode}`);
                error.fatalAuth = response.statusCode === 401 || response.statusCode === 403;
                response.resume?.();
                finish(error);
            });

            socket.on("error", (error) => {
                if (settled) return;
                this.stats.lastError = error.message;
                this.stats.lastErrorAt = new Date().toISOString();
                finish(error);
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
    try {
        const module = await import("ws");
        return module.default ?? module.WebSocket ?? module;
    } catch (error) {
        if (typeof globalThis.WebSocket === "function") return class extends WebSocketAdapter {};
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
        this._native.binaryType = "arraybuffer";
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
export function frameToSnapshot(frame) {
    if (!frame || typeof frame !== "object") return null;
    const matchKey = String(frame.event_key ?? frame.matchKey ?? frame.match_key ?? "").trim();
    if (matchKey === "") return null;
    const status = String(frame.event_status ?? frame.status ?? "").trim().toLowerCase();

    const sets = Array.isArray(frame.scores) ? frame.scores
        .filter(s => s.score_first != null && s.score_second != null && Number(s.score_set) > 0)
        .sort((a, b) => Number(a.score_set) - Number(b.score_set)) : [];
    const completeScores = sets.every((s, index) => Number(s.score_set) === index + 1);
    return {
        matchKey,
        tournamentKey: String(frame.tournament_key ?? frame.tournamentKey ?? "").trim(),
        player1: frame.event_first_player ?? frame.player1 ?? "",
        player2: frame.event_second_player ?? frame.player2 ?? "",
        player1Key: String(frame.first_player_key ?? frame.event_first_player_key ?? frame.player1Key ?? "").trim(),
        player2Key: String(frame.second_player_key ?? frame.event_second_player_key ?? frame.player2Key ?? "").trim(),
        status: mapStatus(status, ["1", "true"].includes(String(frame.event_live).toLowerCase())),
        serverName: frame.event_serve ?? frame.serverName ?? "",
        score: completeScores ? sets.map(s => `${s.score_first}-${s.score_second}`).join(" ") : "",
        setScores: sets.map(s => ({ number: Number(s.score_set), player1Games: String(s.score_first), player2Games: String(s.score_second) })),
        gameScore: sets.length ? `${sets.at(-1).score_first}-${sets.at(-1).score_second}` : (frame.gameScore ?? ""),
        pointScore: frame.point_score ?? frame.event_point_result ?? frame.event_game_result ?? frame.pointScore ?? "",
        setNumber: parseIntOrNull(frame.event_set_number ?? frame.setNumber),
        breakPoint: ["1", "true"].includes(String(frame.event_break_point).toLowerCase()),
        favoritePlayerKeys: Array.isArray(frame.favoritePlayerKeys) ? frame.favoritePlayerKeys : [],
        capturedAt: new Date().toISOString()
    };
}

function mapStatus(raw, liveFlag) {
    const compact = raw.replace(/[\s._-]/g, "");
    if (["final", "completed", "finished", "ended", "ret", "retired", "wo", "walkover", "cancelled", "canceled", "abandoned", "defaulted"].includes(compact)) return "completed";
    if (liveFlag) return "live";
    if (!raw) return "unknown";
    if (raw.includes("live") || /^set\s*[1-5]$/.test(raw) || /tie.?break|in progress/.test(raw)) return "live";
    if (raw.includes("upcoming") || raw.includes("scheduled")) return "upcoming";
    return "unknown";
}

function parseIntOrNull(value) {
    const parsed = Number.parseInt(value, 10);
    return Number.isFinite(parsed) ? parsed : null;
}

function isFatalAuthError(error) {
    return Boolean(error?.fatalAuth);
}
