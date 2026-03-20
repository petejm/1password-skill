# 1password-skill

A Claude Code plugin that teaches Claude to interact with the [1Password CLI (`op`)](https://developer.1password.com/docs/cli/) for auth recovery, secret retrieval, SSH agent management, git commit signing, and troubleshooting.

## What It Does

Provides a decision-router skill that guides Claude through common 1Password operations:

- **Auth Recovery** — SSH/git failures from locked 1Password → biometric unlock flow
- **Runtime Access** — `op run` (preferred), `op read`, `op item get` with security rules
- **Config File Patterns** — `op://` references, `.env` templates, `op inject`
- **SSH Agent** — socket paths by OS, health checks, shell profile setup
- **Git Signing** — SSH-based commit signing via 1Password
- **Error Catalog** — 11 common errors with causes and fixes

## Security Rules

1. Prefer `op run` over `op read` — secret never enters conversation context
2. Never run `op` speculatively — triggers biometric, interrupts user physically
3. Always scope with `--vault` — prevents exposing item names across vaults
4. Never store secrets in files — use `op run --env-file` or `op inject`

## Install

```bash
# Clone to your plugins directory
git clone https://github.com/petejm/1password-skill.git ~/.claude/plugins/1password-skill
```

Or add to an existing project's `.claude/plugins/` directory.

## Requirements

- `op` CLI 2.18+ with desktop app integration enabled
- 1Password desktop app (for biometric unlock)

## Environment Overrides

If your project has specific 1Password configuration (device socket paths, hook conflicts, infrastructure patterns), create `skills/1password/environment.md` alongside the skill with your project-specific overrides.

## License

MIT
