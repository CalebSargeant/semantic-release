# Rolling Back a Release

Use this guide when a release was cut but must be removed so that the previous
version becomes the effective latest.

This procedure covers repositories that use Diatreme with FluxCD
`ImagePolicy` and `ImageUpdateAutomation` for Kubernetes deployments. If your
repository does not use FluxCD, skip the Flux steps.

## Prerequisites

Your `gh` CLI token must have the `delete:packages` scope. Check with:

```bash
gh auth status
```

If `delete:packages` is missing, add it:

```bash
gh auth refresh -h github.com -s delete:packages
```

You also need `flux` CLI access to the target cluster if you want to force
reconciliation rather than waiting up to 5 minutes for the automatic scan.

## Why Order Matters

A common `ImagePolicy` configuration is semver-highest: pick the highest
semver tag currently in the container registry. If your policy uses a
different selection (alphabetical, numerical, regex), substitute
accordingly — but the ordering still applies: if you revert the
kustomization manifest first while the image tag still exists in GHCR,
the `ImageUpdateAutomation` will overwrite your change back within 5
minutes when the policy re-evaluates. Always remove the image from the
registry before touching any manifests.

## Procedure

### 1. Remove the image version from GHCR

GHCR's data model treats a package *version* (a digest-addressed object) as
the unit of deletion — not an individual tag. The delete API at
`/versions/<id>` removes the version and every tag pointing at it. Before
deleting, list the tags on the candidate version so you don't accidentally
delete a digest that's also tagged `latest`, `staging`, or another
release.

Find the internal version ID and its tag set for the release tag you want
to remove. Use `--paginate` so the lookup works when the package has more
than one page of versions (GHCR returns 30 per page by default). The path
is `/orgs/<org>/...` for org-owned packages and `/users/<user>/...` for
user-owned ones:

```bash
gh api --paginate /orgs/<org>/packages/container/<image_name>/versions \
  --jq '.[]
        | select((.metadata.container.tags // []) | index("<tag>"))
        | {id, tags: (.metadata.container.tags // [])}'
```

If the tag set contains only the release tag (and any throwaway tags),
delete the version:

```bash
gh api --method DELETE /orgs/<org>/packages/container/<image_name>/versions/<id>
```

If the version is also tagged `latest` or another environment tag,
**don't delete it** — re-tag `latest` (and any other shared tags) to the
previous version's digest first, then come back and delete the rolled-back
version.

**Example with placeholders** — `my-org` owns a container package `my-app`;
rolling back tag `v1.2.3`:

```bash
ID=$(gh api --paginate /orgs/my-org/packages/container/my-app/versions \
  --jq '.[]
        | select((.metadata.container.tags // []) | index("v1.2.3"))
        | .id')
gh api --method DELETE /orgs/my-org/packages/container/my-app/versions/$ID
```

### 2. Delete the GitHub Release

```bash
gh release delete <tag> --repo <org>/<repo> --yes
```

### 3. Delete the git tag

```bash
# Remote first, then local
git push origin --delete <tag>
git tag -d <tag>
```

### 4. Force Flux to re-scan

Without this step Flux waits up to 5 minutes before it notices the tag is
gone. Force it immediately:

```bash
flux reconcile image repository <imagerepository-name> -n flux-system
flux reconcile image policy <imagepolicy-name> -n flux-system
```

The `ImagePolicy` will now resolve to the previous highest tag. The
`ImageUpdateAutomation` will commit the updated tag into the configured
source repository branch on its next run (up to 5 minutes, or trigger it
manually):

```bash
flux reconcile image update <imageupdateautomation-name> -n flux-system
```

### 5. Verify

```bash
# Confirm the policy resolved to the expected tag
flux get image policy <imagepolicy-name> -n flux-system

# Confirm the automation committed the change
flux get image update <imageupdateautomation-name> -n flux-system
```

Check that the kustomization in the source repository now contains the
previous tag — for example `k8s/overlays/staging/kustomization.yaml` — and
that Flux has reconciled the workloads.

## What Not To Do

- Do not manually edit the kustomization before removing the image from GHCR.
  The automation will overwrite it.
- Do not delete the tag from the source repository only. As long as the image
  tag exists in GHCR, the `ImagePolicy` will keep selecting it.
