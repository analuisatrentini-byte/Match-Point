import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { dirname } from "node:path";
import { fileURLToPath } from "node:url";

const defaultStorePath = new URL("../data/score-history.json", import.meta.url);

/// Append-only audit trail of every observed score change per match. Nothing
/// in this store is ever mutated in place — a settlement dispute or an
/// integrity check should be able to replay the entire life of a match by
/// reading `events` filtered by `matchKey` in insertion order.
export class ScoreHistoryStore {
    constructor(storePath = process.env.SCORE_HISTORY_STORE ?? defaultStorePath) {
        this.storePath = storePath instanceof URL ? fileURLToPath(storePath) : storePath;
    }

    /// Records a diff between two snapshots. Called by the ingest layer AFTER
    /// the snapshot store decided the frame was non-duplicate — the record is
    /// therefore guaranteed to represent a real state change.
    async record({ current, previous, source }) {
        if (!current || typeof current !== "object") {
            throw badRequest("current snapshot is required");
        }
        const database = await this.readDatabase();
        const entry = {
            id: `sh:${Date.now()}:${database.events.length}`,
            matchKey: current.matchKey,
            revision: current.revision,
            recordedAt: new Date().toISOString(),
            source: typeof source === "string" && source.length > 0 ? source : "ingest",
            capturedAt: current.capturedAt,
            status: current.status,
            score: current.score,
            gameScore: current.gameScore,
            pointScore: current.pointScore,
            serverName: current.serverName,
            player1Key: current.player1Key,
            player2Key: current.player2Key,
            setNumber: current.setNumber,
            breakPoint: current.breakPoint,
            hash: current.hash,
            previousHash: previous?.hash ?? null,
            previousStatus: previous?.status ?? null
        };
        database.events.push(entry);
        database.stats.recorded += 1;
        await this.writeDatabase(database);
        return entry;
    }

    /// Returns events for a matchKey in insertion (chronological) order. Not
    /// paginated on purpose — a single tennis match's audit trail is bounded
    /// (a few hundred frames at most).
    async history(matchKey) {
        const database = await this.readDatabase();
        return database.events.filter((event) => event.matchKey === matchKey);
    }

    async stats() {
        const database = await this.readDatabase();
        return {
            recorded: database.stats.recorded,
            events: database.events.length
        };
    }

    async readDatabase() {
        try {
            const raw = await readFile(this.storePath, "utf8");
            return JSON.parse(raw);
        } catch (error) {
            if (error.code === "ENOENT") {
                return { events: [], stats: { recorded: 0 } };
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

function badRequest(message) {
    const error = new Error(message);
    error.statusCode = 400;
    return error;
}
