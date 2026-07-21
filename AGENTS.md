# AGENTS.md

Guidelines for developers and AI agents working on this codebase.

## Versioning Convention

Every script contains a `SCRIPT_VERSION` variable (e.g. `SCRIPT_VERSION="v0.0.1"`).
This version is used by the auto-update mechanism to compare against GitHub releases.
The GitHub Actions release workflow auto-bumps the patch version (e.g. v0.0.1 → v0.0.2).

**Whenever you modify a script, you MUST update its `SCRIPT_VERSION`.**

Follow [Semantic Versioning](https://semver.org/):
- `vMAJOR.MINOR.PATCH` (e.g. `v1.2.3`)
- **PATCH** — bug fixes, small tweaks, comments, docs-only changes
- **MINOR** — new features, new options, backward-compatible changes
- **MAJOR** — breaking changes (removed options, renamed scripts, changed behavior)

### Examples

```bash
# Bug fix → bump patch
SCRIPT_VERSION="v1.0.0"  →  SCRIPT_VERSION="v1.0.1"

# New feature → bump minor
SCRIPT_VERSION="v1.0.1"  →  SCRIPT_VERSION="v1.1.0"

# Breaking change → bump major
SCRIPT_VERSION="v1.1.0"  →  SCRIPT_VERSION="v2.0.0"
```

All three scripts share the same version number since they are released together
via the GitHub Actions release workflow (`.github/workflows/release.yml`).
Bump the version in **all three files** to the same value.

## File Locations

| File | Purpose |
|---|---|
| `lxc-updater.sh` | Full LXC auto-updater with Telegram reports |
| `pve-update-notifier.sh` | Check-only update notifier |
| `system-update-notifier.sh` | Host system updater with Telegram reports |
| `telegram.conf.example` | Template for Telegram credentials |
| `telegram.conf` | Actual credentials (gitignored) |
| `.github/workflows/release.yml` | Auto-release workflow |

## Code Style

- Use `#!/bin/bash` or `#!/usr/bin/env bash` as shebang
- Each script is self-contained — no shared libraries
- Follow existing patterns for `log()`, `send_telegram()`, config loading
- Always use `command -v` instead of `which`
- Quote all variables: `"$var"` not `$var`
- Use `[[ ]]` instead of `[ ]` for conditionals

## Release Notes

When creating or editing a release, always write the release notes with `gh`:

```bash
# Edit an existing release's notes
gh release edit <tag> --notes "## What's Changed
- description of change
..."

# Or write notes from a file
gh release edit <tag> --notes-file CHANGELOG.md
```

Never leave auto-generated (`--generate-notes`) notes as-is — always rewrite them
with a clear summary of what changed and how to upgrade.

## Testing

Validate syntax before committing:
```bash
bash -n script.sh
```
