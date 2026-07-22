# Security Policy

Diatreme is security-sensitive infrastructure: the hosted Cloudflare Worker is an
**OIDC → GitHub App installation-token broker** (`/token`), an **App/bot-attributed
commit & tag signer** (`/sign`), and an HMAC-verified webhook receiver. It holds a
GitHub App private key and mints short-lived, write-scoped installation tokens. We
take reports against it seriously.

## Supported versions

| Version | Supported |
| --- | --- |
| `v2.x` (current major) | ✅ |
| `v1.x` and earlier | ❌ end-of-life — please upgrade to `@v2` |

## Reporting a vulnerability

**Please do _not_ open a public issue for security reports.**

Report privately via **[GitHub Private Vulnerability Reporting](https://github.com/MagmaMoose/diatreme/security/advisories/new)**
(Security → Advisories → *Report a vulnerability*). If that is unavailable, email
**caleb@magmamoose.com** with subject `SECURITY: diatreme`.

Please include: affected surface (Action / Worker endpoint), a description and
impact, reproduction steps or a proof of concept, and any suggested remediation.

## Scope

In scope:

- The Worker endpoints `/token`, `/sign`, `/releases`, and the `/webhook` HMAC
  verification.
- Handling of the secrets `GITHUB_APP_PRIVATE_KEY`, `PROCESS_TRIGGER_SECRET`,
  `GITHUB_WEBHOOK_SECRET` (and the `GHE_*` equivalents).
- The composite action's token resolution and any command-injection / secret-leak
  surface in `action.yml` and `scripts/*.sh`.

Out of scope: vulnerabilities in third-party dependencies without a demonstrated
impact on Diatreme, and findings that require a compromised runner or maintainer
account.

## Response targets

- **Acknowledgement:** within 3 business days.
- **Initial triage / severity assessment:** within 7 business days.

We follow coordinated disclosure and will credit reporters who wish to be named.
There is currently no paid bug-bounty program.

## Hardening note for consumers

For strict supply-chain reproducibility, pin Diatreme to a full commit SHA
(`uses: MagmaMoose/diatreme@<sha>`) rather than the floating `@v2` major tag.
