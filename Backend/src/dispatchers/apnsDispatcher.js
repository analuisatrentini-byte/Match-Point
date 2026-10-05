import { readFile } from "node:fs/promises";
import { connect as http2Connect } from "node:http2";
import { createSign } from "node:crypto";

const APNS_HOSTS = {
    production: "api.push.apple.com",
    sandbox: "api.sandbox.push.apple.com"
};

/// Real APNs dispatcher over HTTP/2 with token-based auth.
///
/// APNs authentication uses a JWT signed with the team's `.p8` private key
/// (ES256). Tokens are valid up to 1 hour — anything under 60 min is fine.
/// Apple caches the token by (kid, iss); refreshing more than once every 20
/// minutes is treated as abuse. This dispatcher signs a fresh token on cold
/// start and refreshes it every 55 minutes.
///
/// One HTTP/2 session per host is kept open and reused. On session errors we
/// discard the session and let the next request reconnect.
///
/// The dispatcher expects `event.resolvedRecipients` — a flat array of
/// `{ deviceToken, bundleIdentifier, environment }` produced by the device
/// registry resolver. That decoupling keeps the decision engine out of the
/// APNs protocol.
export class ApnsDispatcher {
    constructor({
        keyPath = process.env.APNS_KEY_PATH,
        keyId = process.env.APNS_KEY_ID,
        teamId = process.env.APNS_TEAM_ID,
        defaultBundleId = process.env.APNS_BUNDLE_ID,
        defaultEnvironment = process.env.APNS_ENVIRONMENT ?? "production",
        tokenTtlMs = 55 * 60 * 1000
    } = {}) {
        if (!keyPath || !keyId || !teamId) {
            throw new Error("APNs dispatcher requires APNS_KEY_PATH, APNS_KEY_ID, APNS_TEAM_ID");
        }
        this.keyPath = keyPath;
        this.keyId = keyId;
        this.teamId = teamId;
        this.defaultBundleId = defaultBundleId;
        this.defaultEnvironment = defaultEnvironment;
        this.tokenTtlMs = tokenTtlMs;
        this._keyPem = null;
        this._token = null;
        this._tokenExpiresAt = 0;
        this._sessions = new Map();
    }

    /// Dispatches one push event. Returns `{ ok: true, receipt }` if at least
    /// one recipient accepted the push; `{ ok: false, reason }` if all
    /// recipients failed. Individual bad tokens are logged but do not fail
    /// the event — the queue would retry the whole batch, which is wrong.
    async dispatch(event) {
        const recipients = event.resolvedRecipients ?? [];
        if (recipients.length === 0) {
            return { ok: true, receipt: "no-recipients" };
        }

        const results = await Promise.allSettled(
            recipients.map((recipient) => this.sendToRecipient(event, recipient))
        );
        const anyOK = results.some((entry) => entry.status === "fulfilled" && entry.value?.ok);
        const invalidRecipients = results
            .map((entry, index) => ({ entry, recipient: recipients[index] }))
            .filter(({ entry }) => entry.status === "fulfilled" && entry.value?.invalidToken)
            .map(({ recipient }) => recipient);
        if (anyOK) {
            const acceptedCount = results.filter((entry) => entry.status === "fulfilled" && entry.value?.ok).length;
            return { ok: true, receipt: `apns:${event.kind}:${acceptedCount}/${recipients.length}`, invalidRecipients };
        }
        const firstReason = results
            .map((entry) => entry.status === "fulfilled" ? entry.value?.reason : entry.reason?.message)
            .find((reason) => reason);
        return { ok: false, reason: firstReason ?? "all recipients failed", invalidRecipients };
    }

    async sendToRecipient(event, recipient) {
        const bundleId = recipient.bundleIdentifier ?? this.defaultBundleId;
        const environment = recipient.environment ?? this.defaultEnvironment;
        if (!bundleId) return { ok: false, reason: "bundleIdentifier missing" };
        const host = APNS_HOSTS[environment] ?? APNS_HOSTS.production;
        const session = this.getSession(host);
        const token = await this.getProviderToken();

        const notification = buildNotification(event);
        const payload = Buffer.from(JSON.stringify(notification));

        return new Promise((resolve) => {
            const request = session.request({
                ":method": "POST",
                ":path": `/3/device/${recipient.deviceToken}`,
                "authorization": `bearer ${token}`,
                "apns-topic": bundleId,
                "apns-push-type": "alert",
                "apns-priority": event.priority === "high" ? "10" : "5",
                "content-type": "application/json"
            });
            request.setEncoding("utf8");

            let responseStatus = 0;
            let responseBody = "";

            request.on("response", (headers) => {
                responseStatus = Number(headers[":status"] ?? 0);
            });
            request.on("data", (chunk) => { responseBody += chunk; });
            request.on("end", () => {
                if (responseStatus === 200) {
                    resolve({ ok: true });
                } else {
                    resolve({
                        ok: false,
                        reason: `apns ${responseStatus}: ${responseBody || "no body"}`,
                        invalidToken: isInvalidTokenResponse(responseStatus, responseBody)
                    });
                }
            });
            request.on("error", (error) => {
                this.dropSession(host);
                resolve({ ok: false, reason: error.message });
            });

            request.write(payload);
            request.end();
        });
    }

    getSession(host) {
        const existing = this._sessions.get(host);
        if (existing && !existing.closed && !existing.destroyed) return existing;
        const session = http2Connect(`https://${host}`);
        session.on("error", (error) => {
            console.error("apns session error", error.message);
            this.dropSession(host);
        });
        session.on("close", () => this.dropSession(host));
        this._sessions.set(host, session);
        return session;
    }

    dropSession(host) {
        const existing = this._sessions.get(host);
        if (existing) {
            try { existing.destroy(); } catch { /* ignore */ }
            this._sessions.delete(host);
        }
    }

    async loadKey() {
        if (this._keyPem) return this._keyPem;
        this._keyPem = await readFile(this.keyPath, "utf8");
        return this._keyPem;
    }

    /// APNs provider tokens are JWTs signed ES256. Header uses the .p8 key ID,
    /// claims include `iss` (team ID) and `iat` (seconds since epoch). No `exp`
    /// — the caller controls lifetime by resigning.
    async getProviderToken(now = Date.now()) {
        if (this._token && now < this._tokenExpiresAt) return this._token;
        const keyPem = await this.loadKey();
        const header = base64UrlJson({ alg: "ES256", kid: this.keyId });
        const claims = base64UrlJson({ iss: this.teamId, iat: Math.floor(now / 1000) });
        const signingInput = `${header}.${claims}`;
        const signer = createSign("SHA256");
        signer.update(signingInput);
        signer.end();
        const derSignature = signer.sign({ key: keyPem, dsaEncoding: "ieee-p1363" });
        const signature = base64Url(derSignature);
        this._token = `${signingInput}.${signature}`;
        this._tokenExpiresAt = now + this.tokenTtlMs;
        return this._token;
    }

    close() {
        for (const host of Array.from(this._sessions.keys())) {
            this.dropSession(host);
        }
    }
}

function isInvalidTokenResponse(status, body) {
    if (![400, 410].includes(status)) return false;
    const normalized = String(body ?? "").toLowerCase();
    return normalized.includes("baddevicetoken")
        || normalized.includes("unregistered")
        || normalized.includes("devicetokennotfortopic");
}

function buildNotification(event) {
    return {
        aps: {
            alert: {
                title: event.payload?.headline ?? "Match Point",
                body: event.payload?.body ?? ""
            },
            sound: event.priority === "high" ? "default" : undefined,
            "thread-id": event.matchKey
        },
        matchKey: event.matchKey,
        kind: event.kind,
        score: event.payload?.score
    };
}

function base64UrlJson(value) {
    return base64Url(Buffer.from(JSON.stringify(value)));
}

function base64Url(buffer) {
    return buffer.toString("base64").replace(/=+$/, "").replace(/\+/g, "-").replace(/\//g, "_");
}
