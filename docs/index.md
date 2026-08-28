# Diatreme

**Diatreme is a release/deployment orchestrator.** It has two independent surfaces
in one repository that communicate over HTTP, neither imports the other:

- **Composite action** (`action.yml` + `scripts/`), published to the GitHub
  Marketplace. Runs semantic versioning, GitHub Releases, Docker image build and
  promotion, image scanning with SBOM/finding routing, and promotion-PR automation.
- **Hosted broker**, the GitHub App backend at `api.diatreme.magmamoose.com`.
  An OIDC to installation-token broker and an App-attributed commit and tag
  signer. Most users never touch it directly. `worker/` in this repository is
  its TypeScript implementation; see [Deployment](operations/deployment.md) for
  what actually serves that hostname.

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
    - Hit a red X? Go straight to **[Errors](reference/errors.md)**.
    - Running your own broker? See **[Broker configuration](reference/configuration.md)**.
    - The full, exhaustive input/output reference lives in the
      [repository README](https://github.com/MagmaMoose/diatreme#readme).

## The two surfaces at a glance

| Surface | Path | Toolchain | Ships to |
| --- | --- | --- | --- |
| Composite action | `action.yml` + `scripts/*.sh` | Bash, `actionlint`, `shellcheck`, `bats` | GitHub Marketplace |
| Broker (production) | `broker/` | Python, `pytest`, `boto3` | AWS Lambda, eu-west-1 |
| Broker (legacy) | `worker/` | TypeScript, `wrangler`, `vitest` | Rollback target (not currently serving) |

## Related

- **[MagmaMoose/diatreme-pro](https://github.com/MagmaMoose/diatreme-pro)**: the
  separate private observability dashboard (release/run history) for the worker.
