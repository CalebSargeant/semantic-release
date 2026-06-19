import { handleRequest, type BrokerEnv } from "../src/index";
import { generateKeyPairSync } from "node:crypto";

const env: BrokerEnv = {
  GITHUB_APP_ID: "12345",
  GITHUB_APP_PRIVATE_KEY: "-----BEGIN PRIVATE KEY-----\\nsecret\\n-----END PRIVATE KEY-----",
  OIDC_AUDIENCE: "diatreme"
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
  iss?: string;
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
          repository: options.repository ?? "octo-org/octo-repo",
          ...(options.iss ? { iss: options.iss } : {})
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

  const GHE_ENV: BrokerEnv = {
    ...env,
    GHE_OIDC_ISSUER: "https://token.actions.acme.ghe.com",
    GHE_API_BASE: "https://acme.ghe.com/api/v3",
    GHE_GITHUB_APP_ID: "99",
    GHE_GITHUB_APP_PRIVATE_KEY:
      "-----BEGIN PRIVATE KEY-----\\nghe\\n-----END PRIVATE KEY-----"
  };

  it("mints a GHE token against the GHE API base when the issuer is the GHE tenant", async () => {
    const { calls, deps: injected } = deps({
      iss: "https://token.actions.acme.ghe.com",
      githubResponses: [
        Response.json({ id: 7 }),
        Response.json({ token: "ghe-token", expires_at: "2026-05-03T13:00:00Z" })
      ]
    });
    const response = await handleRequest(
      tokenRequest({ oidcToken: "valid.jwt", owner: "octo-org", repo: "octo-repo" }),
      GHE_ENV,
      injected
    );

    expect(response.status).toBe(200);
    expect(await readJson(response)).toEqual({
      token: "ghe-token",
      expires_at: "2026-05-03T13:00:00Z",
      repository: "octo-org/octo-repo"
    });
    // Both GitHub calls hit the GHE REST API, never api.github.com.
    expect(calls[0].url).toBe(
      "https://acme.ghe.com/api/v3/repos/octo-org/octo-repo/installation"
    );
    expect(calls[1].url).toBe(
      "https://acme.ghe.com/api/v3/app/installations/7/access_tokens"
    );
  });

  it("skips the GHE installation lookup when GHE_GITHUB_APP_INSTALLATION_ID is set", async () => {
    const { calls, deps: injected } = deps({
      iss: "https://token.actions.acme.ghe.com",
      githubResponses: [
        Response.json({ token: "ghe-token", expires_at: "2026-05-03T13:00:00Z" })
      ]
    });
    const response = await handleRequest(
      tokenRequest({ oidcToken: "valid.jwt", owner: "octo-org", repo: "octo-repo" }),
      { ...GHE_ENV, GHE_GITHUB_APP_INSTALLATION_ID: "555" },
      injected
    );

    expect(response.status).toBe(200);
    // Only the token-create call is made; the per-repo lookup is skipped.
    expect(calls).toHaveLength(1);
    expect(calls[0].url).toBe(
      "https://acme.ghe.com/api/v3/app/installations/555/access_tokens"
    );
  });

  it("still mints via github.com for tokens whose issuer is not the GHE tenant", async () => {
    const { calls, deps: injected } = deps({
      githubResponses: [
        Response.json({ id: 42 }),
        Response.json({ token: "dotcom-token", expires_at: "2026-05-03T13:00:00Z" })
      ]
    });
    const response = await handleRequest(
      tokenRequest({ oidcToken: "valid.jwt", owner: "octo-org", repo: "octo-repo" }),
      GHE_ENV, // GHE configured, but this token carries no GHE issuer
      injected
    );

    expect(response.status).toBe(200);
    expect(calls[0].url).toBe(
      "https://api.github.com/repos/octo-org/octo-repo/installation"
    );
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
    pull_request: {
      number: 7,
      author_association: "OWNER",
      user: { login: "trusted-dev" }
    },
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

  it("treats an unsure/skip reply as a large-effort fix (never a no-op)", async () => {
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
    const out = await readJson(response);
    expect(out.decision).toBe("fix"); // skip ⇒ fix
    expect(out.effort).toBe("large"); // unsure ⇒ large effort
    expect(out.action).toBe("dispatched"); // no agent configured ⇒ Routine/queue
    expect(calls.length).toBe(1); // only the classify call (queued, no fetch)
  });

  it("dispatches an autonomous task when a comment classifies as fix", async () => {
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
    const out = await readJson(response);
    expect(out.decision).toBe("fix");
    expect(out.action).toBe("dispatched");
    expect(typeof out.dispatch_id).toBe("string");
  });

  it("routes a fix to the Agent SDK dispatcher when DISPATCH_AGENT_URL is set", async () => {
    const { calls, deps: injected } = deps({
      githubResponses: [
        Response.json({
          content: [
            { type: "text", text: '{"decision":"fix","effort":"basic","reason":"null check"}' }
          ]
        }), // classify
        Response.json({ accepted: true }, { status: 202 }) // the agent dispatcher
      ]
    });
    const payload = reviewCommentPayload({
      pull_request: {
        number: 7,
        author_association: "OWNER",
        user: { login: "trusted-dev" },
        head: { ref: "feature-branch" }
      }
    });
    const body = JSON.stringify(payload);
    const sig = await hmac("shh", body);
    const response = await handleRequest(
      reviewCommentRequest(payload, sig),
      {
        ...triageEnv,
        DISPATCH_AGENT_URL: "https://diatreme.example/api/dispatch",
        DISPATCH_AGENT_TOKEN: "agent-secret",
        DISPATCH_AGENT_CF_ACCESS_CLIENT_ID: "cf-id",
        DISPATCH_AGENT_CF_ACCESS_CLIENT_SECRET: "cf-secret"
      },
      injected
    );
    expect(await readJson(response)).toMatchObject({
      ok: true,
      decision: "fix",
      effort: "basic",
      action: "agent",
      status: "agent_accepted"
    });
    // POST to the agent with the bearer + CF Access service token + structured body.
    const agentCall = calls[1];
    expect(agentCall.url).toBe("https://diatreme.example/api/dispatch");
    expect(agentCall.headers.get("authorization")).toBe("Bearer agent-secret");
    expect(agentCall.headers.get("cf-access-client-id")).toBe("cf-id");
    expect(agentCall.headers.get("cf-access-client-secret")).toBe("cf-secret");
    expect((await agentCall.json()) as Record<string, unknown>).toMatchObject({
      repo: "octo-org/octo-repo",
      branch: "feature-branch",
      pr: 7,
      effort: "basic",
      file: "src/x.ts"
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
    const out = await readJson(response);
    expect(out.decision).toBe("fix"); // skip ⇒ fix (never a no-op)
    expect(out.action).toBe("dispatched");
    expect(calls[0].url).toContain("api.deepseek.com");
    expect(calls[0].url).toContain("/chat/completions");
  });

  it("skips PRs from untrusted authors", async () => {
    const payload = reviewCommentPayload({
      pull_request: {
        number: 7,
        author_association: "NONE",
        user: { login: "random-person" }
      }
    });
    const body = JSON.stringify(payload);
    const sig = await hmac("shh", body);
    const { deps: injected } = deps();
    injected.fetch = async () => {
      throw new Error("should not classify an untrusted author's PR");
    };
    const response = await handleRequest(
      reviewCommentRequest(payload, sig),
      triageEnv,
      injected
    );
    expect(await readJson(response)).toEqual({
      ok: true,
      skipped: "untrusted_author"
    });
  });

  it("allows an untrusted association when the author is on TRIAGE_TRUSTED_USERS", async () => {
    const payload = reviewCommentPayload({
      pull_request: {
        number: 7,
        author_association: "NONE",
        user: { login: "trusted-contractor" }
      }
    });
    const body = JSON.stringify(payload);
    const sig = await hmac("shh", body);
    const { deps: injected } = deps({
      githubResponses: [anthropicReply("skip")]
    });
    const response = await handleRequest(
      reviewCommentRequest(payload, sig),
      { ...triageEnv, TRIAGE_TRUSTED_USERS: "trusted-contractor" },
      injected
    );
    const out = await readJson(response);
    expect(out.decision).toBe("fix"); // trusted gate passed → classified (skip ⇒ fix)
    expect(out.action).toBe("dispatched");
  });
});
// ─── /oauth ──────────────────────────────────────────────────────────

describe("copilot-oauth flow", () => {
  it("connect returns 503 when client_id is not configured", async () => {
    const response = await handleRequest(
      new Request("https://broker.example.com/oauth/connect", { method: "GET" }),
      env
    );
    expect(response.status).toBe(503);
    expect(await readJson(response)).toEqual({ error: "oauth_disabled" });
  });

  it("connect 302s to github.com with a CSRF state", async () => {
    const { kv, store } = makeKv();
    const response = await handleRequest(
      new Request("https://broker.example.com/oauth/connect", { method: "GET" }),
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
    expect(loc).toContain("redirect_uri=https%3A%2F%2Fbroker.example.com%2Foauth%2Fcallback");

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
        `https://broker.example.com/oauth/callback?code=abc123&state=${state}`,
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
        "https://broker.example.com/oauth/callback?code=abc&state=unknown",
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
        "https://broker.example.com/oauth/callback?error=access_denied",
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
      new Request("https://broker.example.com/oauth/status?user=alice", {
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
        "https://broker.example.com/oauth/status?user=calebsargeant",
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

// ─── POST /process (manual PR re-walk) ───────────────────────────────────────

function processRequest(
  body: Record<string, unknown>,
  headers: Record<string, string> = {}
): Request {
  return new Request("https://broker.example.com/process", {
    method: "POST",
    headers: { "content-type": "application/json", ...headers },
    body: JSON.stringify(body)
  });
}

const PR_URL = "https://github.com/octo-org/octo-repo/pull/7";

describe("POST /process", () => {
  it("is disabled (503) when PROCESS_TRIGGER_SECRET is unset", async () => {
    const response = await handleRequest(processRequest({ pr_url: PR_URL }), env);
    expect(response.status).toBe(503);
    expect(await readJson(response)).toEqual({ error: "process_disabled" });
  });

  it("rejects a wrong bearer with 401", async () => {
    const response = await handleRequest(
      processRequest({ pr_url: PR_URL }, { authorization: "Bearer nope" }),
      { ...env, PROCESS_TRIGGER_SECRET: "trigger" }
    );
    expect(response.status).toBe(401);
    expect(await readJson(response)).toEqual({ error: "unauthorized" });
  });

  it("returns 400 when neither pr_url nor owner/repo/pull_number is given", async () => {
    const response = await handleRequest(
      processRequest({}, { authorization: "Bearer trigger" }),
      { ...env, PROCESS_TRIGGER_SECRET: "trigger" }
    );
    expect(response.status).toBe(400);
    expect(await readJson(response)).toEqual({ error: "missing_required_fields" });
  });

  it("reports triage disabled when no LLM key is configured", async () => {
    const response = await handleRequest(
      processRequest({ pr_url: PR_URL }, { authorization: "Bearer trigger" }),
      { ...env, PROCESS_TRIGGER_SECRET: "trigger" }
    );
    expect(response.status).toBe(200);
    expect(await readJson(response)).toEqual({ ok: true, triage: "disabled" });
  });

  it("walks the PR's Copilot comments, dismissing and skipping, ignoring humans", async () => {
    const processEnv: BrokerEnv = {
      ...env,
      PROCESS_TRIGGER_SECRET: "trigger",
      TRIAGE_LLM_API_KEY: "sk-test",
      TRIAGE_LLM_PROVIDER: "anthropic"
    };
    const { deps: injected } = deps({
      githubResponses: [
        Response.json({ id: 42 }), // installation lookup
        Response.json({ token: "ghs_x", expires_at: "2026-05-03T13:00:00Z" }),
        Response.json([
          {
            id: 111,
            user: { login: "copilot-pull-request-reviewer[bot]" },
            body: "unused variable",
            path: "a.ts",
            diff_hunk: "@@"
          },
          { id: 222, user: { login: "a-human" }, body: "nit" },
          {
            id: 333,
            user: { login: "copilot-pull-request-reviewer[bot]" },
            body: "is this right?"
          }
        ]), // list review comments
        anthropicReply("dismiss"), // classify #111
        Response.json({
          data: {
            repository: {
              pullRequest: {
                reviewThreads: {
                  nodes: [
                    {
                      id: "T1",
                      isResolved: false,
                      comments: { nodes: [{ databaseId: 111 }] }
                    }
                  ]
                }
              }
            }
          }
        }), // graphql query
        Response.json({
          data: { resolveReviewThread: { thread: { isResolved: true } } }
        }), // graphql mutation
        anthropicReply("skip") // classify #333
      ]
    });

    const response = await handleRequest(
      processRequest({ pr_url: PR_URL }, { authorization: "Bearer trigger" }),
      processEnv,
      injected
    );

    expect(response.status).toBe(200);
    expect(await readJson(response)).toEqual({
      ok: true,
      pull: 7,
      processed: 2,
      counts: { fix: 1, dismiss: 1 },
      results: [
        { comment_id: 111, decision: "dismiss", dismissed: true },
        { comment_id: 333, decision: "fix", effort: "large", dispatch: "queued_no_kv" }
      ]
    });
  });

  it("dispatches a fix for a 'fix' decision (comment-commander parity)", async () => {
    const processEnv: BrokerEnv = {
      ...env,
      PROCESS_TRIGGER_SECRET: "trigger",
      TRIAGE_LLM_API_KEY: "sk-test",
      TRIAGE_LLM_PROVIDER: "anthropic"
    };
    const { calls, deps: injected } = deps({
      githubResponses: [
        Response.json({ id: 42 }), // installation lookup
        Response.json({ token: "ghs_x", expires_at: "2026-05-03T13:00:00Z" }),
        Response.json([
          {
            id: 111,
            user: { login: "copilot-pull-request-reviewer[bot]" },
            body: "this leaks a handle",
            path: "a.ts",
            diff_hunk: "@@"
          }
        ]), // list review comments
        anthropicReply("fix") // classify #111
      ]
    });

    const response = await handleRequest(
      processRequest({ pr_url: PR_URL }, { authorization: "Bearer trigger" }),
      processEnv,
      injected
    );

    expect(response.status).toBe(200);
    expect(await readJson(response)).toEqual({
      ok: true,
      pull: 7,
      processed: 1,
      counts: { fix: 1, dismiss: 0 },
      // No agent / DISPATCH_TRIGGER_URL / KV, so the fix is queued only.
      results: [{ comment_id: 111, decision: "fix", effort: "large", dispatch: "queued_no_kv" }]
    });
    // install + token + list-comments + classify = 4. Dispatch was queued, not
    // fired (no trigger URL), so it added no 5th HTTP call.
    expect(calls).toHaveLength(4);
  });

  const GHE_PROCESS_ENV: BrokerEnv = {
    ...env,
    PROCESS_TRIGGER_SECRET: "trigger",
    TRIAGE_LLM_API_KEY: "sk-test",
    TRIAGE_LLM_PROVIDER: "anthropic",
    GHE_API_BASE: "https://acme.ghe.com/api/v3",
    GHE_GITHUB_APP_ID: "99",
    GHE_GITHUB_APP_PRIVATE_KEY:
      "-----BEGIN PRIVATE KEY-----\\nghe\\n-----END PRIVATE KEY-----"
  };

  const GHE_PR_URL = "https://acme.ghe.com/octo-org/octo-repo/pull/7";

  it("routes a GHE PR's token, REST and GraphQL calls to the GHE host", async () => {
    const { calls, deps: injected } = deps({
      githubResponses: [
        Response.json({ id: 7 }), // GHE installation lookup
        Response.json({ token: "ghs_ghe", expires_at: "2026-05-03T13:00:00Z" }),
        Response.json([
          {
            id: 111,
            user: { login: "copilot-pull-request-reviewer[bot]" },
            body: "unused variable",
            path: "a.ts",
            diff_hunk: "@@"
          }
        ]), // list review comments
        anthropicReply("dismiss"), // classify #111
        Response.json({
          data: {
            repository: {
              pullRequest: {
                reviewThreads: {
                  nodes: [
                    {
                      id: "T1",
                      isResolved: false,
                      comments: { nodes: [{ databaseId: 111 }] }
                    }
                  ]
                }
              }
            }
          }
        }), // graphql query
        Response.json({
          data: { resolveReviewThread: { thread: { isResolved: true } } }
        }) // graphql mutation
      ]
    });

    const response = await handleRequest(
      processRequest({ pr_url: GHE_PR_URL }, { authorization: "Bearer trigger" }),
      GHE_PROCESS_ENV,
      injected
    );

    expect(response.status).toBe(200);
    expect(await readJson(response)).toEqual({
      ok: true,
      pull: 7,
      processed: 1,
      counts: { fix: 0, dismiss: 1 },
      results: [{ comment_id: 111, decision: "dismiss", dismissed: true }]
    });

    // Every GitHub call hits the GHE tenant — never api.github.com.
    expect(calls[0].url).toBe(
      "https://acme.ghe.com/api/v3/repos/octo-org/octo-repo/installation"
    );
    expect(calls[1].url).toBe(
      "https://acme.ghe.com/api/v3/app/installations/7/access_tokens"
    );
    expect(calls[2].url).toBe(
      "https://acme.ghe.com/api/v3/repos/octo-org/octo-repo/pulls/7/comments?per_page=100"
    );
    expect(calls[4].url).toBe("https://acme.ghe.com/api/graphql");
    expect(calls[5].url).toBe("https://acme.ghe.com/api/graphql");
    // Parse the host for an exact compare — a substring check would match
    // arbitrary URLs that merely contain "api.github.com" (CodeQL: incomplete
    // URL substring sanitization).
    expect(calls.some((c) => new URL(c.url).host === "api.github.com")).toBe(
      false
    );
  });

  it("routes a GHE PR with data-residency API base (api.<tenant>.ghe.com)", async () => {
    const { calls, deps: injected } = deps({
      githubResponses: [
        Response.json({ id: 7 }),
        Response.json({ token: "ghs_ghe", expires_at: "2026-05-03T13:00:00Z" }),
        Response.json([
          {
            id: 111,
            user: { login: "copilot-pull-request-reviewer[bot]" },
            body: "unused variable",
            path: "a.ts",
            diff_hunk: "@@"
          }
        ]),
        anthropicReply("dismiss"),
        Response.json({
          data: {
            repository: {
              pullRequest: {
                reviewThreads: {
                  nodes: [
                    {
                      id: "T1",
                      isResolved: false,
                      comments: { nodes: [{ databaseId: 111 }] }
                    }
                  ]
                }
              }
            }
          }
        }),
        Response.json({
          data: { resolveReviewThread: { thread: { isResolved: true } } }
        })
      ]
    });

    const gheApiBaseDataResidency: BrokerEnv = {
      ...GHE_PROCESS_ENV,
      GHE_API_BASE: "https://api.acme.ghe.com"
    };

    const response = await handleRequest(
      processRequest({ pr_url: GHE_PR_URL }, { authorization: "Bearer trigger" }),
      gheApiBaseDataResidency,
      injected
    );

    expect(response.status).toBe(200);
    expect(await readJson(response)).toEqual({
      ok: true,
      pull: 7,
      processed: 1,
      counts: { fix: 0, dismiss: 1 },
      results: [{ comment_id: 111, decision: "dismiss", dismissed: true }]
    });

    // REST calls hit api.acme.ghe.com, GraphQL also.
    expect(calls[0].url).toBe(
      "https://api.acme.ghe.com/repos/octo-org/octo-repo/installation"
    );
    expect(calls[1].url).toBe(
      "https://api.acme.ghe.com/app/installations/7/access_tokens"
    );
    expect(calls[2].url).toBe(
      "https://api.acme.ghe.com/repos/octo-org/octo-repo/pulls/7/comments?per_page=100"
    );
    expect(calls[4].url).toBe("https://api.acme.ghe.com/graphql");
    expect(calls[5].url).toBe("https://api.acme.ghe.com/graphql");
    // Ensure no github.com calls.
    expect(calls.some((c) => new URL(c.url).host === "api.github.com")).toBe(
      false
    );
  });

  it("skips the GHE installation lookup when GHE_GITHUB_APP_INSTALLATION_ID is set", async () => {
    const { calls, deps: injected } = deps({
      githubResponses: [
        Response.json({ token: "ghs_ghe", expires_at: "2026-05-03T13:00:00Z" }),
        Response.json([]) // no comments
      ]
    });

    const response = await handleRequest(
      processRequest({ pr_url: GHE_PR_URL }, { authorization: "Bearer trigger" }),
      { ...GHE_PROCESS_ENV, GHE_GITHUB_APP_INSTALLATION_ID: "555" },
      injected
    );

    expect(response.status).toBe(200);
    // First call is the token-create against the fixed installation; no lookup.
    expect(calls[0].url).toBe(
      "https://acme.ghe.com/api/v3/app/installations/555/access_tokens"
    );
  });

  it("rejects an unrecognized host with 400 invalid_pr_url", async () => {
    const response = await handleRequest(
      processRequest(
        { pr_url: "https://evil.example.com/octo-org/octo-repo/pull/7" },
        { authorization: "Bearer trigger" }
      ),
      GHE_PROCESS_ENV,
      deps().deps
    );

    expect(response.status).toBe(400);
    expect(await readJson(response)).toEqual({ error: "invalid_pr_url" });
  });

  it("rejects a GHE host when GHE is not configured on the worker", async () => {
    const response = await handleRequest(
      processRequest(
        { pr_url: GHE_PR_URL },
        { authorization: "Bearer trigger" }
      ),
      {
        ...env,
        PROCESS_TRIGGER_SECRET: "trigger",
        TRIAGE_LLM_API_KEY: "sk-test",
        TRIAGE_LLM_PROVIDER: "anthropic"
      },
      deps().deps
    );

    expect(response.status).toBe(400);
    expect(await readJson(response)).toEqual({ error: "invalid_pr_url" });
  });

  // ─── GitHub Advanced Security (code scanning) triage ───────────────────────

  const CS_ENV: BrokerEnv = {
    ...env,
    PROCESS_TRIGGER_SECRET: "trigger",
    TRIAGE_LLM_API_KEY: "sk-test",
    TRIAGE_LLM_PROVIDER: "anthropic",
    TRIAGE_CODE_SCANNING: "true"
  };

  it("triages code-scanning alerts (dismiss / fix / skip) when enabled", async () => {
    const { calls, deps: injected } = deps({
      githubResponses: [
        Response.json({ id: 42 }), // main installation lookup
        Response.json({ token: "ghs_main", expires_at: "2026-05-03T13:00:00Z" }),
        Response.json([]), // listReviewComments — no Copilot comments
        Response.json({ id: 42 }), // GHAS installation lookup
        Response.json({ token: "ghs_sec", expires_at: "2026-05-03T13:00:00Z" }),
        Response.json([
          {
            number: 11,
            state: "open",
            rule: {
              id: "js/incomplete-url-substring-sanitization",
              description: "Incomplete URL substring sanitization",
              security_severity_level: "high"
            },
            most_recent_instance: {
              location: { path: "worker/test/index.test.ts", start_line: 1843 },
              message: { text: "'api.github.com' can be anywhere in the URL" }
            },
            tool: { name: "CodeQL" }
          },
          {
            number: 22,
            state: "open",
            rule: { id: "py/sql-injection", security_severity_level: "critical" },
            most_recent_instance: {
              location: { path: "app.py", start_line: 10 },
              message: { text: "SQL injection" }
            },
            tool: { name: "CodeQL" }
          },
          {
            number: 33,
            state: "open",
            rule: { id: "js/unused-local-variable" },
            most_recent_instance: {
              location: { path: "x.ts", start_line: 2 },
              message: { text: "Unused variable" }
            },
            tool: { name: "CodeQL" }
          }
        ]), // listCodeScanningAlerts
        anthropicReply("dismiss"), // classify alert #11
        Response.json({ number: 11, state: "dismissed" }), // PATCH dismiss #11
        anthropicReply("fix"), // classify alert #22 (dispatch is a no-op here)
        anthropicReply("skip") // classify alert #33
      ]
    });

    const response = await handleRequest(
      processRequest({ pr_url: PR_URL }, { authorization: "Bearer trigger" }),
      CS_ENV,
      injected
    );

    expect(response.status).toBe(200);
    expect(await readJson(response)).toEqual({
      ok: true,
      pull: 7,
      processed: 0,
      counts: { fix: 0, dismiss: 0 },
      results: [],
      alerts: {
        available: true,
        processed: 3,
        counts: { fix: 1, dismiss: 1, skip: 1 },
        results: [
          {
            alert_number: 11,
            rule: "js/incomplete-url-substring-sanitization",
            decision: "dismiss",
            dismissed: true
          },
          {
            alert_number: 22,
            rule: "py/sql-injection",
            decision: "fix",
            dispatch: "queued_no_kv"
          },
          { alert_number: 33, rule: "js/unused-local-variable", decision: "skip" }
        ]
      }
    });

    // The GHAS token requested security_events; the alert was dismissed via PATCH.
    const ghasTokenBody = (await calls[4].json()) as Record<string, unknown>;
    expect(ghasTokenBody.permissions).toEqual({ security_events: "write" });
    expect(calls[5].url).toContain("/code-scanning/alerts?state=open");
    expect(calls[5].url).toContain("ref=refs%2Fpull%2F7%2Fhead");
    expect(calls[7].url).toBe(
      "https://api.github.com/repos/octo-org/octo-repo/code-scanning/alerts/11"
    );
    expect(calls[7].method).toBe("PATCH");
  });

  it("routes a code-scanning fix to the Agent SDK dispatcher when configured", async () => {
    const { calls, deps: injected } = deps({
      githubResponses: [
        Response.json({ id: 42 }), // main installation lookup
        Response.json({ token: "ghs_main", expires_at: "2026-05-03T13:00:00Z" }),
        Response.json([]), // listReviewComments — no Copilot comments
        Response.json({ head: { ref: "feature-branch" } }), // PR head ref (agent configured)
        Response.json({ id: 42 }), // GHAS installation lookup
        Response.json({ token: "ghs_sec", expires_at: "2026-05-03T13:00:00Z" }),
        Response.json([
          {
            number: 22,
            state: "open",
            rule: { id: "py/sql-injection", security_severity_level: "critical" },
            most_recent_instance: {
              location: { path: "app.py", start_line: 10 },
              message: { text: "SQL injection" }
            },
            tool: { name: "CodeQL" }
          }
        ]), // listCodeScanningAlerts
        anthropicReply("fix"), // classify alert #22
        Response.json({ accepted: true }, { status: 202 }) // the agent dispatcher
      ]
    });

    const response = await handleRequest(
      processRequest({ pr_url: PR_URL }, { authorization: "Bearer trigger" }),
      {
        ...CS_ENV,
        DISPATCH_AGENT_URL: "https://diatreme.example/api/dispatch",
        DISPATCH_AGENT_TOKEN: "agent-secret"
      },
      injected
    );

    expect(response.status).toBe(200);
    const body = (await readJson(response)) as Record<string, any>;
    expect(body.alerts.results[0]).toEqual({
      alert_number: 22,
      rule: "py/sql-injection",
      decision: "fix",
      dispatch: "agent_accepted"
    });

    // Handed to the agent — inline (medium effort) on the PR's own branch.
    const agentCall = calls.find((c) => c.url === "https://diatreme.example/api/dispatch");
    expect(agentCall).toBeDefined();
    expect(agentCall!.headers.get("authorization")).toBe("Bearer agent-secret");
    expect((await agentCall!.json()) as Record<string, unknown>).toMatchObject({
      repo: "octo-org/octo-repo",
      branch: "feature-branch",
      pr: 7,
      file: "app.py",
      reason: "py/sql-injection",
      effort: "medium"
    });
  });

  it("reports code scanning available-but-empty when the API 404s (not enabled)", async () => {
    const { deps: injected } = deps({
      githubResponses: [
        Response.json({ id: 42 }),
        Response.json({ token: "ghs_main", expires_at: "2026-05-03T13:00:00Z" }),
        Response.json([]), // no Copilot comments
        Response.json({ id: 42 }), // GHAS installation lookup
        Response.json({ token: "ghs_sec", expires_at: "2026-05-03T13:00:00Z" }),
        new Response("{}", { status: 404 }) // code scanning not enabled for the ref
      ]
    });
    const response = await handleRequest(
      processRequest({ pr_url: PR_URL }, { authorization: "Bearer trigger" }),
      CS_ENV,
      injected
    );
    expect(response.status).toBe(200);
    const body = await readJson(response);
    expect(body.alerts).toEqual({
      available: true,
      processed: 0,
      counts: { fix: 0, dismiss: 0, skip: 0 },
      results: []
    });
  });

  it("degrades gracefully (available:false) when the App lacks security_events", async () => {
    const { deps: injected } = deps({
      githubResponses: [
        Response.json({ id: 42 }),
        Response.json({ token: "ghs_main", expires_at: "2026-05-03T13:00:00Z" }),
        Response.json([]), // no Copilot comments
        Response.json({ id: 42 }), // GHAS installation lookup
        new Response("{}", { status: 403 }) // token mint denied — App lacks the perm
      ]
    });
    const response = await handleRequest(
      processRequest({ pr_url: PR_URL }, { authorization: "Bearer trigger" }),
      CS_ENV,
      injected
    );
    // The Copilot-comment run still succeeds; GHAS just reports unavailable.
    expect(response.status).toBe(200);
    const body = await readJson(response);
    expect(body.ok).toBe(true);
    expect((body.alerts as Record<string, unknown>).available).toBe(false);
    expect((body.alerts as Record<string, unknown>).error).toBe(
      "github_token_create_failed"
    );
  });
});

// ─── auto-update branches (push webhook) ─────────────────────────────────────

function pushRequest(body: Record<string, unknown>, sig: string): Request {
  return new Request("https://broker.example.com/webhook", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-github-event": "push",
      "x-hub-signature-256": sig
    },
    body: JSON.stringify(body)
  });
}

const pushEnv: BrokerEnv = {
  ...env,
  GITHUB_WEBHOOK_SECRET: "shh",
  AUTO_UPDATE_BRANCHES: "true"
};

const pushPayload = {
  ref: "refs/heads/main",
  repository: { name: "octo-repo", owner: { login: "octo-org" } }
};

describe("auto-update branches (push webhook)", () => {
  it("does nothing when AUTO_UPDATE_BRANCHES is unset", async () => {
    const body = JSON.stringify(pushPayload);
    const sig = await hmac("shh", body);
    const { deps: injected } = deps();
    injected.fetch = async () => {
      throw new Error("should not call GitHub when disabled");
    };
    const response = await handleRequest(
      pushRequest(pushPayload, sig),
      { ...env, GITHUB_WEBHOOK_SECRET: "shh" },
      injected
    );
    expect(response.status).toBe(200);
    expect(await readJson(response)).toEqual({
      ok: true,
      auto_update: "disabled"
    });
  });

  it("ignores tag pushes", async () => {
    const payload = { ...pushPayload, ref: "refs/tags/v1.2.3" };
    const body = JSON.stringify(payload);
    const sig = await hmac("shh", body);
    const { deps: injected } = deps();
    injected.fetch = async () => {
      throw new Error("should not call GitHub for tags");
    };
    const response = await handleRequest(
      pushRequest(payload, sig),
      pushEnv,
      injected
    );
    expect(response.status).toBe(200);
    expect(await readJson(response)).toEqual({
      ok: true,
      ignored_ref: "refs/tags/v1.2.3"
    });
  });

  it("ignores branch deletions", async () => {
    const payload = { ...pushPayload, deleted: true };
    const body = JSON.stringify(payload);
    const sig = await hmac("shh", body);
    const { deps: injected } = deps();
    injected.fetch = async () => {
      throw new Error("should not call GitHub on delete");
    };
    const response = await handleRequest(
      pushRequest(payload, sig),
      pushEnv,
      injected
    );
    expect(await readJson(response)).toEqual({ ok: true, branch_deleted: true });
  });

  it("updates every open PR targeting the pushed branch", async () => {
    const { calls, deps: injected } = deps({
      githubResponses: [
        Response.json({ id: 42 }), // installation lookup
        Response.json({ token: "ghs_x", expires_at: "2026-05-03T13:00:00Z" }),
        Response.json([{ number: 1 }, { number: 2 }]), // open PRs
        new Response("{}", { status: 202 }), // update PR #1
        new Response("{}", { status: 202 }) // update PR #2
      ]
    });
    const body = JSON.stringify(pushPayload);
    const sig = await hmac("shh", body);
    const response = await handleRequest(
      pushRequest(pushPayload, sig),
      pushEnv,
      injected
    );

    expect(response.status).toBe(200);
    expect(await readJson(response)).toEqual({
      ok: true,
      branch: "main",
      updated: [1, 2],
      skipped: []
    });

    // PR list query targets the pushed base branch.
    expect(calls[2].url).toContain("state=open");
    expect(calls[2].url).toContain("base=main");
    // update-branch PUT per PR.
    expect(calls[3].method).toBe("PUT");
    expect(calls[3].url).toContain("/pulls/1/update-branch");
    expect(calls[4].url).toContain("/pulls/2/update-branch");
  });

  it("records PRs that can't be fast-forwarded as skipped", async () => {
    const { deps: injected } = deps({
      githubResponses: [
        Response.json({ id: 42 }),
        Response.json({ token: "ghs_x", expires_at: "2026-05-03T13:00:00Z" }),
        Response.json([{ number: 5 }]),
        new Response('{"message":"merge conflict"}', { status: 422 })
      ]
    });
    const body = JSON.stringify(pushPayload);
    const sig = await hmac("shh", body);
    const response = await handleRequest(
      pushRequest(pushPayload, sig),
      pushEnv,
      injected
    );

    expect(await readJson(response)).toEqual({
      ok: true,
      branch: "main",
      updated: [],
      skipped: [{ number: 5, reason: "not_updatable" }]
    });
  });

  it("acknowledges (200) with an error code when the app is not installed", async () => {
    const { deps: injected } = deps({
      githubResponses: [new Response("{}", { status: 404 })]
    });
    const body = JSON.stringify(pushPayload);
    const sig = await hmac("shh", body);
    const response = await handleRequest(
      pushRequest(pushPayload, sig),
      pushEnv,
      injected
    );

    expect(response.status).toBe(200);
    expect(await readJson(response)).toEqual({
      ok: true,
      branch: "main",
      error: "app_not_installed"
    });
  });
});

// ─── GET /releases ───────────────────────────────────────────────────────────

function releasesRequest(headers: Record<string, string> = {}): Request {
  return new Request("https://broker.example.com/releases", {
    method: "GET",
    headers
  });
}

describe("GET /releases", () => {
  it("is disabled (503) when PROCESS_TRIGGER_SECRET is unset", async () => {
    const response = await handleRequest(releasesRequest(), env);
    expect(response.status).toBe(503);
    expect(await readJson(response)).toEqual({ error: "releases_disabled" });
  });

  it("rejects a wrong bearer with 401", async () => {
    const response = await handleRequest(
      releasesRequest({ authorization: "Bearer nope" }),
      { ...env, PROCESS_TRIGGER_SECRET: "trigger" }
    );
    expect(response.status).toBe(401);
    expect(await readJson(response)).toEqual({ error: "unauthorized" });
  });

  it("aggregates the latest release across the App's installed repos", async () => {
    const { deps: injected } = deps({
      githubResponses: [
        Response.json([{ id: 42 }]), // GET /app/installations
        Response.json({ token: "ghs_x", expires_at: "2026-05-29T13:00:00Z" }), // access_tokens
        Response.json({
          repositories: [
            { full_name: "octo/repo-a" },
            { full_name: "octo/repo-b" }
          ]
        }), // /installation/repositories
        Response.json({
          tag_name: "v1.2.0",
          name: "1.2.0",
          published_at: "2026-05-20T10:00:00Z",
          html_url: "https://github.com/octo/repo-a/releases/tag/v1.2.0",
          draft: false,
          prerelease: false
        }), // repo-a latest
        new Response("{}", { status: 404 }) // repo-b: no releases
      ]
    });

    const response = await handleRequest(
      releasesRequest({ authorization: "Bearer trigger" }),
      { ...env, PROCESS_TRIGGER_SECRET: "trigger" },
      injected
    );

    expect(response.status).toBe(200);
    const body = await readJson(response);
    expect(body.cached).toBe(false);
    expect(body.truncated).toBe(false);
    const repos = body.repos as Array<Record<string, unknown>>;
    expect(repos).toHaveLength(2);
    // repo-a (has a release) sorts ahead of repo-b (none)
    expect(repos[0].repo).toBe("octo/repo-a");
    expect((repos[0].latest as Record<string, unknown>).tag).toBe("v1.2.0");
    expect(repos[1].repo).toBe("octo/repo-b");
    expect(repos[1].latest).toBeNull();
  });

  it("serves a warm KV cache without re-hitting GitHub", async () => {
    const { kv, store } = makeKv();
    store.set("releases:aggregate", {
      value: JSON.stringify({
        generated_at: "2026-05-29T12:00:00Z",
        repos: [{ repo: "octo/cached", latest: null }],
        truncated: false
      })
    });
    const { deps: injected } = deps();
    injected.fetch = async () => {
      throw new Error("should not hit GitHub when cache is warm");
    };

    const response = await handleRequest(
      releasesRequest({ authorization: "Bearer trigger" }),
      { ...env, PROCESS_TRIGGER_SECRET: "trigger", COPILOT_QUOTA_KV: kv },
      injected
    );

    expect(response.status).toBe(200);
    const body = await readJson(response);
    expect(body.cached).toBe(true);
    expect((body.repos as unknown[])[0]).toEqual({ repo: "octo/cached", latest: null });
  });
});

// ─── POST /dispatch ──────────────────────────────────────────────────────────

function dispatchReq(body: unknown, headers: Record<string, string> = {}): Request {
  return new Request("https://broker.example.com/dispatch", {
    method: "POST",
    headers: { "content-type": "application/json", ...headers },
    body: JSON.stringify(body)
  });
}

describe("POST /dispatch", () => {
  it("is disabled (503) without PROCESS_TRIGGER_SECRET", async () => {
    const r = await handleRequest(dispatchReq({}), env);
    expect(r.status).toBe(503);
    expect(await readJson(r)).toEqual({ error: "dispatch_disabled" });
  });

  it("rejects a wrong bearer with 401", async () => {
    const r = await handleRequest(
      dispatchReq({ repo: "o/r", instruction: "x" }, { authorization: "Bearer nope" }),
      { ...env, PROCESS_TRIGGER_SECRET: "trig" }
    );
    expect(r.status).toBe(401);
  });

  it("400 on missing fields", async () => {
    const r = await handleRequest(
      dispatchReq({ repo: "o/r" }, { authorization: "Bearer trig" }),
      { ...env, PROCESS_TRIGGER_SECRET: "trig" }
    );
    expect(r.status).toBe(400);
  });

  it("enqueues the task and triggers a session", async () => {
    const { kv, store } = makeKv();
    const { deps: injected } = deps({ githubResponses: [new Response("{}", { status: 200 })] });
    const r = await handleRequest(
      dispatchReq(
        { repo: "octo/repo", instruction: "fix the thing", pr: 7, user: "caleb" },
        { authorization: "Bearer trig" }
      ),
      { ...env, PROCESS_TRIGGER_SECRET: "trig", DISPATCH_TRIGGER_URL: "https://routines.example/run", COPILOT_QUOTA_KV: kv },
      injected
    );
    expect(r.status).toBe(202);
    const body = await readJson(r);
    expect(body.status).toBe("triggered");
    expect(typeof body.dispatch_id).toBe("string");
    expect([...store.keys()].some((k) => k.startsWith("dispatch:task:"))).toBe(true);
  });

  it("fires a Claude Code routine and captures the session url", async () => {
    const { kv, store } = makeKv();
    const { calls, deps: injected } = deps({
      githubResponses: [
        Response.json({
          type: "routine_fire",
          claude_code_session_id: "session_abc",
          claude_code_session_url: "https://claude.ai/code/session_abc"
        })
      ]
    });
    const r = await handleRequest(
      dispatchReq(
        { repo: "octo/repo", instruction: "implement issue 12", issue: 12, user: "caleb" },
        { authorization: "Bearer trig" }
      ),
      {
        ...env,
        PROCESS_TRIGGER_SECRET: "trig",
        DISPATCH_TRIGGER_URL: "https://api.anthropic.com/v1/claude_code/routines/r1/fire",
        DISPATCH_ROUTINE_TOKEN: "sk-ant-oat01-routine",
        COPILOT_QUOTA_KV: kv
      },
      injected
    );
    expect(r.status).toBe(202);
    const body = await readJson(r);
    expect(body.status).toBe("triggered");
    expect(body.session_url).toBe("https://claude.ai/code/session_abc");
    expect(body.session_id).toBe("session_abc");

    // fired the routine endpoint with the per-routine bearer + beta header
    expect(calls[0].url).toContain("/routines/r1/fire");
    expect(calls[0].headers.get("authorization")).toBe("Bearer sk-ant-oat01-routine");
    expect(calls[0].headers.get("anthropic-beta")).toBe("experimental-cc-routine-2026-04-01");
    const sent = (await calls[0].json()) as Record<string, unknown>;
    expect(typeof sent.text).toBe("string");
    expect(sent.text as string).toContain("implement issue 12");

    // session url persisted on the task for traceability
    const taskKey = [...store.keys()].find((k) => k.startsWith("dispatch:task:"))!;
    expect(JSON.parse(store.get(taskKey)!.value).session_url).toBe(
      "https://claude.ai/code/session_abc"
    );
  });

  it("queues without a trigger URL configured", async () => {
    const { kv } = makeKv();
    const { deps: injected } = deps();
    injected.fetch = async () => {
      throw new Error("no trigger expected");
    };
    const r = await handleRequest(
      dispatchReq({ repo: "octo/repo", instruction: "x" }, { authorization: "Bearer trig" }),
      { ...env, PROCESS_TRIGGER_SECRET: "trig", COPILOT_QUOTA_KV: kv },
      injected
    );
    expect((await readJson(r)).status).toBe("queued_no_trigger");
  });
});

// ─── POST /sign (GitHub-signed, user-attributed commit) ──────────────────────

describe("POST /sign", () => {
  const signEnv: BrokerEnv = {
    ...env,
    PROCESS_TRIGGER_SECRET: "trig",
    GITHUB_APP_CLIENT_ID: "Iv1",
    GITHUB_APP_CLIENT_SECRET: "sec"
  };
  const body = {
    user: "caleb",
    repo: "octo/repo",
    branch: "feature",
    expected_head_oid: "abc123",
    message: { headline: "fix: thing" },
    additions: [{ path: "a.ts", contents: "Y29uc3Q=" }]
  };
  function signReq(headers: Record<string, string> = { authorization: "Bearer trig" }): Request {
    return new Request("https://broker.example.com/sign", {
      method: "POST",
      headers: { "content-type": "application/json", ...headers },
      body: JSON.stringify(body)
    });
  }

  it("is disabled (503) without PROCESS_TRIGGER_SECRET", async () => {
    const r = await handleRequest(signReq({}), env);
    expect(r.status).toBe(503);
    expect(await readJson(r)).toEqual({ error: "sign_disabled" });
  });

  it("returns 409 when the user has no OAuth connection", async () => {
    const { deps: injected } = deps();
    const r = await handleRequest(signReq(), signEnv, injected);
    expect(r.status).toBe(409);
    expect(await readJson(r)).toEqual({ error: "user_not_connected" });
  });

  it("creates a GitHub-signed commit via createCommitOnBranch", async () => {
    const { kv, store } = makeKv();
    store.set("copilot-oauth:user:caleb", {
      value: JSON.stringify({
        refresh_token: "ghr",
        refresh_token_expires_at: "2099-01-01T00:00:00Z",
        access_token: "ghu_live",
        access_token_expires_at: "2099-01-01T00:00:00Z"
      })
    });
    const { calls, deps: injected } = deps({
      githubResponses: [
        Response.json({
          data: {
            createCommitOnBranch: {
              commit: { oid: "deadbeef", url: "https://github.com/octo/repo/commit/deadbeef" }
            }
          }
        })
      ]
    });
    const r = await handleRequest(signReq(), { ...signEnv, COPILOT_QUOTA_KV: kv }, injected);
    expect(r.status).toBe(200);
    expect((await readJson(r)).commit).toEqual({
      oid: "deadbeef",
      url: "https://github.com/octo/repo/commit/deadbeef"
    });
    // signed with the user's OAuth token, not the App installation token
    expect(calls[0].headers.get("authorization")).toBe("Bearer ghu_live");
  });
});
