#!/usr/bin/env bash
set -euo pipefail

mode="${AUTH_MODE:-public-app}"
action_mode="${ACTION_MODE:-release}"
private_app_token="${PRIVATE_APP_TOKEN:-}"
public_app_token="${PUBLIC_APP_TOKEN:-}"
default_token="${DEFAULT_GITHUB_TOKEN:-}"

case "${mode}" in
  auto)
    if [[ -n "${private_app_token}" ]]; then
      token="${private_app_token}"
      source="private-app"
    else
      token="${default_token}"
      source="github-token"
    fi
    ;;
  github-token)
    token="${default_token}"
    source="github-token"
    ;;
  private-app)
    token="${private_app_token}"
    source="private-app"
    ;;
  public-app)
    if [[ -n "${public_app_token}" ]]; then
      token="${public_app_token}"
      source="public-app"
    elif [[ "${action_mode}" == "ci" || "${action_mode}" == "enable-auto-merge" ]]; then
      token="${default_token}"
      source="github-token"
    else
      token=""
      source="public-app"
    fi
    ;;
  *)
    echo "::error::Unsupported auth-mode '${mode}'. Use auto, github-token, private-app, or public-app."
    exit 1
    ;;
esac

if [[ "${mode}" == "private-app" && -z "${private_app_token}" ]]; then
  echo "::error::auth-mode private-app requires app-id and app-private-key."
  exit 1
fi

if [[ "${mode}" == "public-app" && "${action_mode}" != "ci" && "${action_mode}" != "enable-auto-merge" && -z "${public_app_token}" ]]; then
  echo "::error::auth-mode public-app requires a successful token broker exchange."
  exit 1
fi

if [[ -z "${token}" ]]; then
  echo "::error::Unable to resolve a GitHub token for auth-mode '${mode}'."
  exit 1
fi

if [[ -n "${default_token}" ]]; then
  echo "::add-mask::${default_token}"
fi
echo "::add-mask::${token}"

{
  echo "token=${token}"
  echo "source=${source}"
  echo "registry-token=${default_token}"
} >> "${GITHUB_OUTPUT}"

echo "Resolved GitHub auth token from ${source}."
