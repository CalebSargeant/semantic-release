# Diatreme

**Diatreme is a release/deployment orchestrator.** It has two independent surfaces
in one repository that communicate over HTTP — neither imports the other:

- **Composite action** (`action.yml` + `scripts/`) — published to the GitHub
  Marketplace. Runs semantic versioning, GitHub Releases, Docker image build and
  promotion, image scanning with SBOM/finding routing, and promotion-PR automation.
- **Cloudflare Worker** (`worker/`) — the hosted GitHub App backend at
  `api.diatreme.magmamoose.com`. An OIDC → installation-token broker and an
  App/bot-attributed commit/tag signer. Most users never touch it directly.

Install the action:

```yaml
- uses: MagmaMoose/diatreme@v2
  with:
    mode: release
```

!!! tip "Where to go next"
    - New here? Start with **[Setup](setup.md)**.
    - Want the big picture? See **[Architecture](architecture.md)**.
    - Configuring a pipeline? See **[Using the action](action.md)**.
    - The full, exhaustive input/output reference lives in the
      [repository README](https://github.com/MagmaMoose/diatreme#readme).

## The two surfaces at a glance

| Surface | Path | Toolchain | Ships to |
| --- | --- | --- | --- |
| Composite action | `action.yml` + `scripts/*.sh` | Bash, `actionlint`, `shellcheck`, `bats` | GitHub Marketplace |
| Cloudflare Worker | `worker/` | TypeScript, `wrangler`, `vitest` | Cloudflare |

## Related

- **[MagmaMoose/diatreme-pro](https://github.com/MagmaMoose/diatreme-pro)** — the
  separate private observability dashboard (release/run history) for the worker.
