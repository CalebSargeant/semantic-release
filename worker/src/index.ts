import {
  SignJWT,
  createRemoteJWKSet,
  customFetch,
  decodeJwt,
  decodeProtectedHeader,
  importPKCS8,
  jwtVerify,
  type FetchImplementation,
  type JWTPayload,
  type RemoteJWKSet
} from "jose";

const GITHUB_OIDC_ISSUER = "https://token.actions.githubusercontent.com";
const GITHUB_OIDC_JWKS_URL =
  "https://token.actions.githubusercontent.com/.well-known/jwks";
const GITHUB_API_VERSION = "2022-11-28";
// Our own tag for "the JWKS subrequest itself failed". jose passes such rejections
// through unchanged and workerd does not use a distinguishable error class, so
// jwksFetch stamps this on and classifyOidcError reads it back.
const JWKS_FETCH_FAILED_CODE = "ERR_JWKS_FETCH_FAILED";
const DEFAULT_AUDIENCE = "diatreme";
// Legacy audience accepted during the release-runner → diatreme migration so
// OIDC tokens minted by older pinned action versions still verify.
const LEGACY_AUDIENCE = "release-runner";
const DEFAULT_PERMISSIONS: TokenPermissions = {
  contents: "write",
  pull_requests: "write"
};

const GITHUB_API_BASE = "https://api.github.com";

// Trim and strip trailing slashes WITHOUT a backtracking-prone regex — CodeQL
// flags /\/+$/ as a polynomial regex on (deployer-controlled) input. Used to
// normalize the GHE issuer / API-base secrets so trivial copy-paste formatting
// (trailing slash, stray whitespace/newline) doesn't break verification or URLs.
function normalizeBaseUrl(value: string): string {
  const trimmed = value.trim();
  let end = trimmed.length;
  while (end > 0 && trimmed.charCodeAt(end - 1) === 47) end--; // 47 = "/"
  return trimmed.slice(0, end);
}

// jose issues the JWKS subrequest with no cache directives, and GitHub serves its
// key set with a long max-age — so on Workers the response can come back from the
// colo cache. A cached body makes a signing-key rotation invisible to this
// isolate, which is how a *fresh* runner token ends up failing to verify.
//
// Two kinds of fetch reach this endpoint and they want opposite policies:
//   - jose's own reloads. These are unthrottled (one per request that misses a
//     `kid`) and are NOT deduplicated on Workers — reload() deliberately clears
//     its in-flight promise there, because workerd forbids awaiting another
//     request's I/O. So N concurrent junk tokens mean N subrequests unless the
//     colo cache collapses them. Give them a short TTL: it bounds an
//     unauthenticated caller's amplification against GitHub.
//   - the explicit rotation-recovery reload in verifyOidcToken.
//
// Both now bypass the cache unconditionally. Production evidence (#147): the
// Worker was getting a non-200 from GitHub's JWKS endpoint, which is served
// `public, max-age=3600, must-revalidate` — so any colo that cached a bad response
// kept serving it for an hour while other colos stayed healthy, matching exactly
// the "one repo fails, another succeeds, persists across fresh tokens" report.
// Keeping the cache out of this path removes that failure mode entirely.
//
// The cost is that the colo cache no longer collapses concurrent identical
// subrequests: jose's reloads are unthrottled and it disables in-flight dedupe on
// Workers, so a burst of unknown-`kid` tokens spaced beyond its 30s cooldown can
// still amplify. Real but modest, and tracked separately — correctness during a
// live outage beats a theoretical amplification vector.
const jwksFetch: FetchImplementation = (url, options) =>
  fetch(url, { ...options, cache: "no-store" })
    .then((response) => {
      if (response.status !== 200) {
        // jose's own non-200 error is a bare JOSEError carrying fixed text, so the
        // status never reaches the logs — exactly what left #147 undiagnosable for
        // hours. Carry the status and the headers that explain it.
        throw Object.assign(new Error("jwks fetch returned non-200"), {
          code: JWKS_FETCH_FAILED_CODE,
          jwksStatus: response.status,
          jwksContentType: response.headers.get("content-type") ?? undefined,
          jwksLocation: response.headers.get("location") ?? undefined,
          jwksCfRay: response.headers.get("cf-ray") ?? undefined
        });
      }
      return response;
    })
    .catch((cause: unknown) => {
    // Our own tagged errors (including the non-200 above) pass straight through.
    if ((cause as { code?: unknown } | null)?.code === JWKS_FETCH_FAILED_CODE) {
      throw cause;
    }
    // Let jose map its own AbortSignal.timeout rejection to JWKSTimeout.
    if ((cause as Error | null)?.name === "TimeoutError") throw cause;
    // workerd rejects a failed subrequest with a plain Error ("Network connection
    // lost.") carrying no code — never a TypeError — so the fault has to be tagged
    // here rather than sniffed from the error class downstream. Build a fresh
    // Error: assigning onto the original can throw (DOMException.code is a getter).
    throw Object.assign(new Error("jwks fetch failed"), {
      code: JWKS_FETCH_FAILED_CODE,
      cause
    });
  });

const JWKS_OPTIONS = {
  [customFetch]: jwksFetch,
  cacheMaxAge: 300_000, // 5 min (jose default 10 min)
  timeoutDuration: 5_000
  // cooldownDuration is left at jose's 30s default on purpose: shortening it only
  // widens the window in which jose's *unthrottled* reload fires. Rotation
  // recovery comes from the throttled explicit reload instead.
} as const;

const remoteJwks = createRemoteJWKSet(new URL(GITHUB_OIDC_JWKS_URL), JWKS_OPTIONS);

// GitHub Enterprise (ghe.com data-residency / GHES) support is opt-in via
// GHE_OIDC_ISSUER + GHE_GITHUB_APP_* env. A GHE tenant mints Actions OIDC tokens
// from its own issuer (e.g. https://token.actions.<tenant>.ghe.com) with a
// distinct JWKS, and exposes a distinct REST API — so both verification and
// token-minting must switch on the token's issuer. JWKS sets are cached per
// issuer (note jose does NOT dedupe concurrent fetches on Workers — see the cache
// policy on jwksFetch above).
const jwksByIssuer = new Map<string, RemoteJWKSet>([
  [GITHUB_OIDC_ISSUER, remoteJwks]
]);
function jwksForIssuer(issuer: string): RemoteJWKSet {
  let jwks = jwksByIssuer.get(issuer);
  if (!jwks) {
    // Actions OIDC issuers publish their keys at <issuer>/.well-known/jwks.
    jwks = createRemoteJWKSet(
      new URL(`${normalizeBaseUrl(issuer)}/.well-known/jwks`),
      JWKS_OPTIONS
    );
    jwksByIssuer.set(issuer, jwks);
  }
  return jwks;
}

// `reload()` deliberately bypasses jose's cooldown, so an unauthenticated caller
// spraying tokens with unknown `kid`s could turn one request into one GitHub
// subrequest each. This bounds the *explicit* reload below to one per issuer per
// interval — it does not gate jose's own internal reload, which runs first and is
// bounded instead by its cooldown and by the colo TTL on jwksFetch. The key is
// drawn from the trusted-issuer list, never from caller input, so this map cannot
// grow unboundedly.
const FORCED_RELOAD_MIN_INTERVAL_MS = 5_000;
const lastForcedReload = new Map<string, number>();
function mayForceReload(issuer: string, nowMs: number): boolean {
  if (nowMs - (lastForcedReload.get(issuer) ?? 0) < FORCED_RELOAD_MIN_INTERVAL_MS) {
    return false;
  }
  lastForcedReload.set(issuer, nowMs);
  return true;
}

type PermissionLevel = "read" | "write";
type TokenPermissions = Record<string, PermissionLevel>;

export type BrokerEnv = Env & {
  GITHUB_APP_ID: string;
  GITHUB_APP_PRIVATE_KEY: string;
  OIDC_AUDIENCE?: string;
  ALLOWED_REPOSITORIES?: string;
  TOKEN_PERMISSIONS?: string;
  // GitHub Enterprise (ghe.com / GHES) support — opt-in. When GHE_OIDC_ISSUER is
  // set, /token also accepts OIDC tokens from that issuer and mints via the GHE
  // App against GHE_API_BASE.
  GHE_OIDC_ISSUER?: string; // e.g. https://token.actions.<tenant>.ghe.com
  GHE_API_BASE?: string; // e.g. https://<tenant>.ghe.com/api/v3
  GHE_GITHUB_APP_ID?: string;
  GHE_GITHUB_APP_PRIVATE_KEY?: string;
  GHE_GITHUB_APP_INSTALLATION_ID?: string; // set to skip the per-repo lookup
  // KV namespace used to cache the /releases aggregate.
  COPILOT_QUOTA_KV?: KVNamespace;
  // /webhook push → auto-update open PRs targeting the pushed branch (HMAC-
  // verified against this secret).
  GITHUB_WEBHOOK_SECRET?: string;
  // Bearer secret gating POST /sign and GET /releases.
  PROCESS_TRIGGER_SECRET?: string;
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
    audience: string | string[],
    trustedIssuers?: string[]
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

// Coarse, fixed enum describing *why* verification failed. Surfaced to the caller
// as `reason` and logged; it deliberately carries no token content, no jose
// message text (which can embed claim values) and no broker configuration.
type OidcFailureReason =
  | "malformed_token"
  | "kid_not_found"
  | "key_ambiguous"
  | "signature_invalid"
  | "audience_mismatch"
  | "issuer_mismatch"
  | "token_expired"
  | "token_not_yet_valid"
  | "claim_invalid"
  | "alg_unsupported"
  | "jwks_unavailable"
  | "unknown";

class OidcVerificationError extends Error {
  constructor(readonly reason: OidcFailureReason) {
    super(reason);
  }
}

// Failing to retrieve GitHub's key set is OUR unavailability, not a bad token —
// reporting it as 401 is what made this class of incident unfalsifiable from the
// caller's side.
const JWKS_INFRA_REASONS: ReadonlySet<OidcFailureReason> = new Set([
  "jwks_unavailable"
]);

// Classify on jose's `code`, never on `instanceof JOSEError` — every jose error
// extends it, so that would report a forged token as "GitHub is down".
// ERR_JOSE_GENERIC is only ever thrown by jose's JWKS fetch (non-200 response, or
// a body that will not parse as JSON), so it belongs with the retrieval faults.
function classifyOidcError(error: unknown): OidcFailureReason {
  const code = (error as { code?: unknown } | null)?.code;
  const claim = (error as { claim?: unknown } | null)?.claim;
  switch (code) {
    case "ERR_JWKS_NO_MATCHING_KEY":
      return "kid_not_found";
    case "ERR_JWKS_MULTIPLE_MATCHING_KEYS":
      return "key_ambiguous";
    case "ERR_JWS_SIGNATURE_VERIFICATION_FAILED":
      return "signature_invalid";
    case "ERR_JWT_EXPIRED":
      return "token_expired";
    case "ERR_JWT_CLAIM_VALIDATION_FAILED":
      if (claim === "aud") return "audience_mismatch";
      if (claim === "iss") return "issuer_mismatch";
      if (claim === "nbf") return "token_not_yet_valid";
      return "claim_invalid";
    case "ERR_JWT_INVALID":
    case "ERR_JWS_INVALID":
      return "malformed_token";
    case "ERR_JOSE_NOT_SUPPORTED":
    case "ERR_JOSE_ALG_NOT_ALLOWED":
      return "alg_unsupported";
    case JWKS_FETCH_FAILED_CODE:
    case "ERR_JWKS_TIMEOUT":
    case "ERR_JWKS_INVALID":
    case "ERR_JOSE_GENERIC": // jose's base class — any untyped JOSEError lands here, not exclusively the fetch path
      return "jwks_unavailable";
    default:
      // A raw TypeError from the JWKS subrequest (DNS/TLS/connection reset) has
      // no jose code at all.
      return error instanceof TypeError ? "jwks_unavailable" : "unknown";
  }
}

const defaultDependencies: Dependencies = {
  fetch,
  verifyOidcToken,
  createGitHubAppJwt,
  now: () => new Date()
};

export default {
  fetch(request: Request, env: BrokerEnv): Promise<Response> {
    return handleRequest(request, env);
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
      case "/webhook":
        return await handleWebhookRequest(request, env, dependencies);
      case "/sign":
        return await handleSignRequest(request, env, dependencies);
      case "/releases":
        return await handleReleasesRequest(request, env, dependencies);
      default:
        return jsonError(404, "not_found");
    }
  } catch (error) {
    if (error instanceof HttpError) {
      return jsonError(error.status, error.code);
    }

    if (error instanceof OidcVerificationError) {
      return JWKS_INFRA_REASONS.has(error.reason)
        ? jsonError(503, "oidc_key_fetch_failed", error.reason)
        : jsonError(401, "invalid_oidc_token", error.reason);
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

  const audience = parseAudience(env.OIDC_AUDIENCE);
  const gheIssuer = env.GHE_OIDC_ISSUER ? normalizeBaseUrl(env.GHE_OIDC_ISSUER) : "";
  const trustedIssuers = gheIssuer
    ? [GITHUB_OIDC_ISSUER, gheIssuer]
    : [GITHUB_OIDC_ISSUER];
  const oidcPayload = await verifyOidc(
    body.oidcToken,
    audience,
    dependencies,
    trustedIssuers
  );
  if (oidcPayload.repository !== repository) {
    return jsonError(403, "repo_mismatch");
  }

  if (!repositoryAllowed(repository, env.ALLOWED_REPOSITORIES)) {
    return jsonError(403, "repo_not_allowed");
  }

  // Mint against the same GitHub host the token came from: github.com by
  // default, or the configured GHE tenant when the verified issuer matches
  // GHE_OIDC_ISSUER (a different REST API base and a different App).
  const isGhe = !!gheIssuer && oidcPayload.iss === gheIssuer;
  const host = resolveGitHubHost(env, isGhe);

  const appJwt = await dependencies.createGitHubAppJwt(
    host.appId,
    host.privateKey,
    dependencies.now()
  );
  // The GHE App's Vault secret carries its installation id, so an explicit
  // GHE_GITHUB_APP_INSTALLATION_ID skips the per-repo installation lookup.
  const explicitInstallation = host.installationId
    ? Number(host.installationId)
    : NaN;
  const installationId = Number.isInteger(explicitInstallation) && explicitInstallation > 0
    ? explicitInstallation
    : await findInstallationId(
        dependencies.fetch,
        appJwt,
        body.owner,
        body.repo,
        host.apiBase
      );
  const token = await createInstallationToken(
    dependencies.fetch,
    appJwt,
    installationId,
    body.repo,
    parsePermissions(env.TOKEN_PERMISSIONS),
    host.apiBase
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

// ─── /webhook ────────────────────────────────────────────────────────────────
// Receives GitHub webhook deliveries for the Diatreme App. We verify
// HMAC-SHA256 against GITHUB_WEBHOOK_SECRET, then act only on `push` events
// (auto-update open PRs targeting the pushed branch). All other events are
// acknowledged with a no-op so GitHub stops retrying.

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

  // Only `push` is acted on; everything else is acknowledged so GitHub stops
  // retrying, but does nothing.
  if (event !== "push") {
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

  return await handlePushEvent(payload, env, dependencies);
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

// GraphQL endpoint for github.com — used by createSignedCommitOnBranch (/sign).
const GITHUB_GRAPHQL_URL = "https://api.github.com/graphql";

async function mintInstallationToken(
  dependencies: Dependencies,
  owner: string,
  repo: string,
  host: GitHubHost,
  permissions: TokenPermissions = DEFAULT_PERMISSIONS
): Promise<string> {
  const appJwt = await dependencies.createGitHubAppJwt(
    host.appId,
    host.privateKey,
    dependencies.now()
  );
  // A configured installation id (carried by the GHE App's secret) skips the
  // per-repo lookup, mirroring the /token path.
  const explicitInstallation = host.installationId
    ? Number(host.installationId)
    : NaN;
  const installationId =
    Number.isInteger(explicitInstallation) && explicitInstallation > 0
      ? explicitInstallation
      : await findInstallationId(
          dependencies.fetch,
          appJwt,
          owner,
          repo,
          host.apiBase
        );
  const { token } = await createInstallationToken(
    dependencies.fetch,
    appJwt,
    installationId,
    repo,
    permissions,
    host.apiBase
  );
  return token;
}

function extractRepoFromWebhook(
  payload: Record<string, unknown>
): { owner: string; repo: string } | null {
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

// A deployer-supplied OIDC_AUDIENCE is trimmed and comma-split, mirroring
// ALLOWED_REPOSITORIES. Without this a whitespace-only value is truthy and
// silently replaces the accept-list with an audience nothing can ever match —
// a global, permanent 401 with no way to see why.
export function parseAudience(configured: string | undefined): string[] {
  const parsed = (configured ?? "")
    .split(",")
    .map((entry) => entry.trim())
    .filter(Boolean);
  return parsed.length > 0 ? parsed : [DEFAULT_AUDIENCE, LEGACY_AUDIENCE];
}

async function verifyOidc(
  token: string,
  audience: string | string[],
  deps: Dependencies,
  trustedIssuers?: string[]
): Promise<VerifiedOidcPayload> {
  try {
    return await deps.verifyOidcToken(token, audience, trustedIssuers);
  } catch (error) {
    const reason = classifyOidcError(error);
    logOidcFailure(token, reason, error, audience, trustedIssuers);
    throw new OidcVerificationError(reason);
  }
}

// Truncate every attacker-controlled string so a hostile token cannot flood or
// line-inject the log stream.
function logField(value: unknown): string | undefined {
  if (value === undefined || value === null) return undefined;
  const text = typeof value === "string" ? value : JSON.stringify(value);
  return typeof text === "string" ? text.slice(0, 128) : undefined;
}

// One structured line per verification failure, so the next occurrence is settled
// from `wrangler tail` instead of guesswork. NEVER logs the token (or any slice of
// it) or jose's message, which can embed claim values.
function logOidcFailure(
  token: string,
  reason: OidcFailureReason,
  error: unknown,
  audience: string | string[],
  trustedIssuers?: string[]
): void {
  let claims: Record<string, string | undefined> = { decodable: "false" };
  try {
    const header = decodeProtectedHeader(token);
    const payload = decodeJwt(token);
    claims = {
      decodable: "true",
      headerKid: logField(header.kid),
      headerAlg: logField(header.alg),
      claimIss: logField(payload.iss),
      claimAud: logField(payload.aud),
      claimRepository: logField((payload as VerifiedOidcPayload).repository),
      claimIat: logField(payload.iat),
      claimExp: logField(payload.exp)
    };
  } catch {
    // Deliberately swallowed: an undecodable token must not mask the real error.
  }

  console.warn({
    event: "oidc_verify_failed",
    reason,
    errName: logField((error as Error | null)?.name),
    errCode: logField((error as { code?: unknown } | null)?.code),
    // Present only for a JWKS retrieval fault; names the actual upstream status.
    jwksStatus: logField((error as { jwksStatus?: unknown } | null)?.jwksStatus),
    jwksContentType: logField(
      (error as { jwksContentType?: unknown } | null)?.jwksContentType
    ),
    jwksLocation: logField((error as { jwksLocation?: unknown } | null)?.jwksLocation),
    jwksCfRay: logField((error as { jwksCfRay?: unknown } | null)?.jwksCfRay),
    expectedAudience: Array.isArray(audience) ? audience.join(",") : audience,
    trustedIssuers: (trustedIssuers ?? [GITHUB_OIDC_ISSUER]).join(","),
    nowEpoch: Math.floor(Date.now() / 1000),
    ...claims
  });
}

// Exported for direct unit testing (see test/verify-oidc.test.ts). The token-broker
// tests inject a fake verifyOidcToken via deps; this is the real issuer-pinning path.
export async function verifyOidcToken(
  token: string,
  audience: string | string[],
  trustedIssuers: string[] = [GITHUB_OIDC_ISSUER]
): Promise<VerifiedOidcPayload> {
  // github.com and each GHE tenant sign with different keys, so pick the JWKS by
  // the token's (still-unverified) issuer — but only when it's on the trust list,
  // then pin that issuer in jwtVerify so a forged `iss` can't select a foreign key.
  const claimedIssuer = decodeJwt(token).iss;
  const issuer =
    claimedIssuer && trustedIssuers.includes(claimedIssuer)
      ? claimedIssuer
      : GITHUB_OIDC_ISSUER;
  const jwks = jwksForIssuer(issuer);
  try {
    const { payload } = await jwtVerify(token, jwks, { issuer, audience });
    return payload;
  } catch (error) {
    // jose refetches the key set on a `kid` miss only once its cooldown has lapsed
    // (30s), and its own freshness refetch arms that cooldown in the same call — so
    // a miss inside that window is terminal for this request. Force one reload and
    // retry rather than making a genuine runner token wait the cooldown out.
    //
    // Forced even when jose did reload itself: that reload rides the colo cache
    // (see jwksFetch), so it can miss a rotation that a cache-bypassing fetch
    // sees. One extra subrequest per throttle interval is the right price.
    //
    // This is strictly a key-*availability* retry, not a relaxation: the retried
    // jwtVerify re-checks signature, the pinned issuer, audience and expiry, and
    // only ERR_JWKS_NO_MATCHING_KEY reaches it — a bad signature or a failed claim
    // still throws immediately.
    if (
      (error as { code?: unknown } | null)?.code !== "ERR_JWKS_NO_MATCHING_KEY" ||
      !mayForceReload(issuer, Date.now())
    ) {
      throw error;
    }
    await jwks.reload();
    const { payload } = await jwtVerify(token, jwks, { issuer, audience });
    return payload;
  }
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

// Where (and as whom) to talk to GitHub: App credentials plus the REST/GraphQL
// endpoints. github.com by default, or the configured GHE tenant when isGhe.
interface GitHubHost {
  appId: string;
  privateKey: string;
  apiBase: string;
  graphqlUrl: string;
  installationId?: string;
}

// Derive the GraphQL endpoint from a REST API base. github.com serves GraphQL at
// /graphql on the same host; GHE (ghe.com / GHES) serves REST at <host>/api/v3
// and GraphQL at <host>/api/graphql.
function graphqlUrlForApiBase(apiBase: string): string {
  const restSuffix = "/api/v3";
  if (apiBase.endsWith(restSuffix)) {
    return `${apiBase.slice(0, -restSuffix.length)}/api/graphql`;
  }
  return `${apiBase}/graphql`;
}

function resolveGitHubHost(env: BrokerEnv, isGhe: boolean): GitHubHost {
  if (isGhe) {
    const apiBase = normalizeBaseUrl(
      requiredSecret(env.GHE_API_BASE, "GHE_API_BASE")
    );
    return {
      appId: requiredSecret(env.GHE_GITHUB_APP_ID, "GHE_GITHUB_APP_ID"),
      privateKey: requiredSecret(
        env.GHE_GITHUB_APP_PRIVATE_KEY,
        "GHE_GITHUB_APP_PRIVATE_KEY"
      ),
      apiBase,
      graphqlUrl: graphqlUrlForApiBase(apiBase),
      installationId: env.GHE_GITHUB_APP_INSTALLATION_ID
    };
  }
  return {
    appId: requiredSecret(env.GITHUB_APP_ID, "GITHUB_APP_ID"),
    privateKey: requiredSecret(env.GITHUB_APP_PRIVATE_KEY, "GITHUB_APP_PRIVATE_KEY"),
    apiBase: GITHUB_API_BASE,
    graphqlUrl: GITHUB_GRAPHQL_URL,
    installationId: undefined
  };
}

async function findInstallationId(
  githubFetch: typeof fetch,
  appJwt: string,
  owner: string,
  repo: string,
  apiBase: string = GITHUB_API_BASE
): Promise<number> {
  const response = await githubFetch(
    `${apiBase}/repos/${encodeURIComponent(owner)}/${encodeURIComponent(repo)}/installation`,
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
  permissions: TokenPermissions,
  apiBase: string = GITHUB_API_BASE
): Promise<{ token: string; expires_at: string }> {
  const response = await githubFetch(
    `${apiBase}/app/installations/${installationId}/access_tokens`,
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

function jsonError(status: number, error: string, reason?: string): Response {
  return json(reason ? { error, reason } : { error }, status);
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
// Bearer-gated (PROCESS_TRIGGER_SECRET, same as /sign). The App private key
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

// ─── /sign ───────────────────────────────────────────────────────────────────
// /sign turns a set of file changes into a GitHub-signed, App/bot-attributed
// commit. It mints a short-lived App installation token for the target repo and
// drives GraphQL createCommitOnBranch with it — GitHub signs the commit and
// attributes it to the App's bot identity. Bearer-gated on PROCESS_TRIGGER_SECRET.

function bearerOk(request: Request, secret: string): boolean {
  const auth = request.headers.get("authorization") ?? "";
  const provided = auth.startsWith("Bearer ") ? auth.slice("Bearer ".length) : "";
  return constantTimeEquals(provided, secret);
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

  // `user` is accepted but ignored — the commit is App/bot-attributed now.
  asString(value.user);
  const repo = asString(value.repo);
  const branch = asString(value.branch);
  const expectedHeadOid = asString(value.expected_head_oid);
  const message = isRecord(value.message) ? value.message : null;
  const headline = message ? asString(message.headline) : undefined;
  if (!repo || !branch || !expectedHeadOid || !headline) {
    return jsonError(400, "missing_required_fields");
  }
  const additions = normalizeFileAdditions(value.additions);
  const deletions = normalizeFileDeletions(value.deletions);
  if (additions.length === 0 && deletions.length === 0) {
    return jsonError(400, "no_file_changes");
  }

  // Mint a short-lived App installation token for the repo. GitHub signs the
  // commit (App's bot identity) when createCommitOnBranch is driven with it.
  const [owner, name] = repo.split("/");
  if (!owner || !name) return jsonError(400, "invalid_repo");
  assertRepositoryParts(owner, name);
  const host = resolveGitHubHost(env, false); // github.com app
  let token: string;
  try {
    token = await mintInstallationToken(dependencies, owner, name, host, {
      contents: "write"
    });
  } catch (e) {
    if (e instanceof HttpError) return jsonError(e.status, e.code);
    return jsonError(502, "installation_token_failed");
  }

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
  token: string,
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
      authorization: `Bearer ${token}`,
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

