/// Device registry — decoupled from the decision engine.
///
/// The engine emits `recipients` as *abstract selectors* like
/// `{ type: "favorite-player", playerKey }` or `{ type: "match", matchKey }`.
/// This registry stores which physical device tokens are subscribed to which
/// selectors and exposes `resolveRecipients(selectors)` to expand them into
/// the flat list of device tokens the APNs dispatcher needs.
///
/// Postgres-backed. If `DATABASE_URL` is unset the registry degrades to an
/// in-memory implementation used by dev/tests — subscriptions are lost on
/// restart. That's the correct dev behavior (mock devices).

import { selectorsFromSubscription } from "../deviceTokenStore.js";

export class DeviceRegistry {
    constructor({ pool = null, inMemory = null } = {}) {
        this.pool = pool;
        this.inMemory = inMemory ?? (pool ? null : new Map());
    }

    /// Registers or updates a device. Subscriptions are stored as an array of
    /// selectors. Passing an empty array cleared all subscriptions except the
    /// implicit "match" selectors resolved by matchKey inside the payload.
    async register({ deviceToken, bundleIdentifier, environment = "production", platform = "ios", userRecordName = null, subscriptions = [] }) {
        if (!deviceToken || !bundleIdentifier) {
            throw badRequest("deviceToken and bundleIdentifier are required");
        }
        if (this.pool) {
            const cleaned = cleanSelectors(subscriptions);
            const result = await this.pool.query(
                `INSERT INTO device_registry (device_token, bundle_identifier, environment, platform, user_record_name, subscriptions, active)
                 VALUES ($1,$2,$3,$4,$5,$6,TRUE)
                 ON CONFLICT (bundle_identifier, environment, platform, device_token) DO UPDATE SET
                    user_record_name = EXCLUDED.user_record_name,
                    subscriptions = EXCLUDED.subscriptions,
                    active = TRUE,
                    last_seen_at = NOW()
                 RETURNING id`,
                [deviceToken, bundleIdentifier, environment, platform, userRecordName, JSON.stringify(cleaned)]
            );
            return { id: result.rows[0].id, subscriptions: cleaned };
        }
        const key = registryKey({ deviceToken, bundleIdentifier, environment, platform });
        const cleaned = cleanSelectors(subscriptions);
        this.inMemory.set(key, {
            deviceToken, bundleIdentifier, environment, platform, userRecordName,
            subscriptions: cleaned, active: true
        });
        return { id: key, subscriptions: cleaned };
    }

    async upsert(payload) {
        const result = await this.register({
            deviceToken: payload.deviceToken,
            bundleIdentifier: payload.bundleIdentifier,
            environment: payload.environment,
            platform: payload.platform,
            userRecordName: payload.userRecordName ?? null,
            subscriptions: selectorsFromSubscription(payload.subscription)
        });
        return this.publicToken({ ...payload, active: true, subscriptions: result.subscriptions });
    }

    async revoke(payload) {
        await this.deactivate(payload);
        return this.publicToken({ ...payload, active: false, subscriptions: [] });
    }

    async deactivate({ deviceToken, bundleIdentifier, environment = "production", platform = "ios" }) {
        if (this.pool) {
            await this.pool.query(
                "UPDATE device_registry SET active = FALSE, last_seen_at = NOW() WHERE device_token = $1 AND bundle_identifier = $2 AND environment = $3 AND platform = $4",
                [deviceToken, bundleIdentifier, environment, platform]
            );
            return;
        }
        const key = registryKey({ deviceToken, bundleIdentifier, environment, platform });
        const existing = this.inMemory.get(key);
        if (existing) existing.active = false;
    }

    async deactivateDeviceToken(payload) {
        await this.deactivate(payload);
        return true;
    }

    /// Expands a list of engine selectors into a de-duplicated list of active
    /// devices. A device is included as long as ONE of its subscriptions
    /// matches ONE of the requested selectors.
    async resolveRecipients(selectors) {
        if (!selectors || selectors.length === 0) return [];
        const wanted = selectors.map(canonical).filter(Boolean);
        if (wanted.length === 0) return [];

        if (this.pool) {
            const result = await this.pool.query(
                `SELECT device_token, bundle_identifier, environment
                   FROM device_registry
                  WHERE active = TRUE
                    AND subscriptions @> ANY ($1::jsonb[])`,
                [wanted.map((entry) => JSON.stringify([entry]))]
            );
            return result.rows.map((row) => ({
                deviceToken: row.device_token,
                bundleIdentifier: row.bundle_identifier,
                environment: row.environment
            }));
        }

        const wantedSet = new Set(wanted.map(canonicalKey));
        const results = [];
        for (const entry of this.inMemory.values()) {
            if (!entry.active) continue;
            const anyMatch = entry.subscriptions.some((subscription) => wantedSet.has(canonicalKey(canonical(subscription))));
            if (anyMatch) {
                results.push({
                    deviceToken: entry.deviceToken,
                    bundleIdentifier: entry.bundleIdentifier,
                    environment: entry.environment
                });
            }
        }
        return results;
    }

    async stats() {
        if (this.pool) {
            const result = await this.pool.query(
                "SELECT COUNT(*)::INT AS total, COUNT(*) FILTER (WHERE active)::INT AS active FROM device_registry"
            );
            const row = result.rows[0] ?? {};
            return { total: row.total ?? 0, active: row.active ?? 0 };
        }
        const entries = Array.from(this.inMemory.values());
        return {
            total: entries.length,
            active: entries.filter((entry) => entry.active).length
        };
    }

    publicToken(token) {
        return {
            active: token.active,
            platform: token.platform,
            bundleIdentifier: token.bundleIdentifier,
            environment: token.environment,
            tokenSuffix: token.deviceToken.slice(-8),
            subscriptions: token.subscriptions ?? []
        };
    }
}

function cleanSelectors(subscriptions) {
    return subscriptions
        .map(canonical)
        .filter(Boolean);
}

function canonical(selector) {
    if (!selector || typeof selector !== "object") return null;
    switch (selector.type) {
        case "match":
            return selector.matchKey ? { type: "match", matchKey: String(selector.matchKey) } : null;
        case "tournament":
            return selector.tournamentKey ? { type: "tournament", tournamentKey: String(selector.tournamentKey) } : null;
        case "favorite-player":
            return selector.playerKey ? { type: "favorite-player", playerKey: String(selector.playerKey) } : null;
        default:
            return null;
    }
}

function canonicalKey(selector) {
    if (!selector) return "";
    return `${selector.type}|${selector.matchKey ?? ""}|${selector.tournamentKey ?? ""}|${selector.playerKey ?? ""}`;
}

function registryKey({ deviceToken, bundleIdentifier, environment, platform }) {
    return [bundleIdentifier, environment, platform, deviceToken].join(":");
}

function badRequest(message) {
    const error = new Error(message);
    error.statusCode = 400;
    return error;
}
