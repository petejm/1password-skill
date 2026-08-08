
> Requires: `op` CLI 2.30.0+ with desktop app integration enabled — 2.30.0 made human-readable
> output concealed by default and added the `--reveal` flag this skill depends on.
> Run `op --version` to check.

# 1Password CLI — Decision Router

| You're seeing... | Go to |
|---|---|
| "Permission denied (publickey)" / git push auth fails | → Auth Recovery |
| Need a secret value at runtime | → Runtime Access |
| Don't know the vault, item, or field name | → Runtime Access |
| Setting up op:// in config files / .env | → Config File Patterns |
| SSH agent not responding / wrong socket path | → SSH Agent |
| Git commit signing setup or failures | → Git Signing |
| `gh`, `aws`, or `claude` should authenticate through 1Password | → Shell Plugins |
| Headless / CI / no desktop app available | → Service Accounts |
| `op` hangs, times out, or biometric won't appear | → Troubleshooting |
| Wrong account / multi-account confusion | → Troubleshooting |
| `op` not found / not installed | → Troubleshooting |
| Specific error message | → Error Catalog |

## Security Rules

1. Prefer `op run` over `op read` — secret never enters conversation context. Never add `--no-masking`.
2. Never run `op` commands speculatively — a command that needs authentication raises a biometric prompt on the user's desktop and physically interrupts them. An already-unlocked session answers silently (`op signin --help`: "'op signin' is idempotent. It only prompts for authentication if you aren't already authenticated"), so you cannot tell in advance which one you will get. Run `op` only when the user's request requires it.
3. Scope with `--vault` on `op item get` / `op item list` — prevents exposing item names across all vaults. `op read` and `op run` have no `--vault` flag; for those the vault is the first segment of the `op://` reference.
4. Never store secrets in files — use `op run --env-file` or `op inject` for templating.
5. Don't bypass security hooks — if a hook blocks `.1password/` paths, fix the approach (set `SSH_AUTH_SOCK` in shell profile, not per-command).
6. 1Password's Secure AI access guidance: strip hardcoded secrets out of AI/MCP tool configs and let `op run` supply them at launch. See the MCP server pattern under Config File Patterns.

## Auth Recovery

The most common use case: SSH or git operations fail with auth errors after 1Password locked.

**Step 1: Trigger biometric unlock**
```bash
op account get
```
Prompts appear on the desktop (NOT in the terminal). Wait for user to approve.

**Important:** With desktop app integration (system auth, op 2.30+), do NOT reach for `op whoami`
from an agent shell — it has been observed reporting no authenticated account while every other
`op` command in the same shell works. Use `op account get` instead; it is the reliable check.
Two carve-outs: under `OP_SERVICE_ACCOUNT_TOKEN`, `op whoami` is the check to use — its help says
it "Returns the currently active account or service account", while `op account list --help`
scopes itself to "users and accounts set up on this device". CLI-only sign-in via
`op account add` is unaffected.

**Step 2: Verify SSH agent is alive**
```bash
ssh-add -l
```
Should list keys.
- "Could not open a connection to your authentication agent" → `SSH_AUTH_SOCK` not set or wrong. See SSH Agent.
- Keys listed, but not the one you need → the agent only offers keys from your default Personal/Private/Employee vault unless `agent.toml` says otherwise. See SSH Agent → agent.toml.

**Step 3: Retry the failed operation** (git push, ssh, etc.)

**Multi-account:** if `op account get` returns the wrong account, `op signin` is idempotent and
sets the account for later terminals; account selection resolves in this order:

1. the `--account` flag on the command
2. the `OP_ACCOUNT` environment variable
3. the account most recently signed in to with `op signin` in any terminal

```bash
op account list                            # list accounts configured on this device
op signin --account my.1password.com       # idempotent; sets the most-recent account
op account get --account my.1password.com  # or target one command at a time
export OP_ACCOUNT=my.1password.com         # or pin it for this shell
```

In an agent context each Bash call is a separate process, so `eval $(op signin --account ...)` —
the interactive-terminal idiom — exports a session token that dies with that call. Rely on
`--account` / `OP_ACCOUNT` instead.

## Runtime Access

**Discovery — you need exact names before any of this works.** Neither of these prints a secret
value:
```bash
op vault list                       # vaults this account can read
op item list --vault "VaultName"    # items in that vault
```
For field names, use the `--fields type=concealed` listing under `op item get` below — it returns
field labels, not values.

Three methods in preference order. Always start with `op run`.

**Preferred: `op run`** — secret never in context
```bash
op run --env-file=<(echo "API_KEY=op://VaultName/ItemName/field") -- your-command
# Fish: op run --env-file=(echo "API_KEY=op://VaultName/ItemName/field" | psub) -- your-command
```

`op run` conceals secrets printed to stdout/stderr by default. A masked placeholder in the output
means the secret loaded correctly, not that it failed. `--no-masking` turns masking off — do not
use it: it prints the secret into this conversation and defeats Security Rule 1.

**Fallback: `op read`** — prints to stdout. Warn user: "This will display the secret value in this conversation."
```bash
op read --no-newline "op://VaultName/ItemName/credential"
```

**`op item get`** — `--reveal` is what returns actual values, and it prints them to stdout exactly
like `op read`. Same handling: warn the user "This will display the secret value in this
conversation" before running it, and prefer `op run` when the value only has to reach a command.
`--otp` prints a live one-time code the same way.
```bash
op item get "ItemName" --vault "VaultName" --fields label=password --reveal
# To see WHICH fields exist without their values, omit --reveal and filter by type:
#   op item get "ItemName" --vault "VaultName" --fields type=concealed
```

`--format json` returns cleartext for every field — concealment applies only to human-readable
output — so it places the entire item in this conversation. Treat it like `op read`: warn first,
and prefer the `type=concealed` listing above or the desktop app when you only need field labels.

Note: `--fields password` without `label=` may return wrong field. Use `label=fieldname`.

**Basic auth** (username+password, not token) — never use `curl -u` (mangles special chars):
```bash
OP_USER=$(op item get "ItemName" --vault "VaultName" --fields label=username --reveal)
PASS=$(op item get "ItemName" --vault "VaultName" --fields label=password --reveal)
# Warning: OP_USER and PASS persist in the shell environment for the session — run `unset OP_USER PASS` after use or wrap in a subshell.
HOST="api.example.com"
# <(...) creates a file descriptor, not a disk file — no cleanup needed
curl -s --netrc-file <(echo "machine $HOST login $OP_USER password $PASS") \
  "https://$HOST/api/endpoint"
```

> **Fish shell:** Use `(echo "machine $HOST login $OP_USER password $PASS" | psub)` instead of `<(...)`.

> **Note:** Fish's `psub` creates a temporary file in `/tmp` (unlike bash's `<(...)` which uses an anonymous pipe). The file is cleaned up automatically but briefly exists on disk. For sensitive credentials, prefer `op run` with an `.env.tpl` file instead.

## Config File Patterns

The `op://` URI format: `op://<vault>/<item>/[<section>/]<field>`

The section segment is optional but **required when the field lives in a named section** — common
for one-time passwords and custom sections. Without it the reference does not resolve.

Secret references are **case-insensitive**. The supported characters are alphanumerics (`a-z`,
`A-Z`, `0-9`) plus `-`, `_`, `.` and whitespace. Any part of a reference containing an unsupported
character cannot be written by name — refer to it by its 26-character ID instead. Item and vault
IDs come from `op item list --vault "VaultName" --format json` and `op vault list --format json`;
section and field IDs are in the item's own JSON
(`op item get "ItemName" --vault "VaultName" --format json`, which is cleartext — see the warning
above). Always quote a reference that contains whitespace.

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
op inject -f -i config.yml.tpl -o config.yml
# -f/--force skips the overwrite confirmation — without it, a re-run with config.yml
# already present blocks on a prompt in any non-interactive context.
# Output file mode defaults to 0600 (--file-mode to change).
# WARNING: config.yml now contains live secrets — add to .gitignore, delete after use

# 3. op read for single exported values
export TOKEN=$(op read --no-newline "op://Vault/Item/field")
# Warning: TOKEN persists in the shell environment for the session — run `unset TOKEN` after use.
```

**Query parameters** on a secret reference:
```bash
# One-time password — the non-interactive counterpart to `op item get --otp`
op read --no-newline "op://VaultName/ItemName/one-time password?attribute=otp"

# SSH private key in OpenSSH format — write to a file; do not strip the trailing newline:
#   op read --out-file ./key.pem "op://VaultName/SSH Key/private key?ssh-format=openssh"
```
Other field attributes: `type`, `value`, `id`, `purpose`, and `otp` (used above). 1Password's
secret-references page also lists `title`; the secret-reference-syntax page does not. File
attachments use `type`, `content`, `size`, `id`, `name`.

**MCP server pattern:** `.env` with `op://` references, safe to commit. The variable name is
whichever one the MCP server itself reads; the launch command is unchanged apart from the
`op run` prefix:
```bash
# .env contents: GITHUB_TOKEN=op://DevVault/GitHub/token
op run --env-file=.env -- npx -y your-mcp-server
```

1Password's Secure AI access guidance applies the same shape inside an MCP host's config file:
make `op` the `command`, wrap the original server command in `run` args, and delete every
hardcoded secret from the `env` block — its worked example is
`{"command": "op", "args": ["run", "--environment", "<environmentID>", "--", "npx", ...]}`.
Check `op run --help` on your installed version before using `--environment`; the `--env-file`
form above works everywhere.

Gotcha: some MCP hosts (Claude Desktop on Mac is the one 1Password calls out) launch as GUI apps
and may not inherit your shell's `$PATH`. If `op` can't be found, use its full path as the
`command` value instead.

## SSH Agent

**Step 1 — turn the agent on.** 1Password app → Settings → Developer → **Use the SSH Agent**.
Nothing below works until that toggle is on; the socket is not created otherwise.

**Step 2 — socket paths by OS.** On macOS the real socket lives inside the app group container and
the path contains spaces — always double-quote it. On Linux `~/.1password/agent.sock` is the actual
default. A short macOS path only ever exists if the user created a symlink. Confirm the socket is
really there with `ls -l "$SSH_AUTH_SOCK"` before debugging anything else.

```bash
# Linux (most distros)
export SSH_AUTH_SOCK="$HOME/.1password/agent.sock"

# macOS — canonical path, inside the app group container
export SSH_AUTH_SOCK="$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"

# Optional: give macOS a short path (user-created symlink, not a default)
mkdir -p ~/.1password
ln -s "$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock" ~/.1password/agent.sock

# Auto-detect in bash/zsh
case "$(uname -s)" in
  Darwin)
    export SSH_AUTH_SOCK="$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
    ;;
  Linux)
    if grep -qi microsoft /proc/version 2>/dev/null; then
      echo "WSL: use the 1Password WSL integration (ssh.exe), not a Unix socket" >&2
    else
      export SSH_AUTH_SOCK="$HOME/.1password/agent.sock"
    fi
    ;;
  MINGW*|MSYS*|CYGWIN*)
    echo "Windows: agent uses the named pipe //./pipe/openssh-ssh-agent, not SSH_AUTH_SOCK" >&2
    ;;
esac
```

**Fish shell** (`config.fish`):
```fish
set -gx SSH_AUTH_SOCK ~/.1password/agent.sock   # Linux
# macOS (quote it — the path contains spaces):
# set -gx SSH_AUTH_SOCK "$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
```

Best practice: set `SSH_AUTH_SOCK` in your shell profile (`~/.bashrc`, `~/.zshrc`, `config.fish`), not per-command. This prevents conflicts with security hooks that block commands containing `.1password/` paths.

**Windows / WSL:** on Windows there is no `SSH_AUTH_SOCK` — the agent is the fixed named pipe
`\\.\pipe\openssh-ssh-agent`, and git needs
`git config --global core.sshCommand "C:/Windows/System32/OpenSSH/ssh.exe"`.

WSL has a supported 1Password integration and needs no pipe forwarding — it covers both WSL 1 and
WSL 2 and authenticates SSH and git commands against the 1Password SSH agent running on the
Windows host. In WSL, point git at the Windows client with
`git config --global core.sshCommand ssh.exe`. For commit signing, use the desktop app's
Configure Commit Signing → WSL option; the WSL signer is `op-ssh-sign-wsl`, not `op-ssh-sign`.
Setup steps: https://www.1password.dev/ssh/integrations/wsl

**SSH config** (`~/.ssh/config`). If `~/.ssh` or the config file does not exist yet, create it
first: `mkdir -p ~/.ssh && chmod 700 ~/.ssh`.

Linux:
```text
Host *
  IdentityAgent ~/.1password/agent.sock
```

macOS:
```text
Host *
  IdentityAgent "~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
```
Per-host opt-out: `IdentityAgent none`. If a server rejects you with "Too many authentication
failures", the agent offered more than its `MaxAuthTries` (default 6) before the right key — pin
the key for that host with `IdentityFile` plus `IdentitiesOnly yes`, or narrow the agent's key
list in `agent.toml`.

**agent.toml — which keys the agent offers.** Without this file the agent offers only SSH key items
in your default Personal, Private, or Employee vault, so a key in a Work or shared vault is
silently never offered even though `ssh-add -l` succeeds.

- Mac/Linux: `~/.config/1Password/ssh/agent.toml` (or `$XDG_CONFIG_HOME/1Password/ssh/agent.toml`)
- Windows: `%LOCALAPPDATA%/1Password/config/ssh/agent.toml`

> **Creating this file replaces the default configuration wholesale.** Once the file exists at that
> path, 1Password overrides the default agent behavior *even if the file is empty* — an empty
> `agent.toml` offers zero keys. Keys in your Personal, Private, or Employee vault stop being
> offered unless you add an explicit entry for that vault too.

```toml
[[ssh-keys]]
item = "Deploy Key"
vault = "Work"

[[ssh-keys]]
vault = "Work"          # every SSH key item in a vault

[[ssh-keys]]
account = "ACME"        # every SSH key item in an account
```
Keys are offered in file order (relevant for `MaxAuthTries`). Edits take effect immediately — no
agent restart.

**Flatpak / Snap:** the 1Password SSH agent does not work with Flatpak or Snap Store installs of
1Password for Linux — the socket is never created. Choose a different install method; reinstall
from the `.deb`/`.rpm` package.

**Health check:** `ssh-add -l` (should list your keys); `ssh -T git@github.com 2>&1 || true` (should print "Hi <username>! You've successfully authenticated...")

"Could not open a connection to your authentication agent": check `$SSH_AUTH_SOCK`, confirm app is running, `op account get` to verify auth.

## Git Signing

Requires Git 2.34+.

**Setup:**
```bash
# Configure git to use SSH signing via 1Password
git config --global gpg.format ssh
git config --global user.signingkey "ssh-ed25519 AAAA..."  # your public key
git config --global commit.gpgsign true
git config --global gpg.ssh.program "/opt/1Password/op-ssh-sign"         # Linux (.deb/.rpm install)
# macOS: "/Applications/1Password.app/Contents/MacOS/op-ssh-sign"
# WSL: use the desktop app's Configure Commit Signing → WSL option (signer is op-ssh-sign-wsl)
# Flatpak/Snap: the 1Password SSH agent is unsupported there — reinstall from the .deb/.rpm package

# Local verification needs an allowed-signers file AND a line in it for your own email.
# Creating the file empty is NOT enough — see the acceptance criterion under Verify below.
mkdir -p ~/.ssh && chmod 700 ~/.ssh
printf '%s %s\n' "$(git config user.email)" \
  "$(op read --no-newline "op://VaultName/SSH Key/public key")" >> ~/.ssh/allowed_signers
git config --global gpg.ssh.allowedSignersFile ~/.ssh/allowed_signers
# Format is one line per signer: <email> <keytype> <keydata>
# wendy@appleseed.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA...
# The email must match the user.email on the commits you want to verify.
```

Get the public key from the 1Password desktop app (SSH key item → public key field), or from the
CLI with `op read --no-newline "op://VaultName/SSH Key/public key"`. Register it as a
**signing key** on GitHub/GitLab/Forgejo (separate from auth keys).

Need a key first? `op item create --category ssh --title "My SSH Key" --vault "VaultName"`
generates one (Ed25519 by default; RSA 2048/3072/4096 also supported). Imports accept PKCS#1,
PKCS#8, and OpenSSH formats — anything else, or sub-2048 RSA, is the usual cause of the
"invalid format" error below.

**Verify:** `git log --show-signature -1`. Read the output carefully — two of the three outcomes
look like success:

- `Good "git" signature for <your-email> with ED25519 key ...` — verified. This is the pass.
- `Good "git" signature with ED25519 key ...` followed by `No principal matched.` — **verified
  nothing**, and git still exits 0. Your email has no line in the allowed-signers file.
- `error: gpg.ssh.allowedSignersFile needs to be configured and exist for ssh signature
  verification`, with the commit shown as `No signature` — the config is unset or the file is
  missing.

**Common errors:**
- "Couldn't find key in agent" → `op account get` to verify auth, `ssh-add -l` to confirm; if the key is in a non-default vault, add it to `agent.toml`
- "Load key ... invalid format" → wrong key type or corrupted `user.signingkey`
- "No principal matched" → the allowed-signers file has no line for the committer email; git still exits 0, so treat this as a failure even though the line above it says "Good ... signature"
- "Unverified" on GitHub → signing key not registered, or `user.email` mismatch
- Signing fails despite `op account get` working → check `gpg.ssh.program` path (differs by OS)

## Shell Plugins

Shell plugins let third-party CLIs (`gh`, `aws`, `claude`, ...) authenticate from 1Password instead
of plaintext config. `op plugin init` writes a `plugins.sh` that defines shell **aliases**.

```bash
op plugin list           # every available plugin
op plugin init gh        # configure one; it prints the source command for your plugins.sh
# Use the path it prints — add that source line to ~/.bashrc / ~/.zshrc / config.fish
```

**In a Claude Code session ($CLAUDECODE is set) call the plugin explicitly:**
```bash
op plugin run -- gh pr list
```
The blocker is alias expansion, not biometrics: agent tool calls run non-interactive shells, which
do not source `plugins.sh` and do not expand aliases, so a bare `gh` runs with no credentials at
all. `op plugin run --` does not depend on aliases and still raises the desktop biometric prompt
normally. For headless/CI use where no desktop app exists, use a service account instead.

**AI CLIs, including Claude Code:** op 2.34.0 added a 1Password shell plugin for the Claude Code
CLI itself (`op plugin init claude`), and 2.35.0 added 14 more shell plugins, seven of them AI CLIs
(OpenCode, Cursor, Cline, Kiro, JetBrains Junie, GitHub Copilot, and the Google Gemini AI API CLI),
plus bash/zsh tab completion for plugins.
Confirm the exact executable name with `op plugin list` before running `op plugin init`.
2.35.0 also fixed `op` hanging when a shell plugin was run from outside `$HOME` — if you see that
hang, update.

## Service Accounts

The non-interactive path: a token, no desktop app, no biometrics. The `op service-account create`
and `op service-account ratelimit` management commands require op 2.26.0+, which the 2.30.0 floor
this skill already assumes satisfies.

```bash
# Create — the token is shown ONCE, save it to 1Password immediately
op service-account create "ci-deploy" --expires-in 90d --vault "VaultName:read_items"

# Use — assignment and command in the SAME shell invocation (see note below)
OP_SERVICE_ACCOUNT_TOKEN="ops_..." op run --env-file=.env.tpl -- ./deploy.sh

op service-account ratelimit   # check quota usage
```

**Each agent Bash call is a separate process.** An `export OP_SERVICE_ACCOUNT_TOKEN=...` in one
tool call is gone by the next one, and `op run` then fails as unauthenticated. Put the assignment
and the command on the same line, as above. The same applies to the `TOKEN=`, `OP_USER=` and
`PASS=` assignments in Runtime Access and Config File Patterns — consume the value in the same
Bash call that creates it.

- **You cannot grant a service account access to your built-in Personal, Private, or Employee vault, or your default Shared vault.** Move the item into a purpose-created vault first.
- **Permissions and vault access are immutable.** A mis-scoped service account cannot be widened — create a new one.
- Vault permissions: `read_items`, `write_items` (implies `read_items`), `share_items` (implies `read_items`). `--can-create-vaults` is optional and off by default.
- Under a service account you **must** pass `--vault` on `op item get` (or supply the item on stdin).
- Use `op whoami` for the identity check — it reports the active account *or service account*, while `op account list` lists accounts set up on this device.

**Three auth modes, pick deliberately:**

- **Desktop app integration** — interactive, biometric, one developer's machine. The default this skill assumes.
- **Service account** — token in `OP_SERVICE_ACCOUNT_TOKEN`, non-interactive, scoped to vaults, rate-limited. CI, agents, headless boxes.
- **1Password Connect** — self-hosted server that caches your data in your own infrastructure; unlimited re-requests, no per-item rate limit. Kubernetes and high-volume infra. Configured via `OP_CONNECT_HOST` / `OP_CONNECT_TOKEN`; managed with the `op connect` command family.
  - Narrow command surface: with a Connect server only `op run`, `op inject`, `op read`, and `op item get --format json` are supported. The `--reveal` idiom used everywhere else in this skill does not apply, and `--format json` returns every field in cleartext — Security Rule 1 applies to each read.

## Error Catalog

```text
op prefixes its own errors as [ERROR] YYYY/MM/DD HH:MM:SS <message> — verified on op 2.35.0,
which answers an unknown command with a line of exactly that shape. Match on the distinctive
substring rather than a whole error line. Entries below quote that substring, or describe the
symptom where the exact wording is not something this skill verified.

"Permission denied (publickey)"
→ 1Password locked or SSH agent not configured
→ Fix: `op account get` (triggers biometric), `ssh-add -l` to verify keys loaded

"Could not open a connection to your authentication agent"
→ SSH_AUTH_SOCK not set, or pointing at a socket that does not exist
→ Fix: run ls -l "$SSH_AUTH_SOCK" and branch on it. No such file → the "Use the SSH Agent"
  toggle is off (1Password → Settings → Developer). Socket present → the app is locked, see
  Auth Recovery. Then set the path in your shell profile. Linux: ~/.1password/agent.sock
  macOS: "$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock" (quote it)

ssh-add -l reports no agent connection on Linux while the desktop app is running
→ 1Password installed via Flatpak or Snap — the SSH agent is unsupported there and the
  socket is never created
→ Fix: reinstall 1Password from the .deb/.rpm package

"Too many authentication failures"
→ Agent offered more keys than the server's MaxAuthTries (default 6) before the right one
→ Fix: pin the key per host with IdentityFile + `IdentitiesOnly yes`, or narrow agent.toml

op fails at startup mentioning 1Password Connect, with OP_CONNECT_HOST/OP_CONNECT_TOKEN set
→ OP_CONNECT_HOST/OP_CONNECT_TOKEN route op at a Connect server, whose supported command
  surface is far narrower (see Service Accounts), so unsupported commands fail. Connect
  credentials are documented to take precedence over OP_SERVICE_ACCOUNT_TOKEN
→ Fix: `unset OP_CONNECT_HOST OP_CONNECT_TOKEN` — only if you are not intentionally using Connect

Commands that worked start failing / op asks to authenticate again mid-session
→ Desktop app locked or the session timed out
→ Fix: `op account get` (re-auth), retry command

"no account found"
→ op installed but not linked to the desktop app
→ Fix: 1Password desktop → Settings → Security (turn on Touch ID / Windows Hello / Linux system
  authentication), then Settings → Developer → enable CLI integration

"isn't an item in the" (`op item get` / `op item list`)
→ Item or vault name wrong, or the item is archived (op excludes the Archive by default)
→ Fix: `op item list --vault "VaultName"` to find the exact name; add --include-archive to that
  command (or set OP_INCLUDE_ARCHIVE=true) if it was archived

"isn't an item in the" (`op read`)
→ Same causes, minus case: secret references are documented case-insensitive, so wrong case is
  not it. But `op read` has no --include-archive flag and there is no global one, so an archived
  item cannot be resolved through a secret reference at all
→ Fix: unarchive the item, or fetch the value with
  `op item get "ItemName" --vault "VaultName" --include-archive --reveal` instead

"could not read secret 'op://...'" while the item itself resolves
→ Field name wrong, or the field sits in a named section the reference omits
→ Fix: use op://<vault>/<item>/<section>/<field>; right-click the field in 1Password →
  Copy Secret Reference

"sign_and_send_pubkey: signing failed ... agent refused operation"
→ Biometric denied or 1Password not running
→ Fix: check for prompt on desktop, restart app, then `op account get`

"No principal matched" from git log --show-signature (GitHub may still show Verified)
→ The allowed-signers file exists but has no line for the committer email. git still prints
  Good "git" signature with <key> on the line above and exits 0, so this reads like a pass
→ Fix: append your own line, then re-run the verify —
  printf '%s %s\n' "$(git config user.email)" "$(op read --no-newline "op://VaultName/SSH Key/public key")" >> ~/.ssh/allowed_signers

"gpg.ssh.allowedSignersFile needs to be configured and exist for ssh signature verification"
→ gpg.ssh.allowedSignersFile is unset or points at a file that does not exist; git log reports
  the commit as "No signature"
→ Fix: mkdir -p ~/.ssh && chmod 700 ~/.ssh, create the file with your signer line, then
  git config --global gpg.ssh.allowedSignersFile ~/.ssh/allowed_signers

403 Forbidden / access denied while OP_SERVICE_ACCOUNT_TOKEN is set
→ The service account has no access to that vault. If it is a built-in Personal, Private or
  Employee vault, or the default Shared vault, it cannot be granted at all
→ Fix: grant it at creation (--vault "VaultName:read_items") — access is immutable, so a
  mis-scoped account must be recreated. For a built-in vault, move the item to another vault

"unknown flag: --reveal"
→ op CLI older than 2.30.0
→ Fix: update op — https://www.1password.dev/cli/get-started/

`op item get` returns a masked/placeholder value instead of the actual secret
→ Missing --reveal (human-readable output is concealed by default since 2.30.0)
→ Fix: `op item get "ItemName" --vault "VaultName" --fields label=password --reveal`

`op run` prints a masked placeholder where the secret should be
→ Expected behavior: op run conceals stdout/stderr by default. The secret loaded correctly.
→ Fix: none — do not add --no-masking, it prints the secret into the conversation

`op inject` (or `op read` with --out-file) appears to hang with no output
→ Blocked on an overwrite confirmation prompt for an existing output file
→ Fix: pass -f/--force in non-interactive contexts
```

## Troubleshooting

**`op` not found / not installed:**
Install from https://www.1password.dev/cli/get-started/, then turn on the app integration in this order:

1. Open the 1Password app and sign in.
2. Settings → Security → turn on Touch ID, Windows Hello, or a Linux system authentication option.
3. Settings → Developer → select "Integrate with 1Password CLI".

Step 2 is the one that gets skipped, and without it no biometric prompt is ever raised. Verify the install with `op --version`; verify the *integration* with `op account get`, which fires the desktop prompt — approving it is the confirmation. `op --version` prints a version happily with no account configured at all, so it proves nothing about the integration.

**op hangs / no biometric prompt:**
Prompt appears on the desktop, not in the terminal. On Linux/Wayland: check all workspaces. If no prompt ever appears — not late, never — system authentication is not turned on under Settings → Security (step 2 above); restarting the app will not fix that. If hung 30s+: Ctrl+C, restart 1Password app, retry.

**op fails in Claude Code sandbox:**
Claude Code's bubblewrap sandbox strips setgid bits; `op` requires the `onepassword-cli` group. Symptom: works in terminal but fails as a Claude tool call. Fix: `sudo usermod -aG onepassword-cli $(whoami)`, then log out and log back in (or fully restart your terminal/IDE) so a new login shell picks up the supplementary group — `source ~/.bashrc` will NOT work, since Unix loads supplementary groups via `setgroups()` at login, not from shell config. (`newgrp onepassword-cli` works for the current shell only and does not propagate to other open terminals.) Alternatives: use `op run` to inject secrets before launching Claude so the session inherits them, or use a service account token, which needs no desktop app or group membership.

**Wrong account:**
`op account get` → shows active account. List: `op account list`. Resolution order is `--account` flag, then `OP_ACCOUNT`, then the most recent `op signin`. Prefer `--account` or `OP_ACCOUNT` in agent contexts — an `eval $(op signin ...)` session export does not survive into the next tool call.

**1Password locked mid-session:**
Auto-locks after inactivity (10-30 min typical). SSH fails silently with "Permission denied." Fix: `op account get` to verify auth, then retry. Prevention: Settings → Security → Auto-lock.

**`op item get` returns masked values:**
`--fields password` without `--reveal` returns a placeholder. Always add `--reveal` for actual values.

**Multiple accounts / ambiguous results:**
Always use `--vault "VaultName"` to scope. Add `--account` flag if multi-account confusion persists.

**Docs:** https://www.1password.dev/cli/get-started/ · https://www.1password.dev/service-accounts/ · https://www.1password.dev/ssh/get-started/
