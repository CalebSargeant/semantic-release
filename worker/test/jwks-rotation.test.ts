// Regression tests for the "a GitHub signing-key rotation strands this isolate"
// failure (issue #147): a genuine, freshly minted runner token verified against a
// key set that no longer contains its `kid`.
//
// jose only force-refetches the JWKS on a `kid` miss once its cooldown has
// lapsed — and its own freshness refetch arms that cooldown in the same call — so
// createRemoteJWKSet does NOT reliably self-heal a rotation. verifyOidcToken
// forces one reload itself; these tests pin that behaviour, and pin the throttle
// that keeps it from amplifying junk traffic into GitHub subrequests.
//
// Each case needs a pristine module registry because src/index.ts caches the key
// sets (and the forced-reload timestamps) at module scope, so the harness stubs
// global fetch and THEN dynamically imports the module. Do not move these cases
// into index.test.ts / verify-oidc.test.ts: those hold top-level static imports
// and vi.resetModules() there would leave them asserting against a different
// module instance.
import { SignJWT, exportJWK, generateKeyPair } from "jose";
import type { JWK } from "jose";

const GITHUB_ISSUER = "https://token.actions.githubusercontent.com";
const AUDIENCE = "diatreme";

type Verify = typeof import("../src/index").verifyOidcToken;

interface Signer {
  kid: string;
  jwk: JWK;
  key: CryptoKey;
}

async function signer(kid: string): Promise<Signer> {
  const pair = await generateKeyPair("RS256", { extractable: true });
  const jwk = await exportJWK(pair.publicKey);
  jwk.kid = kid;
  jwk.alg = "RS256";
  jwk.use = "sig";
  return { kid, jwk, key: pair.privateKey };
}

async function mint(
  from: Signer,
  claims: { iss?: string; aud?: string } = {}
): Promise<string> {
  return new SignJWT({ repository: "octo-org/octo-repo" })
    .setProtectedHeader({ alg: "RS256", kid: from.kid })
    .setIssuer(claims.iss ?? GITHUB_ISSUER)
    .setAudience(claims.aud ?? AUDIENCE)
    .setIssuedAt()
    .setExpirationTime("5m")
    .sign(from.key);
}

interface Harness {
  verifyOidcToken: Verify;
  /** Init object of every JWKS subrequest jose made, in order. */
  inits: RequestInit[];
  /** Swap the key set the fake JWKS endpoint serves (i.e. rotate). */
  serve: (keys: JWK[]) => void;
  /** Make the next JWKS fetches fail with an HTTP status. */
  failWith: (status: number | undefined) => void;
  /** Make the next JWKS fetches reject, the way a workerd subrequest fault does. */
  rejectWith: (error: Error | undefined) => void;
}

async function freshModule(initial: JWK[]): Promise<Harness> {
  let served = initial;
  let status: number | undefined;
  let rejection: Error | undefined;
  const inits: RequestInit[] = [];

  // Stub BEFORE importing. (jwksFetch resolves the global `fetch` by name at call
  // time, so order is not load-bearing today — but keep it this way so a future
  // refactor that captures fetch at module scope fails loudly here.)
  vi.stubGlobal("fetch", async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = typeof input === "string" ? input : String(input);
    if (!url.endsWith("/.well-known/jwks")) {
      return new Response("unexpected fetch", { status: 404 });
    }
    inits.push(init ?? {});
    if (rejection) {
      throw rejection;
    }
    if (status !== undefined) {
      return new Response("upstream said no", { status });
    }
    return Response.json({ keys: served });
  });

  vi.resetModules();
  const mod = await import("../src/index");
  return {
    verifyOidcToken: mod.verifyOidcToken,
    inits,
    serve: (keys) => {
      served = keys;
    },
    failWith: (next) => {
      status = next;
    },
    rejectWith: (next) => {
      rejection = next;
    }
  };
}

function codeOf(error: unknown): unknown {
  return (error as { code?: unknown } | null)?.code;
}

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("JWKS key rotation", () => {
  it("recovers from a rotation by forcing exactly one JWKS re-fetch", async () => {
    const a = await signer("kid-a");
    const b = await signer("kid-b");
    const h = await freshModule([a.jwk]);

    expect((await h.verifyOidcToken(await mint(a), AUDIENCE)).repository).toBe(
      "octo-org/octo-repo"
    );
    expect(h.inits).toHaveLength(1);

    // GitHub rotates. The cached set is still "fresh" and jose is still inside its
    // cooldown, so without the explicit reload this token is unverifiable here.
    h.serve([b.jwk]);
    expect((await h.verifyOidcToken(await mint(b), AUDIENCE)).repository).toBe(
      "octo-org/octo-repo"
    );
    expect(h.inits).toHaveLength(2);
  });

  it("throttles the forced re-fetch so unknown kids cannot amplify traffic", async () => {
    const a = await signer("kid-a");
    const unknown = await signer("kid-nope");
    const h = await freshModule([a.jwk]);

    await h.verifyOidcToken(await mint(a), AUDIENCE);
    expect(h.inits).toHaveLength(1);

    // First unknown kid: one forced reload, still no match.
    await expect(h.verifyOidcToken(await mint(unknown), AUDIENCE)).rejects.toSatisfy(
      (error: unknown) => codeOf(error) === "ERR_JWKS_NO_MATCHING_KEY"
    );
    expect(h.inits).toHaveLength(2);

    // Second one within the throttle window: rejected without touching GitHub.
    await expect(h.verifyOidcToken(await mint(unknown), AUDIENCE)).rejects.toSatisfy(
      (error: unknown) => codeOf(error) === "ERR_JWKS_NO_MATCHING_KEY"
    );
    expect(h.inits).toHaveLength(2);
  });

  it("bypasses the colo cache on every JWKS fetch", async () => {
    const a = await signer("kid-a");
    const b = await signer("kid-b");
    const h = await freshModule([a.jwk]);
    await h.verifyOidcToken(await mint(a), AUDIENCE);

    // Every JWKS fetch bypasses the colo cache: a cached bad response is what
    // turned a transient GitHub fault into an hour of failures on one colo.
    const [joseFetch] = h.inits;
    expect(joseFetch.cache).toBe("no-store");
    expect(joseFetch.cf).toBeUndefined();
    // ...and jose's own semantics must survive the spread.
    expect(joseFetch.method).toBe("GET");
    expect(joseFetch.redirect).toBe("manual");
    expect(joseFetch.signal).toBeInstanceOf(AbortSignal);

    // The throttled recovery reload is the one that must see through the cache:
    // a cached body is what turns a rotation into a persistent failure.
    h.serve([b.jwk]);
    await h.verifyOidcToken(await mint(b), AUDIENCE);
    expect(h.inits).toHaveLength(2);
    const forced = h.inits[1];
    expect(forced.cache).toBe("no-store");
    expect(forced.cf).toBeUndefined();
  });

  it("names the upstream status when the JWKS endpoint returns non-200", async () => {
    const a = await signer("kid-a");
    const h = await freshModule([a.jwk]);
    // The production failure in #147: jose collapses any non-200 into a bare
    // JOSEError with fixed text, discarding the status that explains it.
    h.failWith(403);

    await expect(h.verifyOidcToken(await mint(a), AUDIENCE)).rejects.toSatisfy(
      (error: unknown) =>
        codeOf(error) === "ERR_JWKS_FETCH_FAILED" &&
        (error as { jwksStatus?: unknown }).jwksStatus === 403
    );
  });

  it("reports a rejected JWKS subrequest as a retrieval fault, not a bad token", async () => {
    const a = await signer("kid-a");
    const h = await freshModule([a.jwk]);
    // workerd rejects a failed subrequest with a plain Error carrying no code —
    // not a TypeError — so the fault has to be tagged at the fetch wrapper or it
    // would be reported to the caller as an invalid token.
    h.rejectWith(new Error("Network connection lost."));

    await expect(h.verifyOidcToken(await mint(a), AUDIENCE)).rejects.toSatisfy(
      (error: unknown) => codeOf(error) === "ERR_JWKS_FETCH_FAILED"
    );
  });

  it("reports a JWKS retrieval fault as a retrieval fault, not a bad signature", async () => {
    const a = await signer("kid-a");
    const h = await freshModule([a.jwk]);
    h.failWith(500);

    await expect(h.verifyOidcToken(await mint(a), AUDIENCE)).rejects.toSatisfy(
      (error: unknown) =>
        codeOf(error) === "ERR_JWKS_FETCH_FAILED" &&
        (error as { jwksStatus?: unknown }).jwksStatus === 500
    );
  });

  it("still rejects a forged issuer and a wrong audience after a forced reload", async () => {
    const a = await signer("kid-a");
    const rotated = await signer("kid-b");
    const h = await freshModule([a.jwk]);
    await h.verifyOidcToken(await mint(a), AUDIENCE);
    h.serve([rotated.jwk]);

    // Signature is good and the reload finds the key — the pinned issuer check
    // must still reject it.
    await expect(
      h.verifyOidcToken(await mint(rotated, { iss: "https://evil.example.com" }), AUDIENCE)
    ).rejects.toSatisfy(
      (error: unknown) => codeOf(error) === "ERR_JWT_CLAIM_VALIDATION_FAILED"
    );

    await expect(
      h.verifyOidcToken(await mint(rotated, { aud: "someone-else" }), AUDIENCE)
    ).rejects.toSatisfy(
      (error: unknown) =>
        codeOf(error) === "ERR_JWT_CLAIM_VALIDATION_FAILED" &&
        (error as { claim?: unknown }).claim === "aud"
    );
  });
});
