# Security Policy

## Scope

**borealOS** is a Debian-based Linux distribution. Security issues generally fall into two categories:

- **borealOS-specific issues** — bugs in this project's own code: the OpenRC integration/configuration, build/packaging scripts, default configurations, install tooling, branding assets, or anything else maintained in this repository. **Report these here.**
- **Upstream issues** — vulnerabilities in Debian packages, OpenRC itself, the Linux kernel, or other software borealOS ships but does not author. These should be reported to the relevant upstream project:
  - Debian: [Debian Security](https://www.debian.org/security/) / [security@debian.org](mailto:security@debian.org)
  - OpenRC: the [OpenRC repository](https://github.com/OpenRC/openrc)

If you're unsure which category an issue falls into, report it here and we'll help route it.

## Supported Versions

borealOS is in early, pre-release development (no tagged releases yet). Security fixes are applied to the `main` branch only.

| Version          | Supported          |
| ----------------- | ------------------ |
| `main` (latest)    | :white_check_mark: |
| Older commits/forks | :x:                 |

This table will be updated once tagged releases begin.

## Reporting a Vulnerability

**Please do not open a public GitHub issue for security vulnerabilities.**

Instead, use one of the following private channels:

1. **GitHub Private Vulnerability Reporting (preferred):** go to the [Security tab](https://github.com/DamianDaniel/borealOS/security) of this repository and select **"Report a vulnerability"**. This opens a private advisory visible only to maintainers.
2. **Direct contact:** message [@DamianDaniel](https://github.com/DamianDaniel) on GitHub if private reporting is unavailable or you need an alternate channel.

When reporting, please include where possible:

- A description of the vulnerability and its potential impact
- Steps to reproduce, or a proof of concept
- Affected component(s) (e.g. OpenRC integration, installer, a specific script or package)
- Any suggested mitigation, if known

## What to Expect

This is a small, early-stage, community-driven project, so please bear with us on timelines — there is no dedicated security team yet. As a general guide:

- **Acknowledgment:** we'll aim to confirm receipt of your report within a few days.
- **Assessment:** we'll investigate and let you know if it's accepted, needs more information, or is out of scope (e.g. an upstream issue).
- **Fix and disclosure:** for accepted issues, we'll work on a fix and coordinate with you on timing before any public disclosure. We ask that you give us a reasonable window to address the issue before disclosing it publicly.

## Recognition

If you'd like credit for a responsibly disclosed vulnerability, let us know in your report and we'll happily acknowledge you once a fix is released (e.g. in release notes or a security advisory), unless you'd prefer to remain anonymous.

Thank you for helping keep borealOS and its users safe.