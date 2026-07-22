// Direct unit tests for the REAL verifyOidcToken (the security-critical issuer-
// pinning + audience path). The token-broker tests inject a fake verifyOidcToken
// via deps, so without these the actual jose verification is never exercised.
//
// Strategy: generate a local RSA keypair, publish its public JWK at the JWKS URLs
// jose fetches (github.com + a fake GHE issuer) via a stubbed global fetch, then
// mint JWTs with the private key and assert good tokens pass while forged-issuer,
// wrong-audience, and untrusted-issuer tokens are rejected.
import { SignJWT, exportJWK, generateKeyPair } from "jose";
import { verifyOidcToken } from "../src/index";

const GITHUB_ISSUER = "https://token.actions.githubusercontent.com";
const GHE_ISSUER = "https://token.actions.acme.ghe.com";
const AUDIENCE = "diatreme";
const KID = "test-key-1";

let privateKey: CryptoKey;

async function mint(claims: {
  iss: string;
  aud: string;
  repository?: string;
}): Promise<string> {
  return new SignJWT({ repository: claims.repository ?? "octo-org/octo-repo" })
    .setProtectedHeader({ alg: "RS256", kid: KID })
    .setIssuer(claims.iss)
    .setAudience(claims.aud)
    .setIssuedAt()
    .setExpirationTime("5m")
    .sign(privateKey);
}

beforeAll(async () => {
  const pair = await generateKeyPair("RS256", { extractable: true });
  privateKey = pair.privateKey;
  const jwk = await exportJWK(pair.publicKey);
  jwk.kid = KID;
  jwk.alg = "RS256";
  jwk.use = "sig";

  // Any /.well-known/jwks fetch (github.com or the fake GHE issuer) returns our
  // single public key; anything else 404s so an unexpected fetch is obvious.
  vi.stubGlobal("fetch", async (input: RequestInfo | URL) => {
    const url = typeof input === "string" ? input : input.toString();
    if (url.endsWith("/.well-known/jwks")) {
      return Response.json({ keys: [jwk] });
    }
    return new Response("unexpected fetch", { status: 404 });
  });
});

afterAll(() => {
  vi.unstubAllGlobals();
});

describe("verifyOidcToken (real path)", () => {
  it("accepts a github.com token with the correct issuer and audience", async () => {
    const token = await mint({ iss: GITHUB_ISSUER, aud: AUDIENCE });
    const payload = await verifyOidcToken(token, AUDIENCE);
    expect(payload.iss).toBe(GITHUB_ISSUER);
    expect(payload.repository).toBe("octo-org/octo-repo");
  });

  it("accepts the legacy audience when both are allowed", async () => {
    const token = await mint({ iss: GITHUB_ISSUER, aud: "release-runner" });
    const payload = await verifyOidcToken(token, [AUDIENCE, "release-runner"]);
    expect(payload.aud).toBe("release-runner");
  });

  it("rejects a token whose audience does not match", async () => {
    const token = await mint({ iss: GITHUB_ISSUER, aud: "someone-else" });
    await expect(verifyOidcToken(token, AUDIENCE)).rejects.toBeDefined();
  });

  it("rejects a forged issuer (not on the trust list) even if the signature is valid", async () => {
    // Signed with our key, but claims an issuer we don't trust. verifyOidcToken
    // pins to github.com's issuer, so the iss claim check must fail.
    const token = await mint({ iss: "https://evil.example.com", aud: AUDIENCE });
    await expect(verifyOidcToken(token, AUDIENCE)).rejects.toBeDefined();
  });

  it("accepts a GHE-issued token only when its issuer is on the trust list", async () => {
    const token = await mint({ iss: GHE_ISSUER, aud: AUDIENCE });
    const payload = await verifyOidcToken(token, AUDIENCE, [
      GITHUB_ISSUER,
      GHE_ISSUER
    ]);
    expect(payload.iss).toBe(GHE_ISSUER);
  });

  it("rejects a GHE-issued token when its issuer is NOT trusted", async () => {
    const token = await mint({ iss: GHE_ISSUER, aud: AUDIENCE });
    // Default trusted issuers = [github.com] only -> pins to github, iss mismatch.
    await expect(verifyOidcToken(token, AUDIENCE)).rejects.toBeDefined();
  });
});
