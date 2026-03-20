# 1password-skill

A [Claude Code](https://docs.anthropic.com/en/docs/claude-code) plugin that teaches Claude how to use the [1Password CLI (`op`)](https://developer.1password.com/docs/cli/) safely and effectively.

No more fumbling with `op` flags, forgetting `--reveal`, or leaking secrets into your conversation. Install the plugin and Claude handles auth recovery, secret injection, SSH agent setup, git signing, and troubleshooting — all with security guardrails built in.

## The Problem

Using 1Password with AI coding assistants is tricky:

- **Secrets leak into context** — `op read` prints credentials where the model can see them
- **Biometric prompts are invisible** — they appear on your desktop, not in the terminal. Claude doesn't know to wait
- **`op` flags are footguns** — `--fields password` vs `label=password`, missing `--reveal`, `curl -u` mangling special characters
- **Auth breaks silently** — 1Password auto-locks, SSH starts failing with "Permission denied", and Claude has no idea why
- **Shell differences** — `<(...)` process substitution doesn't work in Fish; you need `psub`

## What This Skill Does

Gives Claude a **decision router** — a lookup table that maps what you're seeing to exactly what to do:

| You're seeing... | Claude will... |
|---|---|
| `Permission denied (publickey)` | Run the auth recovery flow (`op whoami` → biometric → retry) |
| "I need a database password" | Use `op run` to inject it without exposing it in conversation |
| Setting up `op://` references | Guide you through `.env` templates and `op inject` |
| SSH agent not responding | Check socket paths per OS, verify with `ssh-add -l` |
| Git commit signing failures | Configure `op-ssh-sign` with the right paths |
| Any of 11 common `op` errors | Match the exact error → cause → fix |

### Security-First Design

The skill enforces 6 rules that align with [1Password's own AI guidance](https://developer.1password.com/docs/cli/secrets-security/):

1. **`op run` over `op read`** — the secret never enters Claude's context window
2. **Never run `op` speculatively** — every `op` call triggers a biometric prompt on your desktop
3. **Always `--vault` scope** — prevents accidentally exposing item names across all vaults
4. **No secrets in files** — use `op run --env-file` or `op inject` for templating
5. **Don't bypass security hooks** — set `SSH_AUTH_SOCK` in your shell profile, not inline
6. **Minimize credential exposure** — short-lived scoped tokens where possible

## Install

```bash
git clone https://github.com/petejm/1password-skill.git ~/.claude/plugins/1password-skill
```

Then restart Claude Code. The skill activates automatically when you mention 1Password, `op` CLI, SSH auth issues, or secret references.

## Requirements

- [1Password CLI (`op`)](https://developer.1password.com/docs/cli/) 2.18+
- 1Password desktop app with [CLI integration enabled](https://developer.1password.com/docs/cli/get-started/#step-2-turn-on-the-1password-desktop-app-integration)
- Claude Code

## Shell Support

All code examples include both **bash/zsh** and **Fish** variants. The main difference: process substitution `<(...)` becomes `(... | psub)` in Fish.

```bash
# bash/zsh
op run --env-file=<(echo "KEY=op://Vault/Item/field") -- ./app

# Fish
op run --env-file=(echo "KEY=op://Vault/Item/field" | psub) -- ./app
```

## Environment Overrides

Projects often have specific 1Password configuration — device-specific socket paths, security hook conflicts, infrastructure credentials. Create a sibling file to customize:

```
skills/1password/environment.md    # your project-specific overrides
```

This keeps the public skill generic while letting each project add its own context. Claude reads both files when the skill activates.

## How It Works

This is a **skill**, not a tool or MCP server. It's a structured markdown document that Claude reads when relevant topics come up. No code runs, no API calls are made by the plugin itself — it simply gives Claude the knowledge to use `op` correctly.

The decision-router pattern means Claude doesn't have to read the entire document every time. It matches your situation to the right section and follows the instructions there.

## Contributing

Issues and PRs welcome! The skill is a single markdown file at `skills/1password/SKILL.md` — no build step, no dependencies, easy to read and review.

### What makes a good contribution

- **New error catalog entries** — hit a confusing `op` error that isn't listed? Add the error message, cause, and fix
- **Shell variants** — we cover bash/zsh and Fish, but other shells (nushell, PowerShell) are welcome
- **Platform-specific fixes** — Windows/WSL paths, NixOS quirks, container gotchas
- **Security improvements** — better patterns for minimizing credential exposure
- **Workflow patterns** — common `op` usage patterns (CI/CD, MCP servers, Docker) that others would benefit from

### How to contribute

1. Fork the repo
2. Edit `skills/1password/SKILL.md` (or `plugin.json` if adding new skill files)
3. Test by cloning your fork into `~/.claude/plugins/1password-skill` and verifying Claude picks up the changes
4. Open a PR with a clear description of the problem your change solves

### Guidelines

- Keep the decision-router table updated if you add new sections
- Include both bash/zsh and Fish examples for any new code blocks that use process substitution
- Error catalog entries follow the format: `"error message"` → cause → `Fix: command`
- No real credentials, vault names, or infrastructure details in examples — use placeholders like `VaultName`, `ItemName`

## License

[Apache 2.0](LICENSE)
