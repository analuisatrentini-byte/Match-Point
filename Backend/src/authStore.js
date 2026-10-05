import crypto from "node:crypto";

const SESSION_TTL_MS = Number(process.env.AUTH_SESSION_TTL_MS ?? 1000 * 60 * 60 * 24 * 30);
const RECOVERY_TTL_MS = Number(process.env.AUTH_RECOVERY_TTL_MS ?? 1000 * 60 * 15);

export class AuthStore {
  constructor({ pool = null, mailer = createMailerFromEnv(), appleAuth = createAppleAuthClientFromEnv() } = {}) {
    this.pool = pool;
    this.mailer = mailer;
    this.appleAuth = appleAuth;
    this.users = new Map();
    this.sessions = new Map();
    this.recoveryCodes = new Map();
  }

  async signUpWithEmail(payload) {
    const email = normalizeEmail(payload.email);
    const username = normalizeUsername(payload.username);
    const password = assertPassword(payload.password);
    const displayName = optionalString(payload.displayName) || username;
    const existing = await this.findUserByEmailOrUsername(email, username);
    if (existing) throw httpError(409, "Conta já existe para este e-mail ou usuário.");

    const id = crypto.randomUUID();
    const passwordHash = await hashSecret(password);
    const user = {
      id,
      provider: "email",
      email,
      username,
      displayName,
      appleUserID: "",
      appleRevokeToken: "",
      passwordHash,
      createdAt: new Date(),
      updatedAt: new Date()
    };
    await this.insertUser(user);
    return this.sessionResponse(user);
  }

  async loginWithEmail(payload) {
    const identifier = optionalString(payload.identifier)?.toLowerCase();
    const password = assertPassword(payload.password);
    if (!identifier) throw httpError(400, "Informe e-mail ou usuário.");
    const user = await this.findUserByIdentifier(identifier);
    if (!user || user.provider !== "email") throw httpError(401, "Credenciais inválidas.");
    const ok = await verifySecret(password, user.passwordHash);
    if (!ok) throw httpError(401, "Credenciais inválidas.");
    return this.sessionResponse(user);
  }

  async signInWithApple(payload) {
    const authorizationCode = optionalString(payload.authorizationCode);
    if (!authorizationCode) throw httpError(400, "Código de autorização Apple ausente.");
    const appleIdentity = await this.appleAuth.identityFromAuthorizationCode(authorizationCode);
    const appleUserID = appleIdentity.appleUserID;
    const email = optionalString(payload.email)?.toLowerCase() || appleIdentity.email;
    const displayName = optionalString(payload.displayName) || "Match Point Fan";
    const appleRevokeToken = appleIdentity.refreshToken;
    const existing = await this.findUserByAppleID(appleUserID);
    if (existing) {
      if (appleRevokeToken) await this.updateAppleRevokeToken(existing.id, appleRevokeToken);
      return this.sessionResponse(existing);
    }

    const id = crypto.randomUUID();
    const user = {
      id,
      provider: "apple",
      email,
      username: `apple-${id.slice(0, 8)}`,
      displayName,
      appleUserID,
      appleRevokeToken,
      passwordHash: "",
      createdAt: new Date(),
      updatedAt: new Date()
    };
    await this.insertUser(user);
    return this.sessionResponse(user);
  }

  async requestPasswordRecovery(payload) {
    const identifier = optionalString(payload.identifier)?.toLowerCase();
    if (!identifier) throw httpError(400, "Informe e-mail ou usuário.");
    const user = await this.findUserByIdentifier(identifier);
    if (!user || user.provider !== "email") {
      // Avoid account enumeration; client gets a neutral success.
      return { sent: false };
    }

    const code = generateRecoveryCode();
    const expiresAt = new Date(Date.now() + RECOVERY_TTL_MS);
    await this.saveRecoveryCode(user.id, await hashSecret(code), expiresAt);
    await this.mailer.sendRecoveryCode({ email: user.email, username: user.username, code, expiresAt });
    return { sent: true, expiresAt: expiresAt.toISOString() };
  }

  async resetPassword(payload) {
    const identifier = optionalString(payload.identifier)?.toLowerCase();
    const code = optionalString(payload.code);
    const password = assertPassword(payload.newPassword);
    if (!identifier || !code) throw httpError(400, "Informe identificação e código.");
    const user = await this.findUserByIdentifier(identifier);
    if (!user || user.provider !== "email") throw httpError(400, "Código inválido ou expirado.");
    const recovery = await this.findRecoveryCode(user.id);
    if (!recovery || recovery.expiresAt.getTime() < Date.now()) throw httpError(400, "Código inválido ou expirado.");
    const ok = await verifySecret(code, recovery.codeHash);
    if (!ok) throw httpError(400, "Código inválido ou expirado.");
    await this.updatePassword(user.id, await hashSecret(password));
    await this.deleteRecoveryCode(user.id);
    const refreshed = await this.findUserByID(user.id);
    return this.sessionResponse(refreshed ?? user);
  }

  async sessionResponse(user) {
    const token = crypto.randomBytes(32).toString("base64url");
    const expiresAt = new Date(Date.now() + SESSION_TTL_MS);
    await this.saveSession(token, user.id, expiresAt);
    return {
      token,
      expiresAt: expiresAt.toISOString(),
      user: publicUser(user)
    };
  }

  async deleteAccountForSession(token) {
    const session = await this.findSession(token);
    if (!session || session.expiresAt.getTime() < Date.now()) {
      throw httpError(401, "Sessão inválida ou expirada.");
    }

    const user = await this.findUserByID(session.userID);
    if (!user) {
      await this.deleteSession(token);
      return { deleted: false, reason: "account-not-found" };
    }

    let appleTokenRevoked = false;
    if (user.provider === "apple" && user.appleRevokeToken) {
      await this.appleAuth.revokeRefreshToken(user.appleRevokeToken);
      appleTokenRevoked = true;
    }

    await this.deleteUser(user.id);
    return {
      deleted: true,
      provider: user.provider,
      appleTokenRevoked
    };
  }

  async stats() {
    if (!this.pool) {
      return { users: this.users.size, sessions: this.sessions.size, persistence: "memory" };
    }
    const result = await this.pool.query("SELECT COUNT(*)::int AS users FROM auth_users");
    return { users: result.rows[0]?.users ?? 0, persistence: "postgres" };
  }

  async findUserByEmailOrUsername(email, username) {
    if (!this.pool) {
      return [...this.users.values()].find((user) => user.email === email || user.username === username) ?? null;
    }
    const result = await this.pool.query(
      "SELECT * FROM auth_users WHERE email = $1 OR username = $2 LIMIT 1",
      [email, username]
    );
    return mapUser(result.rows[0]);
  }

  async findUserByIdentifier(identifier) {
    if (!this.pool) {
      return [...this.users.values()].find((user) => user.email === identifier || user.username === identifier) ?? null;
    }
    const result = await this.pool.query(
      "SELECT * FROM auth_users WHERE email = $1 OR username = $1 LIMIT 1",
      [identifier]
    );
    return mapUser(result.rows[0]);
  }

  async findUserByAppleID(appleUserID) {
    if (!this.pool) {
      return [...this.users.values()].find((user) => user.appleUserID === appleUserID) ?? null;
    }
    const result = await this.pool.query("SELECT * FROM auth_users WHERE apple_user_id = $1 LIMIT 1", [appleUserID]);
    return mapUser(result.rows[0]);
  }

  async findUserByID(id) {
    if (!this.pool) return this.users.get(id) ?? null;
    const result = await this.pool.query("SELECT * FROM auth_users WHERE id = $1 LIMIT 1", [id]);
    return mapUser(result.rows[0]);
  }

  async insertUser(user) {
    if (!this.pool) {
      this.users.set(user.id, user);
      return;
    }
    await this.pool.query(
      `INSERT INTO auth_users
       (id, provider, email, username, display_name, apple_user_id, apple_revoke_token, password_hash, created_at, updated_at)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)`,
      [user.id, user.provider, user.email, user.username, user.displayName, user.appleUserID, user.appleRevokeToken, user.passwordHash, user.createdAt, user.updatedAt]
    );
  }

  async updateAppleRevokeToken(userID, appleRevokeToken) {
    if (!appleRevokeToken) return;
    if (!this.pool) {
      const user = this.users.get(userID);
      if (user) {
        user.appleRevokeToken = appleRevokeToken;
        user.updatedAt = new Date();
      }
      return;
    }
    await this.pool.query(
      "UPDATE auth_users SET apple_revoke_token = $2, updated_at = NOW() WHERE id = $1",
      [userID, appleRevokeToken]
    );
  }

  async updatePassword(userID, passwordHash) {
    if (!this.pool) {
      const user = this.users.get(userID);
      if (user) {
        user.passwordHash = passwordHash;
        user.updatedAt = new Date();
      }
      return;
    }
    await this.pool.query(
      "UPDATE auth_users SET password_hash = $2, updated_at = NOW() WHERE id = $1",
      [userID, passwordHash]
    );
  }

  async saveSession(token, userID, expiresAt) {
    if (!this.pool) {
      this.sessions.set(token, { token, userID, expiresAt });
      return;
    }
    await this.pool.query(
      `INSERT INTO auth_sessions (token, user_id, expires_at)
       VALUES ($1, $2, $3)
       ON CONFLICT (token) DO UPDATE SET user_id = EXCLUDED.user_id, expires_at = EXCLUDED.expires_at`,
      [token, userID, expiresAt]
    );
  }

  async findSession(token) {
    const cleanToken = optionalString(token);
    if (!cleanToken) return null;
    if (!this.pool) return this.sessions.get(cleanToken) ?? null;
    const result = await this.pool.query("SELECT * FROM auth_sessions WHERE token = $1 LIMIT 1", [cleanToken]);
    const row = result.rows[0];
    return row ? { token: row.token, userID: row.user_id, expiresAt: row.expires_at } : null;
  }

  async deleteSession(token) {
    if (!this.pool) {
      this.sessions.delete(token);
      return;
    }
    await this.pool.query("DELETE FROM auth_sessions WHERE token = $1", [token]);
  }

  async deleteUser(userID) {
    if (!this.pool) {
      this.users.delete(userID);
      this.recoveryCodes.delete(userID);
      for (const [token, session] of this.sessions) {
        if (session.userID === userID) this.sessions.delete(token);
      }
      return;
    }
    await this.pool.query("DELETE FROM auth_users WHERE id = $1", [userID]);
  }

  async saveRecoveryCode(userID, codeHash, expiresAt) {
    if (!this.pool) {
      this.recoveryCodes.set(userID, { userID, codeHash, expiresAt });
      return;
    }
    await this.pool.query(
      `INSERT INTO auth_recovery_codes (user_id, code_hash, expires_at)
       VALUES ($1, $2, $3)
       ON CONFLICT (user_id) DO UPDATE SET code_hash = EXCLUDED.code_hash, expires_at = EXCLUDED.expires_at, created_at = NOW()`,
      [userID, codeHash, expiresAt]
    );
  }

  async findRecoveryCode(userID) {
    if (!this.pool) return this.recoveryCodes.get(userID) ?? null;
    const result = await this.pool.query("SELECT * FROM auth_recovery_codes WHERE user_id = $1 LIMIT 1", [userID]);
    const row = result.rows[0];
    return row ? { userID: row.user_id, codeHash: row.code_hash, expiresAt: row.expires_at } : null;
  }

  async deleteRecoveryCode(userID) {
    if (!this.pool) {
      this.recoveryCodes.delete(userID);
      return;
    }
    await this.pool.query("DELETE FROM auth_recovery_codes WHERE user_id = $1", [userID]);
  }
}

export function createConsoleMailer() {
  return {
    async sendRecoveryCode({ email, username, code }) {
      console.info(`Match Point recovery code for ${username} <${email}>: ${code}`);
    }
  };
}

export function createMailerFromEnv(env = process.env) {
  const apiKey = optionalString(env.RESEND_API_KEY);
  const from = optionalString(env.AUTH_EMAIL_FROM);
  if (apiKey && from) {
    return createResendMailer({ apiKey, from });
  }
  return createConsoleMailer();
}

export function createAppleAuthClientFromEnv(env = process.env, fetchImpl = fetch) {
  const clientID = optionalString(env.APPLE_CLIENT_ID);
  const teamID = optionalString(env.APPLE_TEAM_ID);
  const keyID = optionalString(env.APPLE_KEY_ID);
  const privateKey = optionalString(env.APPLE_PRIVATE_KEY)?.replaceAll("\\n", "\n");
  const configured = Boolean(clientID && teamID && keyID && privateKey);

  return {
    async identityFromAuthorizationCode(code) {
      if (!configured) {
        throw httpError(503, "Login com Conta Apple não configurado no servidor.");
      }
      const body = new URLSearchParams({
        client_id: clientID,
        client_secret: appleClientSecret({ clientID, teamID, keyID, privateKey }),
        code,
        grant_type: "authorization_code"
      });
      const response = await fetchImpl("https://appleid.apple.com/auth/token", {
        method: "POST",
        headers: { "content-type": "application/x-www-form-urlencoded" },
        body
      });
      const payload = await response.json().catch(() => ({}));
      if (!response.ok) {
        throw httpError(502, `Falha ao preparar revogação da Conta Apple: ${payload.error ?? response.statusText}`);
      }
      const claims = decodeAppleIdentityToken(optionalString(payload.id_token), clientID);
      return {
        appleUserID: claims.sub,
        email: optionalString(claims.email)?.toLowerCase() ?? "",
        refreshToken: optionalString(payload.refresh_token) ?? ""
      };
    },

    async revokeRefreshToken(refreshToken) {
      if (!refreshToken) return false;
      if (!configured) {
        throw httpError(503, "Revogação da Conta Apple não configurada no servidor.");
      }
      const body = new URLSearchParams({
        client_id: clientID,
        client_secret: appleClientSecret({ clientID, teamID, keyID, privateKey }),
        token: refreshToken,
        token_type_hint: "refresh_token"
      });
      const response = await fetchImpl("https://appleid.apple.com/auth/revoke", {
        method: "POST",
        headers: { "content-type": "application/x-www-form-urlencoded" },
        body
      });
      if (!response.ok) {
        const text = await response.text().catch(() => "");
        throw httpError(502, `Falha ao revogar Conta Apple: ${text || response.statusText}`);
      }
      return true;
    }
  };
}

function appleClientSecret({ clientID, teamID, keyID, privateKey }) {
  const now = Math.floor(Date.now() / 1000);
  const header = { alg: "ES256", kid: keyID };
  const payload = {
    iss: teamID,
    iat: now,
    exp: now + 60 * 60,
    aud: "https://appleid.apple.com",
    sub: clientID
  };
  const signingInput = `${base64urlJSON(header)}.${base64urlJSON(payload)}`;
  const signature = crypto.sign("sha256", Buffer.from(signingInput), {
    key: privateKey,
    dsaEncoding: "ieee-p1363"
  }).toString("base64url");
  return `${signingInput}.${signature}`;
}

function base64urlJSON(value) {
  return Buffer.from(JSON.stringify(value)).toString("base64url");
}

function decodeAppleIdentityToken(idToken, expectedAudience) {
  const parts = optionalString(idToken).split(".");
  if (parts.length < 2) {
    throw httpError(502, "Resposta da Apple sem identidade verificável.");
  }
  let claims;
  try {
    claims = JSON.parse(Buffer.from(parts[1], "base64url").toString("utf8"));
  } catch {
    throw httpError(502, "Identidade Apple inválida.");
  }
  if (claims.iss !== "https://appleid.apple.com") {
    throw httpError(502, "Emissor da identidade Apple inválido.");
  }
  if (!optionalString(claims.sub)) {
    throw httpError(502, "Identidade Apple sem usuário.");
  }
  if (optionalString(claims.aud) !== expectedAudience) {
    throw httpError(502, "Identidade Apple emitida para outro app.");
  }
  return claims;
}

export function createResendMailer({ apiKey, from, fetchImpl = fetch }) {
  return {
    async sendRecoveryCode({ email, username, code, expiresAt }) {
      const response = await fetchImpl("https://api.resend.com/emails", {
        method: "POST",
        headers: {
          authorization: `Bearer ${apiKey}`,
          "content-type": "application/json"
        },
        body: JSON.stringify({
          from,
          to: [email],
          subject: "Seu código de recuperação do Match Point",
          text: recoveryText({ username, code, expiresAt }),
          html: recoveryHTML({ username, code, expiresAt })
        })
      });
      if (!response.ok) {
        const body = await response.text().catch(() => "");
        throw httpError(502, `Falha ao enviar e-mail de recuperação: ${body || response.statusText}`);
      }
    }
  };
}

function recoveryText({ username, code, expiresAt }) {
  return [
    `Olá, ${username}.`,
    "",
    `Seu código de recuperação do Match Point é: ${code}`,
    `Ele expira em ${expiresAt.toISOString()}.`,
    "",
    "Se você não pediu esse código, ignore este e-mail."
  ].join("\n");
}

function recoveryHTML({ username, code, expiresAt }) {
  return `
    <div style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;line-height:1.5;color:#160a2e">
      <h1>Recuperação do Match Point</h1>
      <p>Olá, ${escapeHTML(username)}.</p>
      <p>Use este código para redefinir sua senha:</p>
      <p style="font-size:28px;font-weight:800;letter-spacing:3px;color:#2fd35f">${escapeHTML(code)}</p>
      <p>Ele expira em ${escapeHTML(expiresAt.toISOString())}.</p>
      <p>Se você não pediu esse código, ignore este e-mail.</p>
    </div>
  `;
}

function normalizeEmail(value) {
  const email = optionalString(value)?.toLowerCase();
  if (!email || !email.includes("@") || !email.includes(".")) throw httpError(400, "E-mail inválido.");
  return email;
}

function normalizeUsername(value) {
  const username = optionalString(value)?.toLowerCase();
  if (!username || username.length < 3 || !/^[a-z0-9._-]+$/.test(username)) {
    throw httpError(400, "Usuário inválido. Use pelo menos 3 caracteres, letras, números, ponto, traço ou underline.");
  }
  return username;
}

function assertPassword(value) {
  const password = optionalString(value);
  if (!password || password.length < 8) throw httpError(400, "Senha deve ter pelo menos 8 caracteres.");
  return password;
}

function optionalString(value) {
  return typeof value === "string" ? value.trim() : "";
}

function escapeHTML(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

async function hashSecret(secret) {
  const salt = crypto.randomBytes(16).toString("base64url");
  const hash = await scrypt(secret, salt);
  return `scrypt$${salt}$${hash}`;
}

async function verifySecret(secret, encoded) {
  const [scheme, salt, expected] = String(encoded).split("$");
  if (scheme !== "scrypt" || !salt || !expected) return false;
  const actual = await scrypt(secret, salt);
  return crypto.timingSafeEqual(Buffer.from(actual), Buffer.from(expected));
}

function scrypt(secret, salt) {
  return new Promise((resolve, reject) => {
    crypto.scrypt(secret, salt, 64, (error, derivedKey) => {
      if (error) reject(error);
      else resolve(derivedKey.toString("base64url"));
    });
  });
}

function generateRecoveryCode() {
  return crypto.randomBytes(4).toString("hex").toUpperCase();
}

function publicUser(user) {
  return {
    id: user.id,
    provider: user.provider,
    email: user.email,
    username: user.username,
    displayName: user.displayName,
    externalKey: `${user.provider}:${user.provider === "apple" ? user.appleUserID : user.id}`
  };
}

function mapUser(row) {
  if (!row) return null;
  return {
    id: row.id,
    provider: row.provider,
    email: row.email,
    username: row.username,
    displayName: row.display_name,
    appleUserID: row.apple_user_id,
    appleRevokeToken: row.apple_revoke_token,
    passwordHash: row.password_hash,
    createdAt: row.created_at,
    updatedAt: row.updated_at
  };
}

function httpError(statusCode, message) {
  const error = new Error(message);
  error.statusCode = statusCode;
  return error;
}
