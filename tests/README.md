# 1password-skill Tests

This directory contains the test suite for the `1password-skill` plugin.

## What "testing" means for a markdown skill

This isn't a code project, so there are no unit tests or CI assertions about runtime behavior. Instead, the tests validate four things that matter for a published markdown skill:

1. **Structure** — the skill has the required shape: frontmatter fields, plugin.json integrity, decision router table, required sections
2. **Security** — no real credentials, hostnames, usernames, or token patterns leaked into publishable files
3. **Content** — the `op` commands are accurate: correct flags (`--reveal`, `--vault`, `--no-newline`), Fish alternatives for process substitution, correct variable names. The invalid-subcommand list is checked against `op --help` on op 2.35.0, so it only ever forbids names that command list does not contain
4. **Integration** — `convert.sh` produces valid output for all 4 target tools, is idempotent, `--tool` targeting works, and the **committed `integrations/**` artifacts match what `convert.sh` produces today**

## Prerequisites

| Tool | Used by | Why |
|---|---|---|
| `bash` 3.2+ | all | macOS ships 3.2 as `/bin/bash`; the suites avoid all bash 4+ syntax |
| `git` | `test-security.sh`, `test-integration.sh` | builds the scan corpus from `git ls-files` (the suite refuses to run without it); proves the integration suite left the working tree untouched via `git status --porcelain` |
| `stat` (GNU `-c %Y` or BSD `-f %m`) | `test-integration.sh` | observes mtime for the `--tool` isolation checks; the suite fails if neither flavor works |
| `python3` | `test-structural.sh`, `test-content.sh`, `test-integration.sh` | JSON parsing, YAML frontmatter validation, error-catalog line counting |
| PyYAML (`pip install pyyaml`) | `test-structural.sh`, `test-integration.sh` | parses generated frontmatter — `grep` cannot tell valid YAML from a broken escape |
| `diff` | `test-integration.sh` | compares committed vs freshly generated artifacts |
| `shasum` / `sha256sum` / `md5sum` (any one) | `test-integration.sh` | idempotency checksums |

Missing prerequisites **fail loudly**. They are never silently skipped: a suite that
cannot run its assertions must not report success.

## Read-only guarantee

The suites do not modify the repo.

`test-integration.sh` copies `scripts/` and `skills/` into a `mktemp -d` staging tree and
runs `convert.sh` there, so every generated file lands under `/tmp` and is removed by an
`EXIT` trap. The tracked `integrations/**` directory is only ever **read** — and is diffed
against the staged output, so a stale or corrupt committed artifact fails the suite instead
of being silently overwritten before the assertions run.

`run-all.sh` invokes each suite with `bash`, so a missing executable bit is **reported**
(`WARN`) rather than repaired with `chmod`.

## How to run

```bash
# Run all suites (from repo root)
./tests/run-all.sh

# Run a single suite
./tests/test-structural.sh
./tests/test-security.sh
./tests/test-content.sh
./tests/test-integration.sh

# Disable color output
NO_COLOR=1 ./tests/run-all.sh
```

All scripts are runnable from the repo root. They use absolute paths internally and do not require `cd` first.

## Sample output

Assertion counts are deliberately elided below — they change every time a suite gains a
check, and a hard number here goes stale silently. The authority is each suite's
`EXPECTED_MIN_ASSERTIONS` constant.

```
1password-skill — Test Suite
2026-03-19 14:23:01
Repo: /path/to/1password-skill

=== Structural Tests ===

SKILL.md basics
  PASS SKILL.md exists
  PASS SKILL.md is non-empty

...

╔═══════════════════════════════════════════════════╗
║               Test Suite Summary                  ║
╚═══════════════════════════════════════════════════╝

  Suite            Result    Time
  ---------------  --------  ------
  Structural       PASSED    12ms
  Security         PASSED    45ms
  Content          PASSED    18ms
  Integration      PASSED    310ms

  Total: … passed, 0 failed

  All tests passed.
```

If a test fails, the failing line shows what was expected:

```
  FAIL 'op item get' with label=password always includes --reveal
       Line 89: op item get "ItemName" --vault "VaultName" --fields label=password
```

## Adding new tests

| Category | File | When to edit |
|---|---|---|
| Structure | `test-structural.sh` | New required sections, frontmatter fields, file requirements |
| Security | `test-security.sh` | New sensitive patterns to scan for, new gitignore rules |
| Content | `test-content.sh` | New `op` flags that are required, new shell variants needed |
| Integration | `test-integration.sh` | New output formats from `convert.sh`, new `--tool` options |

Each test follows this pattern — copy it and adapt:

```bash
if <condition>; then
  pass "description of what should be true"
else
  fail "description of what should be true (but isn't)"
fi
```

The `pass`/`fail` functions are defined at the top of each script and handle counter tracking and color output automatically.

### Rules for new assertions

A test that cannot fail is worse than no test. Every assertion must be able to fail, and
"nothing to check" must never read as "clean":

- **Never `continue` past a missing input.** If the file an assertion needs is absent,
  call `fail` and say so — a vanished assertion shrinks the denominator invisibly, and
  `run-all.sh` only scrapes `N/M passed`.
- **Never end a check with `|| true`** where the empty result is the passing condition,
  *unless something else independently proves the check ran*. That fallback otherwise
  collapses "tool missing", "tool errored" and "genuinely absent" into one string.
  `test-security.sh` is the sanctioned exception: every negative scan there ends in
  `|| true`, and it is only defensible because three separate assertions prove the
  scanner is live before any empty result is trusted — the non-empty corpus gate, the
  scannable-files-equals-corpus count, and the canary scan for a string known to be
  present.
- **Guard empty corpora.** `test-security.sh` hard-exits when `git ls-files` returns
  nothing, asserts that every file in the corpus is scannable (a file skipped as binary
  is searched by nothing and must be named, not silently dropped), and runs a canary
  scan for a string known to be present before any negative result is trusted.
- **Put a floor under any count you extract.** Each suite declares
  `EXPECTED_MIN_ASSERTIONS` equal to the number of assertions it runs, so deleting one
  trips the floor; `run-all.sh` reads that constant back to score a crashed suite as the
  assertions it owns. `test-content.sh` does the same for its example corpora
  (`MIN_ITEM_GET_EXAMPLES` and friends): the `--vault` / `--no-newline` checks are the
  product, so an over-broad `grep -v` that empties the set must fail, not pass.
- **Anchor both ends of an exact match.** `grep -qE "^## $target"` is a *prefix* match:
  renaming `## SSH Agent` to `## SSH Agent Stuff` left the router-to-section assertion
  green while the router row pointed at nothing. Use `^## $target[[:space:]]*$` when the
  claim is "this exact heading exists".
- **Assert usage, not occurrence.** A `grep -qF "op whoami"` over the whole document was
  satisfied by the sentence *"do NOT reach for `op whoami`"* — a prohibition proved the
  command was documented. Decide what evidence the claim actually needs and search only
  where that evidence can live: an invocation belongs in a shell-tagged fenced code block
  at command position (comment lines stripped); an ignore rule belongs on a
  non-comment line of `.gitignore`; a section belongs behind a `##` heading, not in a
  cross-reference from the router table. Prose that merely contains the string is not
  evidence for any of them.
- **Compare like with like.** Resolve one checksum/parser command up front and fail if
  none exists, rather than falling back to two different sentinel values that can never
  compare equal.
- **Prefer `-eq` to `-ge`** when the expected relationship is parity. A `-ge` threshold
  against a numerator that is structurally larger can never fail.
- **Portability**: bash 3.2 (no `declare -A`, `mapfile`, `${var,,}`, `wait -n`,
  `head -n -N`); POSIX ERE only (`[[:space:]]` not `\s`; no `\b` — anchor on
  `(^|[^a-zA-Z0-9])` instead); probe `date +%s%N` support rather than assuming BSD
  `date` fails on it (it does not — it prints a literal `N`).
- **Exit boolean.** Suites end with `exit 0` / `exit 1`, never `exit $FAILS` (8-bit exit
  statuses wrap at 256, and a count conflates test failures with script errors).
