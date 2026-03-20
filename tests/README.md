# 1password-skill Tests

This directory contains the test suite for the `1password-skill` plugin.

## What "testing" means for a markdown skill

This isn't a code project, so there are no unit tests or CI assertions about runtime behavior. Instead, the tests validate four things that matter for a published markdown skill:

1. **Structure** — the skill has the required shape: frontmatter fields, plugin.json integrity, decision router table, required sections
2. **Security** — no real credentials, hostnames, usernames, or token patterns leaked into publishable files
3. **Content** — the `op` commands are accurate: correct flags (`--reveal`, `--vault`, `--no-newline`), Fish alternatives for process substitution, correct variable names
4. **Integration** — `convert.sh` produces valid output for all 4 target tools, is idempotent, and `--tool` targeting works

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

```
1password-skill — Test Suite
2026-03-19 14:23:01
Repo: /path/to/1password-skill

=== Structural Tests ===

SKILL.md basics
  PASS SKILL.md exists
  PASS SKILL.md is non-empty

...

=== Summary ===

  Suite            Result    Time
  ---------------  --------  ------
  Structural       PASSED    12ms
  Security         PASSED    45ms
  Content          PASSED    18ms
  Integration      PASSED    310ms

  Total: 62 passed, 0 failed

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
