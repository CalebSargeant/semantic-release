# Glossary

Terms that appear in Diatreme's inputs, outputs, logs and errors.

**Action surface.** `action.yml` plus `scripts/*.sh`: the composite action that
runs on your runner. One of Diatreme's two halves.

**App installation token.** A short-lived credential GitHub issues to a GitHub
App for one repository it's installed on. What `/token` returns, and what the
release then authenticates with. Starts with `ghs_`.

**Auth mode.** How the action gets a token. `public-app` (the default) exchanges
an OIDC token at the broker. `github-token` uses a token you supply.
`private-app` mints from your own App's ID and key.

**Broker.** The hosted GitHub App backend the action calls. Serves `/token`,
`/sign`, `/releases` and `/webhook`. Also called the token broker.

**Broker surface.** Diatreme's other half: the code behind the broker. Currently
the TypeScript Cloudflare Worker in `worker/` as the code of record, with the
running deployment on AWS Lambda.

**Fallback broker.** The secondary hostname the action retries when the primary
is unreachable or returns 5xx. Never tried on 4xx, because a rejected token is
an answer, not an outage.

**Floating major tag.** `@v2`. Force-updated to the newest stable release of
that major after every release. Convenient, and it moves under you.

**JWKS.** JSON Web Key Set: the public keys an issuer publishes so anyone can
verify tokens it signed. The broker fetches GitHub's, caches it, and keeps a
last-known-good snapshot.

**kid.** Key ID. The field in a token's header naming which key from the JWKS
signed it. `kid_not_found` means the broker's cached key set didn't contain it.

**OIDC token.** The short-lived JWT a GitHub Actions job can mint about itself,
carrying claims like `repository`, `ref` and `sha`. Requires `id-token: write`.
Proof of which repository is asking, and the input to `/token`.

**Promotion.** Retagging an already-built `pr-<N>` image as a release version
instead of rebuilding it. Diatreme verifies the image's provenance labels
against the release commit first, and rebuilds rather than promoting anything
stale.

**Provenance labels.** Metadata stamped onto an image at CI build time recording
which commit it came from. What makes promotion verifiable.

**Reason.** The coarse, non-sensitive string the broker returns alongside
`error` on a verification failure, naming which check failed. See
[Errors](reference/errors.md).

**SBOM.** Software Bill of Materials. Diatreme produces one in CycloneDX format
during image scanning and routes it to Dependency-Track.

**Snapshot (JWKS).** A copy of the last key set that successfully verified a
token, kept so the broker can still verify when an issuer's key endpoint is
unreachable. Refused once it's over 24 hours old.

**Versioning backend.** The tool that decides the next version number:
`semantic-release-python`, `semantic-release-npm`, `gitversion` or
`release-please`. Detected from repository markers when `versioning-tool` is
`auto`.
