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
      async list() {
        return { keys: [...store.keys()].map((name) => ({ name })) };
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
