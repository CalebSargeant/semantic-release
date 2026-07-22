# Using the action

This page is a task-oriented tour. The **exhaustive input/output tables** live in
the [repository README](https://github.com/MagmaMoose/diatreme#readme) — this page
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

1. **A tool's own release config wins** — `pyproject.toml` `[tool.semantic_release]`,
   `.releaserc*` / `release.config.*`, `GitVersion.yml`,
   `release-please-config.json` / `.release-please-manifest.json`.
2. **Falls back to ecosystem manifests** — `pyproject.toml`/`setup.py`,
   `package.json`, `*.csproj`/`*.sln` — with a fixed precedence
   (`semantic-release-python` → `semantic-release-npm` → `gitversion`).

Conflicting tier-1 configs, or no markers at all, fail with an actionable error.
Passing an explicit `versioning-tool` skips detection entirely.

## Docker build definition

Diatreme detects **how** to build your image from what's in the repo — you don't
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

So the simplest consumer — one `Dockerfile`, no bake file — Just Works, instead
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

## Publishing language packages

`publish-package` can push to GitHub Packages or public registries, on github.com
and GitHub Enterprise, for these ecosystems: `nuget`, `npm`, `maven`, `gradle`,
`rubygems`, `container`, `pip`. See the README's "Publishing language packages"
section for per-ecosystem inputs (feed URLs, trusted publishing, provenance).

## Outputs

The action exposes: `version`, `tag`, `is-prerelease`, `released`,
`prerelease-identifier`, `resolved-environment`, `package-published`,
`image-scanned`, `image-findings`, `resolved-image-name`.
