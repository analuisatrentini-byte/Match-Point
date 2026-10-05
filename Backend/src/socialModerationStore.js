import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { dirname } from "node:path";
import { fileURLToPath } from "node:url";

const defaultStorePath = new URL("../data/social-moderation.json", import.meta.url);

export class SocialModerationStore {
  constructor(storePath = process.env.SOCIAL_MODERATION_STORE ?? defaultStorePath) {
    this.storePath = storePath instanceof URL ? fileURLToPath(storePath) : storePath;
  }

  async report(payload) {
    const database = await this.readDatabase();
    const now = new Date().toISOString();
    const reportID = `report:${payload.postID}:${payload.userRecordName}`;

    if (database.bans[payload.userRecordName]?.isActive) {
      throw forbidden("User is banned from social actions");
    }

    database.reports[reportID] = {
      ...payload,
      reportID,
      createdAt: payload.createdAt ?? now
    };

    database.audit.push({
      id: `audit:${Date.now()}:${database.audit.length}`,
      type: "report",
      postID: payload.postID,
      actor: payload.userRecordName,
      createdAt: now
    });

    await this.writeDatabase(database);
    return this.summary(database, payload.postID);
  }

  async queue({ limit = 100 } = {}) {
    const database = await this.readDatabase();
    const reportsByPost = new Map();

    for (const report of Object.values(database.reports)) {
      const existing = reportsByPost.get(report.postID) ?? [];
      existing.push(report);
      reportsByPost.set(report.postID, existing);
    }

    return [...reportsByPost.entries()]
      .map(([postID, reports]) => ({
        postID,
        matchKey: reports[0]?.matchKey ?? database.posts[postID]?.matchKey ?? "",
        reportCount: reports.length,
        latestReason: reports.at(-1)?.reason ?? "user-report",
        latestReportAt: latestISOString(...reports.map((report) => report.createdAt)),
        moderation: database.posts[postID] ?? null
      }))
      .sort((lhs, rhs) => (
        rhs.reportCount - lhs.reportCount
        || String(rhs.latestReportAt).localeCompare(String(lhs.latestReportAt))
      ))
      .slice(0, Math.min(Math.max(limit, 1), 200));
  }

  async audit({ limit = 100 } = {}) {
    const database = await this.readDatabase();
    return database.audit
      .slice()
      .sort((lhs, rhs) => String(rhs.createdAt).localeCompare(String(lhs.createdAt)))
      .slice(0, Math.min(Math.max(limit, 1), 200));
  }

  async rules() {
    const database = await this.readDatabase();
    return database.rules;
  }

  async updateRules(payload) {
    const database = await this.readDatabase();
    const now = new Date().toISOString();
    database.rules = payload.rules;
    database.audit.push({
      id: `audit:${Date.now()}:${database.audit.length}`,
      type: "community-rules-update",
      actor: payload.actorRecordName,
      role: payload.actorRole,
      createdAt: now
    });
    await this.writeDatabase(database);
    return database.rules;
  }

  async banUser(payload) {
    const database = await this.readDatabase();
    const now = new Date().toISOString();
    database.bans[payload.userRecordName] = {
      userRecordName: payload.userRecordName,
      reason: payload.reason,
      isActive: payload.isActive,
      actor: payload.actorRecordName,
      role: payload.actorRole,
      updatedAt: now
    };
    database.audit.push({
      id: `audit:${Date.now()}:${database.audit.length}`,
      type: payload.isActive ? "user-ban" : "user-unban",
      userRecordName: payload.userRecordName,
      reason: payload.reason,
      actor: payload.actorRecordName,
      role: payload.actorRole,
      createdAt: now
    });
    await this.writeDatabase(database);
    return database.bans[payload.userRecordName];
  }

  async moderate(payload) {
    const database = await this.readDatabase();
    const now = new Date().toISOString();
    const current = database.posts[payload.postID] ?? {
      postID: payload.postID,
      matchKey: payload.matchKey,
      isPinned: false,
      isHidden: false
    };

    switch (payload.action) {
    case "pin":
      current.isPinned = true;
      break;
    case "unpin":
      current.isPinned = false;
      break;
    case "hide":
      current.isHidden = true;
      break;
    case "unhide":
      current.isHidden = false;
      break;
    default:
      throw new Error("Unsupported moderation action");
    }

    current.updatedAt = now;
    database.posts[payload.postID] = current;
    database.audit.push({
      id: `audit:${Date.now()}:${database.audit.length}`,
      type: "moderation-action",
      postID: payload.postID,
      action: payload.action,
      actor: payload.actorRecordName,
      role: payload.actorRole,
      createdAt: now
    });

    await this.writeDatabase(database);
    return this.summary(database, payload.postID);
  }

  async stats() {
    const database = await this.readDatabase();
    return {
      reports: Object.keys(database.reports).length,
      moderatedPosts: Object.keys(database.posts).length,
      activeBans: Object.values(database.bans).filter((ban) => ban.isActive).length,
      auditEvents: database.audit.length
    };
  }

  summary(database, postID) {
    const reports = Object.values(database.reports).filter((report) => report.postID === postID);
    return {
      postID,
      reportCount: reports.length,
      moderation: database.posts[postID] ?? null
    };
  }

  async readDatabase() {
    try {
      const raw = await readFile(this.storePath, "utf8");
      return normalizeDatabase(JSON.parse(raw));
    } catch (error) {
      if (error.code === "ENOENT") {
        return normalizeDatabase({});
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

const defaultRules = [
  "Sem ataques pessoais, discurso de ódio ou assédio.",
  "Sem spam, links suspeitos ou autopromoção repetitiva.",
  "Denúncias maliciosas podem resultar em banimento.",
  "Spoilers e provocações são permitidos quando não viram abuso."
];

function normalizeDatabase(database) {
  return {
    reports: database?.reports && typeof database.reports === "object" ? database.reports : {},
    posts: database?.posts && typeof database.posts === "object" ? database.posts : {},
    bans: database?.bans && typeof database.bans === "object" ? database.bans : {},
    rules: Array.isArray(database?.rules) && database.rules.length > 0 ? database.rules : defaultRules,
    audit: Array.isArray(database?.audit) ? database.audit : []
  };
}

function latestISOString(...values) {
  return values
    .filter(Boolean)
    .sort()
    .at(-1) ?? new Date(0).toISOString();
}

function forbidden(message) {
  const error = new Error(message);
  error.statusCode = 403;
  return error;
}
