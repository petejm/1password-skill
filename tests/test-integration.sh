#!/usr/bin/env bash
# test-integration.sh -- Verify convert.sh works correctly and produces valid outputs
#
# Tests the conversion pipeline end-to-end: script exists, runs, produces correct
# outputs for all 4 target tools, is idempotent, supports --tool filtering, and that
# the COMMITTED integrations/** artifacts match what convert.sh produces today.
#
# This suite is READ-ONLY with respect to the repo. All conversion happens inside a
# mktemp -d staging tree; the tracked integrations/ directory is only ever read.
# Run from repo root: ./tests/test-integration.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONVERT_SH="$REPO_ROOT/scripts/convert.sh"

PASSES=0
FAILS=0

# Floor on the number of assertions this suite must execute. Assertion blocks that
# vanish when an input is missing would otherwise shrink the denominator invisibly --
# run-all.sh only scrapes "N/M passed" and cannot tell 42/42 from 8/8.
#
# Keep this EQUAL to the number of assertions the suite actually runs, so deleting any
# one of them trips the floor. A number with slack in it is not a floor. Adding
# assertions is a deliberate bump of this line. run-all.sh greps this exact assignment
# out of the file, so keep it on one line with no spaces.
EXPECTED_MIN_ASSERTIONS=66

# Color output (respects NO_COLOR)
if [[ -z "${NO_COLOR:-}" && "${TERM:-dumb}" != "dumb" && -t 1 ]]; then
  # $'...' (ANSI-C quoting) turns \033 into a real ESC byte at assignment time, so
  # color renders whether the variable ends up in a printf FORMAT string or a %s
  # data argument (see scripts/convert.sh for why a plain "\033[...m" is not enough).
  C_GREEN=$'\033[0;32m'; C_RED=$'\033[0;31m'; C_CYAN=$'\033[0;36m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
else
  C_GREEN="" C_RED="" C_CYAN="" C_BOLD="" C_RESET=""
fi

pass() { PASSES=$((PASSES + 1)); printf '%s\n' "  ${C_GREEN}PASS${C_RESET} $1"; }
fail() { FAILS=$((FAILS + 1));  printf '%s\n' "  ${C_RED}FAIL${C_RESET} $1"; }

summary_and_exit() {
  # Enforce the assertion floor on EVERY exit path, including the early
  # summary_and_exit calls used for missing prerequisites. A floor evaluated only at
  # the bottom of the file is skipped exactly when the denominator collapses, and
  # run-all.sh then reports the tiny N/M as a normal result.
  local _ran=$((PASSES + FAILS + 1))
  if [[ $_ran -ge $EXPECTED_MIN_ASSERTIONS ]]; then
    pass "Suite ran $_ran assertions (>= $EXPECTED_MIN_ASSERTIONS expected)"
  else
    fail "Suite ran only $_ran assertions (expected >= $EXPECTED_MIN_ASSERTIONS) -- assertion blocks were skipped"
  fi
  local total=$((PASSES + FAILS))
  printf '\n%s' "${C_BOLD}Integration:${C_RESET} $PASSES/$total passed"
  if [[ $FAILS -eq 0 ]]; then
    printf '%s' " ${C_GREEN}(all passed)${C_RESET}"
  else
    printf '%s' " ${C_RED}($FAILS failed)${C_RESET}"
  fi
  printf "\n"
  # Boolean status, not a mod-256 failure count: `exit $FAILS` would exit 0 on exactly
  # 256 failures and conflates test failures with script errors. run-all.sh parses the
  # real counts from the line above.
  if [[ $FAILS -eq 0 ]]; then exit 0; else exit 1; fi
}

STAGE=""
cleanup() {
  [[ -n "$STAGE" && -d "$STAGE" ]] && rm -rf "$STAGE"
}
trap cleanup EXIT INT TERM

printf '\n%s\n\n' "${C_BOLD}${C_CYAN}=== Integration Tests ===${C_RESET}"

# --- Prerequisites ---
printf '%s\n' "${C_BOLD}Prerequisites${C_RESET}"

if command -v python3 >/dev/null 2>&1; then
  pass "python3 is available"
else
  fail "python3 not found -- YAML frontmatter assertions cannot run"
  summary_and_exit
fi

HAVE_PYYAML=0
if python3 -c "import yaml" >/dev/null 2>&1; then
  HAVE_PYYAML=1
fi

# Resolve ONE checksum tool up front. The old code chained
# `md5sum ... || sha256sum ... || echo unknown` on the "before" side and
# `... || echo unknown2` on the "after" side; on macOS (neither md5sum nor sha256sum)
# both branches took their sentinel and two deliberately different strings can never
# compare equal -- four unconditional false FAILs.
CKSUM_CMD=""
if command -v shasum >/dev/null 2>&1; then
  CKSUM_CMD="shasum -a 256"
elif command -v sha256sum >/dev/null 2>&1; then
  CKSUM_CMD="sha256sum"
elif command -v md5sum >/dev/null 2>&1; then
  CKSUM_CMD="md5sum"
fi
if [[ -n "$CKSUM_CMD" ]]; then
  pass "checksum tool available (${CKSUM_CMD})"
else
  fail "no checksum tool available (shasum / sha256sum / md5sum) -- cannot verify idempotency"
  summary_and_exit
fi

checksum() { $CKSUM_CMD < "$1" | cut -d' ' -f1; }

# Resolve ONE stat flavor up front, the same way CKSUM_CMD is resolved above. The old
# `stat -c '%Y' || stat -f '%m' || echo 0` chain returned the same literal 0 from BOTH
# failure branches, so on a platform with neither flavor the --tool isolation checks
# below compared 0 to 0 and passed no matter what convert.sh did.
STAT_FLAVOR=""
_stat_probe=$(stat -c '%Y' "${BASH_SOURCE[0]}" 2>/dev/null || true)
if [[ "$_stat_probe" =~ ^[0-9]+$ ]]; then
  STAT_FLAVOR="gnu"
else
  _stat_probe=$(stat -f '%m' "${BASH_SOURCE[0]}" 2>/dev/null || true)
  [[ "$_stat_probe" =~ ^[0-9]+$ ]] && STAT_FLAVOR="bsd"
fi
if [[ -n "$STAT_FLAVOR" ]]; then
  pass "stat flavor resolved ($STAT_FLAVOR) -- mtime is observable for the --tool isolation checks"
else
  fail "no usable stat (neither 'stat -c %Y' nor 'stat -f %m' returns a number) -- cannot verify --tool isolation"
  summary_and_exit
fi

# mtime in epoch seconds, or the empty string if it could not be read. Empty is NOT a
# comparable sentinel: every caller must reject it explicitly (see assert_untouched).
mtime_of() {
  local t=""
  if [[ "$STAT_FLAVOR" == "gnu" ]]; then
    t=$(stat -c '%Y' "$1" 2>/dev/null || true)
  else
    t=$(stat -f '%m' "$1" 2>/dev/null || true)
  fi
  [[ "$t" =~ ^[0-9]+$ ]] || t=""
  printf '%s\n' "$t"
}

# Assert a file's mtime is unchanged. An unreadable mtime on either side fails; it is
# never treated as "unchanged".
assert_untouched() {
  local label="$1" before="$2" after="$3"
  if [[ -z "$before" || -z "$after" ]]; then
    fail "$label mtime unreadable (before='$before' after='$after') -- cannot verify --tool cursor isolation"
  elif [[ "$before" == "$after" ]]; then
    pass "$label output not modified by --tool cursor run"
  else
    fail "$label output was modified by --tool cursor run (should only modify cursor)"
  fi
}

# --- Script basics ---
printf '\n%s\n' "${C_BOLD}convert.sh basics${C_RESET}"

if [[ -f "$CONVERT_SH" ]]; then
  pass "convert.sh exists"
else
  fail "convert.sh exists at scripts/convert.sh"
  summary_and_exit
fi

if [[ -x "$CONVERT_SH" ]]; then
  pass "convert.sh is executable"
else
  fail "convert.sh is executable (chmod +x scripts/convert.sh)"
fi

# --- Staging tree ---
# convert.sh derives its output base from its own location ($script_dir/../integrations),
# so running a COPY of the repo's scripts/ + skills/ inside a temp dir redirects every
# write there. Nothing under the tracked integrations/ directory is modified.
printf '\n%s\n' "${C_BOLD}Staging tree (suite is read-only on the repo)${C_RESET}"

# Snapshot of the working tree, taken BEFORE anything runs. `git status --porcelain`
# lists modified tracked files AND untracked ones (`??`), so a stray write anywhere
# under the repo shows up as a line that was not here before. Compared at the end.
REPO_STATE_STATUS=0
REPO_STATE_BEFORE=$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null) || REPO_STATE_STATUS=$?

STAGE=$(mktemp -d 2>/dev/null || mktemp -d -t 1pw-tests)
if [[ -n "$STAGE" && -d "$STAGE" ]]; then
  pass "Created staging tree for generated output"
else
  fail "Could not create a staging directory (mktemp -d failed)"
  summary_and_exit
fi

if cp -R "$REPO_ROOT/scripts" "$STAGE/scripts" 2>/dev/null &&
   cp -R "$REPO_ROOT/skills" "$STAGE/skills" 2>/dev/null; then
  pass "Staged scripts/ and skills/ into the temp tree"
else
  fail "Could not stage scripts/ and skills/ into $STAGE"
  summary_and_exit
fi

STAGE_CONVERT="$STAGE/scripts/convert.sh"

# Wrapper: run the STAGED convert.sh. Invoked via `bash` (rather than executing it
# directly) so the executable bit is asserted as its own test below instead of being
# a silent precondition for every other test in this suite. convert.sh's printf calls
# use a literal format string, so this runs correctly under any NO_COLOR/TERM
# combination -- no environment scrubbing needed here.
run_convert() {
  bash "$STAGE_CONVERT" "$@"
}

# --- --help exits 0 ---
printf '\n%s\n' "${C_BOLD}convert.sh --help${C_RESET}"

if run_convert --help >/dev/null 2>&1; then
  pass "convert.sh --help exits 0"
else
  fail "convert.sh --help exits 0"
fi

# --- Full run produces all 4 outputs ---
printf '\n%s\n' "${C_BOLD}Full conversion run (all 4 outputs)${C_RESET}"

# Capture rather than discard. A bare `>/dev/null 2>&1` reports THAT convert.sh
# failed while throwing away the only thing that explains WHY, which turns any
# environment-specific failure (a CI runner, a different awk, an unset TERM)
# into a guessing game against a remote log. On failure the captured output is
# echoed, indented, so the reason travels with the failure.
_convert_out="$(run_convert 2>&1)"
_convert_rc=$?
if [ "$_convert_rc" -eq 0 ]; then
  pass "convert.sh runs without error"
else
  fail "convert.sh runs without error (exit $_convert_rc)"
  printf '%s\n' "    --- convert.sh output (exit $_convert_rc) ---"
  printf '%s\n' "$_convert_out" | sed 's/^/    /'
  printf '%s\n' "    --- end convert.sh output ---"
fi

# --- Regression guard: convert.sh must not assume a real terminal ---
# This is the exact CI failure this suite exists to catch. CI runners set no TERM at
# all, so convert.sh's color-detection branch leaves every C_* variable empty. A
# printf whose format string starts with one of those (now-empty) variables followed
# by literal text beginning with '-' (e.g. step()'s "-->") is then parsed by printf
# as an option instead of a format string, and the script dies under `set -euo
# pipefail` before writing a single byte -- zero integrations generated, every
# downstream assertion in this suite fails with it. Every printf call above runs
# with TERM inherited from this interactive/CI shell, which is always set to
# *something*, so none of them exercise this path. Only an explicit `env -u TERM`
# invocation reproduces it. Writes to a private OUT_BASE so it cannot collide with
# the $STAGE/integrations tree the rest of this suite depends on.
printf '\n%s\n' "${C_BOLD}No-TERM regression (env -u TERM)${C_RESET}"

NOTERM_OUT="$STAGE/no-term-integrations"
NOTERM_EXIT=0
env -u TERM OUT_BASE="$NOTERM_OUT" bash "$STAGE_CONVERT" >/dev/null 2>&1 || NOTERM_EXIT=$?

if [[ $NOTERM_EXIT -eq 0 ]]; then
  pass "convert.sh exits 0 with TERM unset"
else
  fail "convert.sh exits 0 with TERM unset (exit $NOTERM_EXIT) -- a variable-led printf format string likely collapsed to an option flag"
fi

NOTERM_GEMINI="$NOTERM_OUT/gemini-cli/skills/1password/SKILL.md"
if [[ -s "$NOTERM_GEMINI" ]]; then
  pass "convert.sh with TERM unset generated non-empty output ($NOTERM_GEMINI)"
else
  fail "convert.sh with TERM unset generated no output (or empty output) at $NOTERM_GEMINI"
fi

# Parallel indexed arrays -- NOT `declare -A`, which bash 3.2 (the macOS system bash
# and this project's stated LCD) rejects outright, taking the rest of the suite with it.
TOOL_NAMES=("Gemini" "Cursor" "Aider" "Windsurf")
TOOL_RELPATHS=(
  "integrations/gemini-cli/skills/1password/SKILL.md"
  "integrations/cursor/.cursor/rules/1password.mdc"
  "integrations/aider/CONVENTIONS.md"
  "integrations/windsurf/.windsurfrules"
)

for i in 0 1 2 3; do
  rel="${TOOL_RELPATHS[$i]}"
  if [[ -f "$STAGE/$rel" ]]; then
    pass "Output generated: $rel"
  else
    fail "Output generated: $rel"
  fi
done

GEN_GEMINI="$STAGE/${TOOL_RELPATHS[0]}"
GEN_CURSOR="$STAGE/${TOOL_RELPATHS[1]}"
GEN_AIDER="$STAGE/${TOOL_RELPATHS[2]}"
GEN_WINDSURF="$STAGE/${TOOL_RELPATHS[3]}"

# --- Committed artifacts match freshly generated output ---
# integrations/** is generated, never hand-edited. Regenerating before asserting (what
# this suite used to do) means a stale or corrupt COMMITTED artifact can never fail a
# test. Diff the committed bytes against the staged bytes instead.
printf '\n%s\n' "${C_BOLD}Committed integrations/** are up to date${C_RESET}"

for i in 0 1 2 3; do
  name="${TOOL_NAMES[$i]}"
  rel="${TOOL_RELPATHS[$i]}"
  committed="$REPO_ROOT/$rel"
  generated="$STAGE/$rel"

  if [[ ! -f "$generated" ]]; then
    fail "$name: cannot compare -- convert.sh generated no $rel"
  elif [[ ! -f "$committed" ]]; then
    fail "$name: committed artifact missing at $rel -- run scripts/convert.sh and commit"
  elif diff -q "$committed" "$generated" >/dev/null 2>&1; then
    pass "$name: committed $rel matches generated output"
  else
    fail "$name: committed $rel is STALE -- run scripts/convert.sh and commit the result"
    diff -u "$committed" "$generated" 2>/dev/null | head -12 | \
      while IFS= read -r line; do printf "       %s\n" "$line"; done
  fi
done

# --- Gemini CLI output: preserves YAML frontmatter ---
printf '\n%s\n' "${C_BOLD}Gemini CLI output${C_RESET}"

if [[ -f "$GEN_GEMINI" ]]; then
  if grep -q '^name:' "$GEN_GEMINI"; then
    pass "Gemini output has 'name:' field in frontmatter"
  else
    fail "Gemini output has 'name:' field in frontmatter (should be copy of SKILL.md)"
  fi

  if grep -q '^description:' "$GEN_GEMINI"; then
    pass "Gemini output has 'description:' field in frontmatter"
  else
    fail "Gemini output has 'description:' field in frontmatter"
  fi

  # Gemini output should be identical to SKILL.md (it's a copy)
  if diff -q "$REPO_ROOT/skills/1password/SKILL.md" "$GEN_GEMINI" >/dev/null 2>&1; then
    pass "Gemini output is identical to SKILL.md (correct -- it's a direct copy)"
  else
    fail "Gemini output should be identical to SKILL.md"
  fi
else
  fail "Gemini output missing -- cannot verify 'name:' frontmatter field"
  fail "Gemini output missing -- cannot verify 'description:' frontmatter field"
  fail "Gemini output missing -- cannot verify it is a direct copy of SKILL.md"
fi

# --- Cursor .mdc: correct frontmatter ---
printf '\n%s\n' "${C_BOLD}Cursor .mdc output${C_RESET}"

if [[ -f "$GEN_CURSOR" ]]; then
  if grep -q '^description:' "$GEN_CURSOR"; then
    pass "Cursor .mdc has 'description:' in frontmatter"
  else
    fail "Cursor .mdc has 'description:' in frontmatter"
  fi

  if grep -qE '^globs:' "$GEN_CURSOR"; then
    pass "Cursor .mdc has 'globs:' field"
  else
    fail "Cursor .mdc has 'globs:' field"
  fi

  if grep -q '^alwaysApply: true' "$GEN_CURSOR"; then
    pass "Cursor .mdc has 'alwaysApply: true'"
  else
    fail "Cursor .mdc has 'alwaysApply: true'"
  fi

  # Cursor .mdc should NOT have the original SKILL.md 'name:' frontmatter field
  first_ten=$(head -10 "$GEN_CURSOR")
  if echo "$first_ten" | grep -qE '^name:'; then
    fail "Cursor .mdc must not have 'name:' in its frontmatter (should use Cursor format)"
  else
    pass "Cursor .mdc does not have 'name:' in frontmatter (correct Cursor format)"
  fi

  # grep proves a line STARTS with 'description:'. It cannot tell valid YAML from a
  # double-quoted scalar containing an illegal escape -- which is exactly how the
  # corrupt \'Permission denied\' .mdc passed every check above and shipped.
  cursor_fm=$(awk '/^---/{c++; if(c>2) exit} c==1 && !/^---/{print}' "$GEN_CURSOR")
  if [[ -z "$cursor_fm" ]]; then
    fail "Cursor .mdc has no parseable frontmatter block between the first two '---' lines"
  elif [[ $HAVE_PYYAML -eq 1 ]]; then
    if printf '%s\n' "$cursor_fm" | python3 -c "
import sys, yaml
d = yaml.safe_load(sys.stdin.read())
sys.exit(0 if isinstance(d, dict) else 1)
" 2>/dev/null; then
      pass "Cursor .mdc frontmatter parses as a YAML mapping"
    else
      fail "Cursor .mdc frontmatter is NOT parseable YAML -- convert.sh emitted an invalid scalar"
    fi
  else
    fail "PyYAML not installed -- cannot validate Cursor .mdc frontmatter (pip install pyyaml)"
  fi

  # Direct regression guard for the escape-corruption bug: a backslash immediately
  # before a quote character on the description line.
  BACKSLASH_QUOTE_RE='^description:.*\\["'"'"']'
  if grep -qE "$BACKSLASH_QUOTE_RE" "$GEN_CURSOR"; then
    fail "Cursor .mdc description contains a backslash-escaped quote (invalid YAML double-quoted escape)"
    grep -nE "$BACKSLASH_QUOTE_RE" "$GEN_CURSOR" | cut -c1-160 | \
      while IFS= read -r line; do printf "       %s\n" "$line"; done
  else
    pass "Cursor .mdc description has no backslash-escaped quotes"
  fi
else
  fail "Cursor output missing -- cannot verify 'description:' frontmatter"
  fail "Cursor output missing -- cannot verify 'globs:' field"
  fail "Cursor output missing -- cannot verify 'alwaysApply: true'"
  fail "Cursor output missing -- cannot verify absence of 'name:' field"
  fail "Cursor output missing -- cannot verify frontmatter YAML validity"
  fail "Cursor output missing -- cannot verify absence of backslash-escaped quotes"
fi

# --- Aider CONVENTIONS.md: no YAML frontmatter ---
printf '\n%s\n' "${C_BOLD}Aider CONVENTIONS.md output${C_RESET}"

if [[ -f "$GEN_AIDER" ]]; then
  first_line=$(head -1 "$GEN_AIDER")
  if [[ "$first_line" == "---" ]]; then
    fail "Aider CONVENTIONS.md must not start with YAML frontmatter (---)"
  else
    pass "Aider CONVENTIONS.md has no YAML frontmatter (does not start with ---)"
  fi

  if grep -qE '^name: 1password' "$GEN_AIDER"; then
    fail "Aider CONVENTIONS.md must not contain SKILL.md 'name:' field"
  else
    pass "Aider CONVENTIONS.md does not contain SKILL.md 'name:' field"
  fi

  # Verify body starts with expected content (not just a blank or garbled file)
  if head -3 "$GEN_AIDER" | grep -q "Requires:.*op.*CLI"; then
    pass "Aider output body starts with expected content"
  else
    fail "Aider output body does not start with expected content (possible strip_frontmatter bug)"
  fi
else
  fail "Aider output missing -- cannot verify absence of YAML frontmatter"
  fail "Aider output missing -- cannot verify absence of 'name:' field"
  fail "Aider output missing -- cannot verify body content"
fi

# --- Windsurf .windsurfrules: no YAML frontmatter ---
printf '\n%s\n' "${C_BOLD}Windsurf .windsurfrules output${C_RESET}"

if [[ -f "$GEN_WINDSURF" ]]; then
  first_line=$(head -1 "$GEN_WINDSURF")
  if [[ "$first_line" == "---" ]]; then
    fail "Windsurf .windsurfrules must not start with YAML frontmatter"
  else
    pass "Windsurf .windsurfrules has no YAML frontmatter"
  fi

  if grep -qE '^name: 1password' "$GEN_WINDSURF"; then
    fail "Windsurf .windsurfrules must not contain SKILL.md 'name:' field"
  else
    pass "Windsurf .windsurfrules does not contain SKILL.md 'name:' field"
  fi

  # Verify body starts with expected content (not just a blank or garbled file)
  if head -3 "$GEN_WINDSURF" | grep -q "Requires:.*op.*CLI"; then
    pass "Windsurf output body starts with expected content"
  else
    fail "Windsurf output body does not start with expected content (possible strip_frontmatter bug)"
  fi
else
  fail "Windsurf output missing -- cannot verify absence of YAML frontmatter"
  fail "Windsurf output missing -- cannot verify absence of 'name:' field"
  fail "Windsurf output missing -- cannot verify body content"
fi

# --- All 4 outputs contain Decision Router and Error Catalog ---
printf '\n%s\n' "${C_BOLD}All outputs contain required sections${C_RESET}"

for i in 0 1 2 3; do
  name="${TOOL_NAMES[$i]}"
  path="$STAGE/${TOOL_RELPATHS[$i]}"

  if [[ ! -f "$path" ]]; then
    fail "$name output missing -- cannot verify 'Decision Router' heading"
    fail "$name output missing -- cannot verify 'Error Catalog' section"
    continue
  fi

  # Anchor on the HEADING, not on the words. The router table's own last row is
  # `| Specific error message | → Error Catalog |`, so a bare `grep -q 'Error Catalog'`
  # passed on the cross-reference alone -- the whole section could be dropped by
  # convert.sh and this assertion would still be green. Same for 'Decision Router',
  # which appears both as an `# ` heading and in prose.
  if grep -qE '^# .*Decision Router[[:space:]]*$' "$path"; then
    pass "$name output contains 'Decision Router' heading"
  else
    fail "$name output contains 'Decision Router' heading (the words appear in prose; the '# ' heading does not)"
  fi

  if grep -qE '^## Error Catalog[[:space:]]*$' "$path"; then
    pass "$name output contains 'Error Catalog' section"
  else
    fail "$name output contains 'Error Catalog' section (the router row cross-references it; the '## ' section heading is absent)"
  fi
done

# --- File sizes are reasonable (>5KB) ---
printf '\n%s\n' "${C_BOLD}Output file sizes are reasonable (>5KB)${C_RESET}"

for i in 0 1 2 3; do
  name="${TOOL_NAMES[$i]}"
  rel="${TOOL_RELPATHS[$i]}"
  path="$STAGE/$rel"

  if [[ ! -f "$path" ]]; then
    fail "$name output missing -- cannot verify file size"
    continue
  fi
  size=$(wc -c < "$path" 2>/dev/null || echo 0)
  [[ "$size" =~ ^[0-9]+$ ]] || size=0
  if [[ "$size" -gt 5120 ]]; then
    pass "$name output is >5KB (${size} bytes)"
  else
    fail "$name output is >5KB (only ${size} bytes -- likely truncated)"
  fi
done

# --- Idempotency: running convert.sh twice produces identical output ---
printf '\n%s\n' "${C_BOLD}Idempotency (running convert.sh twice produces identical output)${C_RESET}"

before_sums=("" "" "" "")
for i in 0 1 2 3; do
  path="$STAGE/${TOOL_RELPATHS[$i]}"
  if [[ -f "$path" ]]; then
    before_sums[$i]=$(checksum "$path")
  fi
done

# Run convert.sh again. The old `|| true` discarded this exit code, so a convert.sh
# that aborted before writing anything scored four "identical after second run" passes
# by construction -- unchanged output is the guaranteed outcome of no output.
SECOND_RUN_OK=0
if run_convert >/dev/null 2>&1; then
  SECOND_RUN_OK=1
  pass "convert.sh second run exits 0"
else
  fail "convert.sh second run exited non-zero -- the idempotency comparisons below cannot mean anything"
fi

for i in 0 1 2 3; do
  name="${TOOL_NAMES[$i]}"
  path="$STAGE/${TOOL_RELPATHS[$i]}"

  if [[ $SECOND_RUN_OK -eq 0 ]]; then
    fail "$name: cannot verify idempotency -- the second convert.sh run failed"
    continue
  fi
  if [[ -z "${before_sums[$i]}" ]]; then
    fail "$name output missing before second run -- cannot verify idempotency"
    continue
  fi
  if [[ ! -f "$path" ]]; then
    fail "$name output disappeared after second run (not idempotent)"
    continue
  fi
  after_sum=$(checksum "$path")
  if [[ "${before_sums[$i]}" == "$after_sum" ]]; then
    pass "$name output is identical after second run"
  else
    fail "$name output differs between runs (not idempotent)"
  fi
done

# --- --tool cursor only generates cursor output ---
printf '\n%s\n' "${C_BOLD}--tool cursor generates only cursor output${C_RESET}"

ts_gemini=$(mtime_of "$GEN_GEMINI")
ts_aider=$(mtime_of "$GEN_AIDER")
ts_windsurf=$(mtime_of "$GEN_WINDSURF")

sleep 1  # ensure mtime would differ if files were touched

if run_convert --tool cursor >/dev/null 2>&1; then
  pass "convert.sh --tool cursor exits 0"
else
  fail "convert.sh --tool cursor exits 0"
fi

# Cursor output should have been regenerated
if [[ -f "$GEN_CURSOR" ]]; then
  pass "Cursor output still exists after --tool cursor run"
else
  fail "Cursor output should exist after --tool cursor run"
fi

# Other outputs should not have been modified
ts_gemini_after=$(mtime_of "$GEN_GEMINI")
ts_aider_after=$(mtime_of "$GEN_AIDER")
ts_windsurf_after=$(mtime_of "$GEN_WINDSURF")

assert_untouched "Gemini"   "$ts_gemini"   "$ts_gemini_after"
assert_untouched "Aider"    "$ts_aider"    "$ts_aider_after"
assert_untouched "Windsurf" "$ts_windsurf" "$ts_windsurf_after"

# --- Description fidelity against hostile frontmatter ---
# Nothing above compares the GENERATED description to the SOURCE description, so
# yaml_single_quote() and the plain-scalar branch of the frontmatter parser were both
# untested by construction: the shipped SKILL.md's `description:` block contains no
# apostrophe, and the committed-vs-generated diff compares two artifacts that would be
# truncated identically. Drive convert.sh with synthetic sources instead, and assert
# both that the .mdc frontmatter parses as YAML AND that the description round-trips.
printf '\n%s\n' "${C_BOLD}Description round-trips through hostile frontmatter${C_RESET}"

FIXTURE_N=0
FIXTURE_NAME=()
FIXTURE_EXPECT=()
FIXTURE_DIR=()

# make_fixture <label> <expected description> [crlf]   -- SKILL.md body on stdin
make_fixture() {
  local label="$1" expect="$2" eol="${3:-lf}"
  local idx=$FIXTURE_N
  local dir="$STAGE/fixtures/$idx"
  mkdir -p "$dir/skills/1password"
  cp -R "$STAGE/scripts" "$dir/scripts"
  if [[ "$eol" == "crlf" ]]; then
    awk '{ printf "%s\r\n", $0 }' > "$dir/skills/1password/SKILL.md"
  else
    cat > "$dir/skills/1password/SKILL.md"
  fi
  FIXTURE_NAME[$idx]="$label"
  FIXTURE_EXPECT[$idx]="$expect"
  FIXTURE_DIR[$idx]="$dir"
  FIXTURE_N=$((FIXTURE_N + 1))
}

make_fixture "block scalar with an apostrophe" "it's the agent's socket" <<'FIXEOF'
---
name: fixture
description: |
  it's the agent's socket
---

# Fixture

body
FIXEOF

make_fixture "block scalar with a pre-doubled apostrophe" "it''s already doubled" <<'FIXEOF'
---
name: fixture
description: |
  it''s already doubled
---

# Fixture

body
FIXEOF

make_fixture "block scalar with double quotes, colon and hash" 'say "Permission denied": issue #1' <<'FIXEOF'
---
name: fixture
description: |
  say "Permission denied": issue #1
---

# Fixture

body
FIXEOF

make_fixture "block scalar with backslashes" 'C:\Users\x and a literal \n' <<'FIXEOF'
---
name: fixture
description: |
  C:\Users\x and a literal \n
---

# Fixture

body
FIXEOF

# A pipe that is NOT a block indicator: the value is plain text ending in a pipe
# expression, and must not be parsed as the start of a block scalar.
make_fixture "single-line value containing a pipe" "op read op://Vault/Item/field | tr -d ' '" <<'FIXEOF'
---
name: fixture
description: op read op://Vault/Item/field | tr -d ' '
---

# Fixture

body
FIXEOF

# Plain (unquoted) multi-line scalar: valid YAML that folds onto one line with a space.
make_fixture "plain multi-line scalar (folded continuation)" "first part of the description second part that must not be dropped" <<'FIXEOF'
---
name: fixture
description: first part of the description
  second part that must not be dropped
license: Apache-2.0
---

# Fixture

body
FIXEOF

make_fixture "CRLF source" "no carriage return should survive" crlf <<'FIXEOF'
---
name: fixture
description: |
  no carriage return should survive
---

# Fixture

body
FIXEOF

if [[ $FIXTURE_N -ge 7 ]]; then
  pass "Staged $FIXTURE_N hostile-frontmatter fixtures"
else
  fail "Only $FIXTURE_N hostile-frontmatter fixtures were staged (expected >= 7)"
fi

_fix_i=0
while [[ $_fix_i -lt $FIXTURE_N ]]; do
  fx_label="${FIXTURE_NAME[$_fix_i]}"
  fx_dir="${FIXTURE_DIR[$_fix_i]}"
  fx_want="${FIXTURE_EXPECT[$_fix_i]}"
  fx_mdc="$fx_dir/integrations/cursor/.cursor/rules/1password.mdc"
  _fix_i=$((_fix_i + 1))

  if [[ $HAVE_PYYAML -ne 1 ]]; then
    fail "fixture [$fx_label]: PyYAML not installed -- cannot verify the generated description (pip install pyyaml)"
    continue
  fi
  if ! bash "$fx_dir/scripts/convert.sh" --tool cursor >/dev/null 2>&1; then
    fail "fixture [$fx_label]: convert.sh --tool cursor exited non-zero"
    continue
  fi
  if [[ ! -f "$fx_mdc" ]]; then
    fail "fixture [$fx_label]: convert.sh produced no .mdc"
    continue
  fi
  fx_got=$(python3 -c "
import sys, yaml
raw = open(sys.argv[1], encoding='utf-8').read().split('\n')
if not raw or raw[0].rstrip('\r') != '---':
    sys.stderr.write('no opening --- delimiter\n'); sys.exit(2)
fm = []
for line in raw[1:]:
    if line.rstrip('\r') == '---':
        break
    fm.append(line)
d = yaml.safe_load('\n'.join(fm))
if not isinstance(d, dict):
    sys.stderr.write('frontmatter is not a YAML mapping\n'); sys.exit(3)
if not isinstance(d.get('description'), str):
    sys.stderr.write('description missing or not a string\n'); sys.exit(4)
sys.stdout.write(d['description'])
" "$fx_mdc" 2>/dev/null)
  fx_rc=$?
  if [[ $fx_rc -ne 0 ]]; then
    fail "fixture [$fx_label]: generated .mdc frontmatter is not parseable YAML with a string 'description' (python exit $fx_rc)"
  elif [[ "$fx_got" == "$fx_want" ]]; then
    pass "fixture [$fx_label]: description round-trips intact"
  else
    fail "fixture [$fx_label]: description was mangled"
    printf "       want: %s\n" "$fx_want"
    printf "       got:  %s\n" "$fx_got"
  fi
done

# --- Repo was not mutated ---
# This used to assert `[[ -d "$STAGE/integrations" ]]` -- a fact about the STAGING
# tree, carrying no information at all about $REPO_ROOT. Read the repo instead.
printf '\n%s\n' "${C_BOLD}Suite did not mutate the repo${C_RESET}"

REPO_STATE_AFTER=""
_after_status=0
REPO_STATE_AFTER=$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null) || _after_status=$?

if [[ $REPO_STATE_STATUS -ne 0 || $_after_status -ne 0 ]]; then
  fail "git status --porcelain failed in $REPO_ROOT (before=$REPO_STATE_STATUS after=$_after_status) -- cannot prove the suite left the repo untouched"
elif [[ "$REPO_STATE_BEFORE" == "$REPO_STATE_AFTER" ]]; then
  pass "Repo working tree is unchanged (git status --porcelain identical before and after)"
else
  fail "Suite MUTATED the repo -- git status --porcelain changed:"
  diff <(printf '%s\n' "$REPO_STATE_BEFORE") <(printf '%s\n' "$REPO_STATE_AFTER") 2>/dev/null | \
    while IFS= read -r line; do printf "       %s\n" "$line"; done
fi

# --- Summary ---
summary_and_exit
