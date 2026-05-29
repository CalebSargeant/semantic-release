<p align="center">
  <img src="diatreme-logo.png" alt="Diatreme" width="200">
</p>

# Diatreme

Diatreme is the GitHub Marketplace Action published as
`magmamoose/diatreme@v1`.

It creates semantic version releases from GitHub Actions. It can also build pull
request Docker images and promote or rebuild those images with release tags in
GHCR.

## Start Here

| If you need | Read |
|---|---|
| A quick Marketplace usage example | [GitHub README](https://github.com/magmamoose/diatreme) |
| The concepts behind the action | [Concepts](concepts.md) |
| Organization-level auth setup | [Organization setup](organization-setup.md) |
| Which inputs match your release flow | [Choose your setup](choose-your-setup.md) |
| Files and workflows to add to a repository | [Repository setup](repository-setup.md) |
| Every supported input and output | [Action inputs and outputs](reference/action-inputs-outputs.md) |

## Common Setups

| Goal | Setup |
|---|---|
| Create stable tags from `main` | Production-only release |
| Build and tag GHCR images | PR CI with `mode: ci`, release with `image_name` |
| Require Copilot PR Review before merge | [Require Copilot Review](copilot-review.md) |
| Release `dev`, `staging`, and `prod` from one branch | Trunk-Based Development with promotion PRs |
| Release from long-lived environment branches | Branch-Based Development with `branch-map` |

The recommended path for a new repository is:

1. read [Concepts](concepts.md)
2. choose a flow in [Choose your setup](choose-your-setup.md)
3. add the files from [Repository setup](repository-setup.md)
