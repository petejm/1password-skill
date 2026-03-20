---
name: 1password
description: |
  Interact with 1Password CLI (op) — auth recovery, secret retrieval, SSH agent,
  git commit signing, and troubleshooting. Use this skill when the user mentions
  1Password, op CLI, or when you know their environment uses the 1Password SSH agent.
  Also trigger on SSH "Permission denied" errors when 1Password agent is configured,
  secret retrieval requests mentioning vaults or op://, or git signing with SSH keys
  stored in 1Password. Trigger phrases: '1password', 'op cli', 'op whoami',
  'op run', 'op read', 'op inject', 'secret reference', 'op://', 'ssh agent 1password',
  'git signing 1password', 'biometric prompt', 'vault', '1password ssh'.
---

> Requires: `op` CLI 2.18+ with desktop app integration enabled. Run `op --version` to check.

# 1Password CLI — Decision Router

| You're seeing... | Go to |
|---|---|
| "Permission denied (publickey)" / git push auth fails | → Auth Recovery |
| Need a secret value at runtime | → Runtime Access |
| Setting up op:// in config files / .env | → Config File Patterns |
| SSH agent not responding / wrong socket path | → SSH Agent |
| Git commit signing setup or failures | → Git Signing |
| `op` hangs, times out, or biometric won't appear | → Troubleshooting |
| Wrong account / multi-account confusion | → Troubleshooting |
| `op` not found / not installed | → Troubleshooting |
| Specific error message | → Error Catalog |

## Security Rules

1. Prefer `op run` over `op read` — secret never enters conversation context.
2. Never run `op` commands speculatively — triggers biometric, interrupts user physically.
3. Always scope with `--vault` — prevents exposing item names across all vaults.
4. Never store secrets in files — use `op run --env-file` or `op inject` for templating.
5. Don't bypass security hooks — if a hook blocks `.1password/` paths, fix the approach (set `SSH_AUTH_SOCK` in shell profile, not per-command).
6. 1Password's AI guidance: use short-lived scoped tokens and minimize credential exposure to the model.

## Auth Recovery

The most common use case: SSH or git operations fail with auth errors after 1Password locked.

**Step 1: Trigger biometric unlock**
```bash
op whoami
```
Prompts appear on the desktop (NOT in the terminal). Wait for user to approve.

**Step 2: Verify SSH agent is alive**
```bash
ssh-add -l
```
Should list keys. "Could not open connection" → `SSH_AUTH_SOCK` not set. Set in shell profile: Linux `~/.1password/agent.sock`, macOS `~/.ssh/1password-agent.sock`.

**Step 3: Retry the failed operation** (git push, ssh, etc.)

**Multi-account:** If `op whoami` returns the wrong account:
```bash
op whoami --account my.1password.com
op account list  # list all configured accounts
```

## Runtime Access

Three methods in preference order. Always start with `op run`.

**Preferred: `op run`** — secret never in context
```bash
op run --env-file=<(echo "API_KEY=op://VaultName/ItemName/field") -- your-command
# Fish: op run --env-file=(echo "API_KEY=op://VaultName/ItemName/field" | psub) -- your-command
```

**Fallback: `op read`** — prints to stdout. Warn user: "This will display the secret value in this conversation."
```bash
op read --no-newline "op://VaultName/ItemName/credential"
```

**`op item get`** — always `--reveal` for actual values:
```bash
op item get "ItemName" --vault "VaultName" --fields label=password --reveal
op item get "ItemName" --vault "VaultName" --format json  # inspect all fields
```

Note: `--fields password` without `label=` may return wrong field. Use `label=fieldname`.

**Basic auth** (username+password, not token) — never use `curl -u` (mangles special chars):
```bash
OP_USER=$(op item get "ItemName" --vault "VaultName" --fields label=username --reveal)
PASS=$(op item get "ItemName" --vault "VaultName" --fields label=password --reveal)
HOST="api.example.com"
# <(...) creates a file descriptor, not a disk file — no cleanup needed
curl -s --netrc-file <(echo "machine $HOST login $OP_USER password $PASS") \
  "https://$HOST/api/endpoint"
```

> **Fish shell:** Use `(echo "machine $HOST login $OP_USER password $PASS" | psub)` instead of `<(...)`.

> **Note:** Fish's `psub` creates a temporary file in `/tmp` (unlike bash's `<(...)` which uses an anonymous pipe). The file is cleaned up automatically but briefly exists on disk. For sensitive credentials, prefer `op run` with an `.env.tpl` file instead.

## Config File Patterns

The `op://` URI format: `op://vault/item/field`

These references are safe to commit — they contain no secrets. Resolution happens at runtime.

**Three resolution methods:**

```bash
# 1. op run with .env file — preferred for apps
# .env.tpl (safe to commit):
# DATABASE_URL=op://MyVault/PostgreSQL/connection-string
# API_KEY=op://MyVault/ExternalAPI/key
op run --env-file=.env.tpl -- ./start-server

# 2. op inject for config file templating
# config.yml.tpl contains: api_key: "{{ op://Vault/Item/field }}"
op inject -i config.yml.tpl -o config.yml
# WARNING: config.yml now contains live secrets — add to .gitignore, delete after use

# 3. op read for single exported values
export TOKEN=$(op read --no-newline "op://Vault/Item/field")
```

**MCP server pattern:** `.env` with `op://` references, safe to commit:
```bash
# GITHUB_TOKEN=op://DevVault/GitHub/token
op run --env-file=.env -- npx @modelcontextprotocol/server-github
```

## SSH Agent

**Socket paths by OS:**
```bash
# Linux (most distros)
export SSH_AUTH_SOCK="$HOME/.1password/agent.sock"

# macOS
export SSH_AUTH_SOCK="$HOME/.ssh/1password-agent.sock"

# Auto-detect in bash/zsh
if [[ "$(uname)" == "Darwin" ]]; then
  export SSH_AUTH_SOCK="$HOME/.ssh/1password-agent.sock"
else
  export SSH_AUTH_SOCK="$HOME/.1password/agent.sock"
fi
```

**Fish shell** (`config.fish`):
```fish
set -gx SSH_AUTH_SOCK ~/.1password/agent.sock        # Linux
# set -gx SSH_AUTH_SOCK ~/.ssh/1password-agent.sock  # macOS
```

Best practice: set `SSH_AUTH_SOCK` in your shell profile (`~/.bashrc`, `~/.zshrc`, `config.fish`), not per-command. This prevents conflicts with security hooks that block commands containing `.1password/` paths.

**SSH config** (`~/.ssh/config`): `IdentityAgent ~/.1password/agent.sock`

**Health check:** `ssh-add -l` (lists keys); `ssh -T git@github.com 2>&1 || true`

"Could not open connection": check `$SSH_AUTH_SOCK`, confirm app is running, `op whoami` to unlock.

## Git Signing

Requires Git 2.34+.

**Setup:**
```bash
# Configure git to use SSH signing via 1Password
git config --global gpg.format ssh
git config --global user.signingkey "ssh-ed25519 AAAA..."  # your public key
git config --global commit.gpgsign true
git config --global gpg.ssh.program "/opt/1Password/op-ssh-sign"         # Linux
# macOS: "/Applications/1Password.app/Contents/MacOS/op-ssh-sign"
```

Copy public key from 1Password desktop app → SSH key item → public key field. Register as a **signing key** on GitHub/GitLab/Forgejo (separate from auth keys).

**Verify:** `git log --show-signature -1`

**Common errors:**
- "Couldn't find key in agent" → `op whoami` to unlock, `ssh-add -l` to confirm
- "Load key ... invalid format" → wrong key type or corrupted `user.signingkey`
- "Unverified" on GitHub → signing key not registered, or `user.email` mismatch
- Signing fails despite `op whoami` working → check `gpg.ssh.program` path (differs by OS)

## Error Catalog

```text
"Permission denied (publickey)"
→ 1Password locked or SSH agent not configured
→ Fix: `op whoami` (triggers biometric), `ssh-add -l` to verify keys loaded

"Could not open a connection to your authentication agent"
→ SSH_AUTH_SOCK not set or wrong socket
→ Fix: Set in shell profile. Linux: ~/.1password/agent.sock, macOS: ~/.ssh/1password-agent.sock

"op: error initializing client: connecting to 1Password Connect"
→ OP_CONNECT_HOST set but using desktop app integration
→ Fix: `unset OP_CONNECT_HOST OP_CONNECT_TOKEN`

"op: session expired"
→ Desktop app locked or timed out
→ Fix: `op whoami` (re-auth), retry command

"op: [ERROR] no account found"
→ op CLI not configured
→ Fix: 1Password desktop → Settings → Developer → enable CLI integration

"op: [ERROR] item not found"
→ Wrong item name or vault (case-sensitive)
→ Fix: `op item list --vault "VaultName"` to find exact name

"error: secret not found: op://Vault/Item/Field"
→ Vault, item, or field name wrong (all case-sensitive)
→ Fix: right-click field in 1Password → Copy Secret Reference

"sign_and_send_pubkey: signing failed ... agent refused operation"
→ Biometric denied or 1Password not running
→ Fix: check for prompt on desktop, restart app, then `op whoami`

"op: 403 Forbidden"
→ Service account missing vault access
→ Fix: check vault permissions in 1Password admin console

"op run: unrecognized option '--env-file'"
→ op CLI too old (requires 2.18+)
→ Fix: update op — https://developer.1password.com/docs/cli/

"op item get" returns masked/placeholder value instead of actual secret
→ Missing --reveal flag
→ Fix: `op item get "ItemName" --vault "VaultName" --fields label=password --reveal`
```

## Troubleshooting

**`op` not found / not installed:**
Install from https://developer.1password.com/docs/cli/. After install, enable CLI integration: 1Password desktop → Settings → Developer → "Integrate with 1Password CLI". Verify: `op --version`.

**op hangs / no biometric prompt:**
Prompt appears on the desktop, not in the terminal. On Linux/Wayland: check all workspaces. If hung 30s+: Ctrl+C, restart 1Password app, retry.

**op fails in Claude Code sandbox:**
Claude Code's bubblewrap sandbox strips setgid bits; `op` requires the `onepassword-cli` group. Symptom: works in terminal but fails as a Claude tool call. Workaround (issue #23642): run `op` in your shell before starting Claude, or use `op run` to inject secrets before the session.

**Wrong account:**
`op whoami` → shows active account. Switch: `op whoami --account my.1password.com`. List: `op account list`.

**1Password locked mid-session:**
Auto-locks after inactivity (10-30 min typical). SSH fails silently with "Permission denied." Fix: `op whoami` to re-unlock, then retry. Prevention: Settings → Security → Auto-lock.

**Shell plugin conflicts:**
1Password shell plugins for `gh` etc. don't work non-interactively (no biometric prompt). Disable in Claude sessions:
```bash
if [[ -z "$CLAUDECODE" ]]; then
  alias gh="op plugin run -- gh"
fi
```

**`op item get` returns masked values:**
`--fields password` without `--reveal` returns a placeholder. Always add `--reveal` for actual values.

**Multiple accounts / ambiguous results:**
Always use `--vault "VaultName"` to scope. Add `--account` flag if multi-account confusion persists.
