# Using the action

<!-- sources: action.yml, scripts -->

This page is a task-oriented tour. The **exhaustive input/output tables** live in
the [repository README](https://github.com/MagmaMoose/diatreme#readme), this page
does not duplicate them so they cannot drift.

## Modes

```yaml
# CI: build + push the pr-<N> image on pull_request events
- uses: MagmaMoose/diatreme@v2
  with:
    mode: ci

# Release: version, release, promote (default mode)
- uses: MagmaMoose/diatreme@v2
  with:
    mode: release
    environment: prod

# Enable native auto-merge on a specific PR
- uses: MagmaMoose/diatreme@v2
  with:
    mode: enable-auto-merge
    pr-number: ${{ github.event.pull_request.number }}
```

## Versioning-tool detection

`versioning-tool: auto` (the default) resolves the backend from repository markers
under `working-directory`, so one shared release workflow can serve repos on
different tools. Detection is two-tier:

1. **A tool's own release config wins**: `pyproject.toml` `[tool.semantic_release]`,
   `.releaserc*` / `release.config.*`, `GitVersion.yml`,
   `release-please-config.json` / `.release-please-manifest.json`.
2. **Falls back to ecosystem manifests**: `pyproject.toml`/`setup.py`,
   `package.json`, `*.csproj`/`*.sln`, with a fixed precedence
   (`semantic-release-python` → `semantic-release-npm` → `gitversion`).

Conflicting tier-1 configs, or no markers at all, fail with an actionable error.
Passing an explicit `versioning-tool` skips detection entirely.

## Docker build definition

Diatreme detects **how** to build your image from what's in the repo. You don't
choose a builder, you just have the files:

1. **Docker Bake file present** (`docker-bake.hcl`, or `docker-bake.json` when
   `bake_file` is left at its default) → builds with `docker buildx bake`. Reach
   for this when you want multi-target builds, tag templating, multi-arch
   defaults, or local↔CI build parity.
2. **No bake file, but a `dockerfile` present** → Diatreme builds it directly
   with `docker buildx build -f <dockerfile> .`, honouring the same knobs it
   passes to bake: `platforms`, the computed `${registry}/${image_name}:${version}`
   tag(s) (plus `:latest` on stable releases), provenance labels, GitHub Actions
   cache, the `build-github-token` build secret, and `--push`. It also emits a
   workflow **warning** so the fallback is visible in the run summary.
3. **Neither** → no image is built; versioning-only runs are unaffected.

So the simplest consumer (one `Dockerfile`, no bake file) just works, instead
of failing with `open docker-bake.hcl: no such file or directory`. When no
`image_name` is given on this path, the base name falls back to the repository's
own name (lowercased).

!!! note "Multi-arch on the Dockerfile path"
    A plain Dockerfile has nowhere to declare a default platform set, so with
    `platforms` empty the fallback builds for the builder's default (single)
    architecture. Set `platforms: linux/amd64,linux/arm64` to produce a
    multi-arch manifest, exactly as bake would. For anything past a single image,
    prefer a `docker-bake.hcl`.

## Image scanning and SBOMs

When `mode: ci` builds the `pr-<N>` image it can scan it (Trivy) and route the
results to security backends:

- The **CycloneDX SBOM** goes to **Dependency-Track**.
- Optional **findings** go to **DefectDojo**.

Reporting is visibility-first: **non-blocking** unless you set `image-scan-gate`,
each sink is **failure-isolated** (a sink outage never fails your build), and a
scanner that cannot run is a **build error**, not a silent pass.

## Signing images and provenance

`image-sign: true` signs each released image with cosign in keyless mode and
attaches SLSA build provenance, by digest, during `mode: release`. It's opt-in
and off by default.

```yaml
- uses: MagmaMoose/diatreme@v2
  with:
    mode: release
    image-sign: true
```

The job needs `attestations: write` on top of its usual permissions, plus
`id-token: write`, which `auth-mode: public-app` already requires. The number of
images signed comes back in the `image-signed` output.

Signing happens by digest rather than by tag, so a later retag can't change what
was signed.

## When the broker is down

`auth-mode: public-app` calls a hosted broker for its token. A single hostname
losing egress would block releases in every repository pinned to every published
version, and no change shipped later can redirect those pins, so a second
hostname travels with the action.

| Input | Default | Behaviour |
| --- | --- | --- |
| `token-broker-url` | `https://api.diatreme.magmamoose.com` | Primary. Tried first, always. |
| `token-broker-fallback-url` | `https://broker-diatreme.magmamoose.com` | Tried only when the primary is unreachable or answers 5xx. Set to an empty string to disable. |

The fallback never fires on a 4xx. A rejected token is an answer, not an outage,
and asking a second broker the same question would just get the same refusal
more slowly. When the fallback is used, the run log carries a warning naming the
primary's status, and the final error names which broker answered.

Most repositories should leave both alone. Override them only if you run your
own broker, and read [Security](security.md) first: pointing them elsewhere
sends your OIDC tokens to that server.

## Publishing language packages

`publish-package` can push to GitHub Packages or public registries, on github.com
and GitHub Enterprise, for these ecosystems: `nuget`, `npm`, `maven`, `gradle`,
`rubygems`, `container`, `pip`, `s3`. See the README's "Publishing language packages"
section for per-ecosystem inputs (feed URLs, trusted publishing, provenance).

## Outputs

The action exposes: `version`, `tag`, `is-prerelease`, `released`,
`prerelease-identifier`, `resolved-environment`, `package-published`,
`image-scanned`, `image-findings`, `image-signed`, `resolved-image-name`.

Each one's exact meaning is in the
[README's output table](https://github.com/MagmaMoose/diatreme#outputs).
