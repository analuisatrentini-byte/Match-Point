import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { dirname } from "node:path";
import { fileURLToPath } from "node:url";

const defaultStorePath = new URL("../data/bet-settlements.json", import.meta.url);

export class BetSettlementStore {
  constructor(storePath = process.env.BET_SETTLEMENT_STORE ?? defaultStorePath) {
    this.storePath = storePath instanceof URL ? fileURLToPath(storePath) : storePath;
  }

  async register(payload) {
    const database = await this.readDatabase();
    const now = new Date().toISOString();
    const existing = database.bets[payload.betID] ?? {};
    this.upsertProfile(database, payload, now);

    database.bets[payload.betID] = {
      ...existing,
      ...payload,
      status: existing.status ?? "pending",
      balanceApplied: Boolean(existing.balanceApplied),
      firstSeenAt: existing.firstSeenAt ?? now,
      lastSeenAt: now
    };

    database.audit.push({
      id: `audit:${Date.now()}:${database.audit.length}`,
      type: "bet-register",
      betID: payload.betID,
      userRecordName: payload.userRecordName,
      integrityHash: payload.integrityHash,
      createdAt: now
    });

    await this.writeDatabase(database);
    return database.bets[payload.betID];
  }

  async syncProfile(payload) {
    const database = await this.readDatabase();
    const now = new Date().toISOString();
    this.upsertProfile(database, payload, now);

    database.audit.push({
      id: `audit:${Date.now()}:${database.audit.length}`,
      type: "leaderboard-profile-sync",
      userRecordName: payload.userRecordName,
      createdAt: now
    });

    await this.writeDatabase(database);
    return database.profiles[payload.userRecordName];
  }

  async settle(payload) {
    const database = await this.readDatabase();
    const now = new Date().toISOString();
    const existing = database.bets[payload.betID];
    if (!existing) {
      throw badRequest("Bet is not registered");
    }
    if (existing.integrityHash !== payload.integrityHash) {
      throw badRequest("Bet integrity hash mismatch");
    }

    database.bets[payload.betID] = {
      ...existing,
      status: payload.status,
      serverSettlementID: payload.serverSettlementID,
      settledAt: now,
      balanceDelta: payload.status === "won" ? existing.payout : 0,
      balanceApplied: true
    };

    database.audit.push({
      id: `audit:${Date.now()}:${database.audit.length}`,
      type: "bet-settle",
      betID: payload.betID,
      status: payload.status,
      actor: payload.actor,
      createdAt: now
    });

    await this.writeDatabase(database);
    return database.bets[payload.betID];
  }

  async stats() {
    const database = await this.readDatabase();
    return {
      bets: Object.keys(database.bets).length,
      profiles: Object.keys(database.profiles ?? {}).length,
      auditEvents: database.audit.length
    };
  }

  async leaderboard({ limit = 50, currentUserRecordName = "" } = {}) {
    const database = await this.readDatabase();
    const entries = new Map();

    for (const [userRecordName, profile] of Object.entries(database.profiles ?? {})) {
      entries.set(userRecordName, this.makeLeaderboardEntry(userRecordName, profile));
    }

    const settledBets = Object.values(database.bets)
      .filter((bet) => ["won", "lost", "void"].includes(bet.status))
      .sort((lhs, rhs) => String(lhs.settledAt ?? lhs.createdAt ?? "").localeCompare(String(rhs.settledAt ?? rhs.createdAt ?? "")));

    for (const bet of settledBets) {
      const profile = database.profiles?.[bet.userRecordName] ?? bet;
      const entry = entries.get(bet.userRecordName) ?? this.makeLeaderboardEntry(bet.userRecordName, profile);

      if (bet.status === "won") {
        entry.points += Number.isInteger(bet.payout) ? bet.payout : 0;
        entry.wins += 1;
        entry.currentStreak += 1;
      } else if (bet.status === "lost") {
        entry.points -= Number.isInteger(bet.stake) ? bet.stake : 0;
        entry.losses += 1;
        entry.currentStreak = 0;
      } else if (bet.status === "void") {
        entry.voids += 1;
      }

      entry.lastBetID = bet.betID;
      entry.updatedAt = latestISOString(entry.updatedAt, bet.settledAt, bet.lastSeenAt, bet.createdAt);
      entries.set(bet.userRecordName, entry);
    }

    return [...entries.values()]
      .map((entry) => ({
        ...entry,
        isCurrentUser: entry.userRecordName === currentUserRecordName
      }))
      .sort((lhs, rhs) => (
        rhs.points - lhs.points
        || rhs.wins - lhs.wins
        || lhs.losses - rhs.losses
        || lhs.displayName.localeCompare(rhs.displayName)
      ))
      .slice(0, Math.min(Math.max(limit, 1), 100));
  }

  async readDatabase() {
    try {
      const raw = await readFile(this.storePath, "utf8");
      return normalizeDatabase(JSON.parse(raw));
    } catch (error) {
      if (error.code === "ENOENT") {
        return { bets: {}, profiles: {}, audit: [] };
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

  upsertProfile(database, payload, now) {
    database.profiles ??= {};
    const existing = database.profiles[payload.userRecordName] ?? {};
    database.profiles[payload.userRecordName] = {
      userRecordName: payload.userRecordName,
      displayName: payload.displayName ?? existing.displayName ?? "Fan",
      avatarSymbol: payload.avatarSymbol ?? existing.avatarSymbol ?? "person.crop.circle.fill",
      updatedAt: now
    };
  }

  makeLeaderboardEntry(userRecordName, profile) {
    return {
      id: `leader:${userRecordName}`,
      userRecordName,
      displayName: profile.displayName ?? "Fan",
      avatarSymbol: profile.avatarSymbol ?? "person.crop.circle.fill",
      points: 1000,
      wins: 0,
      losses: 0,
      voids: 0,
      currentStreak: 0,
      lastBetID: null,
      updatedAt: profile.updatedAt ?? new Date(0).toISOString()
    };
  }
}

function normalizeDatabase(database) {
  return {
    bets: database?.bets && typeof database.bets === "object" ? database.bets : {},
    profiles: database?.profiles && typeof database.profiles === "object" ? database.profiles : {},
    audit: Array.isArray(database?.audit) ? database.audit : []
  };
}

function latestISOString(...values) {
  return values
    .filter(Boolean)
    .sort()
    .at(-1) ?? new Date(0).toISOString();
}

function badRequest(message) {
  const error = new Error(message);
  error.statusCode = 400;
  return error;
}
