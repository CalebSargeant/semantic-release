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
const DEFAULT_AUDIENCE = "release-runner";
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
    audience: string
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

  const audience = env.OIDC_AUDIENCE || DEFAULT_AUDIENCE;
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
// allowance. The signal is consumed by release-runner's require-copilot-review
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

  // 3. User-level Billing API for the requester. GitHub tracks Copilot
  // premium-request usage at the user account level (the broker App must
  // be installed on the requester's personal account with Plan:read).
  // This is the most direct signal for individual quota exhaustion.
  let userBilling: CopilotQuotaState | null = null;
  if (requester) {
    userBilling = await tryBillingApiLookup(
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

  let appJwt: string;
  try {
    appJwt = await dependencies.createGitHubAppJwt(appId, privateKey, now);
  } catch {
    return null;
  }

  const installationId = await findInstallationIdForOwner(
    dependencies.fetch,
    appJwt,
    owner
  );
  if (installationId === null) {
    return null;
  }

  // Permissions are configured on the App itself (Plan: read or
  // Billing: read for orgs; user-level billing for user installations).
  // We request whatever the App ships with — if it has billing perms,
  // the token will carry them.
  const tokenResponse = await dependencies.fetch(
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

  // Try the org endpoint first; fall back to user endpoint. The 404 from
  // the wrong scope is harmless.
  const endpoints = [
    `https://api.github.com/orgs/${encodeURIComponent(owner)}/settings/billing/usage`,
    `https://api.github.com/users/${encodeURIComponent(owner)}/settings/billing/usage`
  ];

  for (const endpoint of endpoints) {
    const usageResponse = await dependencies.fetch(endpoint, {
      headers: {
        Accept: "application/vnd.github+json",
        Authorization: `Bearer ${tokenBody.token}`,
        "X-GitHub-Api-Version": GITHUB_API_VERSION,
        "User-Agent": "release-runner-broker"
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

// ─── /webhook ────────────────────────────────────────────────────────────────
// Receives GitHub webhook deliveries for the release-runner App. We verify
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
  if (event !== "pull_request" && event !== "pull_request_review") {
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

  let appJwt: string;
  try {
    appJwt = await dependencies.createGitHubAppJwt(appId, privateKey, now);
  } catch {
    return null;
  }

  const installationId = await findInstallationIdForOwner(
    dependencies.fetch,
    appJwt,
    owner
  );
  if (installationId === null) return null;

  const tokenResponse = await dependencies.fetch(
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
    const response = await dependencies.fetch(endpoint, {
      headers: {
        Accept: "application/vnd.github+json",
        Authorization: `Bearer ${tokenBody.token}`,
        "X-GitHub-Api-Version": GITHUB_API_VERSION,
        "User-Agent": "release-runner-broker"
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
  audience: string,
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
  audience: string
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
    "user-agent": "calebsargeant-release-runner",
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
