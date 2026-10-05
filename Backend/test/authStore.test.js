import assert from "node:assert/strict";
import test from "node:test";

import { AuthStore } from "../src/authStore.js";

function captureMailer() {
  const sent = [];
  return {
    sent,
    async sendRecoveryCode(message) {
      sent.push(message);
    }
  };
}

test("email auth supports signup login recovery request and password reset", async () => {
  const mailer = captureMailer();
  const store = new AuthStore({ mailer });

  const signup = await store.signUpWithEmail({
    email: "Ana@example.com",
    username: "ana",
    password: "old-password"
  });
  assert.equal(signup.user.email, "ana@example.com");
  assert.equal(signup.user.username, "ana");
  assert.ok(signup.token);

  const login = await store.loginWithEmail({
    identifier: "ana",
    password: "old-password"
  });
  assert.equal(login.user.id, signup.user.id);

  const recovery = await store.requestPasswordRecovery({ identifier: "ana@example.com" });
  assert.equal(recovery.sent, true);
  assert.equal(mailer.sent.length, 1);
  assert.equal(mailer.sent[0].email, "ana@example.com");

  const reset = await store.resetPassword({
    identifier: "ana",
    code: mailer.sent[0].code,
    newPassword: "new-password"
  });
  assert.equal(reset.user.id, signup.user.id);

  await assert.rejects(
    () => store.loginWithEmail({ identifier: "ana", password: "old-password" }),
    /Credenciais inválidas/
  );

  const relogin = await store.loginWithEmail({
    identifier: "ana@example.com",
    password: "new-password"
  });
  assert.equal(relogin.user.id, signup.user.id);
});

test("apple auth derives user identity from server-validated authorization code", async () => {
  const store = new AuthStore({
    appleAuth: {
      async identityFromAuthorizationCode(code) {
        assert.equal(code, "valid-authorization-code");
        return {
          appleUserID: "apple-real-subject",
          email: "apple@example.com",
          refreshToken: "refresh-token"
        };
      },
      async revokeRefreshToken() {
        return true;
      }
    }
  });

  const session = await store.signInWithApple({
    appleUserID: "spoofed-client-value",
    authorizationCode: "valid-authorization-code",
    displayName: "Ana Apple"
  });

  assert.equal(session.user.externalKey, "apple:apple-real-subject");
  assert.equal(session.user.email, "apple@example.com");
});
