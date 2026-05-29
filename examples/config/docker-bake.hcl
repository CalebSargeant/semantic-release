# docker-bake.hcl — template for use with magmamoose/diatreme
#
# Standard env vars injected by tbd-ci.yaml and tbd-release.yaml:
#   VERSION    pr-<N> during CI, semver tag during release (e.g., v1.2.3-dev.1)
#   REGISTRY   container registry (default: ghcr.io)
#   IMAGE_NAME <owner>/<base-name> (e.g., my-org/my-app)
#   PLATFORMS  comma-separated platforms (e.g., linux/amd64,linux/arm64)
#
# Single-image repos: use the "default" target directly.
# Multi-image repos:  define one target per image, group them under "default".

variable "VERSION"    { default = "latest" }
variable "REGISTRY"   { default = "ghcr.io" }
variable "IMAGE_NAME" { default = "my-org/my-app" }
variable "PLATFORMS"  { default = "linux/amd64" }

# ── Multi-image example ─────────────────────────────────────────────────────
group "default" {
  targets = ["api", "worker"]
}

target "api" {
  context    = "."
  dockerfile = "Dockerfile.api"
  platforms  = split(",", PLATFORMS)
  tags       = ["${REGISTRY}/${IMAGE_NAME}-api:${VERSION}"]
}

target "worker" {
  context    = "."
  dockerfile = "Dockerfile.worker"
  platforms  = split(",", PLATFORMS)
  tags       = ["${REGISTRY}/${IMAGE_NAME}-worker:${VERSION}"]
}

# ── Single-image example (comment out multi-image above, uncomment this) ────
# target "default" {
#   context    = "."
#   dockerfile = "Dockerfile"
#   platforms  = split(",", PLATFORMS)
#   tags       = ["${REGISTRY}/${IMAGE_NAME}:${VERSION}"]
# }
