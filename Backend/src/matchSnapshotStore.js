import { createHash } from "node:crypto";
import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { dirname } from "node:path";
import { fileURLToPath } from "node:url";

const defaultStorePath = new URL("../data/match-snapshots.json", import.meta.url);

/// Server-side "current known state" per matchKey. The proxy/ingest layer
/// pushes new snapshots as they arrive; the store computes a stable hash of
/// the observable fields, drops the write when the hash is unchanged (dedup),
/// and otherwise upserts the record. Every non-duplicate write also returns
/// the previous snapshot so the decision engine can diff them.
export class MatchSnapshotStore {
    constructor(storePath = process.env.MATCH_SNAPSHOT_STORE ?? defaultStorePath) {
        this.storePath = storePath instanceof URL ? fileURLToPath(storePath) : storePath;
    }

    /// Returns `{ current, previous, changed }`. `changed=false` means the
    /// incoming snapshot was byte-equivalent to the last one and no write
    /// happened — the caller should short-circuit any downstream side effects.
    async ingest(snapshot) {
        const normalized = normalize(snapshot);
        const database = await this.readDatabase();
        const previous = database.snapshots[normalized.matchKey] ?? null;
        const hash = hashSnapshot(normalized);
        const now = new Date().toISOString();

        if (previous && previous.hash === hash) {
            return { current: previous, previous, changed: false };
        }

        const current = {
            ...normalized,
            hash,
            firstSeenAt: previous?.firstSeenAt ?? now,
            lastSeenAt: now,
            revision: (previous?.revision ?? 0) + 1
        };

        database.snapshots[normalized.matchKey] = current;
        database.stats.ingested += 1;
        if (!previous) {
            database.stats.uniqueMatches += 1;
        }
        await this.writeDatabase(database);
        return { current, previous, changed: true };
    }

    async get(matchKey) {
        const database = await this.readDatabase();
        return database.snapshots[matchKey] ?? null;
    }

    async list({ limit = 100 } = {}) {
        const database = await this.readDatabase();
        return Object.values(database.snapshots)
            .sort((a, b) => (a.lastSeenAt < b.lastSeenAt ? 1 : -1))
            .slice(0, limit);
    }

    async stats() {
        const database = await this.readDatabase();
        return {
            uniqueMatches: database.stats.uniqueMatches,
            ingested: database.stats.ingested,
            liveMatches: Object.values(database.snapshots).filter((snapshot) => snapshot.status === "live").length
        };
    }

    async readDatabase() {
        try {
            const raw = await readFile(this.storePath, "utf8");
            return JSON.parse(raw);
        } catch (error) {
            if (error.code === "ENOENT") {
                return { snapshots: {}, stats: { ingested: 0, uniqueMatches: 0 } };
            }
            throw error;
        }
    }

    async writeDatabase(database) {
        await mkdir(dirname(this.storePath), { recursive: true });
        const temporaryPath = `${this.storePath}.tmp`;
        await writeFile(temporaryPath, JSON.stringify(database, null, 2));
        await rename(temporaryPath, this.storePath);
    }
}

function normalize(snapshot) {
    if (!snapshot || typeof snapshot !== "object") {
        throw badRequest("snapshot must be an object");
    }
    const matchKey = requireString(snapshot.matchKey, "snapshot.matchKey");
    return {
        matchKey,
        tournamentKey: optionalString(snapshot.tournamentKey) ?? "",
        player1: optionalString(snapshot.player1) ?? "",
        player2: optionalString(snapshot.player2) ?? "",
        player1Key: optionalString(snapshot.player1Key) ?? "",
        player2Key: optionalString(snapshot.player2Key) ?? "",
        status: normalizeStatus(snapshot.status),
        serverName: optionalString(snapshot.serverName) ?? "",
        score: optionalString(snapshot.score) ?? "",
        gameScore: optionalString(snapshot.gameScore) ?? "",
        pointScore: optionalString(snapshot.pointScore) ?? "",
        setNumber: Number.isInteger(snapshot.setNumber) ? snapshot.setNumber : null,
        breakPoint: Boolean(snapshot.breakPoint),
        favoritePlayerKeys: Array.isArray(snapshot.favoritePlayerKeys)
            ? snapshot.favoritePlayerKeys.filter((value) => typeof value === "string")
            : [],
        capturedAt: optionalString(snapshot.capturedAt) ?? new Date().toISOString()
    };
}

function normalizeStatus(value) {
    const raw = typeof value === "string" ? value.trim().toLowerCase() : "";
    if (["live", "upcoming", "completed", "finished"].includes(raw)) {
        return raw === "finished" ? "completed" : raw;
    }
    return "unknown";
}

/// Deterministic hash used for server-side dedup. Only observable fields — the
/// timestamp is not part of the hash, so re-emitting the same frame twice
/// collapses to a single stored revision.
export function hashSnapshot(snapshot) {
    const material = [
        snapshot.matchKey,
        snapshot.status,
        snapshot.score,
        snapshot.gameScore,
        snapshot.pointScore,
        snapshot.serverName,
        snapshot.player1Key,
        snapshot.player2Key,
        snapshot.setNumber,
        snapshot.breakPoint ? "bp" : ""
    ].join("|");
    return createHash("sha256").update(material).digest("hex");
}

function requireString(value, field) {
    if (typeof value !== "string" || value.trim() === "") {
        throw badRequest(`${field} is required`);
    }
    return value.trim();
}

function optionalString(value) {
    return typeof value === "string" && value.trim() !== "" ? value.trim() : undefined;
}

function badRequest(message) {
    const error = new Error(message);
    error.statusCode = 400;
    return error;
}
