# Diatreme

[![CI](https://github.com/magmamoose/diatreme/actions/workflows/ci.yaml/badge.svg)](https://github.com/magmamoose/diatreme/actions/workflows/ci.yaml)
[![Release](https://github.com/magmamoose/diatreme/actions/workflows/release.yaml/badge.svg)](https://github.com/magmamoose/diatreme/actions/workflows/release.yaml)
[![GitHub Marketplace](https://img.shields.io/badge/Marketplace-Diatreme-purple?logo=github)](https://github.com/marketplace/actions/diatreme)
[![License](https://img.shields.io/github/license/magmamoose/diatreme)](https://github.com/magmamoose/diatreme/blob/main/LICENSE)

Diatreme is a **release/deployment orchestrator**: a composite GitHub Action for semantic-release across TBD and BBD workflows. It runs release flows, builds PR Docker images, scans the assembled image and ships its SBOM to Dependency-Track (and optional findings to DefectDojo), promotes already-built GHCR images by retagging, opens promotion PRs, publishes language packages (npm/maven/gradle/rubygems/containers), and normalizes release outputs across multiple versioning tools.

This repository holds **both surfaces** of Diatreme:

| Surface | Path | What it is |
| --- | --- | --- |
| **Composite Action** | [`action.yml`](action.yml) + [`scripts/`](scripts) | The GitHub Marketplace action your workflows call as `uses: magmamoose/diatreme@v1`. |
| **Cloudflare Worker** | [`worker/`](worker) | The hosted GitHub App backend the action calls at `api.diatreme.magmamoose.com` — the OIDC **token broker** and the **commit/tag signer** that makes App/bot-attributed release commits. |

The Action is what you install from the Marketplace; the Worker is the GitHub App backend that lets `auth-mode: public-app` mint release tokens and sign release commits without you registering your own App. **Most users only need the Action** — start at [Quickstart](#quickstart). To self-host or develop the backend, see [The Diatreme Worker](#the-diatreme-worker).

## Quickstart

Production-only release from `main`, using the hosted Diatreme GitHub App token broker:

```yaml
name: Release

on:
  push:
    branches: [main]

jobs:
  release:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      id-token: write
    steps:
      - uses: magmamoose/diatreme@v1
        with:
          environment: prod
          environments: '["prod"]'
          prerelease-identifiers: '{}'
```

Install the [Diatreme GitHub App](https://github.com/apps/diatreme/installations/new) on the repository or organization. Add your versioning tool's config — a `pyproject.toml` `[tool.semantic_release]` section for the example above — and merge conventional commits. Diatreme writes the tag, GitHub Release, changelog, and normalized outputs.

By default (`versioning-tool: auto`) Diatreme picks the versioning tool from repository markers, so the same workflow works whether a repo versions with python-semantic-release, semantic-release (npm), GitVersion, or release-please — no per-repo `versioning-tool` needed. See [Versioning tool detection](#versioning-tool-detection).

## Required Permissions

For the default `auth-mode: public-app`, the workflow needs `id-token: write` so Diatreme can exchange GitHub OIDC for a short-lived installation token. Keep `contents: read` for checkout. Add only the permissions needed by the selected features:

| Feature | Additional workflow permissions |
| --- | --- |
| Docker PR image push or release promotion | `packages: write` |
| Package publishing to a GitHub Packages feed (`publish-package`) | `packages: write` |
| Public-npm provenance (`npm-provenance`) or PyPI Trusted Publishing (`pypi-trusted-publishing`) | `id-token: write` (already required by the default `auth-mode: public-app`) |
| Promotion PR creation | handled by the Diatreme App token; use `pull-requests: write` only when using `auth-mode: github-token` |
| `auth-mode: github-token` release writes | `contents: write`, plus `pull-requests: write` when creating PRs |

## Examples

PR Docker image build:

```yaml
name: CI

on:
  pull_request:

jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
      pull-requests: read
    steps:
      - uses: magmamoose/diatreme@v1
        with:
          mode: ci
          image_name: my-app
```

Multi-environment TBD with promotion PRs:

```yaml
name: Release

on:
  push:
    branches: [main]
  pull_request:
    types: [closed]

jobs:
  release:
    if: github.event_name == 'push' || github.event.pull_request.merged == true
    runs-on: ubuntu-latest
    permissions:
      contents: read
      id-token: write
      packages: write
    steps:
      - uses: magmamoose/diatreme@v1
        with:
          mode: release
          deployment-model: tbd-pr
          environment: dev
          environments: '["dev", "staging", "prod"]'
          prerelease-identifiers: '{"dev": "dev", "staging": "rc"}'
          create-promotion-pr: 'true'
          image_name: my-app
```

Branch-based development:

```yaml
steps:
  - uses: magmamoose/diatreme@v1
    with:
      deployment-model: bbd
      branch-map: '{"develop": "dev", "release/*": "staging", "main": "prod"}'
```

## Publishing language packages

Set `publish-package: true` and pick a `package-ecosystem` to pack and push a
library package using the version Diatreme just computed — instead of bolting a
separate `pack`/`push` step onto your release workflow. Publishing is opt-in,
runs only when a new version was released (`released == true`), and inherits the
same environment gating as versioning: dev/staging runs publish the prerelease
version (e.g. `1.2.3-rc.1`), prod runs publish the stable version. The package
is pushed before the GitHub Release is published, so a `release:published`
listener finds it already in the feed.

### Choosing where to publish

`package-feed-url` is the **upload/publish endpoint**. Two questions decide what
to point it at.

**1. Which GitHub host are you on?** The registry hostname tracks the host:

| Host | Language-package hosts | Container host |
| --- | --- | --- |
| github.com / standard Enterprise Cloud | `<ecosystem>.pkg.github.com` | `ghcr.io` |
| Enterprise Server (e.g. `github.example.com`) | `<ecosystem>.HOSTNAME` | `containers.HOSTNAME` |
| Enterprise Cloud with data residency (`SUBDOMAIN.ghe.com`) | `<ecosystem>.SUBDOMAIN.ghe.com` | `containers.SUBDOMAIN.ghe.com` |

Diatreme is host-agnostic for the language ecosystems — `package-feed-url` is an
input, so point it at whichever host applies. The per-ecosystem defaults below
assume github.com. See [GitHub Enterprise](#github-enterprise) for the exact
host forms and caveats (notably: the Container registry needs subdomain
isolation on Enterprise Server, and the Apache Maven registry is not offered on
data-residency tenants).

**2. Public or internal?** (a github.com / Enterprise Cloud distinction)

- **Containers** → GitHub Packages (`ghcr.io`) works at any visibility: public
  images can be pulled anonymously with `docker pull`, so ghcr is a good default
  for both internal and public images.
- **Internal/private language packages** — consumers are authenticated org
  members → GitHub Packages (`*.pkg.github.com`) is a good default, which is why
  Diatreme defaults the GitHub Packages ecosystems there.
- **Public language packages** — you want anonymous installs → point
  `package-feed-url` at the canonical public registry instead (npmjs,
  nuget.org, rubygems.org, Maven Central, PyPI). **Every GitHub Packages
  registry except the Container registry requires a token to *consume*, even for
  public packages**
  ([GitHub docs](https://docs.github.com/en/packages/learn-github-packages/about-permissions-for-github-packages)),
  so a package on `*.pkg.github.com` cannot be installed anonymously.

On GitHub Enterprise the two axes collapse. A private Enterprise Server or
data-residency instance has no "public" tier in the github.com sense —
everything lives behind the enterprise's auth boundary. There, "internal" means
the enterprise's *own* registry host, and public/upstream dependencies are
normally proxied through the enterprise's artifact manager (Nexus, Artifactory,
…) rather than pulled from the canonical public registries. The "use the
canonical public registry" advice above is a github.com / Enterprise Cloud
concept.

Supported ecosystems. `nuget`, `maven`, `gradle`, `rubygems`, and `container`
default to **this repo's own GitHub Packages feed** (`*.pkg.github.com` /
`ghcr.io` on github.com), so `package-feed-url` / `package-token` can be omitted
for *internal* distribution. `npm` and `pip` default to the **public** registry
(`registry.npmjs.org` / PyPI). Override `package-feed-url` for public
distribution of the GitHub Packages ecosystems, or for any GitHub Enterprise
host (see above):

- `nuget` — `dotnet pack` + `dotnet nuget push`.
- `npm` — `npm publish` (prereleases go to a non-`latest` dist-tag named after
  the environment's prerelease identifier).
- `maven` — `mvn versions:set` + `mvn deploy` (credentials in a per-run
  `settings.xml`, kept off the project tree).
- `gradle` — `gradle publish` via the project's `maven-publish` block; the
  version and the conventional `GITHUB_ACTOR`/`GITHUB_TOKEN` credentials are
  passed through for the `GitHubPackages` repository.
- `rubygems` — `gem build` + `gem push`.
- `container` — `docker build` + `docker push` to
  `ghcr.io/<owner>/<repo>:<version>` (override the registry host with
  `package-feed-url` — e.g. an enterprise `containers.HOSTNAME` — and the image
  name with `package-name`). Complements the existing image *promotion* — this
  builds and publishes the release version.
- `pip` — `python -m build` + `twine upload` (PyPI or any index; not a GitHub
  Packages ecosystem, kept for convenience).

Publish an internal shared-components library to a private GitHub Enterprise
NuGet feed — Diatreme's originating use case — with versioning and publishing in
a single call:

```yaml
name: Release

on:
  push:
    branches: [main]

jobs:
  release:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      id-token: write
      packages: write
    steps:
      - uses: magmamoose/diatreme@v1
        with:
          versioning-tool: gitversion
          environment: prod
          environments: '["prod"]'
          prerelease-identifiers: '{}'
          publish-package: 'true'
          package-ecosystem: nuget
          package-path: src/SharedComponents/SharedComponents.csproj
          package-feed-url: https://nuget.example.ghe.com/my-org/index.json
          package-token: ${{ secrets.NUGET_FEED_TOKEN }}
```

For the repository owner's GitHub Packages NuGet feed, omit `package-feed-url`
and `package-token` — they default to `https://nuget.pkg.github.com/<owner>/index.json`
and the workflow `GITHUB_TOKEN` (which needs `packages: write`).

The same defaults apply to the other GitHub Packages ecosystems (Maven, Gradle,
RubyGems, and Container → `ghcr.io`). For `container`, `package-path` is the
Docker build context and `package-name` defaults to `<owner>/<repo>`.

> **Version source.** Diatreme sets the published version where the tooling
> allows (`-p:Version`, `npm version`, `mvn versions:set`, `-Pversion`, the image
> tag). For `pip` and `rubygems` it comes from the project manifest
> (`pyproject.toml` / the `.gemspec`), so persist it there before publishing.

> When `package-ecosystem: npm`, let Diatreme do the publish — set
> `npmPublish: false` on `@semantic-release/npm` so versioning and publishing
> don't both push the package.

> **Public npm = npmjs, not GitHub Packages.** Diatreme's npm default is
> `https://registry.npmjs.org`, which serves public packages without auth. If
> you instead point `package-feed-url` at `npm.pkg.github.com`, consumers need a
> token to `npm install` the package — even when it is public — so reserve
> GitHub Packages for *internal* npm packages.
>
> Set `npm-provenance: true` to publish to npmjs with build
> [provenance](https://docs.npmjs.com/generating-provenance-statements)
> (`npm publish --provenance`). It needs `id-token: write` on the job (the
> default `auth-mode: public-app` already grants it) and a public `repository`
> field in `package.json` matching this repo; it is rejected on any non-npmjs
> feed.

### GitHub Enterprise

Publishing works the same on GitHub Enterprise — the auth model is unchanged
(the Actions `GITHUB_TOKEN`, or the `package-token` you pass, just authenticates
against the enterprise instance instead of github.com). Only the **host**
changes, so set `package-feed-url` to the matching registry host. (The NuGet
example above already targets an enterprise host.)

**Enterprise Server** (self-hosted, subdomain isolation enabled) — hosts are
derived from the instance hostname (`HOSTNAME`):

| Ecosystem | `package-feed-url` |
| --- | --- |
| `nuget` | `https://nuget.HOSTNAME/<org>/index.json` |
| `npm` | `https://npm.HOSTNAME` |
| `maven` / `gradle` | `https://maven.HOSTNAME/<org>/<repo>` |
| `rubygems` | `https://rubygems.HOSTNAME` |
| `container` | `containers.HOSTNAME` |

The Container registry **requires subdomain isolation** to be enabled on the
instance — without it there is no container host. (Older releases exposed a
legacy Docker registry at `docker.HOSTNAME`; image refs that use it keep working
after the instance migrates to `containers.HOSTNAME`.)

**Enterprise Cloud with data residency** — a `SUBDOMAIN.ghe.com` tenant, where
`SUBDOMAIN` is your enterprise's unique subdomain:

| Ecosystem | `package-feed-url` |
| --- | --- |
| `nuget` | `https://nuget.SUBDOMAIN.ghe.com/<org>/index.json` |
| `npm` | `https://npm.SUBDOMAIN.ghe.com` |
| `rubygems` | `https://rubygems.SUBDOMAIN.ghe.com` |
| `container` | `containers.SUBDOMAIN.ghe.com` |

> **Maven/Gradle on data residency.** The GitHub Packages Apache Maven registry
> is **not available** on data-residency (`*.ghe.com`) tenants. Publish JVM
> artifacts to your enterprise's own Maven host (Nexus, Artifactory, …) via
> `package-feed-url` instead.

Standard Enterprise Cloud organizations (accessed at github.com, no data
residency) use the public `*.pkg.github.com` / `ghcr.io` hosts — the same
defaults as github.com.

### Maven and Gradle: not a Maven Central release

The `maven` and `gradle` paths run `mvn deploy` / `gradle publish` against a
**Maven-style repository** — GitHub Packages by default, or your enterprise
Maven host. This is *not* a Maven Central release flow: Central requires GPG
signing and a staging / Central Portal (formerly OSSRH) deployment that this
action does not perform. To release to Maven Central, drive it from a tool built
for that flow — [JReleaser](https://jreleaser.org/) or the
[`central-publishing-maven-plugin`](https://central.sonatype.org/publish/publish-portal-maven/) —
rather than `publish-package`.

### Private Python indexes (pip)

GitHub Packages has **no Python registry** (on github.com or Enterprise), so
`pip` is not a GitHub Packages ecosystem — it always targets PyPI or a separate
index. Two endpoints are involved, and they are independent:

- **Upload** — `package-feed-url` is twine's `--repository-url`. Empty publishes
  to PyPI.
- **Install** — consumers set `pip install --index-url`; that's a separate
  concern Diatreme does not configure.

Options for the private upload target:

- [pypiserver](https://github.com/pypiserver/pypiserver) — minimal; serves a
  directory of wheels.
- [devpi](https://www.devpi.net/) — private index with staging and a
  pull-through PyPI mirror.
- [Nexus](https://www.sonatype.com/products/sonatype-nexus-repository) /
  [Artifactory](https://jfrog.com/artifactory/) — multi-format artifact managers
  (the usual enterprise target).
- Managed: AWS CodeArtifact, GCP Artifact Registry, Azure Artifacts, Cloudsmith,
  Gemfury.

In an Enterprise context the pip target is usually the org's *existing* internal
index (Nexus / Artifactory / CodeArtifact), since GitHub Enterprise has no
Python registry either.

For the managed clouds the upload token is often short-lived — mint it in a
preceding step and pass it as `package-token`. AWS CodeArtifact, for example:

```yaml
      - name: CodeArtifact token
        id: ca
        run: |
          echo "token=$(aws codeartifact get-authorization-token \
            --domain my-domain --query authorizationToken --output text)" >> "$GITHUB_OUTPUT"
      - uses: magmamoose/diatreme@v1
        with:
          # …versioning inputs…
          publish-package: 'true'
          package-ecosystem: pip
          package-feed-url: https://my-domain-111122223333.d.codeartifact.us-east-1.amazonaws.com/pypi/my-repo/
          package-username: aws
          package-token: ${{ steps.ca.outputs.token }}
```

> **Dependency-confusion footgun.** Don't naively add a private
> `--extra-index-url` alongside PyPI: pip considers *all* configured indexes and
> installs the highest version, so a public squatter can shadow a private
> package name. Prefer a single `--index-url` pointing at a pull-through proxy
> (devpi, Nexus, Artifactory) that fronts both your packages and PyPI, or
> namespace your packages. [PEP 708](https://peps.python.org/pep-0708/) is the
> standards-side fix as indexes adopt it.

> **Trusted Publishing (OIDC) for public PyPI.** Set
> `pypi-trusted-publishing: true` to upload to public PyPI / TestPyPI with **no
> stored token** — Diatreme mints a short-lived token from the job's GitHub OIDC
> identity. It needs `id-token: write` (the default `auth-mode: public-app`
> already grants it) and a
> [Trusted Publisher](https://docs.pypi.org/trusted-publishers/) configured for
> this repo + workflow on the PyPI project. It is public-PyPI/TestPyPI only;
> private indexes still authenticate with `package-token`.

Publishing to public PyPI via Trusted Publishing (no `package-token`):

```yaml
    # Needs id-token: write on the job — granted by default `auth-mode:
    # public-app`; add it explicitly under `auth-mode: github-token`.
    permissions:
      id-token: write
    steps:
      - uses: magmamoose/diatreme@v1
        with:
          # …versioning inputs…
          publish-package: 'true'
          package-ecosystem: pip
          pypi-trusted-publishing: 'true'
          # package-feed-url omitted → public PyPI; for TestPyPI set it to
          # https://test.pypi.org/legacy/
```

## Docker image name

`image_name` is **optional**. Just as Diatreme infers the release environment
from your deployment model and branch-map, it infers the image name from your
Docker Bake config when you don't pass one — so platform repos don't need a
bespoke pre-step to compute it.

Resolution order:

1. **Explicit `image_name`** always wins and is used verbatim (as before). It
   sets `IMAGE_NAME=<owner>/<image_name>` for bake files that consume that
   variable.
2. **Auto-detect from Docker Bake.** When `image_name` is empty and the
   `bake_file` exists, Diatreme runs `docker buildx bake -f <bake_file>
   <bake_target> --print`, takes the **first non-empty target tag**, and strips
   the digest, tag, registry host, and owner/org prefix down to the base name:

   | First bake tag | Detected `image_name` |
   | --- | --- |
   | `ghcr.io/platform1-systems/backend:latest` | `backend` |
   | `ghcr.io/platform1-systems/camera-probe-propagator:v1` | `camera-probe-propagator` |
   | `platform1-systems/admin-frontend:latest` | `admin-frontend` |

3. **No `image_name` and no bake file** → the name stays empty and the image
   steps (CI build, image scan, release promotion) are skipped. Versioning-only
   workflows are unaffected.

A bake file that exists but produces **no tags** is a hard error — Diatreme
never silently falls back to the repository name; fix the bake target or pass
`image_name` explicitly.

Detection feeds every image path identically to an explicit value, so **`mode:
ci` image builds and BBD release image promotion work without passing
`image_name`** as long as `docker-bake.hcl` has tagged targets:

```yaml
steps:
  - uses: magmamoose/diatreme@v1
    with:
      deployment-model: bbd
      branch-map: '{"staging": "staging", "main": "prod"}'
      # image_name omitted — detected from docker-bake.hcl tags.
```

The value Diatreme used is exposed as the `resolved-image-name` output.

**Opting out.** If a repo keeps a tagged `docker-bake.hcl` but uses Diatreme for
**versioning only**, set `detect-image-name: false` so a bare `mode: ci` /
`release` run does not start building or promoting images. With detection off,
`image_name` behaves exactly as before — empty leaves image workflows off; an
explicit `image_name` still turns them on.

For multi-target bake **groups** with distinct images, detection resolves a
single base name (the first target `bake --print` emits) — consistent with the
single-`IMAGE_NAME` model. It only gates the image steps and sets the
`IMAGE_NAME` bake var; the scan and promote steps still enumerate every target
from the bake tags, so multi-image builds are not collapsed to one.

## Image scanning and SBOMs

In `mode: ci`, after the `pr-<N>` image is built, Diatreme can scan the
**assembled** image and route the results to two sinks. This is the image's
view of the world — base-image packages and whatever the Dockerfile added —
which a source-dependency scan never sees.

- **CycloneDX SBOM → Dependency-Track.** The image's component inventory is
  uploaded as its own Dependency-Track project (distinct from any
  source-dependency SBOM project for the same repo). Dependency-Track derives
  component CVEs from the SBOM and re-checks them as new advisories land.
- **Findings → DefectDojo** *(optional)*. The Trivy report is imported for what
  SBOM matching misses — OS-level CVEs, image misconfigurations, and secrets
  baked into layers.

Reporting is **visibility-first**: a successful scan never blocks the PR unless
you opt in with `image-scan-gate: true`. A scanner that cannot run at all is a
build error, never reported as "no findings". Both sinks are
**failure-isolated** — a Dependency-Track or DefectDojo outage logs a warning
and does not fail the build. Each sink activates only when its URL is set.

The scanned `pr-<N>` image is the exact artifact that `mode: release` later
promotes by digest, so what is scanned on the PR is what ships.

The uploads use the same wire format as [Chargate](https://github.com/MagmaMoose/chargate),
which ships SBOMs and SARIF to these backends today: the SBOM is `POST`ed to
Dependency-Track's `/api/v1/bom` as a multipart raw file, and DefectDojo imports
via `reimport-scan` (one Test per engagement, updated across PR re-runs).

```yaml
name: CI

on:
  pull_request:

jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
      pull-requests: read
    steps:
      - uses: magmamoose/diatreme@v1
        with:
          mode: ci
          image_name: my-app
          image-scan: 'true'
          dependency-track-url: https://dtrack.example.com
          dependency-track-api-key: ${{ secrets.DEPENDENCY_TRACK_API_KEY }}
          # Optional findings feed:
          defectdojo-url: https://defectdojo.example.com
          defectdojo-api-key: ${{ secrets.DEFECTDOJO_API_KEY }}
          defectdojo-product-name: my-app
          # Stay non-blocking at first; flip on once the signal is trusted:
          # image-scan-gate: 'true'
```

## Versioning tool detection

`versioning-tool` defaults to `auto`, which detects the tool from markers in
`working-directory`. This lets one shared release workflow serve repos on
different versioning tools — set an explicit tool only to override detection.

Detection runs in two tiers:

**Tier 1 — a tool's own release config** (authoritative; each marker maps to
exactly one tool):

| Marker | Resolves to |
| --- | --- |
| `pyproject.toml` with a `[tool.semantic_release]` table | `semantic-release-python` |
| `.releaserc*` / `release.config.*` | `semantic-release-npm` |
| `GitVersion.yml` / `GitVersion.yaml` (or a custom `gitversion-config`) | `gitversion` |
| `release-please-config.json` / `.release-please-manifest.json` (or a custom `release-please-config-file`) | `release-please` |

If two or more distinct tier&#8209;1 tools match, the repo has conflicting
release configs and the run **errors** — set `versioning-tool` explicitly to
disambiguate.

**Tier 2 — ecosystem manifests** (consulted only when no tier&#8209;1 config is
found):

| Marker | Resolves to |
| --- | --- |
| `pyproject.toml` / `setup.py` / `setup.cfg` | `semantic-release-python` |
| `package.json` | `semantic-release-npm` |
| `*.csproj` / `*.sln` | `gitversion` |

When several tier&#8209;2 manifests coexist, a fixed precedence
(`semantic-release-python` → `semantic-release-npm` → `gitversion`) breaks the
tie so a Python service that also ships a `package.json` still resolves to
`semantic-release-python`. If nothing matches at all, the run **errors** with
the full marker list.

A tier&#8209;2 match resolves the *tool*, not a config file: a `.csproj`-only
repo runs GitVersion on its built-in defaults, and no `GitVersion.yml` is
required. The same holds for the other tools — each falls back to its own
defaults when its config file is absent.

## Inputs

All inputs are optional unless noted. Defaults match `action.yml`.

| Input | Default | Purpose |
| --- | --- | --- |
| `mode` | `release` | `ci`, `release`, or `enable-auto-merge`. |
| `auth-mode` | `public-app` | Token source: hosted public App, private App, workflow token, or auto. |
| `token-broker-url` | `https://api.diatreme.magmamoose.com` | Hosted broker base URL override. |
| `oidc-audience` | `diatreme` | OIDC audience used for public App auth. |
| `versioning-tool` | `auto` | `auto` (detect from repo markers — see [Versioning tool detection](#versioning-tool-detection)), `semantic-release-python`, `semantic-release-npm`, `gitversion`, or `release-please`. |
| `deployment-model` | `tbd` | `tbd`, `bbd`, or `tbd-pr`. |
| `branch-map` | `''` | JSON branch-to-environment map for BBD. |
| `promote-branch-prefix` | `promote` | Branch prefix for `tbd-pr` promotion PRs. |
| `promote-target-branch` | `main` | Target branch for promotion PRs. |
| `create-promotion-pr` | `false` | Open or refresh the next environment promotion PR after prerelease. |
| `environment` | `''` | Target environment, required for plain `tbd`. |
| `environments` | `["dev", "staging", "prod"]` | Ordered environment list; last entry is stable production. |
| `prerelease-identifiers` | `{"dev": "dev", "staging": "rc"}` | Environment-to-prerelease suffix map. |
| `tag-prefix` | `v` | Version tag prefix. |
| `github-token` | `''` | Override token for GHCR login and github-token auth mode. |
| `app-id` | `''` | Private GitHub App ID. |
| `app-private-key` | `''` | Private GitHub App PEM. |
| `submodules` | `false` | Pass-through to checkout: `false`, `true`, or `recursive`. |
| `image_name` | `''` | Base image name without registry or owner. Optional — auto-detected from the Docker Bake config (`bake_file`/`bake_target`) when omitted; an explicit value wins. See [Docker image name](#docker-image-name). |
| `bake_file` | `docker-bake.hcl` | Docker Bake file. |
| `bake_target` | `default` | Docker Bake target or group. |
| `detect-image-name` | `true` | Auto-detect `image_name` from the Docker Bake config when it is empty. Set `false` to opt out (versioning-only repos with a tagged bake file). Explicit `image_name` always wins. |
| `registry` | `ghcr.io` | Container registry. |
| `registry-username` | `''` | Explicit registry login username. |
| `registry-password` | `''` | Explicit registry login password or token. |
| `platforms` | `linux/amd64` | Target platforms for CI builds and fallback fresh builds. |
| `build-github-token` | `''` | Docker Bake secret `github_token` for private package installs. |
| `image-scan` | `false` | Scan the assembled `pr-<N>` image in `mode: ci` and emit SBOM + findings. Opt-in. Requires a resolved image name (explicit `image_name` or bake-detected). |
| `image-scan-severity` | `CRITICAL,HIGH` | Trivy severity filter for findings and the gate. The SBOM still inventories all components. |
| `image-scan-scanners` | `vuln,secret,misconfig` | Trivy scanners for the findings report. |
| `image-scan-gate` | `false` | Fail the build when findings at/above `image-scan-severity` exist. Non-blocking by default. |
| `image-scan-strict` | `false` | Treat a Dependency-Track / DefectDojo sink failure as fatal. Default keeps sinks failure-isolated. |
| `dependency-track-url` | `''` | Dependency-Track base URL. When set, the image's CycloneDX SBOM is uploaded. Outages are non-blocking. |
| `dependency-track-api-key` | `''` | Dependency-Track API key with BOM upload permission. |
| `dependency-track-project-name` | `''` | DT project name. Defaults to the image repository path with an `(image)` suffix (e.g. `owner/app (image)`), distinct from a source-SBOM project for the same repo. |
| `dependency-track-project-version` | `''` | DT project version. Defaults to the image tag (e.g. `pr-12`). |
| `dependency-track-auto-create` | `true` | Auto-create the DT project/version on first upload (needs `PROJECT_CREATION_UPLOAD` on the key). |
| `defectdojo-url` | `''` | DefectDojo base URL. When set, the Trivy findings report is imported. Optional; outages are non-blocking. |
| `defectdojo-api-key` | `''` | DefectDojo API v2 token. |
| `defectdojo-engagement` | `''` | DefectDojo engagement id to import into. Or set `defectdojo-product-name` for auto-created context. With neither set (and a URL), the import is skipped with a warning. |
| `defectdojo-product-name` | `''` | DefectDojo product name for the auto-create-context import path. |
| `defectdojo-product-type` | `''` | DefectDojo product type for the auto-create-context path. |
| `defectdojo-engagement-name` | `''` | DefectDojo engagement name for auto-create-context. Default `Diatreme image scan`. |
| `defectdojo-close-old` | `true` | Close findings no longer present on reimport (Diatreme imports via `reimport-scan`). |
| `publish-package` | `false` | Pack and push a language package to `package-feed-url` after versioning. Opt-in. |
| `package-ecosystem` | `''` | `nuget`, `npm`, `maven`, `gradle`, `rubygems`, `container`, or `pip`. Required when `publish-package` is true. |
| `package-path` | `''` | Project/path to pack/build/publish. Defaults to `working-directory`. |
| `package-feed-url` | `''` | Feed/registry URL. Empty → the repo's GitHub Packages feed per ecosystem (`ghcr.io` for container; the public registry for npm/pip). |
| `package-token` | `''` | Feed auth token. Defaults to the workflow `GITHUB_TOKEN` (GitHub Packages). |
| `package-username` | `''` | Login username. Default `__token__` (pip) / `x-access-token` (maven, gradle, rubygems, container). Ignored by nuget/npm. |
| `dotnet-version` | `8.0.x` | .NET SDK version for `package-ecosystem: nuget`. |
| `python-version` | `3.x` | Python version for `package-ecosystem: pip`. |
| `node-version` | `20` | Node.js version for `package-ecosystem: npm`. |
| `java-version` | `17` | JDK version for `package-ecosystem: maven`/`gradle`. |
| `java-distribution` | `temurin` | JDK distribution for `maven`/`gradle` (setup-java). |
| `ruby-version` | `3.3` | Ruby version for `package-ecosystem: rubygems`. |
| `package-name` | `''` | Image name for `package-ecosystem: container`. Defaults to `<owner>/<repo>`. |
| `npm-provenance` | `false` | Publish to npmjs with `npm publish --provenance`. npmjs-only; needs `id-token: write`. |
| `pypi-trusted-publishing` | `false` | Upload to public PyPI/TestPyPI via GitHub OIDC instead of `package-token`. Needs `id-token: write`. |
| `enforce_branch_naming` | `true` | Enforce TBD PR branch naming in `mode: ci`. Allowed prefixes: `feat`, `fix`, `chore`, `hotfix`, `docs`, `refactor`, `perf`, `test`, `ci`, `style`, `build`, `revert`, `deploy`, `release` (plus the promote prefix). |
| `extra-branch-prefixes` | `''` | Extra branch prefixes to accept beyond the built-in set (comma/space/pipe-separated), e.g. `spike wip`. Letters, digits, `_` and `-` only; anything else is rejected. |
| `aggregate-github-projects` | `false` | Append linked Projects v2 items to release docs. |
| `move-github-projects-on-release` | `false` | Move linked Projects v2 items after release. |
| `github-projects-target-status` | `Released` | Target Projects v2 status. |
| `github-projects-move-on-environments` | `@last` | Environments where Projects movement runs. |
| `admin-required-from` | `@last` | Environments where manual production releases require repo admin. |
| `working-directory` | `.` | Repository subdirectory where versioning runs. |
| `create-release` | `true` | Create GitHub Release when the backend supports it. |
| `changelog` | `true` | Let supported backends update changelogs. |
| `force-bump` | `''` | Force the bump level (`patch`/`minor`/`major`) instead of deriving it from commits (semantic-release-python, semantic-release-npm, gitversion; ignored by release-please). |
| `version-override` | `''` | Create this exact version instead of deriving one. |
| `version-file` | `''` | Tracked file to update with the released version. |
| `version-file-json-path` | `.Application.Version` | JSON path for version-file injection. |
| `version-file-yaml-path` | `.appVersion` | YAML path for version-file injection. |
| `aggregate-clickup-tickets` | `false` | Append ClickUp ticket links from the release range. |
| `gitversion-spec` | `6.x` | GitVersion action version spec. |
| `gitversion-config` | `''` | GitVersion config file. Empty lets GitVersion pick up a root `GitVersion.yml`/`GitVersion.yaml`, or run on its built-in defaults when neither exists. |
| `gitversion-appsettings-file` | `''` | Deprecated; use `version-file`. |
| `gitversion-appsettings-version-path` | `''` | Deprecated; use `version-file-json-path`. |
| `release-please-release-type` | `simple` | release-please release type. |
| `release-please-config-file` | `release-please-config.json` | release-please config file. |
| `pr-number` | `''` | PR number for `mode: enable-auto-merge`. |
| `auto-merge-method` | `squash` | Auto-merge method: `squash`, `merge`, or `rebase`. |

## Outputs

| Output | Description |
| --- | --- |
| `version` | Semver version string without prefix, such as `1.2.3` or `1.2.3-rc.1`. |
| `tag` | Full git tag with prefix, such as `v1.2.3`. |
| `is-prerelease` | `true` when this environment produces a prerelease. |
| `released` | `true` when a new version was created and published. |
| `prerelease-identifier` | Prerelease identifier, or empty for production. |
| `resolved-environment` | The resolved environment name. |
| `package-published` | `true` when a language package was packed and pushed to the configured feed. |
| `image-scanned` | `true` when the assembled `pr-<N>` image(s) were scanned (`mode: ci` with `image-scan`). |
| `image-findings` | Count of image-scan findings at/above `image-scan-severity` across all scanned images. |
| `resolved-image-name` | The base image name used for image workflows — explicit `image_name`, or the value auto-detected from Docker Bake. Empty on versioning-only runs. |

## The Diatreme Worker

The [`worker/`](worker) directory is the Cloudflare Worker — the GitHub App backend — behind the hosted broker at `https://api.diatreme.magmamoose.com`. The Action's default `auth-mode: public-app` calls it so you never have to register and run your own GitHub App. You can also self-host it and point the Action at your own deployment with the `token-broker-url` input.

| Endpoint | Purpose |
| --- | --- |
| `POST /token` | Exchange a GitHub Actions OIDC token for a short-lived App installation token. |
| `POST /sign` | Create a GitHub-signed, **App/bot-attributed** release commit (version bumps / tags) via `createCommitOnBranch`. |
| `GET /releases` | Aggregated release history (for the dashboard). |

Develop and deploy with [Wrangler](https://developers.cloudflare.com/workers/wrangler/):

```bash
cd worker
npm install
npm run check     # typecheck + tests + wrangler dry-run deploy
npm test          # vitest only
wrangler dev      # run locally
wrangler deploy   # ship to Cloudflare
```

Configuration (secrets and vars) is documented in [`worker/README.md`](worker/README.md) and [`worker/.dev.vars.example`](worker/.dev.vars.example). The private observability dashboard for this worker is the separate [`MagmaMoose/diatreme-pro`](https://github.com/MagmaMoose/diatreme-pro) repository.

## Release Notes

Use immutable tags or SHAs for strict reproducibility. `@v1` is the floating major tag that this repository updates after each stable release. The root release workflow dogfoods `uses: ./`, then force-updates the matching major tag after semantic-release publishes a stable version.

Docker promotion prefers `docker buildx imagetools create` so multi-arch manifests are preserved. For the known GitHub Enterprise Packages referrers-index parse error, Diatreme falls back to pull/tag/push for single-arch images, then to a fresh Docker Bake build if retagging cannot work.

Before promoting a `pr-<N>` image, Diatreme verifies it was actually built from the code being released. `mode: ci` stamps every image with `org.opencontainers.image.revision` (build commit) and `com.magmamoose.diatreme.git-tree` (that commit's git tree) — injected at build time, so no bake-file changes are needed. `mode: release` compares the image's tree against the release commit's tree; a PR that was merged while behind the branch tip fails the comparison (its CI image is stale) and the release rebuilds from the release checkout instead of promoting old code under the new tag. Images that cannot be verified — including ones built by pre-provenance Diatreme versions — also take the fresh-build path. Later-environment promotions (e.g. `v1.2.3-rc.1` → `v1.2.3`) are exempt: carrying the previous environment's artifact forward unchanged is their purpose.

A Magma Moose product.
