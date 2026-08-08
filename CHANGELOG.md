# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.0] - 2026-08-07

A correctness release, from an audit of the skill against live 1Password documentation and
`op` 2.35.0 help output. The previously documented install path did not actually load the
plugin, the environment override path pointed inside a cache directory that is replaced on
every update, and the skill documented a macOS SSH agent socket path and several `op` error
strings that do not exist.

### Added
- `.claude-plugin/marketplace.json` — the repo can now be added with `/plugin marketplace add petejm/1password-skill` and installed with `/plugin install 1password-skill@petejm-plugins`. Without this file no marketplace install was possible
- SKILL.md `## Shell Plugins` — `op plugin init` for authenticating other CLIs through 1Password. `op` 2.34.0 added a shell plugin for the Claude Code CLI itself; 2.35.0 added 14 more shell plugins, 7 of them AI CLIs (OpenCode, Cursor, Cline, Kiro, JetBrains Junie, GitHub Copilot, Google Gemini AI API), plus tab completion for shell plugins in bash and zsh, and fixed `op` hanging when a shell plugin was run from outside `$HOME`
- SKILL.md `## Service Accounts` — the non-interactive path (`OP_SERVICE_ACCOUNT_TOKEN`) for headless and CI use, where no desktop app and no biometric prompt are available
- SKILL.md frontmatter: `when_to_use`, `license`, and `compatibility` fields
- SKILL.md: secret-reference query parameters (`?ssh-format=openssh`), the optional section segment in `op://<vault>/<item>/[<section>/]<field>`, and `--force` on `op inject`
- `.claude-plugin/plugin.json`: `license` (`Apache-2.0`, matching the shipped LICENSE), plus the discovery fields the current manifest schema defines — `$schema`, `homepage`, `keywords`
- README: `claude --plugin-dir ./1password-skill` documented as the local development loop, and `claude plugin validate ./1password-skill --strict` as a pre-PR step

### Changed
- README install instructions: replaced `git clone` into `~/.claude/plugins/` — which is Claude Code-managed state and never loaded the plugin — with the marketplace flow, a `~/.claude/skills/1password-skill` clone that loads as `1password-skill@skills-dir`, and `--plugin-dir` for development
- README environment overrides: the override now lives in a user-owned skill (`~/.claude/skills/1password-environment/SKILL.md` or `<repo>/.claude/skills/…`) instead of `~/.claude/plugins/1password-skill/skills/1password/environment.md`. Marketplace installs land in a versioned cache that is replaced on update and wiped by the documented `rm -rf ~/.claude/plugins/cache` remedy, so the old location destroyed user customization on every upgrade
- README contributing guidance: skills in `skills/<name>/SKILL.md` are auto-discovered and need no manifest edit; the manifest is at `.claude-plugin/plugin.json`, not the repo root
- Test suite hardened against silent passes: the security scan now aborts rather than reporting clean when its file corpus is empty, and carries a scanner canary; `tests/test-integration.sh` diffs the committed `integrations/**` against freshly generated output, so a stale or corrupt generated artifact fails the build (this is the check that would have caught the invalid Cursor YAML); crashed suites are counted as failures instead of zero; and assertion-count floors keep skipped blocks from shrinking the denominator. The suite is now read-only on the repo, running conversions in a temp staging tree. bash 3.2 compatibility fixes throughout (`declare -A` removed, `date +%s%N` probed rather than assumed)
- `.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json` descriptions now match the SKILL.md frontmatter description, which the generated `integrations/**` already carried: both manifests had drifted and omitted git *commit* signing, shell plugins, and service accounts. The README lede and the README decision-router table were updated the same way — the table was missing rows for the two sections this release adds
- `.gitignore`: added `.claude/skills/1password-environment/` for the new override location. The legacy `skills/*/environment.md` entry is deliberately retained — earlier READMEs told users to create that file and promised it was gitignored, so removing the rule could let a fork commit device paths

### Fixed
- **macOS SSH agent socket path was fabricated.** The skill documented `~/.ssh/1password-agent.sock`, which 1Password never creates. The real path is `$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock` — it contains spaces and is now always double-quoted, with the short path presented only as a user-created symlink. Affected `SSH_AUTH_SOCK`, the fish example, the `IdentityAgent` snippet, and the error catalog
- **Error catalog contained `op` error strings that do not exist.** Removed the invented `op: session expired`, `op: 403 Forbidden`, `op: error initializing client: connecting to 1Password Connect`, and `op run: unrecognized option '--env-file'`; the first three are now described as symptoms rather than quoted, and the last is replaced by the real `unknown flag: --reveal` (indicating `op` older than 2.30.0). Added the `[ERROR] YYYY/MM/DD HH:MM:SS` prefix note, the archived-item case, and `Too many authentication failures`
- SKILL.md version floor: `op` 2.18+ → **2.30.0+**, matching README
- README version floor: `op` 2.18+ → **2.30.0+**. The skill's mandatory `--reveal` and the concealed-by-default human-readable output both landed in `op` 2.30.0
- **Cursor rule frontmatter was invalid YAML.** `scripts/convert.sh` emitted a double-quoted scalar built with an inline `${desc//\'/\'\'}`, which on bash ≤ 4.2 (including the macOS system bash) leaves `\'` in the output — an invalid YAML escape that made `integrations/cursor/.cursor/rules/1password.mdc` unparseable. Now emitted as a single-quoted scalar, which processes no backslash escapes at all, and verified byte-identical across `BASH_COMPAT` 3.2/4.2/5.0
- `scripts/convert.sh` failed open: missing frontmatter, an unextractable description, or an empty generated body all printed `[OK]` and exited 0. Every generation step now asserts and exits non-zero
- `scripts/convert.sh` description extraction treated any `|` on the `description:` line as a block-scalar indicator, blanking descriptions containing a shell pipe
- SSH agent config: `IdentityAgent` needs a `Host *` block, git commit signing needs `~/.ssh/allowed_signers` to exist or verification fails, and WSL/MSYS no longer fall through to a nonexistent Linux socket. Flatpak and Snap are documented as unsupported
- `scripts/gemini-review.sh`: API key moved out of the URL and out of `argv` into a `curl --config` file; `declare -A` removed (a hard error on bash 3.2); truncated responses now fail instead of returning a partial review; the generated `integrations/**` are included in the review bundle, so generator output is no longer invisible to review
- **The Aider install step never loaded the file.** README said "Aider loads `CONVENTIONS.md` from the project root automatically at session start," so following it left an inert file. Aider's own conventions documentation says to load it with `aider --read CONVENTIONS.md` or `/read CONVENTIONS.md`, or to set `read: CONVENTIONS.md` in `.aider.conf.yml` for every session. This also retracts the parenthetical in the 1.0.1 entry below, "(Aider reads from project root)"
- **Shell-variant coverage was overclaimed.** README said all code examples carry a Fish variant and named process substitution as the only divergence. Four bash-only blocks in SKILL.md are not valid Fish — `export OP_ACCOUNT=`, `export TOKEN=$(op read …)`, the `plugins.sh` profile append, and `export OP_SERVICE_ACCOUNT_TOKEN=` — since Fish needs `set -gx`. README now promises Fish variants only where process substitution is used, matching the contributing guideline it already carried, and gives the `set -gx` translation. This retracts "Shell support matrix: bash/zsh and Fish variants for all code examples" in the 1.0.0 entry below
- **Retraction: `op://` secret references are not case-sensitive.** The 1.0.1 entry below records a case-sensitivity note added to the `op://` URI documentation. 1Password's secret reference syntax reference states the opposite in as many words — "Secret references are case-insensitive" — so the note is removed from SKILL.md
- **Softened the `op whoami` root-cause claim.** The 1.0.2 entry below attributes the failure to `op whoami` reading `config.latest_signin` while other commands read `system_auth_latest_signin` via the daemon socket. That mechanism is not documented by 1Password and was never sourced; the observed behavior stands as the reason to prefer `op account get`, but the internal explanation is no longer asserted
- README links to three retired documentation paths: `docs.anthropic.com/en/docs/claude-code` → `code.claude.com/docs/en/overview`, and the `developer.1password.com/docs/cli/*` links → their `www.1password.dev/*` equivalents (`op --help` in 2.35.0 prints `https://www.1password.dev/cli`). The retired `docs/cli/secrets-security/` path now points at 1Password's current AI guidance, `https://www.1password.dev/get-started/secure-ai-access`

## [1.0.2] - 2026-04-10

### Fixed
- Replace `op whoami` with `op account get` as primary auth health check
- `op whoami` is broken in system-auth mode (1Password desktop app integration, op v2.30+): returns "not signed in" even when the desktop app is unlocked and all other `op` commands work
- Root cause: `op whoami` checks `config.latest_signin` (empty in system-auth mode) while all other commands use `system_auth_latest_signin` via the daemon socket
- `op whoami` retained as fallback note for CLI-only users who use `op signin` manually

## [1.0.1] - 2026-04-09

### Fixed
- Aider install path: `.aider/CONVENTIONS.md` → `./CONVENTIONS.md` (Aider reads from project root)
- `op whoami --account` does not switch accounts; corrected to `eval $(op signin --account ...)`
- Bubblewrap sandbox workaround: replaced incorrect advice with real fix (`usermod -aG`)
- `convert.sh` `get_description()`: correctly handles multiline YAML block scalars
- `convert.sh` Cursor output: escape double quotes in YAML description field
- Shell environment persistence warnings added to `export TOKEN=` and `OP_USER`/`PASS` examples
- Case-sensitivity note added to `op://` URI format documentation
- macOS path added to `IdentityAgent` SSH config example
- Flatpak/Snap path note added for `op-ssh-sign` git signing binary
- SSH health check expected output documented
- README: clone step added to non-Claude install sections (Gemini CLI, Cursor, Aider, Windsurf)
- README: valid `--tool` values listed for `convert.sh`

### Added
- `CHANGELOG.md` (Keep a Changelog format)
- `plugin.json`: `author` and `repository` metadata fields
- `.gitignore`: `.idea/` and `.vscode/` exclusions

## [1.0.0] - 2026-03-19

### Added
- Initial public release of the 1password-skill Claude Code plugin
- Core skill document (`skills/1password/SKILL.md`) with decision-router pattern for `op` CLI usage
- Six security rules enforcing `op run` over `op read`, vault scoping, no secrets in files, and minimal credential exposure
- Error catalog covering common `op` failures, auth recovery flow, and SSH agent troubleshooting
- Shell support matrix: bash/zsh and Fish variants for all code examples
- Multi-model integration support via `scripts/convert.sh`:
  - Gemini CLI (`integrations/gemini-cli/`)
  - Cursor (`.cursor/rules/1password.mdc`)
  - Aider (`integrations/aider/CONVENTIONS.md`)
  - Windsurf (`integrations/windsurf/.windsurfrules`)
- `convert.sh` with `--tool` flag for targeted generation and dynamic description extraction from SKILL.md frontmatter
- Gemini-powered tabula rasa review script (`scripts/gemini-review.sh`) for skill quality validation
- Comprehensive test suite (110 tests) covering convert.sh and plugin structure
- Apache 2.0 license

### Fixed
- Hardened test suite against `|| true` exit code traps and narrow regex patterns (adversarial review)
- Vault name sanitization in `gemini-review.sh`
- Dynamic Cursor description extraction from multiline YAML block scalars; corrected Gemini CLI install path in README

<!--
Keep a Changelog comparison links are omitted deliberately: this repo publishes no tags,
so every `compare/vX.Y.Z...` and `releases/tag/vX.Y.Z` URL returned 404 (verified 2026-08-07).
Restore the link references below once v1.0.0 / v1.0.1 / v1.0.2 / v1.1.0 are tagged and pushed.
-->

