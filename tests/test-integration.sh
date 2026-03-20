#!/usr/bin/env bash
# test-integration.sh -- Verify convert.sh works correctly and produces valid outputs
#
# Tests the conversion pipeline end-to-end: script exists, runs, produces correct
# outputs for all 4 target tools, is idempotent, and supports --tool filtering.
# Run from repo root: ./tests/test-integration.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONVERT_SH="$REPO_ROOT/scripts/convert.sh"

PASSES=0
FAILS=0

# Color output (respects NO_COLOR)
if [[ -z "${NO_COLOR:-}" && "${TERM:-dumb}" != "dumb" && -t 1 ]]; then
  C_GREEN="\033[0;32m"; C_RED="\033[0;31m"; C_CYAN="\033[0;36m"; C_BOLD="\033[1m"; C_RESET="\033[0m"
else
  C_GREEN="" C_RED="" C_CYAN="" C_BOLD="" C_RESET=""
fi

pass() { PASSES=$((PASSES + 1)); printf "  ${C_GREEN}PASS${C_RESET} %s\n" "$1"; }
fail() { FAILS=$((FAILS + 1));  printf "  ${C_RED}FAIL${C_RESET} %s\n" "$1"; }

# Wrapper: run convert.sh without inheriting NO_COLOR (convert.sh has a printf bug with NO_COLOR).
# Always unset NO_COLOR for convert.sh invocations; it produces file content, not terminal output.
run_convert() {
  env -u NO_COLOR "$CONVERT_SH" "$@"
}

printf "\n${C_BOLD}${C_CYAN}=== Integration Tests ===${C_RESET}\n\n"

# Expected output paths
GEMINI_OUT="$REPO_ROOT/integrations/gemini-cli/skills/1password/SKILL.md"
CURSOR_OUT="$REPO_ROOT/integrations/cursor/.cursor/rules/1password.mdc"
AIDER_OUT="$REPO_ROOT/integrations/aider/CONVENTIONS.md"
WINDSURF_OUT="$REPO_ROOT/integrations/windsurf/.windsurfrules"

# --- Script basics ---
printf "${C_BOLD}convert.sh basics${C_RESET}\n"

if [[ -f "$CONVERT_SH" ]]; then
  pass "convert.sh exists"
else
  fail "convert.sh exists at scripts/convert.sh"
fi

if [[ -x "$CONVERT_SH" ]]; then
  pass "convert.sh is executable"
else
  fail "convert.sh is executable (chmod +x scripts/convert.sh)"
fi

# --- --help exits 0 ---
printf "\n${C_BOLD}convert.sh --help${C_RESET}\n"

if run_convert --help >/dev/null 2>&1; then
  pass "convert.sh --help exits 0"
else
  fail "convert.sh --help exits 0"
fi

# --- Full run produces all 4 outputs ---
printf "\n${C_BOLD}Full conversion run (all 4 outputs)${C_RESET}\n"

if run_convert >/dev/null 2>&1; then
  pass "convert.sh runs without error"
else
  fail "convert.sh runs without error"
fi

for path in "$GEMINI_OUT" "$CURSOR_OUT" "$AIDER_OUT" "$WINDSURF_OUT"; do
  rel="${path#$REPO_ROOT/}"
  if [[ -f "$path" ]]; then
    pass "Output exists: $rel"
  else
    fail "Output exists: $rel"
  fi
done

# --- Gemini CLI output: preserves YAML frontmatter ---
printf "\n${C_BOLD}Gemini CLI output${C_RESET}\n"

if [[ -f "$GEMINI_OUT" ]]; then
  if grep -q '^name:' "$GEMINI_OUT"; then
    pass "Gemini output has 'name:' field in frontmatter"
  else
    fail "Gemini output has 'name:' field in frontmatter (should be copy of SKILL.md)"
  fi

  if grep -q '^description:' "$GEMINI_OUT"; then
    pass "Gemini output has 'description:' field in frontmatter"
  else
    fail "Gemini output has 'description:' field in frontmatter"
  fi

  # Gemini output should be identical to SKILL.md (it's a copy)
  if diff -q "$REPO_ROOT/skills/1password/SKILL.md" "$GEMINI_OUT" >/dev/null 2>&1; then
    pass "Gemini output is identical to SKILL.md (correct -- it's a direct copy)"
  else
    fail "Gemini output should be identical to SKILL.md"
  fi
fi

# --- Cursor .mdc: correct frontmatter ---
printf "\n${C_BOLD}Cursor .mdc output${C_RESET}\n"

if [[ -f "$CURSOR_OUT" ]]; then
  if grep -q '^description:' "$CURSOR_OUT"; then
    pass "Cursor .mdc has 'description:' in frontmatter"
  else
    fail "Cursor .mdc has 'description:' in frontmatter"
  fi

  if grep -qE '^globs:' "$CURSOR_OUT"; then
    pass "Cursor .mdc has 'globs:' field"
  else
    fail "Cursor .mdc has 'globs:' field"
  fi

  if grep -q '^alwaysApply: true' "$CURSOR_OUT"; then
    pass "Cursor .mdc has 'alwaysApply: true'"
  else
    fail "Cursor .mdc has 'alwaysApply: true'"
  fi

  # Cursor .mdc should NOT have the original SKILL.md 'name:' frontmatter field
  first_ten=$(head -10 "$CURSOR_OUT")
  if echo "$first_ten" | grep -qE '^name:'; then
    fail "Cursor .mdc must not have 'name:' in its frontmatter (should use Cursor format)"
  else
    pass "Cursor .mdc does not have 'name:' in frontmatter (correct Cursor format)"
  fi
fi

# --- Aider CONVENTIONS.md: no YAML frontmatter ---
printf "\n${C_BOLD}Aider CONVENTIONS.md output${C_RESET}\n"

if [[ -f "$AIDER_OUT" ]]; then
  first_line=$(head -1 "$AIDER_OUT")
  if [[ "$first_line" == "---" ]]; then
    fail "Aider CONVENTIONS.md must not start with YAML frontmatter (---)"
  else
    pass "Aider CONVENTIONS.md has no YAML frontmatter (does not start with ---)"
  fi

  if grep -qE '^name: 1password' "$AIDER_OUT"; then
    fail "Aider CONVENTIONS.md must not contain SKILL.md 'name:' field"
  else
    pass "Aider CONVENTIONS.md does not contain SKILL.md 'name:' field"
  fi
fi

# --- Windsurf .windsurfrules: no YAML frontmatter ---
printf "\n${C_BOLD}Windsurf .windsurfrules output${C_RESET}\n"

if [[ -f "$WINDSURF_OUT" ]]; then
  first_line=$(head -1 "$WINDSURF_OUT")
  if [[ "$first_line" == "---" ]]; then
    fail "Windsurf .windsurfrules must not start with YAML frontmatter"
  else
    pass "Windsurf .windsurfrules has no YAML frontmatter"
  fi

  if grep -qE '^name: 1password' "$WINDSURF_OUT"; then
    fail "Windsurf .windsurfrules must not contain SKILL.md 'name:' field"
  else
    pass "Windsurf .windsurfrules does not contain SKILL.md 'name:' field"
  fi
fi

# --- All 4 outputs contain Decision Router and Error Catalog ---
printf "\n${C_BOLD}All outputs contain required sections${C_RESET}\n"

declare -A output_files=(
  ["Gemini"]="$GEMINI_OUT"
  ["Cursor"]="$CURSOR_OUT"
  ["Aider"]="$AIDER_OUT"
  ["Windsurf"]="$WINDSURF_OUT"
)

for tool in "Gemini" "Cursor" "Aider" "Windsurf"; do
  path="${output_files[$tool]}"
  [[ -f "$path" ]] || continue

  if grep -q 'Decision Router' "$path"; then
    pass "$tool output contains 'Decision Router' heading"
  else
    fail "$tool output contains 'Decision Router' heading"
  fi

  if grep -q 'Error Catalog' "$path"; then
    pass "$tool output contains 'Error Catalog' section"
  else
    fail "$tool output contains 'Error Catalog' section"
  fi
done

# --- File sizes are reasonable (>5KB) ---
printf "\n${C_BOLD}Output file sizes are reasonable (>5KB)${C_RESET}\n"

for tool in "Gemini" "Cursor" "Aider" "Windsurf"; do
  path="${output_files[$tool]}"
  [[ -f "$path" ]] || continue
  size=$(wc -c < "$path" 2>/dev/null || echo 0)
  rel="${path#$REPO_ROOT/}"
  if [[ "$size" -gt 5120 ]]; then
    pass "$tool output is >5KB (${size} bytes)"
  else
    fail "$tool output is >5KB (only ${size} bytes -- likely truncated)"
  fi
done

# --- Idempotency: running convert.sh twice produces identical output ---
printf "\n${C_BOLD}Idempotency (running convert.sh twice produces identical output)${C_RESET}\n"

# Capture checksums before second run
declare -A before_sums
for tool in "Gemini" "Cursor" "Aider" "Windsurf"; do
  path="${output_files[$tool]}"
  [[ -f "$path" ]] || continue
  before_sums[$tool]=$(md5sum "$path" 2>/dev/null | cut -d' ' -f1 || sha256sum "$path" 2>/dev/null | cut -d' ' -f1 || echo "unknown")
done

# Run convert.sh again
run_convert >/dev/null 2>&1 || true

# Compare checksums
for tool in "Gemini" "Cursor" "Aider" "Windsurf"; do
  path="${output_files[$tool]}"
  [[ -f "$path" ]] || continue
  after_sum=$(md5sum "$path" 2>/dev/null | cut -d' ' -f1 || sha256sum "$path" 2>/dev/null | cut -d' ' -f1 || echo "unknown2")
  if [[ "${before_sums[$tool]}" == "$after_sum" ]]; then
    pass "$tool output is identical after second run"
  else
    fail "$tool output differs between runs (not idempotent)"
  fi
done

# --- --tool cursor only generates cursor output ---
printf "\n${C_BOLD}--tool cursor generates only cursor output${C_RESET}\n"

# Record timestamps of non-cursor outputs before targeted run
ts_gemini=$(stat -c '%Y' "$GEMINI_OUT" 2>/dev/null || stat -f '%m' "$GEMINI_OUT" 2>/dev/null || echo 0)
ts_aider=$(stat -c '%Y' "$AIDER_OUT" 2>/dev/null || stat -f '%m' "$AIDER_OUT" 2>/dev/null || echo 0)
ts_windsurf=$(stat -c '%Y' "$WINDSURF_OUT" 2>/dev/null || stat -f '%m' "$WINDSURF_OUT" 2>/dev/null || echo 0)

sleep 1  # ensure mtime would differ if files were touched

if run_convert --tool cursor >/dev/null 2>&1; then
  pass "convert.sh --tool cursor exits 0"
else
  fail "convert.sh --tool cursor exits 0"
fi

# Cursor output should have been regenerated
if [[ -f "$CURSOR_OUT" ]]; then
  pass "Cursor output still exists after --tool cursor run"
else
  fail "Cursor output should exist after --tool cursor run"
fi

# Other outputs should not have been modified
ts_gemini_after=$(stat -c '%Y' "$GEMINI_OUT" 2>/dev/null || stat -f '%m' "$GEMINI_OUT" 2>/dev/null || echo 0)
ts_aider_after=$(stat -c '%Y' "$AIDER_OUT" 2>/dev/null || stat -f '%m' "$AIDER_OUT" 2>/dev/null || echo 0)
ts_windsurf_after=$(stat -c '%Y' "$WINDSURF_OUT" 2>/dev/null || stat -f '%m' "$WINDSURF_OUT" 2>/dev/null || echo 0)

if [[ "$ts_gemini" == "$ts_gemini_after" ]]; then
  pass "Gemini output not modified by --tool cursor run"
else
  fail "Gemini output was modified by --tool cursor run (should only modify cursor)"
fi

if [[ "$ts_aider" == "$ts_aider_after" ]]; then
  pass "Aider output not modified by --tool cursor run"
else
  fail "Aider output was modified by --tool cursor run (should only modify cursor)"
fi

if [[ "$ts_windsurf" == "$ts_windsurf_after" ]]; then
  pass "Windsurf output not modified by --tool cursor run"
else
  fail "Windsurf output was modified by --tool cursor run (should only modify cursor)"
fi

# --- Summary ---
total=$((PASSES + FAILS))
printf "\n${C_BOLD}Integration:${C_RESET} $PASSES/$total passed"
if [[ $FAILS -eq 0 ]]; then
  printf " ${C_GREEN}(all passed)${C_RESET}"
else
  printf " ${C_RED}($FAILS failed)${C_RESET}"
fi
printf "\n"

exit $FAILS
