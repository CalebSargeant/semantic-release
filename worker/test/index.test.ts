import { handleRequest, type BrokerEnv } from "../src/index";
import { generateKeyPairSync } from "node:crypto";

const env: BrokerEnv = {
  GITHUB_APP_ID: "12345",
  GITHUB_APP_PRIVATE_KEY: "-----BEGIN PRIVATE KEY-----\\nsecret\\n-----END PRIVATE KEY-----",
  OIDC_AUDIENCE: "release-runner"
};

function tokenRequest(body: Record<string, unknown>): Request {
  return new Request("https://broker.example.com/token", {
    method: "POST",
    headers: {
      "content-type": "application/json"
    },
    body: JSON.stringify(body)
  });
}

async function readJson(response: Response): Promise<Record<string, unknown>> {
  return (await response.json()) as Record<string, unknown>;
}

function deps(options: {
  repository?: string;
  githubResponses?: Response[];
  verifyThrows?: boolean;
} = {}) {
  const calls: Request[] = [];
  const githubResponses = [...(options.githubResponses ?? [])];

  return {
    calls,
    deps: {
      verifyOidcToken: async () => {
        if (options.verifyThrows) {
          throw new Error("bad oidc");
        }
        return {
          repository: options.repository ?? "octo-org/octo-repo"
        };
      },
      createGitHubAppJwt: async () => "app.jwt",
      fetch: async (input: RequestInfo | URL, init?: RequestInit) => {
        calls.push(new Request(input, init));
        return githubResponses.shift() ?? Response.json({ id: 42 });
      },
      now: () => new Date("2026-05-03T12:00:00Z")
    }
  };
}

describe("token broker", () => {
  it("rejects missing fields with 400", async () => {
    const response = await handleRequest(tokenRequest({ owner: "octo-org" }), env);

    expect(response.status).toBe(400);
    expect(await readJson(response)).toEqual({ error: "missing_required_fields" });
  });

  it("rejects invalid OIDC tokens with 401", async () => {
    const { deps: injected } = deps({ verifyThrows: true });
    const response = await handleRequest(
      tokenRequest({
        oidcToken: "bad.jwt",
        owner: "octo-org",
        repo: "octo-repo"
      }),
      env,
      injected
    );

    expect(response.status).toBe(401);
    expect(await readJson(response)).toEqual({ error: "invalid_oidc_token" });
  });

  it("rejects repo claim mismatch with 403", async () => {
    const { deps: injected } = deps({ repository: "octo-org/other-repo" });
    const response = await handleRequest(
      tokenRequest({
        oidcToken: "valid.jwt",
        owner: "octo-org",
        repo: "octo-repo"
      }),
      env,
      injected
    );

    expect(response.status).toBe(403);
    expect(await readJson(response)).toEqual({ error: "repo_mismatch" });
  });

  it("rejects repos outside the allow-list with 403", async () => {
    const { deps: injected } = deps();
    const response = await handleRequest(
      tokenRequest({
        oidcToken: "valid.jwt",
        owner: "octo-org",
        repo: "octo-repo"
      }),
      {
        ...env,
        ALLOWED_REPOSITORIES: "octo-org/allowed-repo"
      },
      injected
    );

    expect(response.status).toBe(403);
    expect(await readJson(response)).toEqual({ error: "repo_not_allowed" });
  });

  it("returns 404 when the app is not installed", async () => {
    const { deps: injected } = deps({
      githubResponses: [new Response("{}", { status: 404 })]
    });
    const response = await handleRequest(
      tokenRequest({
        oidcToken: "valid.jwt",
        owner: "octo-org",
        repo: "octo-repo"
      }),
      env,
      injected
    );

    expect(response.status).toBe(404);
    expect(await readJson(response)).toEqual({ error: "app_not_installed" });
  });

  it("returns a generic error when GitHub token creation fails", async () => {
    const { deps: injected } = deps({
      githubResponses: [
        Response.json({ id: 42 }),
        new Response('{"token":"do-not-leak"}', { status: 500 })
      ]
    });
    const response = await handleRequest(
      tokenRequest({
        oidcToken: "valid.jwt",
        owner: "octo-org",
        repo: "octo-repo"
      }),
      env,
      injected
    );
    const body = await response.text();

    expect(response.status).toBe(500);
    expect(body).toBe('{"error":"github_token_create_failed"}');
    expect(body).not.toContain("do-not-leak");
  });

  it("creates a repo-scoped installation token", async () => {
    const { calls, deps: injected } = deps({
      githubResponses: [
        Response.json({ id: 42 }),
        Response.json({
          token: "installation-token",
          expires_at: "2026-05-03T13:00:00Z"
        })
      ]
    });
    const response = await handleRequest(
      tokenRequest({
        oidcToken: "valid.jwt",
        owner: "octo-org",
        repo: "octo-repo"
      }),
      env,
      injected
    );

    expect(response.status).toBe(200);
    expect(await readJson(response)).toEqual({
      token: "installation-token",
      expires_at: "2026-05-03T13:00:00Z",
      repository: "octo-org/octo-repo"
    });

    const tokenRequestBody = await calls[1].json();
    expect(tokenRequestBody).toEqual({
      repositories: ["octo-repo"],
      permissions: {
        contents: "write",
        pull_requests: "write"
      }
    });
  });

  it("accepts GitHub-style PKCS#1 RSA private keys", async () => {
    const { privateKey } = generateKeyPairSync("rsa", {
      modulusLength: 2048
    });
    const pkcs1PrivateKey = privateKey.export({
      format: "pem",
      type: "pkcs1"
    }) as string;

    const { deps: injected } = deps({
      githubResponses: [
        Response.json({ id: 42 }),
        Response.json({
          token: "installation-token",
          expires_at: "2026-05-03T13:00:00Z"
        })
      ]
    });

    const response = await handleRequest(
      tokenRequest({
        oidcToken: "valid.jwt",
        owner: "octo-org",
        repo: "octo-repo"
      }),
      {
        ...env,
        GITHUB_APP_PRIVATE_KEY: pkcs1PrivateKey
      },
      {
        verifyOidcToken: injected.verifyOidcToken,
        fetch: injected.fetch,
        now: injected.now
      }
    );

    expect(response.status).toBe(200);
  });
});

// ─── /copilot-quota ──────────────────────────────────────────────────────────
//
// Tests run the worker through `handleRequest` with injected `fetch` / `now`,
// the same shape the /token tests already use. The KV namespace is faked
// with an in-memory Map so we don't pull in miniflare just for these cases.

function makeKv() {
  const store = new Map<string, { value: string; expiresAt?: number }>();
  return {
    store,
    kv: {
      async get(key: string) {
        const entry = store.get(key);
        if (!entry) return null;
        if (entry.expiresAt && entry.expiresAt <= Date.now()) {
          store.delete(key);
          return null;
        }
        return entry.value;
      },
      async put(
        key: string,
        value: string,
        options?: { expirationTtl?: number }
      ) {
        const expiresAt = options?.expirationTtl
          ? Date.now() + options.expirationTtl * 1000
          : undefined;
        store.set(key, { value, expiresAt });
      },
      async delete(key: string) {
        store.delete(key);
      },
      async list(options?: { prefix?: string; cursor?: string }) {
        const prefix = options?.prefix ?? "";
        const keys = [...store.keys()]
          .filter((name) => name.startsWith(prefix))
          .map((name) => ({ name }));
        return { keys, list_complete: true };
      },
      async getWithMetadata(_key: string) {
        return { value: null, metadata: null };
      }
    } as unknown as KVNamespace
  };
}

function quotaGet(owner: string): Request {
  return new Request(
    `https://broker.example.com/copilot-quota?owner=${encodeURIComponent(owner)}`,
    { method: "GET" }
  );
}

function quotaPost(body: unknown, headers: Record<string, string> = {}): Request {
  return new Request("https://broker.example.com/copilot-quota", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      ...headers
    },
    body: JSON.stringify(body)
  });
}

describe("copilot-quota endpoint", () => {
  it("returns default false when no KV is configured and Billing API is unavailable", async () => {
    const { deps: injected } = deps({
      githubResponses: [
        new Response("{}", { status: 404 }), // org installation lookup
        new Response("{}", { status: 404 })  // user installation lookup
      ]
    });
    const response = await handleRequest(quotaGet("octo-org"), env, injected);

    expect(response.status).toBe(200);
    const body = await readJson(response);
    expect(body.rate_limited).toBe(false);
    expect(body.source).toBe("default");
  });

  it("rejects requests with no owner param", async () => {
    const response = await handleRequest(
      new Request("https://broker.example.com/copilot-quota", { method: "GET" }),
      env
    );
    expect(response.status).toBe(400);
    expect(await readJson(response)).toEqual({ error: "missing_owner" });
  });

  it("rejects owners that aren't valid GitHub login slugs", async () => {
    const response = await handleRequest(
      quotaGet("not a valid name"),
      env
    );
    expect(response.status).toBe(400);
    expect(await readJson(response)).toEqual({ error: "invalid_owner" });
  });

  it("returns a manual override when KV has one", async () => {
    const { kv, store } = makeKv();
    store.set("copilot-quota:manual:octo-org", {
      value: JSON.stringify({
        rate_limited: true,
        resets_at: "2026-06-01T00:00:00.000Z",
        set_at: "2026-05-26T10:00:00.000Z"
      })
    });

    const { deps: injected } = deps();
    const response = await handleRequest(
      quotaGet("octo-org"),
      { ...env, COPILOT_QUOTA_KV: kv },
      injected
    );

    expect(response.status).toBe(200);
    const body = await readJson(response);
    expect(body.rate_limited).toBe(true);
    expect(body.source).toBe("manual");
    expect(body.resets_at).toBe("2026-06-01T00:00:00.000Z");
  });

  it("ignores stale manual overrides past their reset date", async () => {
    const { kv, store } = makeKv();
    store.set("copilot-quota:manual:octo-org", {
      value: JSON.stringify({
        rate_limited: true,
        resets_at: "2026-04-01T00:00:00.000Z",
        set_at: "2026-03-26T10:00:00.000Z"
      })
    });

    const { deps: injected } = deps({
      githubResponses: [
        new Response("{}", { status: 404 }),
        new Response("{}", { status: 404 })
      ]
    });
    const response = await handleRequest(
      quotaGet("octo-org"),
      { ...env, COPILOT_QUOTA_KV: kv },
      injected
    );

    expect(response.status).toBe(200);
    const body = await readJson(response);
    expect(body.rate_limited).toBe(false);
    expect(body.source).toBe("default");
  });

  it("POST without override secret returns 503 override_disabled", async () => {
    const response = await handleRequest(
      quotaPost({ owner: "octo-org", rate_limited: true }),
      env
    );
    expect(response.status).toBe(503);
    expect(await readJson(response)).toEqual({ error: "override_disabled" });
  });

  it("POST with wrong bearer returns 401", async () => {
    const response = await handleRequest(
      quotaPost(
        { owner: "octo-org", rate_limited: true },
        { authorization: "Bearer nope" }
      ),
      { ...env, COPILOT_QUOTA_OVERRIDE_SECRET: "secret" }
    );
    expect(response.status).toBe(401);
    expect(await readJson(response)).toEqual({ error: "unauthorized" });
  });

  it("POST stores a manual override and returns the reset date", async () => {
    const { kv, store } = makeKv();
    const { deps: injected } = deps();
    const response = await handleRequest(
      quotaPost(
        { owner: "octo-org", rate_limited: true },
        { authorization: "Bearer secret" }
      ),
      {
        ...env,
        COPILOT_QUOTA_OVERRIDE_SECRET: "secret",
        COPILOT_QUOTA_KV: kv
      },
      injected
    );

    expect(response.status).toBe(200);
    const body = await readJson(response);
    expect(body.stored).toBe(true);
    expect(body.owner).toBe("octo-org");
    expect(typeof body.resets_at).toBe("string");
    expect(store.get("copilot-quota:manual:octo-org")).toBeDefined();
  });

  it("POST with rate_limited=false clears the manual override", async () => {
    const { kv, store } = makeKv();
    store.set("copilot-quota:manual:octo-org", {
      value: JSON.stringify({
        rate_limited: true,
        resets_at: "2026-06-01T00:00:00.000Z",
        set_at: "2026-05-26T10:00:00.000Z"
      })
    });

    const { deps: injected } = deps();
    const response = await handleRequest(
      quotaPost(
        { owner: "octo-org", rate_limited: false },
        { authorization: "Bearer secret" }
      ),
      {
        ...env,
        COPILOT_QUOTA_OVERRIDE_SECRET: "secret",
        COPILOT_QUOTA_KV: kv
      },
      injected
    );

    expect(response.status).toBe(200);
    expect(await readJson(response)).toEqual({ cleared: true, owner: "octo-org" });
    expect(store.has("copilot-quota:manual:octo-org")).toBe(false);
  });

  it("flags rate-limited when the Billing API reports an exhausted premium-request item", async () => {
    const { deps: injected } = deps({
      githubResponses: [
        Response.json({ id: 99 }),                      // org installation lookup
        Response.json({ token: "ghs_x", expires_at: "2026-05-26T13:00:00Z" }), // installation token
        Response.json({
          usageItems: [
            {
              product: "Copilot",
              sku: "Copilot Premium Requests",
              quantity: 500,
              includedQuantity: 500,
              remaining: 0,
              periodEnd: "2026-06-01T00:00:00.000Z"
            }
          ]
        })
      ]
    });

    const response = await handleRequest(quotaGet("octo-org"), env, injected);

    expect(response.status).toBe(200);
    const body = await readJson(response);
    expect(body.rate_limited).toBe(true);
    expect(body.source).toBe("github-billing-api");
    expect(body.resets_at).toBe("2026-06-01T00:00:00.000Z");
  });

  it("reports rate_limited:false when the Billing API has Copilot data but quota remains", async () => {
    const { deps: injected } = deps({
      githubResponses: [
        Response.json({ id: 99 }),
        Response.json({ token: "ghs_x", expires_at: "2026-05-26T13:00:00Z" }),
        Response.json({
          usageItems: [
            {
              product: "Copilot",
              sku: "Copilot Premium Requests",
              quantity: 100,
              includedQuantity: 500,
              remaining: 400
            }
          ]
        })
      ]
    });

    const response = await handleRequest(quotaGet("octo-org"), env, injected);

    expect(response.status).toBe(200);
    const body = await readJson(response);
    expect(body.rate_limited).toBe(false);
    expect(body.source).toBe("github-billing-api");
  });

  it("falls back to user-scoped Billing API when org lookup returns 404", async () => {
    const { deps: injected } = deps({
      githubResponses: [
        new Response("{}", { status: 404 }),            // /orgs/.../installation
        Response.json({ id: 77 }),                      // /users/.../installation
        Response.json({ token: "ghs_y", expires_at: "2026-05-26T13:00:00Z" }),
        new Response("{}", { status: 404 }),            // org billing usage
        Response.json({
          usageItems: [
            {
              product: "Copilot",
              sku: "Copilot Premium Requests",
              quantity: 200,
              includedQuantity: 200,
              remaining: 0
            }
          ]
        })
      ]
    });

    const response = await handleRequest(quotaGet("calebsargeant"), env, injected);

    expect(response.status).toBe(200);
    const body = await readJson(response);
    expect(body.rate_limited).toBe(true);
    expect(body.source).toBe("github-billing-api");
  });

  it("flags rate-limited via OAuth user-billing when requester has a stored refresh token", async () => {
    // requester has a stored OAuth refresh token; worker refreshes,
    // queries /users/{requester}/settings/billing/premium_request/usage,
    // sees exhausted Copilot premium-request line item.
    const { kv, store } = makeKv();
    store.set("copilot-oauth:user:calebsargeant", {
      value: JSON.stringify({
        refresh_token: "ghr_old",
        refresh_token_expires_at: "2026-11-01T00:00:00.000Z",
        connected_at: "2026-05-01T12:00:00.000Z"
      })
    });

    const { deps: injected } = deps({
      githubResponses: [
        // 1. token refresh
        Response.json({
          access_token: "ghu_fresh",
          refresh_token: "ghr_rotated",
          expires_in: 28800,
          refresh_token_expires_in: 15897600
        }),
        // 2. premium_request/usage
        Response.json({
          usageItems: [
            {
              product: "Copilot",
              sku: "Copilot Premium Requests",
              quantity: 500,
              includedQuantity: 500,
              remaining: 0,
              periodEnd: "2026-06-01T00:00:00.000Z"
            }
          ]
        })
      ]
    });

    const response = await handleRequest(
      new Request(
        "https://broker.example.com/copilot-quota?owner=octo-org&requester=calebsargeant",
        { method: "GET" }
      ),
      {
        ...env,
        COPILOT_QUOTA_KV: kv,
        GITHUB_APP_CLIENT_ID: "Iv23test",
        GITHUB_APP_CLIENT_SECRET: "test_secret"
      },
      injected
    );

    expect(response.status).toBe(200);
    const body = await readJson(response);
    expect(body.rate_limited).toBe(true);
    expect(body.source).toBe("github-oauth-user-billing");
    expect(body.resets_at).toBe("2026-06-01T00:00:00.000Z");

    // Refresh token should have been rotated and persisted
    const stored = store.get("copilot-oauth:user:calebsargeant");
    expect(stored).toBeDefined();
    const parsed = JSON.parse(stored!.value);
    expect(parsed.refresh_token).toBe("ghr_rotated");
    expect(parsed.access_token).toBe("ghu_fresh");
  });

  it("OAuth user-billing layer is a no-op when no refresh token exists for requester", async () => {
    // No OAuth record → Layer 3 returns null. The chain falls through
    // to org billing (Layer 4), which here also has no Copilot data,
    // so the gate stays default-false.
    const { kv } = makeKv();
    const { deps: injected } = deps({
      githubResponses: [
        // org billing for owner — App not installed
        new Response("{}", { status: 404 }),
        new Response("{}", { status: 404 })
      ]
    });

    const response = await handleRequest(
      new Request(
        "https://broker.example.com/copilot-quota?owner=octo-org&requester=calebsargeant",
        { method: "GET" }
      ),
      {
        ...env,
        COPILOT_QUOTA_KV: kv,
        GITHUB_APP_CLIENT_ID: "Iv23test",
        GITHUB_APP_CLIENT_SECRET: "test_secret"
      },
      injected
    );

    expect(response.status).toBe(200);
    const body = await readJson(response);
    expect(body.rate_limited).toBe(false);
    expect(body.source).toBe("default");
  });

  it("OAuth user-billing returns no-signal when refresh token has expired", async () => {
    const { kv } = makeKv();
    kv.put(
      "copilot-oauth:user:calebsargeant",
      JSON.stringify({
        refresh_token: "ghr_old",
        refresh_token_expires_at: "2026-01-01T00:00:00.000Z", // already past
        connected_at: "2025-08-01T00:00:00.000Z"
      })
    );

    const { deps: injected } = deps({
      githubResponses: [
        new Response("{}", { status: 404 }),
        new Response("{}", { status: 404 })
      ]
    });

    const response = await handleRequest(
      new Request(
        "https://broker.example.com/copilot-quota?owner=octo-org&requester=calebsargeant",
        { method: "GET" }
      ),
      {
        ...env,
        COPILOT_QUOTA_KV: kv,
        GITHUB_APP_CLIENT_ID: "Iv23test",
        GITHUB_APP_CLIENT_SECRET: "test_secret"
      },
      injected
    );

    expect(response.status).toBe(200);
    const body = await readJson(response);
    expect(body.rate_limited).toBe(false);
    expect(body.source).toBe("default");
  });

  it("checks the manual override for the requester as well as the owner", async () => {
    // Owner has no override; requester does.
    const { kv, store } = makeKv();
    store.set("copilot-quota:manual:calebsargeant", {
      value: JSON.stringify({
        rate_limited: true,
        resets_at: "2026-06-01T00:00:00.000Z",
        set_at: "2026-05-26T10:00:00.000Z"
      })
    });

    const { deps: injected } = deps();
    const response = await handleRequest(
      new Request(
        "https://broker.example.com/copilot-quota?owner=octo-org&requester=calebsargeant",
        { method: "GET" }
      ),
      { ...env, COPILOT_QUOTA_KV: kv },
      injected
    );

    expect(response.status).toBe(200);
    const body = await readJson(response);
    expect(body.rate_limited).toBe(true);
    expect(body.source).toBe("manual");
  });

  it("silently ignores invalid requester strings and stays backward-compatible", async () => {
    // Invalid requester should not throw; the endpoint should still
    // resolve based on owner alone (default false when no signal).
    const { deps: injected } = deps({
      githubResponses: [
        new Response("{}", { status: 404 }),
        new Response("{}", { status: 404 })
      ]
    });
    const response = await handleRequest(
      new Request(
        "https://broker.example.com/copilot-quota?owner=octo-org&requester=not%20a%20valid%20name",
        { method: "GET" }
      ),
      env,
      injected
    );

    expect(response.status).toBe(200);
    const body = await readJson(response);
    expect(body.rate_limited).toBe(false);
    expect(body.source).toBe("default");
  });

  it("returns 405 for unsupported methods", async () => {
    const response = await handleRequest(
      new Request("https://broker.example.com/copilot-quota?owner=octo-org", {
        method: "DELETE"
      }),
      env
    );
    expect(response.status).toBe(405);
  });

  it("returns 404 for unknown paths", async () => {
    const response = await handleRequest(
      new Request("https://broker.example.com/whatever", { method: "GET" }),
      env
    );
    expect(response.status).toBe(404);
  });
});

// ─── /webhook + scheduled refresh + metrics fallback ─────────────────────────

import { handleScheduledRefresh } from "../src/index";

async function hmac(secret: string, body: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const mac = await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode(body)
  );
  return (
    "sha256=" +
    Array.from(new Uint8Array(mac))
      .map((b) => b.toString(16).padStart(2, "0"))
      .join("")
  );
}

function webhookRequest(
  body: Record<string, unknown>,
  event: string,
  signatureHeader: string
): Request {
  return new Request("https://broker.example.com/webhook", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-github-event": event,
      "x-hub-signature-256": signatureHeader
    },
    body: JSON.stringify(body)
  });
}

describe("copilot-quota /webhook", () => {
  it("rejects requests when no webhook secret is configured", async () => {
    const response = await handleRequest(
      webhookRequest({}, "ping", "sha256=abc"),
      env
    );
    expect(response.status).toBe(503);
    expect(await readJson(response)).toEqual({ error: "webhook_disabled" });
  });

  it("rejects requests with an invalid HMAC signature", async () => {
    const response = await handleRequest(
      webhookRequest({ zen: "hi" }, "ping", "sha256=deadbeef"),
      { ...env, GITHUB_WEBHOOK_SECRET: "shh" }
    );
    expect(response.status).toBe(401);
    expect(await readJson(response)).toEqual({ error: "invalid_signature" });
  });

  it("ignores events other than pull_request / pull_request_review", async () => {
    const body = JSON.stringify({ zen: "hi" });
    const sig = await hmac("shh", body);
    const response = await handleRequest(
      new Request("https://broker.example.com/webhook", {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "x-github-event": "ping",
          "x-hub-signature-256": sig
        },
        body
      }),
      { ...env, GITHUB_WEBHOOK_SECRET: "shh" }
    );
    expect(response.status).toBe(200);
    const out = await readJson(response);
    expect(out.ok).toBe(true);
    expect(out.ignored).toBe("ping");
  });

  it("records a Copilot review_requested event in KV", async () => {
    const { kv, store } = makeKv();
    const payload = {
      action: "review_requested",
      repository: { owner: { login: "octo-org" } },
      requested_reviewer: { login: "copilot-pull-request-reviewer[bot]" }
    };
    const body = JSON.stringify(payload);
    const sig = await hmac("shh", body);
    const response = await handleRequest(
      new Request("https://broker.example.com/webhook", {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "x-github-event": "pull_request",
          "x-hub-signature-256": sig
        },
        body
      }),
      {
        ...env,
        GITHUB_WEBHOOK_SECRET: "shh",
        COPILOT_QUOTA_KV: kv
      }
    );
    expect(response.status).toBe(200);
    expect(await readJson(response)).toEqual({
      ok: true,
      owner: "octo-org",
      touched: true
    });
    expect(store.has("copilot-quota:webhook:octo-org")).toBe(true);
    const stored = JSON.parse(
      store.get("copilot-quota:webhook:octo-org")!.value
    );
    expect(stored.last_request_at).toBeTruthy();
    expect(stored.recent_request_count).toBe(1);
  });

  it("clears the backlog when Copilot submits a review", async () => {
    const { kv, store } = makeKv();
    store.set("copilot-quota:webhook:octo-org", {
      value: JSON.stringify({
        last_request_at: "2026-05-26T10:00:00.000Z",
        recent_request_count: 3
      })
    });
    const payload = {
      action: "submitted",
      repository: { owner: { login: "octo-org" } },
      review: { user: { login: "copilot-pull-request-reviewer[bot]" } }
    };
    const body = JSON.stringify(payload);
    const sig = await hmac("shh", body);
    const response = await handleRequest(
      new Request("https://broker.example.com/webhook", {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "x-github-event": "pull_request_review",
          "x-hub-signature-256": sig
        },
        body
      }),
      {
        ...env,
        GITHUB_WEBHOOK_SECRET: "shh",
        COPILOT_QUOTA_KV: kv
      }
    );
    expect(response.status).toBe(200);
    const stored = JSON.parse(
      store.get("copilot-quota:webhook:octo-org")!.value
    );
    expect(stored.recent_request_count).toBe(0);
    expect(stored.last_review_at).toBeTruthy();
  });

  it("ignores non-Copilot review submissions", async () => {
    const { kv, store } = makeKv();
    const payload = {
      action: "submitted",
      repository: { owner: { login: "octo-org" } },
      review: { user: { login: "human-reviewer" } }
    };
    const body = JSON.stringify(payload);
    const sig = await hmac("shh", body);
    await handleRequest(
      new Request("https://broker.example.com/webhook", {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "x-github-event": "pull_request_review",
          "x-hub-signature-256": sig
        },
        body
      }),
      {
        ...env,
        GITHUB_WEBHOOK_SECRET: "shh",
        COPILOT_QUOTA_KV: kv
      }
    );
    expect(store.has("copilot-quota:webhook:octo-org")).toBe(false);
  });
});

describe("copilot-quota webhook signal in resolution chain", () => {
  it("returns rate_limited:true when webhook shows requests outpacing reviews past the threshold", async () => {
    const { kv, store } = makeKv();
    // last_request_at is 45 min ago; last_review_at is 2 hours ago
    store.set("copilot-quota:webhook:octo-org", {
      value: JSON.stringify({
        last_request_at: "2026-05-26T11:15:00.000Z",
        last_review_at: "2026-05-26T10:00:00.000Z",
        recent_request_count: 5
      })
    });
    const { deps: injected } = deps({
      githubResponses: [
        new Response("{}", { status: 404 }), // org installation
        new Response("{}", { status: 404 })  // user installation
      ],
      // hardcode "now" to 12:00, so last_request_at is 45 min stale and
      // gap from last_review_at is 2h
    });
    // Override the injected `now` to a fixed value past the gap.
    injected.now = () => new Date("2026-05-26T12:00:00.000Z");

    const response = await handleRequest(
      quotaGet("octo-org"),
      { ...env, COPILOT_QUOTA_KV: kv },
      injected
    );

    expect(response.status).toBe(200);
    const body = await readJson(response);
    expect(body.rate_limited).toBe(true);
    expect(body.source).toBe("github-webhook");
  });

  it("returns rate_limited:false when last review is recent", async () => {
    const { kv, store } = makeKv();
    store.set("copilot-quota:webhook:octo-org", {
      value: JSON.stringify({
        last_request_at: "2026-05-26T11:00:00.000Z",
        last_review_at: "2026-05-26T11:30:00.000Z",
        recent_request_count: 0
      })
    });
    const { deps: injected } = deps({
      githubResponses: [
        new Response("{}", { status: 404 }),
        new Response("{}", { status: 404 })
      ]
    });
    injected.now = () => new Date("2026-05-26T12:00:00.000Z");

    const response = await handleRequest(
      quotaGet("octo-org"),
      { ...env, COPILOT_QUOTA_KV: kv },
      injected
    );

    const body = await readJson(response);
    expect(body.rate_limited).toBe(false);
    expect(body.source).toBe("default");
  });

  it("doesn't fire the webhook signal when request is newer than the configured gap", async () => {
    const { kv, store } = makeKv();
    store.set("copilot-quota:webhook:octo-org", {
      value: JSON.stringify({
        last_request_at: "2026-05-26T11:50:00.000Z",
        last_review_at: "2026-05-26T10:00:00.000Z",
        recent_request_count: 1
      })
    });
    const { deps: injected } = deps({
      githubResponses: [
        new Response("{}", { status: 404 }),
        new Response("{}", { status: 404 })
      ]
    });
    injected.now = () => new Date("2026-05-26T12:00:00.000Z");

    const response = await handleRequest(
      quotaGet("octo-org"),
      { ...env, COPILOT_QUOTA_KV: kv },
      injected
    );

    const body = await readJson(response);
    // request was 10 min ago, less than the 30 min default gap
    expect(body.rate_limited).toBe(false);
  });
});

describe("copilot-quota Copilot Metrics API fallback", () => {
  it("flags rate-limited when Copilot activity dropped from non-zero to zero", async () => {
    const { deps: injected } = deps({
      githubResponses: [
        // Billing chain
        Response.json({ id: 99 }),                                            // org install
        Response.json({ token: "ghs_x", expires_at: "2026-05-26T13:00:00Z" }),// install token
        Response.json({ usageItems: [] }),                                    // org billing (no copilot data)
        // Metrics chain
        Response.json({ id: 99 }),                                            // org install (re-mint installation lookup)
        Response.json({ token: "ghs_x", expires_at: "2026-05-26T13:00:00Z" }),
        Response.json([
          { date: "2026-05-24", total_engaged_users: 10 },
          { date: "2026-05-25", total_engaged_users: 0 }
        ])
      ]
    });

    const response = await handleRequest(
      quotaGet("octo-org"),
      env,
      injected
    );

    expect(response.status).toBe(200);
    const body = await readJson(response);
    expect(body.rate_limited).toBe(true);
    expect(body.source).toBe("github-copilot-metrics");
  });

  it("doesn't fire metrics signal when latest day still shows activity", async () => {
    const { deps: injected } = deps({
      githubResponses: [
        Response.json({ id: 99 }),
        Response.json({ token: "ghs_x", expires_at: "2026-05-26T13:00:00Z" }),
        Response.json({ usageItems: [] }),
        Response.json({ id: 99 }),
        Response.json({ token: "ghs_x", expires_at: "2026-05-26T13:00:00Z" }),
        Response.json([
          { date: "2026-05-24", total_engaged_users: 10 },
          { date: "2026-05-25", total_engaged_users: 8 }
        ])
      ]
    });

    const response = await handleRequest(
      quotaGet("octo-org"),
      env,
      injected
    );

    const body = await readJson(response);
    expect(body.rate_limited).toBe(false);
  });
});

describe("scheduled cron refresh", () => {
  it("does nothing when KV is unbound", async () => {
    // No throw, no fetch calls.
    await expect(
      handleScheduledRefresh(env, {
        verifyOidcToken: async () => ({ repository: "octo-org/octo-repo" }),
        createGitHubAppJwt: async () => "app.jwt",
        fetch: async () => {
          throw new Error("should not be called");
        },
        now: () => new Date("2026-05-26T12:00:00.000Z")
      })
    ).resolves.toBeUndefined();
  });

  it("refreshes billing cache for owners present in KV", async () => {
    const { kv, store } = makeKv();
    // Seed a webhook record so the cron has something to iterate.
    store.set("copilot-quota:webhook:octo-org", {
      value: JSON.stringify({
        last_request_at: "2026-05-26T11:00:00.000Z"
      })
    });

    const fetchCalls: string[] = [];
    await handleScheduledRefresh(
      { ...env, COPILOT_QUOTA_KV: kv },
      {
        verifyOidcToken: async () => ({ repository: "octo-org/octo-repo" }),
        createGitHubAppJwt: async () => "app.jwt",
        fetch: async (input: RequestInfo | URL) => {
          const url = typeof input === "string" ? input : input.toString();
          fetchCalls.push(url);
          if (url.includes("/orgs/octo-org/installation")) {
            return Response.json({ id: 88 });
          }
          if (url.includes("/access_tokens")) {
            return Response.json({
              token: "ghs_y",
              expires_at: "2026-05-26T13:00:00Z"
            });
          }
          if (url.includes("/orgs/octo-org/settings/billing/usage")) {
            return Response.json({
              usageItems: [
                {
                  product: "Copilot",
                  sku: "Copilot Premium Requests",
                  remaining: 0,
                  includedQuantity: 500,
                  quantity: 500
                }
              ]
            });
          }
          return new Response("{}", { status: 404 });
        },
        now: () => new Date("2026-05-26T12:00:00.000Z")
      }
    );

    expect(fetchCalls.some((u) => u.includes("billing/usage"))).toBe(true);
    expect(store.has("copilot-quota:billing:octo-org")).toBe(true);
    const cached = JSON.parse(
      store.get("copilot-quota:billing:octo-org")!.value
    );
    expect(cached.rate_limited).toBe(true);
  });
});

// ─── Copilot comment triage (pull_request_review_comment) ────────────────────

function reviewCommentRequest(
  body: Record<string, unknown>,
  sig: string
): Request {
  return new Request("https://broker.example.com/webhook", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-github-event": "pull_request_review_comment",
      "x-hub-signature-256": sig
    },
    body: JSON.stringify(body)
  });
}

const triageEnv: BrokerEnv = {
  ...env,
  GITHUB_WEBHOOK_SECRET: "shh",
  TRIAGE_LLM_API_KEY: "sk-test",
  TRIAGE_LLM_PROVIDER: "anthropic"
};

function reviewCommentPayload(
  overrides: Record<string, unknown> = {},
  commentOverrides: Record<string, unknown> = {}
): Record<string, unknown> {
  return {
    action: "created",
    repository: { name: "octo-repo", owner: { login: "octo-org" } },
    pull_request: { number: 7 },
    comment: {
      id: 12345,
      user: { login: "copilot-pull-request-reviewer[bot]" },
      body: "This variable is never used.",
      path: "src/x.ts",
      diff_hunk: "@@ -1 +1 @@",
      ...commentOverrides
    },
    ...overrides
  };
}

function anthropicReply(decision: string): Response {
  return Response.json({
    content: [{ type: "text", text: `{"decision":"${decision}"}` }]
  });
}

describe("Copilot comment triage", () => {
  it("is disabled when no LLM key is configured", async () => {
    const payload = reviewCommentPayload();
    const body = JSON.stringify(payload);
    const sig = await hmac("shh", body);
    const { deps: injected } = deps();
    injected.fetch = async () => {
      throw new Error("should not call any API when triage is disabled");
    };
    const response = await handleRequest(
      reviewCommentRequest(payload, sig),
      { ...env, GITHUB_WEBHOOK_SECRET: "shh" },
      injected
    );
    expect(response.status).toBe(200);
    expect(await readJson(response)).toEqual({ ok: true, triage: "disabled" });
  });

  it("ignores comments not authored by Copilot", async () => {
    const payload = reviewCommentPayload({}, { user: { login: "a-human" } });
    const body = JSON.stringify(payload);
    const sig = await hmac("shh", body);
    const { deps: injected } = deps();
    injected.fetch = async () => {
      throw new Error("should not classify non-Copilot comments");
    };
    const response = await handleRequest(
      reviewCommentRequest(payload, sig),
      triageEnv,
      injected
    );
    expect(await readJson(response)).toEqual({ ok: true, not_copilot: true });
  });

  it("classifies a Copilot comment and dismisses it by resolving the thread", async () => {
    const { calls, deps: injected } = deps({
      githubResponses: [
        anthropicReply("dismiss"), // classification
        Response.json({ id: 42 }), // installation lookup
        Response.json({ token: "ghs_x", expires_at: "2026-05-03T13:00:00Z" }),
        Response.json({
          data: {
            repository: {
              pullRequest: {
                reviewThreads: {
                  nodes: [
                    {
                      id: "THREAD_1",
                      isResolved: false,
                      comments: { nodes: [{ databaseId: 12345 }] }
                    }
                  ]
                }
              }
            }
          }
        }), // graphql: review threads
        Response.json({
          data: { resolveReviewThread: { thread: { isResolved: true } } }
        }) // graphql: resolve mutation
      ]
    });
    const payload = reviewCommentPayload();
    const body = JSON.stringify(payload);
    const sig = await hmac("shh", body);
    const response = await handleRequest(
      reviewCommentRequest(payload, sig),
      triageEnv,
      injected
    );

    expect(response.status).toBe(200);
    expect(await readJson(response)).toEqual({
      ok: true,
      decision: "dismiss",
      dismissed: true
    });
    expect(calls[0].url).toContain("api.anthropic.com");
    expect(calls[3].url).toContain("/graphql");
    expect(calls[4].url).toContain("/graphql");
  });

  it("treats skip as a no-op (classification only, no GitHub calls)", async () => {
    const { calls, deps: injected } = deps({
      githubResponses: [anthropicReply("skip")]
    });
    const payload = reviewCommentPayload();
    const body = JSON.stringify(payload);
    const sig = await hmac("shh", body);
    const response = await handleRequest(
      reviewCommentRequest(payload, sig),
      triageEnv,
      injected
    );
    expect(await readJson(response)).toEqual({
      ok: true,
      decision: "skip",
      action: "none"
    });
    expect(calls.length).toBe(1);
  });

  it("recognises fix but defers it (no signing path yet)", async () => {
    const { deps: injected } = deps({
      githubResponses: [anthropicReply("fix")]
    });
    const payload = reviewCommentPayload();
    const body = JSON.stringify(payload);
    const sig = await hmac("shh", body);
    const response = await handleRequest(
      reviewCommentRequest(payload, sig),
      triageEnv,
      injected
    );
    expect(await readJson(response)).toEqual({
      ok: true,
      decision: "fix",
      action: "deferred"
    });
  });

  it("routes OpenAI-compatible providers (DeepSeek) to /chat/completions", async () => {
    const { calls, deps: injected } = deps({
      githubResponses: [
        Response.json({
          choices: [{ message: { content: '{"decision":"skip"}' } }]
        })
      ]
    });
    const payload = reviewCommentPayload();
    const body = JSON.stringify(payload);
    const sig = await hmac("shh", body);
    const response = await handleRequest(
      reviewCommentRequest(payload, sig),
      {
        ...triageEnv,
        TRIAGE_LLM_PROVIDER: "deepseek",
        TRIAGE_LLM_MODEL: "deepseek-chat"
      },
      injected
    );
    expect(await readJson(response)).toEqual({
      ok: true,
      decision: "skip",
      action: "none"
    });
    expect(calls[0].url).toContain("api.deepseek.com");
    expect(calls[0].url).toContain("/chat/completions");
  });
});
// ─── /copilot-oauth ──────────────────────────────────────────────────────────

describe("copilot-oauth flow", () => {
  it("connect returns 503 when client_id is not configured", async () => {
    const response = await handleRequest(
      new Request("https://broker.example.com/copilot-oauth/connect", { method: "GET" }),
      env
    );
    expect(response.status).toBe(503);
    expect(await readJson(response)).toEqual({ error: "oauth_disabled" });
  });

  it("connect 302s to github.com with a CSRF state", async () => {
    const { kv, store } = makeKv();
    const response = await handleRequest(
      new Request("https://broker.example.com/copilot-oauth/connect", { method: "GET" }),
      {
        ...env,
        COPILOT_QUOTA_KV: kv,
        GITHUB_APP_CLIENT_ID: "Iv23test"
      }
    );
    expect(response.status).toBe(302);
    const loc = response.headers.get("Location") ?? "";
    expect(loc.startsWith("https://github.com/login/oauth/authorize")).toBe(true);
    expect(loc).toContain("client_id=Iv23test");
    expect(loc).toContain("state=");
    expect(loc).toContain("redirect_uri=https%3A%2F%2Fbroker.example.com%2Fcopilot-oauth%2Fcallback");

    // state should be stashed in KV with the matching value
    const stateMatch = loc.match(/state=([a-f0-9]+)/);
    expect(stateMatch).toBeTruthy();
    expect(store.has(`copilot-oauth:state:${stateMatch![1]}`)).toBe(true);
  });

  it("callback exchanges code for tokens and stores refresh_token in KV", async () => {
    const { kv, store } = makeKv();
    const state = "fakestate1234";
    store.set(`copilot-oauth:state:${state}`, {
      value: JSON.stringify({ created_at: "2026-05-27T10:00:00.000Z" })
    });

    const { deps: injected } = deps({
      githubResponses: [
        // POST /login/oauth/access_token
        Response.json({
          access_token: "ghu_initial",
          refresh_token: "ghr_initial",
          expires_in: 28800,
          refresh_token_expires_in: 15897600
        }),
        // GET /user
        Response.json({ login: "calebsargeant", id: 4991715 })
      ]
    });

    const response = await handleRequest(
      new Request(
        `https://broker.example.com/copilot-oauth/callback?code=abc123&state=${state}`,
        { method: "GET" }
      ),
      {
        ...env,
        COPILOT_QUOTA_KV: kv,
        GITHUB_APP_CLIENT_ID: "Iv23test",
        GITHUB_APP_CLIENT_SECRET: "test_secret"
      },
      injected
    );

    expect(response.status).toBe(200);
    expect(response.headers.get("content-type")).toContain("text/html");
    const body = await response.text();
    expect(body).toContain("calebsargeant");

    // State should be burned
    expect(store.has(`copilot-oauth:state:${state}`)).toBe(false);

    // User record persisted
    const stored = store.get("copilot-oauth:user:calebsargeant");
    expect(stored).toBeDefined();
    const parsed = JSON.parse(stored!.value);
    expect(parsed.refresh_token).toBe("ghr_initial");
    expect(parsed.access_token).toBe("ghu_initial");
    expect(parsed.connected_at).toBeDefined();
  });

  it("callback rejects unknown state (CSRF protection)", async () => {
    const { kv } = makeKv();
    const response = await handleRequest(
      new Request(
        "https://broker.example.com/copilot-oauth/callback?code=abc&state=unknown",
        { method: "GET" }
      ),
      {
        ...env,
        COPILOT_QUOTA_KV: kv,
        GITHUB_APP_CLIENT_ID: "Iv23test",
        GITHUB_APP_CLIENT_SECRET: "test_secret"
      }
    );
    expect(response.status).toBe(400);
    expect(await response.text()).toContain("Authorization expired");
  });

  it("callback surfaces GitHub's error param without exchanging tokens", async () => {
    const response = await handleRequest(
      new Request(
        "https://broker.example.com/copilot-oauth/callback?error=access_denied",
        { method: "GET" }
      ),
      {
        ...env,
        GITHUB_APP_CLIENT_ID: "Iv23test",
        GITHUB_APP_CLIENT_SECRET: "test_secret"
      }
    );
    expect(response.status).toBe(400);
    expect(await response.text()).toContain("access_denied");
  });

  it("status returns connected:false when KV is empty", async () => {
    const { kv } = makeKv();
    const response = await handleRequest(
      new Request("https://broker.example.com/copilot-oauth/status?user=alice", {
        method: "GET"
      }),
      { ...env, COPILOT_QUOTA_KV: kv }
    );
    expect(response.status).toBe(200);
    const body = await readJson(response);
    expect(body).toEqual({ connected: false, user: "alice" });
  });

  it("status returns connected:true with metadata when refresh token is stored", async () => {
    const { kv, store } = makeKv();
    store.set("copilot-oauth:user:calebsargeant", {
      value: JSON.stringify({
        refresh_token: "ghr_x",
        refresh_token_expires_at: "2026-11-01T00:00:00.000Z",
        connected_at: "2026-05-01T12:00:00.000Z"
      })
    });
    const response = await handleRequest(
      new Request(
        "https://broker.example.com/copilot-oauth/status?user=calebsargeant",
        { method: "GET" }
      ),
      { ...env, COPILOT_QUOTA_KV: kv }
    );
    expect(response.status).toBe(200);
    const body = await readJson(response);
    expect(body).toMatchObject({
      connected: true,
      user: "calebsargeant",
      connected_at: "2026-05-01T12:00:00.000Z",
      refresh_token_expires_at: "2026-11-01T00:00:00.000Z"
    });
  });
});
