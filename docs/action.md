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

## Skipping images that are already published

A multi-target promote that dies half way is the case that stings: the re-run
redoes every target that already landed before it reaches the one that did not.
`image-skip-existing` lets it resume instead.

```yaml
- uses: MagmaMoose/diatreme@v2
  with:
    mode: release
    image-skip-existing: true
```

**What it checks is identity, not existence.** A tag is a mutable pointer, and
anyone holding `packages: write` on the registry can create one — so "a tag with
that name is already there" is no evidence that Diatreme put it there. A gate
that skipped on existence alone would let an image this pipeline never built be
released, cosign-signed and attested under the release tag, and would step
straight over the provenance check that exists to stop exactly that.

So the gate runs *after* the provenance check on the promote source, and skips
only when the release tag already resolves to the **same manifest digest** as
the source it was about to retag. On a stable release it additionally requires
`:latest` to resolve to that digest; if it does not — an interrupted promote
that wrote the version tag but never moved `:latest` — the promote runs anyway
and repairs it. Anything unproven (registry outage, expired credential, an
unreadable manifest, a digest that differs) means promote it.

Two limits worth knowing before you turn it on:

- **It cannot skip a fresh build.** A rebuild's digest is not knowable in
  advance, so an image whose source failed provenance verification is rebuilt on
  every run. The saving is on the retag path.
- **It does not defend against a compromised registry credential.** Nothing here
  does: image promotion already trusts whoever can write to your registry. The
  digest comparison keeps this gate from *widening* that trust, which is the
  reason it is a digest comparison and not a lookup.

It applies to `mode: release` only — `pr-<N>` is a mutable tag and CI must
rebuild it on every push. Leave it off if you deliberately re-cut a version in
place (a moved or force-pushed tag), because there the already-published tag is
exactly what you meant to replace.

`images-promoted`, `images-skipped` and `images-rebuilt` report what each run
actually did.

## Who may cut a release

By default, whoever can push to or merge into the release branch can cut a
release. `allowed-release-actors` narrows that to a named list, and
`allowed-release-actors-from` picks the environment it starts applying at —
`@last`, the default, means production only.

```yaml
- uses: MagmaMoose/diatreme@v2
  with:
    mode: release
    allowed-release-actors: |
      alice
      @acme/release-managers
      acme-release-bot[bot]
```

Entries are GitHub logins, or teams written as `@org/team-slug` (`@team-slug`
resolves against this repository's owner). Separate them with newlines or commas,
or pass a JSON array. Matching is case-insensitive. Empty — the default — leaves
releases unrestricted, so the gate stays inert until you populate it.

Both the login the run is attributed to (`github.actor`) and the one that
started it (`github.triggering_actor`) have to clear the list. They are the same
person on an ordinary run; they differ on a **re-run**, where `github.actor`
stays the original initiator. Checking only that would leave the gate open to a
single click — anyone with write access could re-run an allowed person's failed
release and cut production under their name, and the log would record a pass.

This is not the gate `admin-required-from` provides. The two are independent, and
both are enforced when both are set:

| | `admin-required-from` | `allowed-release-actors` |
| --- | --- | --- |
| Fires on | `workflow_dispatch` only | every trigger, including push and merged promotion PRs |
| Asks | is this person a repo admin? | is this principal on the list? |
| Rights the release manager needs | repo admin: settings, secrets, branch protection | none |

!!! warning "List every bot that merges on your behalf"
    The actor is whoever triggered the run, and for a promotion PR that merges
    itself that is the bot, not the person who approved it. A bot missing from
    the list turns every automated promotion into a failed release. Add its login
    (`acme-release-bot[bot]`, `dependabot[bot]`, …) next to the people.

Team entries need the resolved token to be able to read org team membership; an
allowlist of plain logins makes no API call at all. A membership lookup that
cannot be completed **denies** the release — a check that did not happen is never
read as approval.

## Syncing the version into your manifests

`version-file` writes the released version back into the files that carry it and
commits them to the release branch. It takes one path, as it always has, or
several separated by newlines (preferred) or commas — and each entry may be a
glob:

```yaml
- uses: MagmaMoose/diatreme@v2
  with:
    mode: release
    version-file: |
      package.json
      packages/*/package.json
    version-file-json-path: .version
```

`*` and `**` are expanded against the workspace, and everything matched moves in
a **single commit** rather than one commit per file.

That is one commit, not an all-or-nothing guarantee, and the difference matters.
A file that cannot be updated — a missing path, a glob that matched nothing, a
path expression the file's shape rejects — is warned about and left out, and the
files that *did* update are still committed. So a mistyped entry leaves that one
manifest behind at the old version while its siblings move. Nothing fails; the
only signal is a `::warning::` in the release log. **Read that log the first
time you configure a multi-path `version-file`**, or check the resulting commit,
rather than assuming a green release means every manifest moved.

Format comes from the extension — `.yaml`/`.yml` through `yq` at
`version-file-yaml-path` (default `.appVersion`, for Helm charts), everything
else through `jq` at `version-file-json-path` — and that is one path expression
per format for the whole list, so keep files that share a schema together.

None of this can fail the release: the tag and the GitHub Release are already
published by the time it runs. A path that does not exist, a glob that matches
nothing, or a file the path expression cannot be applied to is warned about and
skipped, and the remaining files still commit. `version-files-updated` reports
how many were written.

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
`image-scanned`, `image-findings`, `image-signed`, `resolved-image-name`,
`images-promoted`, `images-skipped`, `images-rebuilt`, `version-files-updated`.

The three `images-*` counters partition a `mode: release` promote: every image is
either retagged from a verified source, skipped as already present, or rebuilt.

Each one's exact meaning is in the
[README's output table](https://github.com/MagmaMoose/diatreme#outputs).
