# Architecture

Diatreme is two independent surfaces in one repo. They talk over HTTP and share no
code — the action calls the worker's broker endpoints; the worker never calls the
action.

```
GitHub Actions runner                         Cloudflare
┌──────────────────────────────┐              ┌────────────────────────────┐
│ action.yml (composite)       │  POST /token │ worker/src/index.ts        │
│  ├─ mode: ci                 │─────────────▶│  /token   OIDC→App token   │
│  ├─ mode: release            │  POST /sign  │  /sign    signed commit    │
│  └─ mode: enable-auto-merge  │─────────────▶│  /releases  aggregate      │
│  scripts/*.sh do the work    │              │  /webhook   push auto-update│
└──────────────────────────────┘              └────────────────────────────┘
```

## The composite action

`action.yml` is deliberately thin glue (83 inputs, 44 steps); the real logic lives
in `scripts/*.sh`, which are `bats`-tested. Three modes:

- **`ci`** — build and push the `pr-<N>` Docker image, optionally enforce branch
  naming, and (optionally) run a Trivy scan whose CycloneDX SBOM is routed to
  Dependency-Track and whose findings are routed to DefectDojo. Reporting is
  visibility-first: non-blocking unless `image-scan-gate`, sinks are
  failure-isolated, and a scanner that cannot run is a build error (not a finding).
- **`release`** — resolve auth, determine the target environment, delegate
  versioning to the selected backend, normalize outputs, optionally promote the
  Docker image, publish a GitHub Release, and optionally open a promotion PR.
  Before promoting a `pr-<N>` image it verifies the image's provenance labels
  (stamped by `mode: ci`) against the release commit's git tree; stale or
  unverifiable images are rebuilt from the release checkout instead of promoted.
- **`enable-auto-merge`** — enable native GitHub auto-merge for a specific PR.

**Versioning backends** are selected by `versioning-tool` (default `auto`, which
detects from repository markers): `semantic-release-python`, `semantic-release-npm`,
`gitversion`, `release-please`.

## The worker

`worker/src/index.ts` is a single-file Cloudflare Worker (`export default { fetch }`)
whose only runtime dependency is [`jose`](https://github.com/panva/jose). It exists
so callers don't have to register and run their own GitHub App.

| Endpoint | Purpose | Auth |
| --- | --- | --- |
| `POST /token` | Exchange a GitHub Actions OIDC token for a short-lived App installation token. | OIDC (`id-token: write`) |
| `POST /sign` | Create a GitHub-signed, App/bot-attributed commit via `createCommitOnBranch`. | `Bearer PROCESS_TRIGGER_SECRET` |
| `GET /releases` | Aggregated latest-release history across installations (KV-cached). | `Bearer PROCESS_TRIGGER_SECRET` |
| Webhook `push` | Fast-forward open PRs targeting the pushed branch (opt-in). | HMAC (`GITHUB_WEBHOOK_SECRET`) |

OIDC verification pins the issuer before selecting its JWKS, so a forged `iss` can't
select a foreign key. **GitHub Enterprise** (ghe.com / GHES) is opt-in via the
`GHE_*` environment: a GHE token is verified against that tenant's issuer and minted
via the GHE App against the GHE REST/GraphQL base.

!!! note "Deeper map for contributors"
    `PROJECT_INDEX.json` at the repo root has the module/callgraph breakdown, and
    `AGENTS.md` has the repository boundary and editing rules.
