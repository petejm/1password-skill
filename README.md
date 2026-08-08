# 1password-skill

[![CI](https://github.com/petejm/1password-skill/actions/workflows/ci.yml/badge.svg)](https://github.com/petejm/1password-skill/actions/workflows/ci.yml)

A [Claude Code](https://code.claude.com/docs/en/overview) plugin that teaches Claude how to use the [1Password CLI (`op`)](https://www.1password.dev/cli/) safely and effectively.

No more fumbling with `op` flags, forgetting `--reveal`, or leaking secrets into your conversation. Install the plugin and Claude handles auth recovery, secret injection, SSH agent setup, git commit signing, shell plugins, service accounts, and troubleshooting — all with security guardrails built in.

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
| `Permission denied (publickey)` | Run the auth recovery flow (`op account get` → biometric → retry) |
| "I need a database password" | Use `op run` to inject it without exposing it in conversation |
| Setting up `op://` references | Guide you through `.env` templates and `op inject` |
| SSH agent not responding | Check socket paths per OS, verify with `ssh-add -l` |
| Git commit signing failures | Configure `op-ssh-sign` with the right paths |
| `gh`, `aws`, or `claude` should authenticate through 1Password | Set up the matching shell plugin with `op plugin init` |
| Headless / CI, no desktop app available | Switch to a service account token (`OP_SERVICE_ACCOUNT_TOKEN`) |
| Common `op` errors | Match the error → cause → fix |

### Security-First Design

The skill enforces 6 rules that align with [1Password's own AI guidance](https://www.1password.dev/get-started/secure-ai-access):

1. **`op run` over `op read`** — the secret never enters Claude's context window
2. **Never run `op` speculatively** — a call that needs authentication raises a biometric prompt on your desktop, away from the terminal, and physically interrupts you. An already-unlocked session answers silently, so Claude cannot know in advance which it will get
3. **Scope with `--vault`** on `op item get` and `op item list` — prevents exposing item names across all vaults. `op read` and `op run` have no `--vault` flag; there the vault is the first segment of the `op://` reference
4. **No secrets in files** — use `op run --env-file` or `op inject` for templating
5. **Don't bypass security hooks** — set `SSH_AUTH_SOCK` in your shell profile, not inline
6. **Keep secrets out of AI/MCP configs** — strip hardcoded values from tool configs and let `op run` supply them at launch

## Install

### Claude Code

From inside Claude Code, add the marketplace and install the plugin:

```
/plugin marketplace add petejm/1password-skill
/plugin install 1password-skill@petejm-plugins
```

If the install summary says `Run /reload-plugins to activate.`, run `/reload-plugins`.

Prefer not to use a marketplace? Clone the repo into your personal skills directory — it carries `.claude-plugin/plugin.json`, so Claude Code loads it as `1password-skill@skills-dir`:

```bash
mkdir -p ~/.claude/skills
git clone https://github.com/petejm/1password-skill.git ~/.claude/skills/1password-skill
```

For local development, load a working copy for the duration of a session without installing it:

```bash
claude --plugin-dir ./1password-skill
```

The skill activates automatically when you mention 1Password, `op` CLI, SSH auth issues, or secret references.

### Gemini CLI

After cloning this repo:

```bash
# Copy the skill to your Gemini skills directory
mkdir -p ~/.gemini/skills
cp -r integrations/gemini-cli/skills/1password ~/.gemini/skills/
```

Or symlink directly:
```bash
mkdir -p ~/.gemini/skills
ln -s /path/to/1password-skill/integrations/gemini-cli/skills/1password ~/.gemini/skills/
```

### Cursor

After cloning this repo:

```bash
# Copy the rule to your project
cp integrations/cursor/.cursor/rules/1password.mdc .cursor/rules/1password.mdc
```

The rule is set to `alwaysApply: true` so it loads automatically in every conversation.

### Aider

After cloning this repo:

```bash
# Copy to your project root
cp integrations/aider/CONVENTIONS.md ./CONVENTIONS.md
```

Aider does not pick the file up on its own — load it explicitly:

```bash
aider --read CONVENTIONS.md
```

To load it in every session, add `read: CONVENTIONS.md` to `.aider.conf.yml`. To load it mid-session, run `/read CONVENTIONS.md`. All three mark the file read-only, which also lets it be cached when prompt caching is enabled. See [Aider's conventions docs](https://aider.chat/docs/usage/conventions.html).

### Windsurf

After cloning this repo:

```bash
# Copy to your project root
cp integrations/windsurf/.windsurfrules .windsurfrules
```

Windsurf loads `.windsurfrules` automatically.

### Regenerating integrations

If you modify `skills/1password/SKILL.md`, regenerate all integration formats:

```bash
./scripts/convert.sh
```

Or target a specific tool: `./scripts/convert.sh --tool cursor`

Valid `--tool` values: `gemini-cli`, `cursor`, `aider`, `windsurf`, `all`

## Requirements

- [1Password CLI (`op`)](https://www.1password.dev/cli/) 2.30.0+ — the skill depends on `--reveal`, which landed in 2.30.0 along with concealed-by-default human-readable output
- 1Password desktop app with [CLI integration enabled](https://www.1password.dev/cli/get-started/#step-2-turn-on-the-1password-desktop-app-integration)
- Claude Code

## Shell Support

Code examples that use process substitution carry both a **bash/zsh** and a **Fish** variant, because `<(...)` becomes `(... | psub)` in Fish:

```bash
# bash/zsh
op run --env-file=<(echo "KEY=op://<vault>/<item>/<field>") -- ./app

# Fish
op run --env-file=(echo "KEY=op://<vault>/<item>/<field>" | psub) -- ./app
```

Other examples are written for bash/zsh only. The two translations you will need most often: `export VAR=value` is `set -gx VAR value` in Fish, and command substitution is `(...)`.

## Environment Overrides

If your environment has specific 1Password configuration (device socket paths, hook conflicts, infrastructure patterns), put it in a **companion skill that you own**, not inside the installed plugin. Marketplace installs live in a versioned cache (`~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/`) that is replaced on every update and wiped by the documented `rm -rf ~/.claude/plugins/cache` remedy, so anything you write there is lost on the next upgrade.

Create the override as a skill in a directory you control:

```
~/.claude/skills/1password-environment/SKILL.md      # personal — loads in every project
<repo>/.claude/skills/1password-environment/SKILL.md # project — shared with collaborators
```

Give it a frontmatter `description` that names your environment (for example, "Project-specific 1Password overrides — device SSH socket paths, security hook conflicts"). Claude loads it alongside this skill: the generic `op` knowledge plus your environment-specific context.

Keep secrets out of it. If the override contains sensitive infrastructure detail, use the personal `~/.claude/skills/` location, or gitignore the project path.

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
2. Edit `skills/1password/SKILL.md`, or add a new `skills/<name>/SKILL.md` directory — skills are auto-discovered and need no manifest change. Edit `.claude-plugin/plugin.json` only for plugin metadata
3. Test with `claude --plugin-dir ./1password-skill`, run `/reload-plugins` after each edit, and invoke `/1password-skill:1password`
4. Run `claude plugin validate ./1password-skill --strict` before opening the PR
5. Open a PR with a clear description of the problem your change solves

### Guidelines

- Keep the decision-router table updated if you add new sections
- Include both bash/zsh and Fish examples for any new code blocks that use process substitution
- Error catalog entries follow the format: `"error message"` → cause → `Fix: command`
- No real credentials, vault names, or infrastructure details in examples — use placeholders like `VaultName`, `ItemName`

## License

[Apache 2.0](LICENSE)
