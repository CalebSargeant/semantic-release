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

// ─── shared helpers ──────────────────────────────────────────────────────────
//
// Tests run the worker through `handleRequest` with injected `fetch` / `now`,
// the same shape the /token tests use. The KV namespace is faked with an
// in-memory Map so we don't pull in miniflare just for these cases.

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

// ─── /webhook signature gate + non-push no-op ────────────────────────────────

describe("/webhook", () => {
  it("rejects requests when no webhook secret is configured", async () => {
    const response = await handleRequest(
      new Request("https://broker.example.com/webhook", {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "x-github-event": "ping",
          "x-hub-signature-256": "sha256=abc"
        },
        body: "{}"
      }),
      env
    );
    expect(response.status).toBe(503);
    expect(await readJson(response)).toEqual({ error: "webhook_disabled" });
  });

  it("rejects requests with an invalid HMAC signature", async () => {
    const response = await handleRequest(
      new Request("https://broker.example.com/webhook", {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "x-github-event": "ping",
          "x-hub-signature-256": "sha256=deadbeef"
        },
        body: JSON.stringify({ zen: "hi" })
      }),
      { ...env, GITHUB_WEBHOOK_SECRET: "shh" }
    );
    expect(response.status).toBe(401);
    expect(await readJson(response)).toEqual({ error: "invalid_signature" });
  });

  it("acknowledges non-push events as a no-op", async () => {
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

  it("returns 404 for unknown paths", async () => {
    const response = await handleRequest(
      new Request("https://broker.example.com/whatever", { method: "GET" }),
      env
    );
    expect(response.status).toBe(404);
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

// ─── POST /sign (GitHub-signed, App/bot-attributed commit) ───────────────────

describe("POST /sign", () => {
  const signEnv: BrokerEnv = {
    ...env,
    PROCESS_TRIGGER_SECRET: "trig"
  };
  const body = {
    user: "caleb", // accepted but ignored — kept for backward compatibility
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

  it("rejects a wrong bearer with 401", async () => {
    const { deps: injected } = deps();
    const r = await handleRequest(
      signReq({ authorization: "Bearer nope" }),
      signEnv,
      injected
    );
    expect(r.status).toBe(401);
    expect(await readJson(r)).toEqual({ error: "unauthorized" });
  });

  it("creates a GitHub-signed, App-attributed commit via createCommitOnBranch", async () => {
    const { calls, deps: injected } = deps({
      githubResponses: [
        // mintInstallationToken: installation lookup, then access_tokens mint
        Response.json({ id: 42 }),
        Response.json({ token: "ghs_app", expires_at: "2026-05-03T13:00:00Z" }),
        // GraphQL createCommitOnBranch
        Response.json({
          data: {
            createCommitOnBranch: {
              commit: { oid: "deadbeef", url: "https://github.com/octo/repo/commit/deadbeef" }
            }
          }
        })
      ]
    });
    const r = await handleRequest(signReq(), signEnv, injected);
    expect(r.status).toBe(200);
    expect((await readJson(r)).commit).toEqual({
      oid: "deadbeef",
      url: "https://github.com/octo/repo/commit/deadbeef"
    });
    // First two calls mint the App installation token for the repo.
    expect(calls[0].url).toBe(
      "https://api.github.com/repos/octo/repo/installation"
    );
    expect(calls[1].url).toBe(
      "https://api.github.com/app/installations/42/access_tokens"
    );
    const tokenBody = (await calls[1].json()) as Record<string, unknown>;
    expect(tokenBody).toEqual({ repositories: ["repo"], permissions: { contents: "write" } });
    // The commit is signed with the App installation token, not a user token.
    expect(calls[2].url).toContain("/graphql");
    expect(calls[2].headers.get("authorization")).toBe("Bearer ghs_app");
  });

  it("surfaces an HttpError from token minting (404 app_not_installed)", async () => {
    const { deps: injected } = deps({
      githubResponses: [new Response("{}", { status: 404 })] // installation lookup 404s
    });
    const r = await handleRequest(signReq(), signEnv, injected);
    expect(r.status).toBe(404);
    expect(await readJson(r)).toEqual({ error: "app_not_installed" });
  });
});
