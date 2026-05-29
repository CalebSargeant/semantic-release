import {
  SignJWT,
  createRemoteJWKSet,
  importPKCS8,
  jwtVerify,
  type JWTPayload
} from "jose";

const GITHUB_OIDC_ISSUER = "https://token.actions.githubusercontent.com";
const GITHUB_OIDC_JWKS_URL =
  "https://token.actions.githubusercontent.com/.well-known/jwks";
const GITHUB_API_VERSION = "2022-11-28";
const DEFAULT_AUDIENCE = "diatreme";
// Legacy audience accepted during the release-runner → diatreme migration so
// OIDC tokens minted by older pinned action versions still verify.
const LEGACY_AUDIENCE = "release-runner";
const DEFAULT_PERMISSIONS: TokenPermissions = {
  contents: "write",
  pull_requests: "write"
};

const remoteJwks = createRemoteJWKSet(new URL(GITHUB_OIDC_JWKS_URL));

type PermissionLevel = "read" | "write";
type TokenPermissions = Record<string, PermissionLevel>;

export type BrokerEnv = Env & {
  GITHUB_APP_ID: string;
  GITHUB_APP_PRIVATE_KEY: string;
  OIDC_AUDIENCE?: string;
  ALLOWED_REPOSITORIES?: string;
  TOKEN_PERMISSIONS?: string;
  // /copilot-quota + /webhook
  COPILOT_QUOTA_KV?: KVNamespace;
  COPILOT_QUOTA_OVERRIDE_SECRET?: string;
  COPILOT_QUOTA_CACHE_TTL_SECONDS?: string;
  GITHUB_WEBHOOK_SECRET?: string;
  COPILOT_WEBHOOK_REVIEW_GAP_SECONDS?: string;
  // /oauth (App user-access-token flow)
  GITHUB_APP_CLIENT_ID?: string;
  GITHUB_APP_CLIENT_SECRET?: string;
  // /webhook pull_request_review_comment → triage Copilot review comments.
  // Bring-your-own-key: no API key ⇒ triage disabled (no free AI).
  TRIAGE_LLM_PROVIDER?: string; // anthropic (default) | openai | deepseek | openrouter (latter three = OpenAI-compatible)
  TRIAGE_LLM_API_KEY?: string;
  TRIAGE_LLM_MODEL?: string; // default claude-haiku-4-5 for anthropic
  TRIAGE_LLM_BASE_URL?: string; // override for OpenAI-compatible providers
  // Trusted-author gate for automatic triage: untrusted PRs are skipped.
  TRIAGE_TRUSTED_ASSOCIATIONS?: string; // default OWNER,MEMBER,COLLABORATOR
  TRIAGE_TRUSTED_USERS?: string; // extra allowlisted logins (comma-separated)
  // POST /process — manual re-walk of a PR's Copilot comments. Bearer-gated;
  // unset disables the endpoint. Also gates /dispatch and /sign.
  PROCESS_TRIGGER_SECRET?: string;
  // POST /dispatch enqueues an autonomous code-writing task and fires a Claude
  // Code on the Web Routine to do it. DISPATCH_TRIGGER_URL is the routine's
  // fire URL (https://api.anthropic.com/v1/claude_code/routines/<id>/fire);
  // DISPATCH_ROUTINE_TOKEN is its per-routine bearer token. With the token set
  // we POST {text:<brief>} + the Anthropic beta headers and capture the
  // returned session URL; without it we fall back to a plain webhook POST (for
  // a self-hosted runner). Unset URL ⇒ the task is queued only.
  DISPATCH_TRIGGER_URL?: string;
  DISPATCH_ROUTINE_TOKEN?: string;
  // /webhook push → auto-update open PRs targeting the pushed branch (opt-in).
  AUTO_UPDATE_BRANCHES?: string;
};

interface TokenRequest {
  oidcToken: string;
  owner: string;
  repo: string;
  ref?: string;
  runId?: string;
  sha?: string;
}

interface VerifiedOidcPayload extends JWTPayload {
  repository?: string;
}

interface Dependencies {
  fetch: typeof fetch;
  verifyOidcToken: (
    token: string,
    audience: string | string[]
  ) => Promise<VerifiedOidcPayload>;
  createGitHubAppJwt: (
    appId: string,
    privateKey: string,
    now: Date
  ) => Promise<string>;
  now: () => Date;
}

class HttpError extends Error {
  constructor(
    readonly status: number,
    readonly code: string
  ) {
    super(code);
  }
}

class OidcVerificationError extends Error {}

const defaultDependencies: Dependencies = {
  fetch,
  verifyOidcToken,
  createGitHubAppJwt,
  now: () => new Date()
};

export default {
  fetch(request: Request, env: BrokerEnv): Promise<Response> {
    return handleRequest(request, env);
  },
  scheduled(
    _controller: ScheduledController,
    env: BrokerEnv,
    ctx: ExecutionContext
  ): void {
    ctx.waitUntil(handleScheduledRefresh(env, defaultDependencies));
  }
} satisfies ExportedHandler<BrokerEnv>;

export async function handleRequest(
  request: Request,
  env: BrokerEnv,
  deps: Partial<Dependencies> = {}
): Promise<Response> {
  const dependencies: Dependencies = {
    ...defaultDependencies,
    ...deps
  };

  try {
    const url = new URL(request.url);
    switch (url.pathname) {
      case "/token":
        return await handleTokenRequest(request, env, dependencies);
      case "/copilot-quota":
        return await handleCopilotQuotaRequest(request, env, dependencies, url);
      case "/webhook":
        return await handleWebhookRequest(request, env, dependencies);
      case "/process":
        return await handleProcessRequest(request, env, dependencies);
      case "/dispatch":
        return await handleDispatchRequest(request, env, dependencies);
      case "/sign":
        return await handleSignRequest(request, env, dependencies);
      case "/releases":
        return await handleReleasesRequest(request, env, dependencies);
      case "/oauth/connect":
        return await handleOAuthConnect(env, dependencies, url);
      case "/oauth/callback":
        return await handleOAuthCallback(env, dependencies, url);
      case "/oauth/status":
        return await handleOAuthStatus(env, url);
      default:
        return jsonError(404, "not_found");
    }
  } catch (error) {
    if (error instanceof HttpError) {
      return jsonError(error.status, error.code);
    }

    if (error instanceof OidcVerificationError) {
      return jsonError(401, "invalid_oidc_token");
    }

    return jsonError(500, "internal_error");
  }
}

async function handleTokenRequest(
  request: Request,
  env: BrokerEnv,
  dependencies: Dependencies
): Promise<Response> {
  if (request.method !== "POST") {
    return jsonError(405, "method_not_allowed");
  }

  const body = await readTokenRequest(request);
  const repository = `${body.owner}/${body.repo}`;
  assertRepositoryParts(body.owner, body.repo);

  const audience = env.OIDC_AUDIENCE || [DEFAULT_AUDIENCE, LEGACY_AUDIENCE];
  const oidcPayload = await verifyOidc(body.oidcToken, audience, dependencies);
  if (oidcPayload.repository !== repository) {
    return jsonError(403, "repo_mismatch");
  }

  if (!repositoryAllowed(repository, env.ALLOWED_REPOSITORIES)) {
    return jsonError(403, "repo_not_allowed");
  }

  const appJwt = await dependencies.createGitHubAppJwt(
    requiredSecret(env.GITHUB_APP_ID, "GITHUB_APP_ID"),
    requiredSecret(env.GITHUB_APP_PRIVATE_KEY, "GITHUB_APP_PRIVATE_KEY"),
    dependencies.now()
  );
  const installationId = await findInstallationId(
    dependencies.fetch,
    appJwt,
    body.owner,
    body.repo
  );
  const token = await createInstallationToken(
    dependencies.fetch,
    appJwt,
    installationId,
    body.repo,
    parsePermissions(env.TOKEN_PERMISSIONS)
  );

  return json(
    {
      token: token.token,
      expires_at: token.expires_at,
      repository
    },
    200
  );
}

// ─── /copilot-quota ──────────────────────────────────────────────────────────
// Reports whether a GitHub account has exhausted its Copilot premium-request
// allowance. The signal is consumed by Diatreme's require-copilot-review
// gate so it can pass gracefully when no review will ever arrive.
//
// State sources, in order of preference:
//   1. Manual override in KV (POSTed by an operator who saw the UI banner).
//   2. GitHub Billing Usage API (auto-detect; best-effort, may not be
//      available for the account type or App permissions).
//   3. Default false (don't claim a rate limit we can't prove).
//
// Manual override TTL defaults to the next UTC month boundary (matching the
// "Limit resets on Jun 1" wording in the UI banner). Caller can pass an
// explicit `until` ISO timestamp to override.

interface CopilotQuotaState {
  rate_limited: boolean;
  resets_at?: string;
  source:
    | "manual"
    | "github-oauth-user-billing"
    | "github-billing-api"
    | "github-webhook"
    | "github-copilot-metrics"
    | "default";
  checked_at: string;
  detail?: string;
}

interface ManualOverrideRecord {
  rate_limited: boolean;
  resets_at: string;
  set_at: string;
}

const COPILOT_QUOTA_DEFAULT_CACHE_TTL_SECONDS = 3600;

async function handleCopilotQuotaRequest(
  request: Request,
  env: BrokerEnv,
  dependencies: Dependencies,
  url: URL
): Promise<Response> {
  if (request.method === "GET") {
    return handleCopilotQuotaGet(env, dependencies, url);
  }
  if (request.method === "POST") {
    return handleCopilotQuotaPost(request, env, dependencies);
  }
  return jsonError(405, "method_not_allowed");
}

async function handleCopilotQuotaGet(
  env: BrokerEnv,
  dependencies: Dependencies,
  url: URL
): Promise<Response> {
  const owner = url.searchParams.get("owner");
  if (!owner) {
    return jsonError(400, "missing_owner");
  }
  assertOwnerName(owner);

  // Optional `requester` is the PR author whose user-scoped Copilot quota
  // matters even when the repo lives under an organization. Copilot
  // premium-request quotas are per-user even on Copilot Business, so
  // org-level billing for `owner` will miss individual exhaustion.
  // Invalid requester strings are silently ignored — the endpoint stays
  // backward-compatible with callers that don't pass the parameter.
  let requester: string | null = url.searchParams.get("requester");
  if (requester) {
    try {
      assertOwnerName(requester);
    } catch {
      requester = null;
    }
  }

  const now = dependencies.now();

  // 1. Manual override for the owner wins. KV may be unbound on dev or
  // in legacy deploys.
  const manualOwner = await readManualOverride(env, owner, now);
  if (manualOwner) {
    return json({ ...manualOwner } as unknown as Record<string, unknown>, 200);
  }

  // 2. Manual override for the requester — operator may flip a specific
  // user's flag without knowing every repo it touches.
  if (requester) {
    const manualRequester = await readManualOverride(env, requester, now);
    if (manualRequester) {
      return json(
        { ...manualRequester } as unknown as Record<string, unknown>,
        200
      );
    }
  }

  // 3. OAuth-backed user billing for the requester. Most reliable
  // detection path for individual quota exhaustion when the requester
  // has authorized Diatreme via /oauth/connect. Uses a
  // user access token (not the App installation token) to query
  // /users/{requester}/settings/billing/premium_request/usage, which
  // requires the "Plan" account permission. No-op when the requester
  // hasn't authorized — falls through to the next layer.
  let userBilling: CopilotQuotaState | null = null;
  if (requester) {
    userBilling = await tryOAuthUserBillingLookup(
      env,
      dependencies,
      requester,
      now
    ).catch(() => null);
    if (userBilling && userBilling.rate_limited) {
      return json(
        { ...userBilling } as unknown as Record<string, unknown>,
        200
      );
    }
  }

  // 4. Org-level Billing API for owner. Useful for Copilot Business orgs
  // where premium-request usage shows up at the org level.
  const billing = await tryBillingApiLookup(env, dependencies, owner, now).catch(
    () => null
  );
  if (billing && billing.rate_limited) {
    return json({ ...billing } as unknown as Record<string, unknown>, 200);
  }

  // 5. Webhook-derived heuristic for the owner. If our event stream
  // shows Copilot review requests outpacing deliveries, Copilot is
  // likely rate-limited even when the Billing API hasn't caught up (or
  // isn't available).
  const webhook = await webhookSignalForOwner(env, owner, now).catch(() => null);
  if (webhook) {
    return json({ ...webhook } as unknown as Record<string, unknown>, 200);
  }

  // 6. Webhook signal scoped to the requester — only set if we've seen
  // a Copilot review request whose sender matched the requester.
  if (requester) {
    const webhookUser = await webhookSignalForOwner(env, requester, now).catch(
      () => null
    );
    if (webhookUser) {
      return json({ ...webhookUser } as unknown as Record<string, unknown>, 200);
    }
  }

  // 7. Copilot Metrics API as a softer fallback — useful when the App
  // has copilot:read but not billing:read.
  const metrics = await tryMetricsApiLookup(env, dependencies, owner, now).catch(
    () => null
  );
  if (metrics && metrics.rate_limited) {
    return json({ ...metrics } as unknown as Record<string, unknown>, 200);
  }

  // 8. Negative billing results — surface stronger no-signal data
  // (Copilot data present but not exhausted) over the bare default.
  // User billing is more specific than org billing, so prefer it.
  if (userBilling) {
    return json({ ...userBilling } as unknown as Record<string, unknown>, 200);
  }
  if (billing) {
    return json({ ...billing } as unknown as Record<string, unknown>, 200);
  }

  const fallback: CopilotQuotaState = {
    rate_limited: false,
    source: "default",
    checked_at: now.toISOString()
  };
  return json({ ...fallback } as unknown as Record<string, unknown>, 200);
}

async function handleCopilotQuotaPost(
  request: Request,
  env: BrokerEnv,
  dependencies: Dependencies
): Promise<Response> {
  const expected = env.COPILOT_QUOTA_OVERRIDE_SECRET;
  if (!expected || expected.trim() === "") {
    return jsonError(503, "override_disabled");
  }
  const authz = request.headers.get("authorization") ?? "";
  if (authz !== `Bearer ${expected}`) {
    return jsonError(401, "unauthorized");
  }

  if (!env.COPILOT_QUOTA_KV) {
    return jsonError(503, "kv_not_configured");
  }

  let payload: unknown;
  try {
    payload = await request.json();
  } catch {
    return jsonError(400, "invalid_json");
  }

  if (!isRecord(payload)) {
    return jsonError(400, "invalid_request");
  }

  const owner = asString(payload.owner);
  if (!owner) {
    return jsonError(400, "missing_owner");
  }
  assertOwnerName(owner);

  const rateLimited = payload.rate_limited;
  if (typeof rateLimited !== "boolean") {
    return jsonError(400, "missing_rate_limited");
  }

  const now = dependencies.now();
  const resetsAt = resolveResetsAt(payload.resets_at, now);

  if (!rateLimited) {
    await env.COPILOT_QUOTA_KV.delete(manualKey(owner));
    return json({ cleared: true, owner }, 200);
  }

  const ttlSeconds = Math.max(
    60,
    Math.floor((resetsAt.getTime() - now.getTime()) / 1000)
  );
  const record: ManualOverrideRecord = {
    rate_limited: true,
    resets_at: resetsAt.toISOString(),
    set_at: now.toISOString()
  };
  await env.COPILOT_QUOTA_KV.put(manualKey(owner), JSON.stringify(record), {
    expirationTtl: ttlSeconds
  });
  return json({ stored: true, owner, resets_at: record.resets_at }, 200);
}

async function readManualOverride(
  env: BrokerEnv,
  owner: string,
  now: Date
): Promise<CopilotQuotaState | null> {
  if (!env.COPILOT_QUOTA_KV) return null;
  const raw = await env.COPILOT_QUOTA_KV.get(manualKey(owner));
  if (!raw) return null;
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return null;
  }
  if (!isRecord(parsed) || typeof parsed.rate_limited !== "boolean") {
    return null;
  }
  const resetsAt = asString(parsed.resets_at);
  if (resetsAt) {
    const expiry = new Date(resetsAt);
    if (!Number.isNaN(expiry.getTime()) && expiry.getTime() <= now.getTime()) {
      // Defensive: KV TTL should have evicted, but a stale value snuck
      // through. Treat as cleared.
      return null;
    }
  }
  return {
    rate_limited: parsed.rate_limited,
    resets_at: resetsAt,
    source: "manual",
    checked_at: now.toISOString()
  };
}

async function tryBillingApiLookup(
  env: BrokerEnv,
  dependencies: Dependencies,
  owner: string,
  now: Date
): Promise<CopilotQuotaState | null> {
  if (!env.COPILOT_QUOTA_KV) {
    return performBillingApiLookup(env, dependencies, owner, now);
  }
  const cacheKey = billingCacheKey(owner);
  const cached = await env.COPILOT_QUOTA_KV.get(cacheKey);
  if (cached) {
    try {
      const parsed = JSON.parse(cached) as CopilotQuotaState;
      if (parsed && typeof parsed.rate_limited === "boolean") {
        return parsed;
      }
    } catch {
      // fall through to refresh
    }
  }

  const fresh = await performBillingApiLookup(env, dependencies, owner, now);
  if (fresh) {
    const ttl = Math.max(
      60,
      Number(env.COPILOT_QUOTA_CACHE_TTL_SECONDS) ||
        COPILOT_QUOTA_DEFAULT_CACHE_TTL_SECONDS
    );
    await env.COPILOT_QUOTA_KV.put(cacheKey, JSON.stringify(fresh), {
      expirationTtl: ttl
    });
  }
  return fresh;
}

async function performBillingApiLookup(
  env: BrokerEnv,
  dependencies: Dependencies,
  owner: string,
  now: Date
): Promise<CopilotQuotaState | null> {
  // The Billing Usage API requires an App installation with billing
  // permissions on the owner. Without an installation token we can't
  // proceed. We mint a fresh App JWT and look up the installation for
  // this owner the same way the /token endpoint does for repos.
  const appId = env.GITHUB_APP_ID;
  const privateKey = env.GITHUB_APP_PRIVATE_KEY;
  if (!appId || !privateKey) {
    return null;
  }

  // Extract fetch off `dependencies` into a local. Calling
  // `dependencies.fetch(...)` is a method call with `this=dependencies`,
  // which Cloudflare's native fetch rejects ("Illegal invocation"). The
  // existing `findInstallationIdForOwner` path passes fetch as a plain
  // argument and so avoids the bind; mirror that here.
  const fetchFn: typeof fetch = dependencies.fetch;

  let appJwt: string;
  try {
    appJwt = await dependencies.createGitHubAppJwt(appId, privateKey, now);
  } catch {
    return null;
  }

  const installationId = await findInstallationIdForOwner(
    fetchFn,
    appJwt,
    owner
  );
  if (installationId === null) {
    return null;
  }

  // Permissions are configured on the App itself ("Plan" account /
  // organization permissions for billing usage endpoints). The
  // installation token carries whichever subset the installation
  // has accepted — a stale installation that pre-dates a new App
  // permission needs to be re-approved to surface it.
  const tokenResponse = await fetchFn(
    `https://api.github.com/app/installations/${installationId}/access_tokens`,
    {
      method: "POST",
      headers: githubHeaders(appJwt)
    }
  );
  if (!tokenResponse.ok) {
    return null;
  }
  const tokenBody = (await tokenResponse.json()) as { token?: string };
  if (!tokenBody.token) {
    return null;
  }

  // GitHub exposes Copilot premium-request usage under a dedicated
  // /premium_request/usage endpoint, distinct from the general
  // /billing/usage SKU dump (which surfaces only Actions / Storage /
  // Packages, not Copilot). Try both — premium_request first — and
  // accept whichever returns a usable shape. 404 from the wrong scope
  // is harmless; the loop just continues.
  const enc = encodeURIComponent(owner);
  const endpoints = [
    `https://api.github.com/organizations/${enc}/settings/billing/premium_request/usage`,
    `https://api.github.com/users/${enc}/settings/billing/premium_request/usage`,
    `https://api.github.com/orgs/${enc}/settings/billing/usage`,
    `https://api.github.com/users/${enc}/settings/billing/usage`
  ];

  for (const endpoint of endpoints) {
    const usageResponse = await fetchFn(endpoint, {
      headers: {
        Accept: "application/vnd.github+json",
        Authorization: `Bearer ${tokenBody.token}`,
        "X-GitHub-Api-Version": GITHUB_API_VERSION,
        "User-Agent": "diatreme-broker"
      }
    });
    if (usageResponse.status === 404) continue;
    if (!usageResponse.ok) continue;

    const body = (await usageResponse.json()) as unknown;
    const verdict = interpretBillingUsage(body, now);
    if (verdict) return verdict;
  }

  return null;
}

async function findInstallationIdForOwner(
  githubFetch: typeof fetch,
  appJwt: string,
  owner: string
): Promise<number | null> {
  // Try organisation first, then user. We can't know which scope ahead
  // of time without an extra round-trip, so we just try both.
  const candidates = [
    `https://api.github.com/orgs/${encodeURIComponent(owner)}/installation`,
    `https://api.github.com/users/${encodeURIComponent(owner)}/installation`
  ];
  for (const url of candidates) {
    const response = await githubFetch(url, { headers: githubHeaders(appJwt) });
    if (response.status === 404) continue;
    if (!response.ok) continue;
    const body = (await response.json()) as { id?: number };
    if (typeof body.id === "number") return body.id;
  }
  return null;
}

function interpretBillingUsage(
  body: unknown,
  now: Date
): CopilotQuotaState | null {
  // The Billing Usage API returns a list of usage items keyed by product.
  // We're looking for any Copilot premium-request item whose remaining
  // quota is exhausted. GitHub's response shape has shifted across
  // previews, so we accept a few shapes:
  //
  //   { usageItems: [ { product, sku, quantity, remaining, ... }, ... ] }
  //   { items:      [ ... ] }
  //
  // Heuristic: an item is "rate-limited" when product matches /copilot/i
  // AND (remaining === 0 OR included_quantity === 0) AND either an SKU
  // or description mentions "premium" or "request".
  if (!isRecord(body)) return null;
  const items = (body.usageItems ?? body.items ?? body.usage_items) as
    | unknown
    | undefined;
  if (!Array.isArray(items)) return null;

  for (const raw of items) {
    if (!isRecord(raw)) continue;
    const product = String(raw.product ?? "").toLowerCase();
    const sku = String(raw.sku ?? raw.unitType ?? "").toLowerCase();
    const desc = String(raw.description ?? "").toLowerCase();
    if (!product.includes("copilot")) continue;
    const mentionsPremium = sku.includes("premium") || desc.includes("premium");
    const mentionsRequest = sku.includes("request") || desc.includes("request");
    if (!mentionsPremium && !mentionsRequest) continue;

    const remaining = Number(raw.remaining ?? raw.remainingQuantity ?? NaN);
    const includedQty = Number(raw.includedQuantity ?? raw.included ?? NaN);
    const usedQty = Number(raw.quantity ?? raw.used ?? NaN);
    let exhausted = false;
    if (Number.isFinite(remaining)) {
      exhausted = remaining <= 0;
    } else if (Number.isFinite(includedQty) && Number.isFinite(usedQty)) {
      exhausted = usedQty >= includedQty;
    }
    if (!exhausted) continue;

    const resetsAt =
      asString(raw.periodEnd ?? raw.period_end ?? raw.resets_at) ??
      nextUtcMonthBoundary(now).toISOString();
    return {
      rate_limited: true,
      resets_at: resetsAt,
      source: "github-billing-api",
      checked_at: now.toISOString(),
      detail: desc || sku || "premium request quota exhausted"
    };
  }

  // We saw billing data but no exhausted Copilot premium-request item.
  return {
    rate_limited: false,
    source: "github-billing-api",
    checked_at: now.toISOString()
  };
}

function manualKey(owner: string): string {
  return `copilot-quota:manual:${owner.toLowerCase()}`;
}

function billingCacheKey(owner: string): string {
  return `copilot-quota:billing:${owner.toLowerCase()}`;
}

function assertOwnerName(owner: string): void {
  if (!/^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38}[A-Za-z0-9])?$/.test(owner)) {
    throw new HttpError(400, "invalid_owner");
  }
}

function resolveResetsAt(input: unknown, now: Date): Date {
  if (typeof input === "string" && input.trim() !== "") {
    const parsed = new Date(input);
    if (!Number.isNaN(parsed.getTime()) && parsed.getTime() > now.getTime()) {
      return parsed;
    }
  }
  return nextUtcMonthBoundary(now);
}

function nextUtcMonthBoundary(now: Date): Date {
  return new Date(
    Date.UTC(now.getUTCFullYear(), now.getUTCMonth() + 1, 1, 0, 0, 0)
  );
}

// ─── /oauth ──────────────────────────────────────────────────────────
// OAuth user-access-token flow against the Diatreme GitHub App. Each
// contributor authorizes once; the worker stores a refresh token in KV
// keyed by their github login. The /copilot-quota resolver mints fresh
// user access tokens on demand and queries the user-scoped billing API —
// the only way to get a real "Copilot premium-request quota exhausted"
// signal for individual contributors, since installation tokens never
// carry account-level "Plan" permissions.
//
// GitHub App user-access-token docs:
//   https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-a-user-access-token-for-a-github-app
//
// Endpoints:
//   GET /oauth/connect[?return_to=URL]
//     Initiates the OAuth dance. Generates a CSRF state, stashes it in
//     KV with a 10 min TTL, then 302s to github.com/login/oauth/authorize.
//
//   GET /oauth/callback?code=…&state=…
//     Receives GitHub's auth code. Validates state, exchanges code for
//     access_token + refresh_token, fetches /user to learn the login,
//     stores the refresh_token in KV. Returns an HTML success page.
//
//   GET /oauth/status?user=LOGIN
//     Returns whether KV holds a non-expired refresh token for that user.
//     No auth — connection state isn't sensitive (just a boolean).

const OAUTH_STATE_TTL_SECONDS = 600;            // 10 minutes
const OAUTH_REFRESH_TOKEN_TTL_SECONDS = 60 * 60 * 24 * 180; // ~6 months
const OAUTH_AUTHORIZE_URL = "https://github.com/login/oauth/authorize";
const OAUTH_TOKEN_URL = "https://github.com/login/oauth/access_token";

interface OAuthStateRecord {
  return_to?: string;
  created_at: string;
}

interface OAuthUserRecord {
  refresh_token: string;
  refresh_token_expires_at: string;
  // Most recent access_token issued, plus its expiry. Cached to avoid
  // refreshing on every PR check during a short window (access tokens
  // expire in 8 hours). Not strictly required — we can always refresh
  // — but a cheap optimization.
  access_token?: string;
  access_token_expires_at?: string;
  connected_at: string;
  last_used_at?: string;
}

// NB: the URL routes are /oauth/* but these KV key prefixes stay
// `copilot-oauth:` on purpose — renaming them would orphan connections already
// stored in the (shared) KV namespace. Internal-only; never user-visible.
function oauthStateKey(state: string): string {
  return `copilot-oauth:state:${state}`;
}

function oauthUserKey(login: string): string {
  return `copilot-oauth:user:${login.toLowerCase()}`;
}

function callbackUrl(env: BrokerEnv, requestUrl: URL): string {
  // Build the callback URL from the request origin, so the worker
  // works under workers.dev preview deploys without env tweaks.
  return `${requestUrl.origin}/oauth/callback`;
}

function randomState(): string {
  const bytes = new Uint8Array(24);
  crypto.getRandomValues(bytes);
  return Array.from(bytes)
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

async function handleOAuthConnect(
  env: BrokerEnv,
  dependencies: Dependencies,
  url: URL
): Promise<Response> {
  const clientId = env.GITHUB_APP_CLIENT_ID;
  if (!clientId) {
    return jsonError(503, "oauth_disabled");
  }
  if (!env.COPILOT_QUOTA_KV) {
    return jsonError(503, "kv_not_configured");
  }

  const state = randomState();
  const returnTo = url.searchParams.get("return_to") ?? "";
  const stateRecord: OAuthStateRecord = {
    return_to: returnTo || undefined,
    created_at: dependencies.now().toISOString()
  };
  await env.COPILOT_QUOTA_KV.put(
    oauthStateKey(state),
    JSON.stringify(stateRecord),
    { expirationTtl: OAUTH_STATE_TTL_SECONDS }
  );

  const redirectTo = new URL(OAUTH_AUTHORIZE_URL);
  redirectTo.searchParams.set("client_id", clientId);
  redirectTo.searchParams.set("redirect_uri", callbackUrl(env, url));
  redirectTo.searchParams.set("state", state);
  // No `scope` parameter — GitHub App user access tokens are scoped to
  // the App's declared user permissions, not OAuth scopes.

  return new Response(null, {
    status: 302,
    headers: {
      Location: redirectTo.toString(),
      "Cache-Control": "no-store"
    }
  });
}

async function handleOAuthCallback(
  env: BrokerEnv,
  dependencies: Dependencies,
  url: URL
): Promise<Response> {
  // Surface GitHub-reported errors (e.g. user clicked "Cancel") before
  // any worker-config checks, so the user gets a useful page even if
  // the worker is misconfigured.
  const ghError = url.searchParams.get("error");
  if (ghError) {
    return oauthHtmlResponse(
      "Authorization cancelled",
      `GitHub reported: <code>${escapeHtml(ghError)}</code>. Close this tab and try again from the connect link.`,
      400
    );
  }

  const clientId = env.GITHUB_APP_CLIENT_ID;
  const clientSecret = env.GITHUB_APP_CLIENT_SECRET;
  if (!clientId || !clientSecret) {
    return jsonError(503, "oauth_disabled");
  }
  if (!env.COPILOT_QUOTA_KV) {
    return jsonError(503, "kv_not_configured");
  }

  const code = url.searchParams.get("code");
  const state = url.searchParams.get("state");
  if (!code || !state) {
    return jsonError(400, "missing_code_or_state");
  }

  // Validate state (CSRF + replay protection)
  const stateRaw = await env.COPILOT_QUOTA_KV.get(oauthStateKey(state));
  if (!stateRaw) {
    return oauthHtmlResponse(
      "Authorization expired",
      "The authorization link is missing or expired. Open <code>/oauth/connect</code> again to restart the flow.",
      400
    );
  }
  // One-shot — burn the state regardless of what happens next.
  await env.COPILOT_QUOTA_KV.delete(oauthStateKey(state));

  // Exchange code for tokens
  const fetchFn: typeof fetch = dependencies.fetch;
  const tokenResponse = await fetchFn(OAUTH_TOKEN_URL, {
    method: "POST",
    headers: {
      Accept: "application/json",
      "Content-Type": "application/json",
      "User-Agent": "diatreme-broker"
    },
    body: JSON.stringify({
      client_id: clientId,
      client_secret: clientSecret,
      code,
      redirect_uri: callbackUrl(env, url)
    })
  });
  if (!tokenResponse.ok) {
    const t = await tokenResponse.text().catch(() => "");
    return oauthHtmlResponse(
      "Token exchange failed",
      `GitHub returned HTTP ${tokenResponse.status}. Body: <code>${escapeHtml(t.slice(0, 200))}</code>`,
      502
    );
  }
  const tokenBody = (await tokenResponse.json()) as {
    access_token?: string;
    refresh_token?: string;
    expires_in?: number;
    refresh_token_expires_in?: number;
    error?: string;
    error_description?: string;
  };
  if (tokenBody.error || !tokenBody.access_token || !tokenBody.refresh_token) {
    const detail = tokenBody.error_description ?? tokenBody.error ?? "no token in response";
    return oauthHtmlResponse(
      "Token exchange failed",
      `GitHub: <code>${escapeHtml(detail)}</code>. This usually means the App's client secret is wrong or the redirect URL doesn't match what's configured on the App.`,
      502
    );
  }

  // Learn the user's login from the access token
  const userResponse = await fetchFn("https://api.github.com/user", {
    headers: {
      Accept: "application/vnd.github+json",
      Authorization: `Bearer ${tokenBody.access_token}`,
      "X-GitHub-Api-Version": GITHUB_API_VERSION,
      "User-Agent": "diatreme-broker"
    }
  });
  if (!userResponse.ok) {
    const t = await userResponse.text().catch(() => "");
    return oauthHtmlResponse(
      "Couldn't identify the GitHub user",
      `GitHub /user returned HTTP ${userResponse.status}. Body: <code>${escapeHtml(t.slice(0, 200))}</code>`,
      502
    );
  }
  const userBody = (await userResponse.json()) as { login?: string };
  if (!userBody.login) {
    return oauthHtmlResponse(
      "Couldn't identify the GitHub user",
      "GitHub /user response had no login.",
      502
    );
  }
  const login = userBody.login;
  try {
    assertOwnerName(login);
  } catch {
    return oauthHtmlResponse(
      "Invalid GitHub login",
      `GitHub returned an unusable login: <code>${escapeHtml(login)}</code>`,
      400
    );
  }

  const now = dependencies.now();
  const accessTokenExpiresAt = new Date(
    now.getTime() + (Number(tokenBody.expires_in) || 8 * 3600) * 1000
  );
  const refreshTokenExpiresAt = new Date(
    now.getTime() + (Number(tokenBody.refresh_token_expires_in) || OAUTH_REFRESH_TOKEN_TTL_SECONDS) * 1000
  );
  const userRecord: OAuthUserRecord = {
    refresh_token: tokenBody.refresh_token,
    refresh_token_expires_at: refreshTokenExpiresAt.toISOString(),
    access_token: tokenBody.access_token,
    access_token_expires_at: accessTokenExpiresAt.toISOString(),
    connected_at: now.toISOString()
  };
  const ttlSeconds = Math.max(
    60,
    Math.floor((refreshTokenExpiresAt.getTime() - now.getTime()) / 1000)
  );
  await env.COPILOT_QUOTA_KV.put(oauthUserKey(login), JSON.stringify(userRecord), {
    expirationTtl: ttlSeconds
  });

  // Parse state record for optional return_to
  let returnTo: string | undefined;
  try {
    const parsed = JSON.parse(stateRaw) as OAuthStateRecord;
    if (parsed.return_to && /^https?:\/\//.test(parsed.return_to)) {
      returnTo = parsed.return_to;
    }
  } catch {
    // ignore
  }

  return oauthHtmlResponse(
    "Connected ✓",
    `Diatreme can now check your Copilot premium-request quota when you open pull requests. You're connected as <strong>${escapeHtml(login)}</strong>; the connection is good for ~6 months and auto-renews each time you push a PR. You can close this tab.` +
      (returnTo ? `<p><a href="${escapeAttr(returnTo)}">Return to ${escapeHtml(returnTo)}</a></p>` : ""),
    200
  );
}

async function handleOAuthStatus(
  env: BrokerEnv,
  url: URL
): Promise<Response> {
  const user = url.searchParams.get("user");
  if (!user) {
    return jsonError(400, "missing_user");
  }
  try {
    assertOwnerName(user);
  } catch {
    return jsonError(400, "invalid_user");
  }
  if (!env.COPILOT_QUOTA_KV) {
    return jsonError(503, "kv_not_configured");
  }
  const raw = await env.COPILOT_QUOTA_KV.get(oauthUserKey(user));
  if (!raw) {
    return json({ connected: false, user }, 200);
  }
  try {
    const parsed = JSON.parse(raw) as OAuthUserRecord;
    return json(
      {
        connected: true,
        user,
        connected_at: parsed.connected_at,
        refresh_token_expires_at: parsed.refresh_token_expires_at
      },
      200
    );
  } catch {
    return json({ connected: false, user, parse_error: true }, 200);
  }
}

// Mint a fresh user access token for `login` using the stored refresh
// token. Rotates the refresh token (GitHub returns a new one each call)
// and writes the updated record back to KV. Returns null when no
// connection exists, the refresh fails, or the refresh token has
// expired.
async function getUserAccessToken(
  env: BrokerEnv,
  dependencies: Dependencies,
  login: string,
  now: Date
): Promise<string | null> {
  if (!env.COPILOT_QUOTA_KV) return null;
  const clientId = env.GITHUB_APP_CLIENT_ID;
  const clientSecret = env.GITHUB_APP_CLIENT_SECRET;
  if (!clientId || !clientSecret) return null;

  const raw = await env.COPILOT_QUOTA_KV.get(oauthUserKey(login));
  if (!raw) return null;
  let record: OAuthUserRecord;
  try {
    record = JSON.parse(raw) as OAuthUserRecord;
  } catch {
    return null;
  }

  // Reuse cached access_token if it's still good for >5 min
  if (record.access_token && record.access_token_expires_at) {
    const expiresAt = new Date(record.access_token_expires_at).getTime();
    if (Number.isFinite(expiresAt) && expiresAt - now.getTime() > 5 * 60 * 1000) {
      return record.access_token;
    }
  }

  // Check refresh token hasn't expired
  const refreshExpires = new Date(record.refresh_token_expires_at).getTime();
  if (!Number.isFinite(refreshExpires) || refreshExpires <= now.getTime()) {
    return null;
  }

  // Refresh
  const fetchFn: typeof fetch = dependencies.fetch;
  const refreshResponse = await fetchFn(OAUTH_TOKEN_URL, {
    method: "POST",
    headers: {
      Accept: "application/json",
      "Content-Type": "application/json",
      "User-Agent": "diatreme-broker"
    },
    body: JSON.stringify({
      client_id: clientId,
      client_secret: clientSecret,
      grant_type: "refresh_token",
      refresh_token: record.refresh_token
    })
  });
  if (!refreshResponse.ok) return null;
  const refreshBody = (await refreshResponse.json()) as {
    access_token?: string;
    refresh_token?: string;
    expires_in?: number;
    refresh_token_expires_in?: number;
    error?: string;
  };
  if (refreshBody.error || !refreshBody.access_token || !refreshBody.refresh_token) {
    return null;
  }

  const accessTokenExpiresAt = new Date(
    now.getTime() + (Number(refreshBody.expires_in) || 8 * 3600) * 1000
  );
  const refreshTokenExpiresAt = new Date(
    now.getTime() + (Number(refreshBody.refresh_token_expires_in) || OAUTH_REFRESH_TOKEN_TTL_SECONDS) * 1000
  );
  const updated: OAuthUserRecord = {
    refresh_token: refreshBody.refresh_token,
    refresh_token_expires_at: refreshTokenExpiresAt.toISOString(),
    access_token: refreshBody.access_token,
    access_token_expires_at: accessTokenExpiresAt.toISOString(),
    connected_at: record.connected_at,
    last_used_at: now.toISOString()
  };
  const ttlSeconds = Math.max(
    60,
    Math.floor((refreshTokenExpiresAt.getTime() - now.getTime()) / 1000)
  );
  await env.COPILOT_QUOTA_KV.put(oauthUserKey(login), JSON.stringify(updated), {
    expirationTtl: ttlSeconds
  });
  return refreshBody.access_token;
}

// Query /users/{login}/settings/billing/premium_request/usage with a
// fresh user access token. Returns a rate-limited verdict when the
// requester is over Copilot premium-request quota, false when they
// have quota remaining, or null when we can't tell (no connection,
// API failure, unexpected shape).
async function tryOAuthUserBillingLookup(
  env: BrokerEnv,
  dependencies: Dependencies,
  login: string,
  now: Date
): Promise<CopilotQuotaState | null> {
  const accessToken = await getUserAccessToken(env, dependencies, login, now);
  if (!accessToken) return null;

  const fetchFn: typeof fetch = dependencies.fetch;
  // premium_request/usage is the dedicated Copilot endpoint. Fall back
  // to the general usage endpoint if it 404s (older accounts may not
  // have the new endpoint enabled).
  const endpoints = [
    `https://api.github.com/users/${encodeURIComponent(login)}/settings/billing/premium_request/usage`,
    `https://api.github.com/users/${encodeURIComponent(login)}/settings/billing/usage`
  ];
  for (const endpoint of endpoints) {
    const response = await fetchFn(endpoint, {
      headers: {
        Accept: "application/vnd.github+json",
        Authorization: `Bearer ${accessToken}`,
        "X-GitHub-Api-Version": GITHUB_API_VERSION,
        "User-Agent": "diatreme-broker"
      }
    });
    if (response.status === 404) continue;
    if (!response.ok) continue;
    const body = (await response.json()) as unknown;
    const verdict = interpretBillingUsage(body, now);
    if (verdict) {
      return {
        ...verdict,
        source: "github-oauth-user-billing"
      };
    }
  }
  return null;
}

// ─── /oauth HTML helpers ─────────────────────────────────────────────

function escapeHtml(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

function escapeAttr(s: string): string {
  return escapeHtml(s);
}

function oauthHtmlResponse(
  title: string,
  body: string,
  status: number
): Response {
  const html = `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>${escapeHtml(title)} — Diatreme</title>
  <style>
    :root { color-scheme: light dark; }
    body { font: 15px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; max-width: 540px; margin: 4rem auto; padding: 0 1rem; }
    h1 { font-size: 1.4rem; margin-bottom: 0.5rem; }
    code { background: rgba(127,127,127,0.15); padding: 0.1rem 0.3rem; border-radius: 3px; font-size: 0.9em; }
  </style>
</head>
<body>
  <h1>${escapeHtml(title)}</h1>
  <p>${body}</p>
</body>
</html>`;
  return new Response(html, {
    status,
    headers: {
      "content-type": "text/html; charset=utf-8",
      "cache-control": "no-store"
    }
  });
}

// ─── /webhook ────────────────────────────────────────────────────────────────
// Receives GitHub webhook deliveries for the Diatreme App. We verify
// HMAC-SHA256 against GITHUB_WEBHOOK_SECRET, then accumulate per-owner
// Copilot review request/delivery timestamps in KV. The /copilot-quota GET
// path reads these as a third signal in its resolution chain.

const COPILOT_LOGIN_PATTERN = /copilot/i;
const DEFAULT_COPILOT_WEBHOOK_REVIEW_GAP_SECONDS = 30 * 60; // 30 minutes
const WEBHOOK_RETENTION_TTL_SECONDS = 24 * 60 * 60; // 24h is plenty for the heuristic

interface CopilotWebhookRecord {
  last_request_at?: string;
  last_review_at?: string;
  recent_request_count?: number;
}

async function handleWebhookRequest(
  request: Request,
  env: BrokerEnv,
  dependencies: Dependencies
): Promise<Response> {
  if (request.method !== "POST") {
    return jsonError(405, "method_not_allowed");
  }

  const secret = env.GITHUB_WEBHOOK_SECRET;
  if (!secret || secret.trim() === "") {
    return jsonError(503, "webhook_disabled");
  }

  const signature = request.headers.get("x-hub-signature-256") ?? "";
  const event = request.headers.get("x-github-event") ?? "";
  const rawBody = await request.text();

  if (!(await verifyWebhookSignature(secret, rawBody, signature))) {
    return jsonError(401, "invalid_signature");
  }

  // Only the events we care about; everything else is acknowledged so
  // GitHub stops retrying, but doesn't touch state.
  if (
    event !== "push" &&
    event !== "pull_request" &&
    event !== "pull_request_review" &&
    event !== "pull_request_review_comment"
  ) {
    return json({ ok: true, ignored: event }, 200);
  }

  let payload: unknown;
  try {
    payload = JSON.parse(rawBody);
  } catch {
    return jsonError(400, "invalid_json");
  }
  if (!isRecord(payload)) {
    return jsonError(400, "invalid_request");
  }

  // pull_request_review_comment → Copilot comment triage. Independent of the
  // Copilot-quota KV signal handled below.
  if (event === "push") {
    return await handlePushEvent(payload, env, dependencies);
  }
  if (event === "pull_request_review_comment") {
    return await handleReviewCommentEvent(payload, env, dependencies);
  }

  const owner = extractOwnerFromWebhook(payload);
  if (!owner) {
    return json({ ok: true, no_owner: true }, 200);
  }

  if (!env.COPILOT_QUOTA_KV) {
    // Nowhere to persist the signal — acknowledge the delivery so
    // GitHub doesn't keep retrying.
    return json({ ok: true, kv: "absent" }, 200);
  }

  const now = dependencies.now();
  let touched = false;

  if (event === "pull_request") {
    const action = asString(payload.action);
    if (action === "review_requested" && isCopilotReviewerEvent(payload)) {
      await bumpWebhookRecord(env.COPILOT_QUOTA_KV, owner, now, "request");
      touched = true;
    }
  } else if (event === "pull_request_review") {
    const action = asString(payload.action);
    if (action === "submitted" && isCopilotReviewSubmission(payload)) {
      await bumpWebhookRecord(env.COPILOT_QUOTA_KV, owner, now, "review");
      touched = true;
    }
  }

  return json({ ok: true, owner, touched }, 200);
}

function extractOwnerFromWebhook(payload: Record<string, unknown>): string | null {
  // Both pull_request and pull_request_review events carry the same
  // repository.owner.login structure.
  const repo = payload.repository;
  if (!isRecord(repo)) return null;
  const ownerObj = repo.owner;
  if (!isRecord(ownerObj)) return null;
  const login = asString(ownerObj.login);
  if (!login) return null;
  try {
    assertOwnerName(login);
  } catch {
    return null;
  }
  return login;
}

function isCopilotReviewerEvent(payload: Record<string, unknown>): boolean {
  const reviewer = payload.requested_reviewer;
  if (isRecord(reviewer)) {
    const login = asString(reviewer.login);
    if (login && COPILOT_LOGIN_PATTERN.test(login)) return true;
  }
  // Some payload shapes embed the array of all reviewers; the
  // most recently requested one is normally on `requested_reviewer`
  // but we accept either source as a positive.
  const pr = payload.pull_request;
  if (isRecord(pr) && Array.isArray(pr.requested_reviewers)) {
    for (const entry of pr.requested_reviewers) {
      if (isRecord(entry)) {
        const login = asString(entry.login);
        if (login && COPILOT_LOGIN_PATTERN.test(login)) return true;
      }
    }
  }
  return false;
}

function isCopilotReviewSubmission(payload: Record<string, unknown>): boolean {
  const review = payload.review;
  if (!isRecord(review)) return false;
  const user = review.user;
  if (!isRecord(user)) return false;
  const login = asString(user.login);
  return !!login && COPILOT_LOGIN_PATTERN.test(login);
}

async function bumpWebhookRecord(
  kv: KVNamespace,
  owner: string,
  now: Date,
  kind: "request" | "review"
): Promise<void> {
  const key = webhookKey(owner);
  const existing = (await readWebhookRecord(kv, owner)) ?? {};
  const updated: CopilotWebhookRecord = {
    ...existing
  };
  if (kind === "request") {
    updated.last_request_at = now.toISOString();
    updated.recent_request_count = (existing.recent_request_count ?? 0) + 1;
  } else {
    updated.last_review_at = now.toISOString();
    // A delivered review clears the backlog signal — Copilot is alive.
    updated.recent_request_count = 0;
  }
  await kv.put(key, JSON.stringify(updated), {
    expirationTtl: WEBHOOK_RETENTION_TTL_SECONDS
  });
}

async function readWebhookRecord(
  kv: KVNamespace,
  owner: string
): Promise<CopilotWebhookRecord | null> {
  const raw = await kv.get(webhookKey(owner));
  if (!raw) return null;
  try {
    const parsed = JSON.parse(raw);
    if (isRecord(parsed)) return parsed as CopilotWebhookRecord;
  } catch {
    // ignore
  }
  return null;
}

function webhookKey(owner: string): string {
  return `copilot-quota:webhook:${owner.toLowerCase()}`;
}

async function verifyWebhookSignature(
  secret: string,
  body: string,
  signatureHeader: string
): Promise<boolean> {
  if (!signatureHeader.startsWith("sha256=")) return false;
  const provided = signatureHeader.slice("sha256=".length);
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const mac = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(body));
  const expected = Array.from(new Uint8Array(mac))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
  return constantTimeEquals(provided, expected);
}

function constantTimeEquals(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let mismatch = 0;
  for (let i = 0; i < a.length; i++) {
    mismatch |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return mismatch === 0;
}

// ─── Copilot comment triage ──────────────────────────────────────────────────
// On a Copilot `pull_request_review_comment`, classify it (fix | dismiss | skip)
// with a bring-your-own-key LLM, then act: `dismiss` resolves the review thread
// via GraphQL; `skip` is a no-op; `fix` is recognised but deferred until the
// signing/dispatch path lands. No LLM key ⇒ triage is disabled (no free AI).
// Classifier is provider-agnostic: anthropic (Messages API) or any
// OpenAI-compatible endpoint (OpenAI, DeepSeek, OpenRouter) via base URL.

type TriageDecision = "fix" | "dismiss" | "skip";

const DEFAULT_ANTHROPIC_MODEL = "claude-haiku-4-5";
const ANTHROPIC_API_URL = "https://api.anthropic.com/v1/messages";
const ANTHROPIC_VERSION = "2023-06-01";
const GITHUB_GRAPHQL_URL = "https://api.github.com/graphql";

const TRIAGE_SYSTEM_PROMPT =
  "You triage GitHub Copilot pull request review comments. For the comment, decide:\n" +
  '- "fix": it identifies a real, actionable problem that should be changed in code.\n' +
  '- "dismiss": it is wrong, not applicable, or a false positive.\n' +
  '- "skip": you cannot decide from the provided context alone.\n' +
  'Respond with ONLY a JSON object: {"decision":"fix|dismiss|skip","reason":"<short>"}.';

type TriageConfig =
  | { kind: "anthropic"; apiKey: string; model: string }
  | { kind: "openai"; apiKey: string; model: string; baseUrl: string };

function resolveTriageConfig(env: BrokerEnv): TriageConfig | null {
  const apiKey = env.TRIAGE_LLM_API_KEY?.trim();
  if (!apiKey) return null; // bring-your-own-key: no key ⇒ triage disabled.

  const provider = (env.TRIAGE_LLM_PROVIDER ?? "anthropic").trim().toLowerCase();
  const model = env.TRIAGE_LLM_MODEL?.trim();

  if (provider === "anthropic" || provider === "") {
    return { kind: "anthropic", apiKey, model: model || DEFAULT_ANTHROPIC_MODEL };
  }

  // Everything else is OpenAI-compatible — same /chat/completions shape,
  // differing only by base URL and model.
  const baseUrl =
    env.TRIAGE_LLM_BASE_URL?.trim() ||
    (provider === "deepseek"
      ? "https://api.deepseek.com/v1"
      : provider === "openrouter"
        ? "https://openrouter.ai/api/v1"
        : "https://api.openai.com/v1");
  const defaultModel =
    provider === "deepseek"
      ? "deepseek-chat"
      : provider === "openai"
        ? "gpt-4o-mini"
        : "";
  return { kind: "openai", apiKey, model: model || defaultModel, baseUrl };
}

const DEFAULT_TRUSTED_ASSOCIATIONS = ["OWNER", "MEMBER", "COLLABORATOR"];

// Whether a PR author is trusted enough for automatic triage. An explicit
// TRIAGE_TRUSTED_USERS login allowlist wins; otherwise the author's
// repo association must be in the trusted set (default OWNER/MEMBER/COLLABORATOR).
function isTrustedAuthor(
  association: string | undefined,
  login: string | undefined,
  env: BrokerEnv
): boolean {
  const allowlist = (env.TRIAGE_TRUSTED_USERS ?? "")
    .split(",")
    .map((entry) => entry.trim().toLowerCase())
    .filter(Boolean);
  if (login && allowlist.includes(login.toLowerCase())) return true;

  const configured = (env.TRIAGE_TRUSTED_ASSOCIATIONS ?? "")
    .split(",")
    .map((entry) => entry.trim().toUpperCase())
    .filter(Boolean);
  const trusted =
    configured.length > 0 ? configured : DEFAULT_TRUSTED_ASSOCIATIONS;
  return !!association && trusted.includes(association.toUpperCase());
}

async function handleReviewCommentEvent(
  payload: Record<string, unknown>,
  env: BrokerEnv,
  dependencies: Dependencies
): Promise<Response> {
  const config = resolveTriageConfig(env);
  if (!config) {
    return json({ ok: true, triage: "disabled" }, 200);
  }
  if (!config.model) {
    return json({ ok: true, triage: "no_model" }, 200);
  }

  if (asString(payload.action) !== "created") {
    return json(
      { ok: true, ignored_action: asString(payload.action) ?? null },
      200
    );
  }

  const comment = payload.comment;
  if (!isRecord(comment)) {
    return json({ ok: true, no_comment: true }, 200);
  }

  const author = isRecord(comment.user) ? asString(comment.user.login) : undefined;
  if (!author || !COPILOT_LOGIN_PATTERN.test(author)) {
    return json({ ok: true, not_copilot: true }, 200);
  }

  const repo = extractRepoFromWebhook(payload);
  const pr = isRecord(payload.pull_request) ? payload.pull_request : null;
  const prNumber = pr && typeof pr.number === "number" ? pr.number : null;
  const commentId = typeof comment.id === "number" ? comment.id : null;
  const body = asString(comment.body) ?? "";
  if (!repo || prNumber === null || commentId === null) {
    return json({ ok: true, incomplete: true }, 200);
  }

  // Trusted-author gate: only auto-triage PRs opened by trusted authors, so a
  // random contributor's PR can't drive auto-dismiss (or, later, auto-fix).
  // The manual POST /process bypasses this — it's an explicit operator action.
  const prAuthor = pr && isRecord(pr.user) ? asString(pr.user.login) : undefined;
  const association = pr ? asString(pr.author_association) : undefined;
  if (!isTrustedAuthor(association, prAuthor, env)) {
    return json({ ok: true, skipped: "untrusted_author" }, 200);
  }

  if (!env.GITHUB_APP_ID || !env.GITHUB_APP_PRIVATE_KEY) {
    return json({ ok: true, app: "unconfigured" }, 200);
  }

  try {
    const decision = await classifyComment(dependencies.fetch, config, body, {
      path: asString(comment.path),
      diffHunk: asString(comment.diff_hunk)
    });

    if (decision === "dismiss") {
      const token = await mintInstallationToken(
        env,
        dependencies,
        repo.owner,
        repo.repo
      );
      const dismissed = await dismissReviewComment(
        dependencies.fetch,
        token,
        repo.owner,
        repo.repo,
        prNumber,
        commentId
      );
      return json({ ok: true, decision, dismissed }, 200);
    }

    // "skip" is a no-op; "fix" enqueues an autonomous dispatch (and starts a
    // Claude Code Web session when DISPATCH_TRIGGER_URL is configured).
    if (decision === "fix") {
      const dispatched = await enqueueDispatch(env, dependencies, {
        repo: `${repo.owner}/${repo.repo}`,
        pr: prNumber,
        instruction:
          `Address this Copilot review comment on ` +
          `${repo.owner}/${repo.repo}#${prNumber}` +
          (asString(comment.path) ? ` (${asString(comment.path)})` : "") +
          `: ${body}`,
        user: prAuthor,
        source: "triage"
      });
      return json({ ok: true, decision, action: "dispatched", ...dispatched }, 200);
    }
    return json({ ok: true, decision, action: "none" }, 200);
  } catch (error) {
    const code = error instanceof HttpError ? error.code : "triage_failed";
    return json({ ok: true, error: code }, 200);
  }
}

async function classifyComment(
  doFetch: typeof fetch,
  config: TriageConfig,
  comment: string,
  context: { path?: string; diffHunk?: string }
): Promise<TriageDecision> {
  const user = buildTriageUserMessage(comment, context);
  const text =
    config.kind === "anthropic"
      ? await callAnthropic(doFetch, config, TRIAGE_SYSTEM_PROMPT, user)
      : await callOpenAiCompatible(doFetch, config, TRIAGE_SYSTEM_PROMPT, user);
  return parseDecision(text);
}

function buildTriageUserMessage(
  comment: string,
  context: { path?: string; diffHunk?: string }
): string {
  const parts: string[] = [];
  if (context.path) parts.push(`File: ${context.path}`);
  if (context.diffHunk) parts.push(`Diff hunk:\n${context.diffHunk}`);
  parts.push(`Copilot review comment:\n${comment}`);
  return parts.join("\n\n");
}

async function callAnthropic(
  doFetch: typeof fetch,
  config: { apiKey: string; model: string },
  system: string,
  user: string
): Promise<string> {
  const response = await doFetch(ANTHROPIC_API_URL, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-api-key": config.apiKey,
      "anthropic-version": ANTHROPIC_VERSION
    },
    body: JSON.stringify({
      model: config.model,
      max_tokens: 256,
      system,
      messages: [{ role: "user", content: user }]
    })
  });
  if (!response.ok) throw new HttpError(502, "triage_llm_failed");
  const body = await response.json();
  if (isRecord(body) && Array.isArray(body.content)) {
    for (const block of body.content) {
      if (isRecord(block) && block.type === "text") {
        const text = asString(block.text);
        if (text) return text;
      }
    }
  }
  throw new HttpError(502, "triage_llm_bad_response");
}

async function callOpenAiCompatible(
  doFetch: typeof fetch,
  config: { apiKey: string; model: string; baseUrl: string },
  system: string,
  user: string
): Promise<string> {
  let base = config.baseUrl;
  while (base.endsWith("/")) base = base.slice(0, -1);
  const url = `${base}/chat/completions`;
  const response = await doFetch(url, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      authorization: `Bearer ${config.apiKey}`
    },
    body: JSON.stringify({
      model: config.model,
      max_tokens: 256,
      messages: [
        { role: "system", content: system },
        { role: "user", content: user }
      ]
    })
  });
  if (!response.ok) throw new HttpError(502, "triage_llm_failed");
  const body = await response.json();
  if (isRecord(body) && Array.isArray(body.choices) && body.choices.length > 0) {
    const choice = body.choices[0];
    if (isRecord(choice) && isRecord(choice.message)) {
      const content = asString(choice.message.content);
      if (content) return content;
    }
  }
  throw new HttpError(502, "triage_llm_bad_response");
}

function parseDecision(text: string): TriageDecision {
  const jsonMatch = text.match(/\{[\s\S]*\}/);
  if (jsonMatch) {
    try {
      const parsed = JSON.parse(jsonMatch[0]);
      if (isRecord(parsed)) {
        const decision = asString(parsed.decision)?.toLowerCase();
        if (decision === "fix" || decision === "dismiss" || decision === "skip") {
          return decision;
        }
      }
    } catch {
      // fall through to keyword scan
    }
  }
  const match = text.toLowerCase().match(/\b(fix|dismiss|skip)\b/);
  if (match) return match[1] as TriageDecision;
  return "skip";
}

async function mintInstallationToken(
  env: BrokerEnv,
  dependencies: Dependencies,
  owner: string,
  repo: string
): Promise<string> {
  const appJwt = await dependencies.createGitHubAppJwt(
    requiredSecret(env.GITHUB_APP_ID, "GITHUB_APP_ID"),
    requiredSecret(env.GITHUB_APP_PRIVATE_KEY, "GITHUB_APP_PRIVATE_KEY"),
    dependencies.now()
  );
  const installationId = await findInstallationId(
    dependencies.fetch,
    appJwt,
    owner,
    repo
  );
  const { token } = await createInstallationToken(
    dependencies.fetch,
    appJwt,
    installationId,
    repo,
    DEFAULT_PERMISSIONS
  );
  return token;
}

interface TriageRepoRef {
  owner: string;
  repo: string;
}

function extractRepoFromWebhook(
  payload: Record<string, unknown>
): TriageRepoRef | null {
  const repository = payload.repository;
  if (!isRecord(repository)) return null;
  const ownerObj = repository.owner;
  if (!isRecord(ownerObj)) return null;
  const owner = asString(ownerObj.login) ?? asString(ownerObj.name);
  const repo = asString(repository.name);
  if (!owner || !repo) return null;
  try {
    assertRepositoryParts(owner, repo);
  } catch {
    return null;
  }
  return { owner, repo };
}

async function dismissReviewComment(
  doFetch: typeof fetch,
  token: string,
  owner: string,
  repo: string,
  prNumber: number,
  commentDatabaseId: number
): Promise<boolean> {
  const query =
    "query($owner:String!,$repo:String!,$pr:Int!){" +
    "repository(owner:$owner,name:$repo){pullRequest(number:$pr){" +
    "reviewThreads(first:100){nodes{id isResolved " +
    "comments(first:100){nodes{databaseId}}}}}}}";
  const data = await githubGraphql(doFetch, token, query, {
    owner,
    repo,
    pr: prNumber
  });
  const threadId = findThreadIdForComment(data, commentDatabaseId);
  if (!threadId) return false;

  const mutation =
    "mutation($id:ID!){resolveReviewThread(input:{threadId:$id}){thread{isResolved}}}";
  const result = await githubGraphql(doFetch, token, mutation, { id: threadId });
  const resolved = isRecord(result.resolveReviewThread)
    ? result.resolveReviewThread
    : null;
  const thread = resolved && isRecord(resolved.thread) ? resolved.thread : null;
  return thread?.isResolved === true;
}

function findThreadIdForComment(
  data: Record<string, unknown>,
  commentDatabaseId: number
): string | null {
  const repository = isRecord(data.repository) ? data.repository : null;
  const pullRequest =
    repository && isRecord(repository.pullRequest)
      ? repository.pullRequest
      : null;
  const reviewThreads =
    pullRequest && isRecord(pullRequest.reviewThreads)
      ? pullRequest.reviewThreads
      : null;
  const nodes =
    reviewThreads && Array.isArray(reviewThreads.nodes)
      ? reviewThreads.nodes
      : [];
  for (const node of nodes) {
    if (!isRecord(node)) continue;
    const comments =
      isRecord(node.comments) && Array.isArray(node.comments.nodes)
        ? node.comments.nodes
        : [];
    for (const comment of comments) {
      if (isRecord(comment) && comment.databaseId === commentDatabaseId) {
        const id = asString(node.id);
        if (id) return id;
      }
    }
  }
  return null;
}

async function githubGraphql(
  doFetch: typeof fetch,
  token: string,
  query: string,
  variables: Record<string, unknown>
): Promise<Record<string, unknown>> {
  const response = await doFetch(GITHUB_GRAPHQL_URL, {
    method: "POST",
    headers: {
      ...githubHeaders(token),
      "content-type": "application/json"
    },
    body: JSON.stringify({ query, variables })
  });
  if (!response.ok) throw new HttpError(502, "github_graphql_failed");
  const body = await response.json();
  if (!isRecord(body) || !isRecord(body.data)) {
    throw new HttpError(502, "github_graphql_failed");
  }
  return body.data;
}

// ─── POST /process ───────────────────────────────────────────────────────────
// Manual re-walk of a pull request's Copilot review comments — the surface the
// Diatreme Pro dashboard calls. Bearer-gated (PROCESS_TRIGGER_SECRET). Reuses the
// same classify/dismiss logic as the webhook triage path, but processes every
// Copilot comment on the PR rather than reacting to a single delivery.

interface ProcessTarget {
  owner: string;
  repo: string;
  pullNumber: number;
}

interface ReviewComment {
  id: number;
  body: string;
  path?: string;
  diffHunk?: string;
  isCopilot: boolean;
}

async function handleProcessRequest(
  request: Request,
  env: BrokerEnv,
  dependencies: Dependencies
): Promise<Response> {
  if (request.method !== "POST") {
    return jsonError(405, "method_not_allowed");
  }

  const secret = env.PROCESS_TRIGGER_SECRET;
  if (!secret || secret.trim() === "") {
    return jsonError(503, "process_disabled");
  }
  const authorization = request.headers.get("authorization") ?? "";
  const provided = authorization.startsWith("Bearer ")
    ? authorization.slice("Bearer ".length)
    : "";
  if (!constantTimeEquals(provided, secret)) {
    return jsonError(401, "unauthorized");
  }

  const target = await readProcessTarget(request);

  const config = resolveTriageConfig(env);
  if (!config || !config.model) {
    return json({ ok: true, triage: "disabled" }, 200);
  }
  if (!env.GITHUB_APP_ID || !env.GITHUB_APP_PRIVATE_KEY) {
    return jsonError(503, "app_unconfigured");
  }

  const token = await mintInstallationToken(
    env,
    dependencies,
    target.owner,
    target.repo
  );
  const comments = await listReviewComments(
    dependencies.fetch,
    token,
    target.owner,
    target.repo,
    target.pullNumber
  );

  const counts = { fix: 0, dismiss: 0, skip: 0 };
  const results: {
    comment_id: number;
    decision: TriageDecision;
    dismissed?: boolean;
  }[] = [];

  for (const comment of comments) {
    if (!comment.isCopilot) continue;
    const decision = await classifyComment(
      dependencies.fetch,
      config,
      comment.body,
      { path: comment.path, diffHunk: comment.diffHunk }
    );
    counts[decision] += 1;
    if (decision === "dismiss") {
      const dismissed = await dismissReviewComment(
        dependencies.fetch,
        token,
        target.owner,
        target.repo,
        target.pullNumber,
        comment.id
      );
      results.push({ comment_id: comment.id, decision, dismissed });
    } else {
      results.push({ comment_id: comment.id, decision });
    }
  }

  return json(
    { ok: true, pull: target.pullNumber, processed: results.length, counts, results },
    200
  );
}

async function readProcessTarget(request: Request): Promise<ProcessTarget> {
  let value: unknown;
  try {
    value = await request.json();
  } catch {
    throw new HttpError(400, "invalid_json");
  }
  if (!isRecord(value)) {
    throw new HttpError(400, "invalid_request");
  }

  const prUrl = asString(value.pr_url);
  if (prUrl) {
    const match = prUrl.match(/github\.com\/([^/]+)\/([^/]+)\/pull\/(\d+)/);
    if (!match) {
      throw new HttpError(400, "invalid_pr_url");
    }
    const owner = match[1];
    const repo = match[2];
    assertRepositoryParts(owner, repo);
    return { owner, repo, pullNumber: Number(match[3]) };
  }

  const owner = asString(value.owner);
  const repo = asString(value.repo);
  const pullNumber = value.pull_number;
  if (!owner || !repo || typeof pullNumber !== "number") {
    throw new HttpError(400, "missing_required_fields");
  }
  assertRepositoryParts(owner, repo);
  return { owner, repo, pullNumber };
}

async function listReviewComments(
  doFetch: typeof fetch,
  token: string,
  owner: string,
  repo: string,
  pullNumber: number
): Promise<ReviewComment[]> {
  const url =
    `https://api.github.com/repos/${encodeURIComponent(owner)}/` +
    `${encodeURIComponent(repo)}/pulls/${pullNumber}/comments?per_page=100`;
  const response = await doFetch(url, { headers: githubHeaders(token) });
  if (!response.ok) {
    throw new HttpError(502, "github_pull_comments_failed");
  }
  const body = await response.json();
  if (!Array.isArray(body)) return [];
  const comments: ReviewComment[] = [];
  for (const entry of body) {
    if (!isRecord(entry)) continue;
    if (typeof entry.id !== "number") continue;
    const author = isRecord(entry.user) ? asString(entry.user.login) : undefined;
    comments.push({
      id: entry.id,
      body: asString(entry.body) ?? "",
      path: asString(entry.path),
      diffHunk: asString(entry.diff_hunk),
      isCopilot: !!author && COPILOT_LOGIN_PATTERN.test(author)
    });
  }
  return comments;
}

async function webhookSignalForOwner(
  env: BrokerEnv,
  owner: string,
  now: Date
): Promise<CopilotQuotaState | null> {
  if (!env.COPILOT_QUOTA_KV) return null;
  const record = await readWebhookRecord(env.COPILOT_QUOTA_KV, owner);
  if (!record) return null;

  const gapSeconds = Math.max(
    60,
    Number(env.COPILOT_WEBHOOK_REVIEW_GAP_SECONDS) ||
      DEFAULT_COPILOT_WEBHOOK_REVIEW_GAP_SECONDS
  );

  const lastRequestAt = record.last_request_at
    ? new Date(record.last_request_at)
    : null;
  const lastReviewAt = record.last_review_at
    ? new Date(record.last_review_at)
    : null;

  // No outstanding requests at all — no negative signal to share.
  if (!lastRequestAt || Number.isNaN(lastRequestAt.getTime())) return null;

  // A recent Copilot review delivery shows the service is responsive.
  if (lastReviewAt && !Number.isNaN(lastReviewAt.getTime())) {
    if (lastReviewAt.getTime() >= lastRequestAt.getTime() - 60 * 1000) {
      return null;
    }
  }

  const requestAgeSeconds = (now.getTime() - lastRequestAt.getTime()) / 1000;
  // Newly-pending request — give Copilot a beat before crying "rate-limited".
  if (requestAgeSeconds < gapSeconds) return null;

  return {
    rate_limited: true,
    source: "github-webhook",
    checked_at: now.toISOString(),
    detail:
      `Copilot review last requested at ${record.last_request_at}; ` +
      `last delivered review at ${record.last_review_at ?? "never"}. ` +
      `Gap exceeds ${gapSeconds}s threshold.`
  };
}

// ─── Cron-driven refresh ─────────────────────────────────────────────────────
// Iterates owners that have any record in KV (manual, billing cache, or
// webhook signal) and refreshes the billing/metrics view. Owners we've
// never heard of are out of scope — we don't enumerate all installations
// because Apps installed on millions of orgs would blow Worker CPU
// limits. The first GET for an owner seeds the cache; cron keeps it warm.

const SCHEDULED_REFRESH_LIMIT = 50;

export async function handleScheduledRefresh(
  env: BrokerEnv,
  dependencies: Dependencies
): Promise<void> {
  if (!env.COPILOT_QUOTA_KV) return;
  const seen = new Set<string>();
  const owners: string[] = [];
  let cursor: string | undefined;
  do {
    const page: KVNamespaceListResult<unknown, string> =
      await env.COPILOT_QUOTA_KV.list({ prefix: "copilot-quota:", cursor });
    for (const key of page.keys) {
      // key.name looks like copilot-quota:<kind>:<owner>
      const parts = key.name.split(":");
      if (parts.length < 3) continue;
      const owner = parts.slice(2).join(":");
      if (!owner) continue;
      try {
        assertOwnerName(owner);
      } catch {
        continue;
      }
      if (seen.has(owner)) continue;
      seen.add(owner);
      owners.push(owner);
      if (owners.length >= SCHEDULED_REFRESH_LIMIT) break;
    }
    if (owners.length >= SCHEDULED_REFRESH_LIMIT) break;
    cursor = "list_complete" in page && page.list_complete ? undefined : page.cursor;
  } while (cursor);

  const now = dependencies.now();
  for (const owner of owners) {
    try {
      const fresh = await performBillingApiLookup(env, dependencies, owner, now);
      if (fresh && env.COPILOT_QUOTA_KV) {
        const ttl = Math.max(
          60,
          Number(env.COPILOT_QUOTA_CACHE_TTL_SECONDS) ||
            COPILOT_QUOTA_DEFAULT_CACHE_TTL_SECONDS
        );
        await env.COPILOT_QUOTA_KV.put(
          billingCacheKey(owner),
          JSON.stringify(fresh),
          { expirationTtl: ttl }
        );
      }
    } catch {
      // Skip individual failures; cron will try again next tick.
    }
  }
}

// ─── Copilot Metrics API fallback ────────────────────────────────────────────
// When billing usage doesn't reveal an exhausted quota, fall through to
// the metrics reports. Heuristic: if the owner has had recent Copilot
// PR review request webhook events AND the metrics show zero Copilot
// review activity for the last day, infer rate-limited.

async function tryMetricsApiLookup(
  env: BrokerEnv,
  dependencies: Dependencies,
  owner: string,
  now: Date
): Promise<CopilotQuotaState | null> {
  const appId = env.GITHUB_APP_ID;
  const privateKey = env.GITHUB_APP_PRIVATE_KEY;
  if (!appId || !privateKey) return null;

  // See performBillingApiLookup — calling `dependencies.fetch(...)`
  // directly binds `this=dependencies` and Cloudflare's native fetch
  // rejects with "Illegal invocation". Extract to a local first.
  const fetchFn: typeof fetch = dependencies.fetch;

  let appJwt: string;
  try {
    appJwt = await dependencies.createGitHubAppJwt(appId, privateKey, now);
  } catch {
    return null;
  }

  const installationId = await findInstallationIdForOwner(
    fetchFn,
    appJwt,
    owner
  );
  if (installationId === null) return null;

  const tokenResponse = await fetchFn(
    `https://api.github.com/app/installations/${installationId}/access_tokens`,
    {
      method: "POST",
      headers: githubHeaders(appJwt)
    }
  );
  if (!tokenResponse.ok) return null;
  const tokenBody = (await tokenResponse.json()) as { token?: string };
  if (!tokenBody.token) return null;

  const endpoints = [
    `https://api.github.com/orgs/${encodeURIComponent(owner)}/copilot/metrics`,
    `https://api.github.com/users/${encodeURIComponent(owner)}/copilot/metrics`
  ];

  for (const endpoint of endpoints) {
    const response = await fetchFn(endpoint, {
      headers: {
        Accept: "application/vnd.github+json",
        Authorization: `Bearer ${tokenBody.token}`,
        "X-GitHub-Api-Version": GITHUB_API_VERSION,
        "User-Agent": "diatreme-broker"
      }
    });
    if (response.status === 404) continue;
    if (!response.ok) continue;

    const body = (await response.json()) as unknown;
    const verdict = interpretMetricsResponse(body, now);
    if (verdict) return verdict;
  }
  return null;
}

function interpretMetricsResponse(
  body: unknown,
  now: Date
): CopilotQuotaState | null {
  // The metrics API returns a daily report array. We look for the most
  // recent day's `copilot_ide_code_completions` / `copilot_dotcom_chat`
  // / `copilot_dotcom_pull_requests` blocks. If `total_engaged_users` is
  // zero (or the block is missing) for the latest day AND the second-
  // most-recent day shows non-zero activity, treat as a sudden drop —
  // potential rate limit. This is a weak signal on its own, so we mark
  // it as `metrics-heuristic` so the action knows to weigh it.
  if (!Array.isArray(body) || body.length === 0) return null;
  const sorted = [...body]
    .filter((entry) => isRecord(entry) && typeof entry.date === "string")
    .sort((a, b) =>
      String((a as Record<string, unknown>).date).localeCompare(
        String((b as Record<string, unknown>).date)
      )
    );
  if (sorted.length < 2) return null;

  const latest = sorted[sorted.length - 1] as Record<string, unknown>;
  const prior = sorted[sorted.length - 2] as Record<string, unknown>;

  const latestActive = totalEngagedUsers(latest);
  const priorActive = totalEngagedUsers(prior);

  if (latestActive > 0 || priorActive === 0) return null;

  return {
    rate_limited: true,
    source: "github-copilot-metrics",
    checked_at: now.toISOString(),
    detail:
      `Copilot metrics show 0 engaged users on ${String(latest.date)} ` +
      `after ${priorActive} on ${String(prior.date)}.`
  };
}

function totalEngagedUsers(day: Record<string, unknown>): number {
  const direct = Number(day.total_engaged_users ?? day.totalEngagedUsers);
  if (Number.isFinite(direct)) return direct;
  // Sum across feature blocks (completions, chat, PR review, etc.).
  let total = 0;
  for (const value of Object.values(day)) {
    if (isRecord(value)) {
      const sub = Number(
        value.total_engaged_users ?? value.totalEngagedUsers ?? 0
      );
      if (Number.isFinite(sub)) total += sub;
    }
  }
  return total;
}

async function readTokenRequest(request: Request): Promise<TokenRequest> {
  let value: unknown;
  try {
    value = await request.json();
  } catch {
    throw new HttpError(400, "invalid_json");
  }

  if (!isRecord(value)) {
    throw new HttpError(400, "invalid_request");
  }

  const oidcToken = asString(value.oidcToken);
  const owner = asString(value.owner);
  const repo = asString(value.repo);

  if (!oidcToken || !owner || !repo) {
    throw new HttpError(400, "missing_required_fields");
  }

  return {
    oidcToken,
    owner,
    repo,
    ref: asString(value.ref),
    runId: asString(value.runId),
    sha: asString(value.sha)
  };
}

async function verifyOidc(
  token: string,
  audience: string | string[],
  deps: Dependencies
): Promise<VerifiedOidcPayload> {
  try {
    return await deps.verifyOidcToken(token, audience);
  } catch {
    throw new OidcVerificationError();
  }
}

async function verifyOidcToken(
  token: string,
  audience: string | string[]
): Promise<VerifiedOidcPayload> {
  const { payload } = await jwtVerify(token, remoteJwks, {
    issuer: GITHUB_OIDC_ISSUER,
    audience
  });
  return payload;
}

async function createGitHubAppJwt(
  appId: string,
  privateKey: string,
  now: Date
): Promise<string> {
  try {
    const epochSeconds = Math.floor(now.getTime() / 1000);
    const key = await importPKCS8(normalizePrivateKey(privateKey), "RS256");

    return await new SignJWT({})
      .setProtectedHeader({ alg: "RS256", typ: "JWT" })
      .setIssuedAt(epochSeconds - 60)
      .setExpirationTime(epochSeconds + 9 * 60)
      .setIssuer(appId)
      .sign(key);
  } catch {
    throw new HttpError(500, "github_app_private_key_invalid");
  }
}

async function findInstallationId(
  githubFetch: typeof fetch,
  appJwt: string,
  owner: string,
  repo: string
): Promise<number> {
  const response = await githubFetch(
    `https://api.github.com/repos/${encodeURIComponent(owner)}/${encodeURIComponent(repo)}/installation`,
    {
      headers: githubHeaders(appJwt)
    }
  );

  if (response.status === 404) {
    throw new HttpError(404, "app_not_installed");
  }

  if (!response.ok) {
    throw new HttpError(500, "github_installation_lookup_failed");
  }

  const body = await response.json();
  if (!isRecord(body) || typeof body.id !== "number") {
    throw new HttpError(500, "github_installation_lookup_failed");
  }

  return body.id;
}

async function createInstallationToken(
  githubFetch: typeof fetch,
  appJwt: string,
  installationId: number,
  repo: string,
  permissions: TokenPermissions
): Promise<{ token: string; expires_at: string }> {
  const response = await githubFetch(
    `https://api.github.com/app/installations/${installationId}/access_tokens`,
    {
      method: "POST",
      headers: {
        ...githubHeaders(appJwt),
        "content-type": "application/json"
      },
      body: JSON.stringify({
        repositories: [repo],
        permissions
      })
    }
  );

  if (!response.ok) {
    throw new HttpError(500, "github_token_create_failed");
  }

  const body = await response.json();
  if (
    !isRecord(body) ||
    typeof body.token !== "string" ||
    typeof body.expires_at !== "string"
  ) {
    throw new HttpError(500, "github_token_create_failed");
  }

  return {
    token: body.token,
    expires_at: body.expires_at
  };
}

function githubHeaders(appJwt: string): HeadersInit {
  return {
    accept: "application/vnd.github+json",
    authorization: `Bearer ${appJwt}`,
    "user-agent": "calebsargeant-diatreme",
    "x-github-api-version": GITHUB_API_VERSION
  };
}

function parsePermissions(rawPermissions: string | undefined): TokenPermissions {
  if (!rawPermissions || rawPermissions.trim() === "") {
    return DEFAULT_PERMISSIONS;
  }

  const trimmed = rawPermissions.trim();
  const parsed = trimmed.startsWith("{")
    ? parseJsonPermissions(trimmed)
    : parseDelimitedPermissions(trimmed);

  if (Object.keys(parsed).length === 0) {
    throw new HttpError(400, "invalid_token_permissions");
  }

  return parsed;
}

function parseJsonPermissions(rawPermissions: string): TokenPermissions {
  let parsed: unknown;
  try {
    parsed = JSON.parse(rawPermissions);
  } catch {
    throw new HttpError(400, "invalid_token_permissions");
  }

  if (!isRecord(parsed)) {
    throw new HttpError(400, "invalid_token_permissions");
  }

  return normalizePermissions(parsed);
}

function parseDelimitedPermissions(rawPermissions: string): TokenPermissions {
  const permissions: Record<string, string> = {};
  for (const entry of rawPermissions.split(",")) {
    const [rawKey, rawValue] = entry.includes("=")
      ? entry.split("=", 2)
      : entry.split(":", 2);
    if (!rawKey || !rawValue) {
      throw new HttpError(400, "invalid_token_permissions");
    }
    permissions[rawKey.trim()] = rawValue.trim();
  }
  return normalizePermissions(permissions);
}

function normalizePermissions(
  permissions: Record<string, unknown>
): TokenPermissions {
  const normalized: TokenPermissions = {};
  for (const [key, value] of Object.entries(permissions)) {
    if (!/^[a-z_]+$/.test(key)) {
      throw new HttpError(400, "invalid_token_permissions");
    }
    if (value !== "read" && value !== "write") {
      throw new HttpError(400, "invalid_token_permissions");
    }
    normalized[key] = value;
  }
  return normalized;
}

function repositoryAllowed(
  repository: string,
  allowedRepositories: string | undefined
): boolean {
  if (!allowedRepositories || allowedRepositories.trim() === "") {
    return true;
  }

  return allowedRepositories
    .split(",")
    .map((entry) => entry.trim())
    .filter(Boolean)
    .includes(repository);
}

function assertRepositoryParts(owner: string, repo: string): void {
  const validPart = /^[A-Za-z0-9_.-]+$/;
  if (!validPart.test(owner) || !validPart.test(repo)) {
    throw new HttpError(400, "invalid_repository");
  }
}

function normalizePrivateKey(privateKey: string): string {
  const normalized = privateKey.replace(/\\n/g, "\n").trim();
  if (normalized.includes("-----BEGIN RSA PRIVATE KEY-----")) {
    return convertPkcs1ToPkcs8Pem(normalized);
  }
  return normalized;
}

function convertPkcs1ToPkcs8Pem(pkcs1Pem: string): string {
  const pkcs1Der = base64ToBytes(pemBody(pkcs1Pem));
  const version = der(0x02, new Uint8Array([0x00]));
  const rsaEncryptionOid = new Uint8Array([
    0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01
  ]);
  const nullParameter = new Uint8Array([0x05, 0x00]);
  const algorithmIdentifier = der(0x30, concat(rsaEncryptionOid, nullParameter));
  const privateKey = der(0x04, pkcs1Der);
  const pkcs8Der = der(0x30, concat(version, algorithmIdentifier, privateKey));
  return pem("PRIVATE KEY", pkcs8Der);
}

function pemBody(value: string): string {
  return value
    .replace(/-----BEGIN [^-]+-----/g, "")
    .replace(/-----END [^-]+-----/g, "")
    .replace(/\s+/g, "");
}

function pem(label: string, bytes: Uint8Array): string {
  const body = bytesToBase64(bytes)
    .replace(/(.{64})/g, "$1\n")
    .trim();
  return `-----BEGIN ${label}-----\n${body}\n-----END ${label}-----`;
}

function der(tag: number, content: Uint8Array): Uint8Array {
  return concat(new Uint8Array([tag]), derLength(content.length), content);
}

function derLength(length: number): Uint8Array {
  if (length < 0x80) {
    return new Uint8Array([length]);
  }

  const bytes: number[] = [];
  let value = length;
  while (value > 0) {
    bytes.unshift(value & 0xff);
    value >>= 8;
  }

  return new Uint8Array([0x80 | bytes.length, ...bytes]);
}

function base64ToBytes(value: string): Uint8Array {
  return Uint8Array.from(atob(value), (char) => char.charCodeAt(0));
}

function bytesToBase64(bytes: Uint8Array): string {
  let binary = "";
  const chunkSize = 0x8000;
  for (let index = 0; index < bytes.length; index += chunkSize) {
    binary += String.fromCharCode(...bytes.subarray(index, index + chunkSize));
  }
  return btoa(binary);
}

function concat(...arrays: Uint8Array[]): Uint8Array {
  const length = arrays.reduce((total, array) => total + array.length, 0);
  const result = new Uint8Array(length);
  let offset = 0;
  for (const array of arrays) {
    result.set(array, offset);
    offset += array.length;
  }
  return result;
}

function requiredSecret(value: string | undefined, name: string): string {
  if (!value || value.trim() === "") {
    throw new HttpError(500, `${name.toLowerCase()}_missing`);
  }
  return value;
}

function json(body: Record<string, unknown>, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "content-type": "application/json"
    }
  });
}

function jsonError(status: number, error: string): Response {
  return json({ error }, status);
}

function asString(value: unknown): string | undefined {
  return typeof value === "string" ? value : undefined;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

// ─── Auto-update branches ────────────────────────────────────────────────────
// On a push to a base branch, fast-forward every open PR that targets it via
// GitHub's "update branch" API. Opt-in through AUTO_UPDATE_BRANCHES; unset or
// falsey disables it so existing deployments are unaffected. Worker-only: the
// whole flow is GitHub REST calls — no git checkout — so it runs on the free
// (Cloudflare-Worker) tier.

const AUTO_UPDATE_MAX_PULLS = 100;

function autoUpdateEnabled(env: BrokerEnv): boolean {
  const raw = env.AUTO_UPDATE_BRANCHES;
  if (!raw) return false;
  const value = raw.trim().toLowerCase();
  return value === "1" || value === "true" || value === "yes" || value === "on";
}

interface AutoUpdateResult {
  updated: number[];
  skipped: { number: number; reason: string }[];
}

async function handlePushEvent(
  payload: Record<string, unknown>,
  env: BrokerEnv,
  dependencies: Dependencies
): Promise<Response> {
  if (!autoUpdateEnabled(env)) {
    return json({ ok: true, auto_update: "disabled" }, 200);
  }

  const ref = asString(payload.ref);
  if (!ref || !ref.startsWith("refs/heads/")) {
    return json({ ok: true, ignored_ref: ref ?? null }, 200);
  }
  if (payload.deleted === true) {
    return json({ ok: true, branch_deleted: true }, 200);
  }
  const base = ref.slice("refs/heads/".length);

  const repo = extractRepoFromWebhook(payload);
  if (!repo) {
    return json({ ok: true, no_repo: true }, 200);
  }

  if (!env.GITHUB_APP_ID || !env.GITHUB_APP_PRIVATE_KEY) {
    return json({ ok: true, app: "unconfigured" }, 200);
  }

  try {
    const result = await updateOpenPullRequestsForBase(
      env,
      dependencies,
      repo.owner,
      repo.repo,
      base
    );
    return json({ ok: true, branch: base, ...result }, 200);
  } catch (error) {
    // Acknowledge the delivery (200) so GitHub stops retrying, but surface the
    // failure code for observability.
    const code = error instanceof HttpError ? error.code : "auto_update_failed";
    return json({ ok: true, branch: base, error: code }, 200);
  }
}

async function updateOpenPullRequestsForBase(
  env: BrokerEnv,
  dependencies: Dependencies,
  owner: string,
  repo: string,
  base: string
): Promise<AutoUpdateResult> {
  const appJwt = await dependencies.createGitHubAppJwt(
    requiredSecret(env.GITHUB_APP_ID, "GITHUB_APP_ID"),
    requiredSecret(env.GITHUB_APP_PRIVATE_KEY, "GITHUB_APP_PRIVATE_KEY"),
    dependencies.now()
  );
  const installationId = await findInstallationId(
    dependencies.fetch,
    appJwt,
    owner,
    repo
  );
  const { token } = await createInstallationToken(
    dependencies.fetch,
    appJwt,
    installationId,
    repo,
    DEFAULT_PERMISSIONS
  );

  const pulls = await listOpenPullRequestsForBase(
    dependencies.fetch,
    token,
    owner,
    repo,
    base
  );

  const updated: number[] = [];
  const skipped: { number: number; reason: string }[] = [];
  for (const pullNumber of pulls) {
    const outcome = await updatePullRequestBranch(
      dependencies.fetch,
      token,
      owner,
      repo,
      pullNumber
    );
    if (outcome === "updated") {
      updated.push(pullNumber);
    } else {
      skipped.push({ number: pullNumber, reason: outcome });
    }
  }
  return { updated, skipped };
}

async function listOpenPullRequestsForBase(
  githubFetch: typeof fetch,
  token: string,
  owner: string,
  repo: string,
  base: string
): Promise<number[]> {
  const url =
    `https://api.github.com/repos/${encodeURIComponent(owner)}/` +
    `${encodeURIComponent(repo)}/pulls?state=open&base=${encodeURIComponent(base)}` +
    `&per_page=${AUTO_UPDATE_MAX_PULLS}`;
  const response = await githubFetch(url, { headers: githubHeaders(token) });
  if (!response.ok) {
    throw new HttpError(502, "github_pull_list_failed");
  }
  const body = await response.json();
  if (!Array.isArray(body)) return [];
  const numbers: number[] = [];
  for (const entry of body) {
    if (isRecord(entry) && typeof entry.number === "number") {
      numbers.push(entry.number);
    }
  }
  return numbers;
}

async function updatePullRequestBranch(
  githubFetch: typeof fetch,
  token: string,
  owner: string,
  repo: string,
  pullNumber: number
): Promise<"updated" | string> {
  const response = await githubFetch(
    `https://api.github.com/repos/${encodeURIComponent(owner)}/` +
      `${encodeURIComponent(repo)}/pulls/${pullNumber}/update-branch`,
    {
      method: "PUT",
      headers: {
        ...githubHeaders(token),
        "content-type": "application/json"
      },
      body: JSON.stringify({})
    }
  );

  if (response.status === 202) return "updated";
  // 422 → already current or not fast-forwardable (conflict / fork head).
  if (response.status === 422) return "not_updatable";
  if (response.status === 403) return "forbidden";
  return `error_${response.status}`;
}

// ─── GET /releases ───────────────────────────────────────────────────────────
// Aggregates the latest release across every repo the Diatreme GitHub App is
// installed on — the data behind the Diatreme Pro dashboard's release view.
// Bearer-gated (PROCESS_TRIGGER_SECRET, same as /process). The App private key
// never leaves the worker, so the dashboard reads releases THROUGH this
// endpoint instead of holding the key itself. KV-cached so the dashboard's
// poll stays cheap and we don't hammer the GitHub API (or the Workers
// subrequest budget). Caps are surfaced via `truncated` — never silent.

const RELEASES_CACHE_KEY = "releases:aggregate";
const RELEASES_CACHE_TTL_SECONDS = 300;
const RELEASES_MAX_INSTALLATIONS = 10;
const RELEASES_MAX_REPOS = 40;

interface RepoReleaseLatest {
  tag: string;
  name: string | null;
  published_at: string | null;
  url: string | null;
  draft: boolean;
  prerelease: boolean;
}

interface RepoRelease {
  repo: string; // owner/name
  latest: RepoReleaseLatest | null;
}

async function handleReleasesRequest(
  request: Request,
  env: BrokerEnv,
  dependencies: Dependencies
): Promise<Response> {
  if (request.method !== "GET") {
    return jsonError(405, "method_not_allowed");
  }
  const secret = env.PROCESS_TRIGGER_SECRET;
  if (!secret || secret.trim() === "") {
    return jsonError(503, "releases_disabled");
  }
  const authorization = request.headers.get("authorization") ?? "";
  const provided = authorization.startsWith("Bearer ")
    ? authorization.slice("Bearer ".length)
    : "";
  if (!constantTimeEquals(provided, secret)) {
    return jsonError(401, "unauthorized");
  }
  if (!env.GITHUB_APP_ID || !env.GITHUB_APP_PRIVATE_KEY) {
    return jsonError(503, "app_unconfigured");
  }

  // Serve from the warm cache when present.
  if (env.COPILOT_QUOTA_KV) {
    const cached = await env.COPILOT_QUOTA_KV.get(RELEASES_CACHE_KEY);
    if (cached) {
      try {
        const parsed = JSON.parse(cached);
        if (isRecord(parsed)) {
          return json({ ...parsed, cached: true }, 200);
        }
      } catch {
        // fall through and refresh
      }
    }
  }

  const result = await aggregateReleases(env, dependencies);
  if (env.COPILOT_QUOTA_KV) {
    await env.COPILOT_QUOTA_KV.put(RELEASES_CACHE_KEY, JSON.stringify(result), {
      expirationTtl: RELEASES_CACHE_TTL_SECONDS
    });
  }
  return json({ ...result, cached: false }, 200);
}

async function aggregateReleases(
  env: BrokerEnv,
  dependencies: Dependencies
): Promise<{ generated_at: string; repos: RepoRelease[]; truncated: boolean }> {
  const appJwt = await dependencies.createGitHubAppJwt(
    requiredSecret(env.GITHUB_APP_ID, "GITHUB_APP_ID"),
    requiredSecret(env.GITHUB_APP_PRIVATE_KEY, "GITHUB_APP_PRIVATE_KEY"),
    dependencies.now()
  );

  const installations = await listAppInstallations(dependencies.fetch, appJwt);
  let truncated = installations.length > RELEASES_MAX_INSTALLATIONS;
  const repos: RepoRelease[] = [];

  for (const installationId of installations.slice(0, RELEASES_MAX_INSTALLATIONS)) {
    const token = await createInstallationTokenAllRepos(
      dependencies.fetch,
      appJwt,
      installationId
    ).catch(() => null);
    if (!token) continue;
    const repoFullNames = await listInstallationRepos(
      dependencies.fetch,
      token
    ).catch(() => [] as string[]);
    for (const full of repoFullNames) {
      if (repos.length >= RELEASES_MAX_REPOS) {
        truncated = true;
        break;
      }
      const [owner, name] = full.split("/");
      if (!owner || !name) continue;
      const latest = await getLatestRelease(
        dependencies.fetch,
        token,
        owner,
        name
      ).catch(() => null);
      repos.push({ repo: full, latest });
    }
    if (repos.length >= RELEASES_MAX_REPOS) {
      truncated = true;
      break;
    }
  }

  // Newest release first; repos without a release sink to the bottom.
  repos.sort((a, b) => {
    const ta = a.latest?.published_at ? Date.parse(a.latest.published_at) : 0;
    const tb = b.latest?.published_at ? Date.parse(b.latest.published_at) : 0;
    return tb - ta;
  });

  return { generated_at: dependencies.now().toISOString(), repos, truncated };
}

async function listAppInstallations(
  githubFetch: typeof fetch,
  appJwt: string
): Promise<number[]> {
  const response = await githubFetch(
    "https://api.github.com/app/installations?per_page=100",
    { headers: githubHeaders(appJwt) }
  );
  if (!response.ok) throw new HttpError(502, "github_installations_failed");
  const body = await response.json();
  if (!Array.isArray(body)) return [];
  return body
    .filter(isRecord)
    .map((i) => i.id)
    .filter((id): id is number => typeof id === "number");
}

async function createInstallationTokenAllRepos(
  githubFetch: typeof fetch,
  appJwt: string,
  installationId: number
): Promise<string> {
  const response = await githubFetch(
    `https://api.github.com/app/installations/${installationId}/access_tokens`,
    {
      method: "POST",
      headers: { ...githubHeaders(appJwt), "content-type": "application/json" },
      // Read-only, all repos in the installation. No `repositories` field.
      body: JSON.stringify({ permissions: { contents: "read", metadata: "read" } })
    }
  );
  if (!response.ok) throw new HttpError(502, "github_token_create_failed");
  const body = await response.json();
  if (!isRecord(body) || typeof body.token !== "string") {
    throw new HttpError(502, "github_token_create_failed");
  }
  return body.token;
}

async function listInstallationRepos(
  githubFetch: typeof fetch,
  token: string
): Promise<string[]> {
  const response = await githubFetch(
    "https://api.github.com/installation/repositories?per_page=100",
    { headers: githubHeaders(token) }
  );
  if (!response.ok) throw new HttpError(502, "github_repos_failed");
  const body = await response.json();
  const list =
    isRecord(body) && Array.isArray(body.repositories) ? body.repositories : [];
  return list
    .filter(isRecord)
    .map((r) => asString(r.full_name))
    .filter((n): n is string => !!n);
}

async function getLatestRelease(
  githubFetch: typeof fetch,
  token: string,
  owner: string,
  name: string
): Promise<RepoReleaseLatest | null> {
  const response = await githubFetch(
    `https://api.github.com/repos/${encodeURIComponent(owner)}/${encodeURIComponent(name)}/releases/latest`,
    { headers: githubHeaders(token) }
  );
  if (!response.ok) return null; // 404 = no releases yet; anything else = skip
  const body = await response.json();
  if (!isRecord(body)) return null;
  return {
    tag: asString(body.tag_name) ?? "",
    name: asString(body.name) ?? null,
    published_at: asString(body.published_at) ?? null,
    url: asString(body.html_url) ?? null,
    draft: body.draft === true,
    prerelease: body.prerelease === true
  };
}

// ─── /dispatch + /sign ───────────────────────────────────────────────────────
// /dispatch enqueues an autonomous code-writing task (issue→PR, a non-trivial
// triage "fix", a Tier-2 conflict) and POSTs it to DISPATCH_TRIGGER_URL to
// start a Claude Code Web session. /sign turns a set of file changes into a
// GitHub-signed, user-attributed commit via the user's OAuth token (GraphQL
// createCommitOnBranch) — the "broker re-signs" primitive that keeps signing
// authority in the worker and the signing credential out of the Web session.
// Both Bearer-gated on PROCESS_TRIGGER_SECRET.

const DISPATCH_TASK_TTL_SECONDS = 24 * 60 * 60;
// Beta header for the Claude Code "fire a routine" API (experimental).
const ROUTINE_FIRE_BETA = "experimental-cc-routine-2026-04-01";

interface DispatchTask {
  repo: string;
  instruction: string;
  issue?: number;
  pr?: number;
  user?: string;
  source?: string;
}

function dispatchKey(id: string): string {
  return `dispatch:task:${id}`;
}

function bearerOk(request: Request, secret: string): boolean {
  const auth = request.headers.get("authorization") ?? "";
  const provided = auth.startsWith("Bearer ") ? auth.slice("Bearer ".length) : "";
  return constantTimeEquals(provided, secret);
}

interface DispatchResult {
  dispatch_id: string;
  status: string;
  session_id?: string;
  session_url?: string;
}

async function enqueueDispatch(
  env: BrokerEnv,
  dependencies: Dependencies,
  task: DispatchTask
): Promise<DispatchResult> {
  const id = crypto.randomUUID();
  const record: Record<string, unknown> = {
    id,
    ...task,
    status: "queued",
    created_at: dependencies.now().toISOString()
  };

  const persist = async () => {
    if (env.COPILOT_QUOTA_KV) {
      await env.COPILOT_QUOTA_KV.put(dispatchKey(id), JSON.stringify(record), {
        expirationTtl: DISPATCH_TASK_TTL_SECONDS
      });
    }
  };
  await persist();

  const triggerUrl = env.DISPATCH_TRIGGER_URL;
  if (!triggerUrl) {
    return {
      dispatch_id: id,
      status: env.COPILOT_QUOTA_KV ? "queued_no_trigger" : "queued_no_kv"
    };
  }

  try {
    // With a routine token, fire the Claude Code on the Web routine: POST
    // {text} + the Anthropic beta headers; the routine's saved prompt clones,
    // implements, and opens the PR. We capture the returned session id/url for
    // traceability (and to put in the eventual PR body).
    if (env.DISPATCH_ROUTINE_TOKEN) {
      const resp = await dependencies.fetch(triggerUrl, {
        method: "POST",
        headers: {
          authorization: `Bearer ${env.DISPATCH_ROUTINE_TOKEN}`,
          "anthropic-beta": ROUTINE_FIRE_BETA,
          "anthropic-version": ANTHROPIC_VERSION,
          "content-type": "application/json"
        },
        body: JSON.stringify({ text: buildDispatchBrief(id, task) })
      });
      if (!resp.ok) {
        record.status = `trigger_error_${resp.status}`;
        await persist();
        return { dispatch_id: id, status: `trigger_error_${resp.status}` };
      }
      const fired = await resp.json().catch(() => null);
      const sessionId = isRecord(fired) ? asString(fired.claude_code_session_id) : undefined;
      const sessionUrl = isRecord(fired) ? asString(fired.claude_code_session_url) : undefined;
      record.status = "triggered";
      if (sessionId) record.session_id = sessionId;
      if (sessionUrl) record.session_url = sessionUrl;
      await persist();
      return { dispatch_id: id, status: "triggered", session_id: sessionId, session_url: sessionUrl };
    }

    // No routine token → plain webhook POST (self-hosted runner).
    const resp = await dependencies.fetch(triggerUrl, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(record)
    });
    return {
      dispatch_id: id,
      status: resp.ok ? "triggered" : `trigger_error_${resp.status}`
    };
  } catch {
    return { dispatch_id: id, status: "trigger_failed" };
  }
}

// The freeform task brief handed to the routine (its saved prompt owns the
// "clone → implement → open a signed PR" mechanics; this carries the specifics).
function buildDispatchBrief(id: string, task: DispatchTask): string {
  const lines = [
    `Repository: ${task.repo}`,
    task.issue !== undefined ? `GitHub issue: #${task.issue}` : "",
    task.pr !== undefined ? `Pull request: #${task.pr}` : "",
    "",
    "Task:",
    task.instruction,
    "",
    `Diatreme dispatch id: ${id}. Include it in the pull request body when done.`
  ];
  return lines.filter((line) => line !== "").join("\n");
}

async function handleDispatchRequest(
  request: Request,
  env: BrokerEnv,
  dependencies: Dependencies
): Promise<Response> {
  if (request.method !== "POST") return jsonError(405, "method_not_allowed");
  const secret = env.PROCESS_TRIGGER_SECRET;
  if (!secret || secret.trim() === "") return jsonError(503, "dispatch_disabled");
  if (!bearerOk(request, secret)) return jsonError(401, "unauthorized");

  let value: unknown;
  try {
    value = await request.json();
  } catch {
    return jsonError(400, "invalid_json");
  }
  if (!isRecord(value)) return jsonError(400, "invalid_request");

  const repo = asString(value.repo);
  const instruction = asString(value.instruction);
  if (!repo || !instruction) return jsonError(400, "missing_required_fields");
  const [owner, name] = repo.split("/");
  if (!owner || !name) return jsonError(400, "invalid_repo");
  try {
    assertRepositoryParts(owner, name);
  } catch {
    return jsonError(400, "invalid_repo");
  }

  const result = await enqueueDispatch(env, dependencies, {
    repo,
    instruction,
    issue: typeof value.issue === "number" ? value.issue : undefined,
    pr: typeof value.pr === "number" ? value.pr : undefined,
    user: asString(value.user),
    source: asString(value.source) ?? "api"
  });
  return json({ ok: true, ...result }, 202);
}

async function handleSignRequest(
  request: Request,
  env: BrokerEnv,
  dependencies: Dependencies
): Promise<Response> {
  if (request.method !== "POST") return jsonError(405, "method_not_allowed");
  const secret = env.PROCESS_TRIGGER_SECRET;
  if (!secret || secret.trim() === "") return jsonError(503, "sign_disabled");
  if (!bearerOk(request, secret)) return jsonError(401, "unauthorized");

  let value: unknown;
  try {
    value = await request.json();
  } catch {
    return jsonError(400, "invalid_json");
  }
  if (!isRecord(value)) return jsonError(400, "invalid_request");

  const user = asString(value.user);
  const repo = asString(value.repo);
  const branch = asString(value.branch);
  const expectedHeadOid = asString(value.expected_head_oid);
  const message = isRecord(value.message) ? value.message : null;
  const headline = message ? asString(message.headline) : undefined;
  if (!user || !repo || !branch || !expectedHeadOid || !headline) {
    return jsonError(400, "missing_required_fields");
  }
  const additions = normalizeFileAdditions(value.additions);
  const deletions = normalizeFileDeletions(value.deletions);
  if (additions.length === 0 && deletions.length === 0) {
    return jsonError(400, "no_file_changes");
  }

  // The user's OAuth token makes GitHub sign the commit (web-flow GPG key) and
  // attribute it to them. null ⇒ they haven't authorised (or lack the perms).
  const token = await getUserAccessToken(env, dependencies, user, dependencies.now());
  if (!token) return jsonError(409, "user_not_connected");

  try {
    const commit = await createSignedCommitOnBranch(dependencies.fetch, token, {
      repoNameWithOwner: repo,
      branchName: branch,
      expectedHeadOid,
      headline,
      body: message ? asString(message.body) : undefined,
      additions,
      deletions
    });
    return json({ ok: true, commit }, 200);
  } catch (error) {
    if (error instanceof HttpError) return jsonError(error.status, error.code);
    return jsonError(502, "sign_failed");
  }
}

function normalizeFileAdditions(
  value: unknown
): { path: string; contents: string }[] {
  if (!Array.isArray(value)) return [];
  const out: { path: string; contents: string }[] = [];
  for (const entry of value) {
    if (!isRecord(entry)) continue;
    const path = asString(entry.path);
    const contents = asString(entry.contents); // base64
    if (path && typeof contents === "string") out.push({ path, contents });
  }
  return out;
}

function normalizeFileDeletions(value: unknown): { path: string }[] {
  if (!Array.isArray(value)) return [];
  const out: { path: string }[] = [];
  for (const entry of value) {
    if (!isRecord(entry)) continue;
    const path = asString(entry.path);
    if (path) out.push({ path });
  }
  return out;
}

async function createSignedCommitOnBranch(
  doFetch: typeof fetch,
  userToken: string,
  input: {
    repoNameWithOwner: string;
    branchName: string;
    expectedHeadOid: string;
    headline: string;
    body?: string;
    additions: { path: string; contents: string }[];
    deletions: { path: string }[];
  }
): Promise<{ oid: string; url: string | null }> {
  const mutation =
    "mutation($input: CreateCommitOnBranchInput!) {" +
    "createCommitOnBranch(input: $input) { commit { oid url } } }";
  const variables = {
    input: {
      branch: {
        repositoryNameWithOwner: input.repoNameWithOwner,
        branchName: input.branchName
      },
      expectedHeadOid: input.expectedHeadOid,
      message: { headline: input.headline, body: input.body ?? "" },
      fileChanges: { additions: input.additions, deletions: input.deletions }
    }
  };
  const response = await doFetch(GITHUB_GRAPHQL_URL, {
    method: "POST",
    headers: {
      authorization: `Bearer ${userToken}`,
      "content-type": "application/json",
      "user-agent": "calebsargeant-diatreme"
    },
    body: JSON.stringify({ query: mutation, variables })
  });
  if (!response.ok) throw new HttpError(502, "github_graphql_failed");
  const out = await response.json();
  if (!isRecord(out)) throw new HttpError(502, "github_graphql_failed");
  if (Array.isArray(out.errors) && out.errors.length > 0) {
    throw new HttpError(422, "createcommit_rejected");
  }
  const data = isRecord(out.data) ? out.data : null;
  const ccob =
    data && isRecord(data.createCommitOnBranch) ? data.createCommitOnBranch : null;
  const commit = ccob && isRecord(ccob.commit) ? ccob.commit : null;
  const oid = commit ? asString(commit.oid) : undefined;
  if (!oid) throw new HttpError(502, "createcommit_no_oid");
  return { oid, url: (commit && asString(commit.url)) ?? null };
}

