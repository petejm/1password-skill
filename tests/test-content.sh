#!/usr/bin/env bash
# test-content.sh -- Validate SKILL.md content accuracy and completeness
#
# Tests that commands are correct, flags are present, shell alternatives exist,
# and markdown formatting is valid.
# Run from repo root: ./tests/test-content.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILL_MD="$REPO_ROOT/skills/1password/SKILL.md"

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

# Safe grep -c: returns 0 instead of 1 on no match (grep exits 1 on no match)
gcount() { grep -c "$@" 2>/dev/null || true; }
gcountE() { grep -cE "$@" 2>/dev/null || true; }

printf "\n${C_BOLD}${C_CYAN}=== Content Tests ===${C_RESET}\n\n"

skill=$(cat "$SKILL_MD")

# --- Valid op subcommands ---
printf "${C_BOLD}op commands use valid subcommands${C_RESET}\n"

# Extract lines that start 'op ' from code blocks
op_lines=$(grep -nE '^\s*(op |`op )' "$SKILL_MD" || true)

# Deprecated / invalid subcommands that should not appear
invalid_subcmds=("op login" "op signout" "op fetch" "op get " "op secret ")
for subcmd in "${invalid_subcmds[@]}"; do
  if echo "$op_lines" | grep -qF "$subcmd"; then
    fail "Invalid/deprecated op subcommand used: '$subcmd'"
  else
    pass "No invalid subcommand '$subcmd'"
  fi
done

# Valid subcommands that should appear
valid_subcmds=("op whoami" "op run" "op read" "op item get" "op account list")
for subcmd in "${valid_subcmds[@]}"; do
  if echo "$skill" | grep -qF "$subcmd"; then
    pass "Valid subcommand '$subcmd' present"
  else
    fail "Valid subcommand '$subcmd' not found (expected in skill)"
  fi
done

# --- --reveal flag on op item get ---
printf "\n${C_BOLD}--reveal flag on op item get examples that retrieve passwords${C_RESET}\n"

# Every 'op item get' that includes '--fields' should have --reveal (excluding comments and --format json)
needs_reveal=$(grep -n 'op item get.*--fields' "$SKILL_MD" | grep -v -- '--reveal' | grep -v '^[0-9]*:\s*#' | grep -v -- '--format json' || true)
if [[ -z "$needs_reveal" ]]; then
  pass "'op item get' with --fields always includes --reveal"
else
  fail "'op item get' with --fields missing --reveal on some lines"
  echo "$needs_reveal" | while IFS= read -r line; do [[ -n "$line" ]] && printf "       Line %s\n" "$line"; done
fi

# --- --vault flag on op item get / op item list ---
printf "\n${C_BOLD}--vault flag on op item get/list examples${C_RESET}\n"

# Match op item get lines that look like actual commands (any indentation, including variable assignments)
# Exclude: comment lines, backtick/quote inline references, prose descriptions, Fix: pointers
item_get_lines=$(grep -n 'op item get' "$SKILL_MD" | \
  grep -v '^[0-9]*:\s*#' | \
  grep -v '^[0-9]*:.*`op item get`' | \
  grep -v '^[0-9]*:.*"op item get"' | \
  grep -v '^[0-9]*:.*Prefer' | \
  grep -v '^[0-9]*:.*→' | \
  grep -v '^[0-9]*:\*\*' | \
  grep -v '^[0-9]*:.*op item get.*--format json' 2>/dev/null || true)
if [[ -n "$item_get_lines" ]]; then
  missing_vault=$(echo "$item_get_lines" | grep -v -- '--vault' | grep -v '^\s*$' || true)
  if [[ -z "$missing_vault" ]]; then
    pass "'op item get' examples include --vault flag"
  else
    fail "'op item get' examples missing --vault flag"
    echo "$missing_vault" | while IFS= read -r line; do [[ -n "$line" ]] && printf "       %s\n" "$line"; done
  fi
else
  pass "No 'op item get' command lines found to check"
fi

item_list_lines=$(grep -n 'op item list' "$SKILL_MD" | \
  grep -v '^[0-9]*:\s*#' | \
  grep -v '^[0-9]*:.*`op item list`' | \
  grep -v "^[0-9]*:.*'op item list'" 2>/dev/null || true)
if [[ -n "$item_list_lines" ]]; then
  missing_vault=$(echo "$item_list_lines" | grep -v -- '--vault' || true)
  if [[ -z "$missing_vault" ]]; then
    pass "'op item list' examples include --vault flag"
  else
    fail "'op item list' examples missing --vault flag"
    echo "$missing_vault" | while IFS= read -r line; do [[ -n "$line" ]] && printf "       %s\n" "$line"; done
  fi
else
  pass "No bare 'op item list' lines found to check"
fi

# --- --no-newline on op read ---
printf "\n${C_BOLD}--no-newline on op read examples${C_RESET}\n"

op_read_lines=$(grep -n 'op read' "$SKILL_MD" | \
  grep -v '^[0-9]*:\s*#' | \
  grep -v '^[0-9]*:.*`op read`' | \
  grep -v "^[0-9]*:.*'op read'" | \
  grep -v '^[0-9]*:.*Prefer' | \
  grep -v '^[0-9]*:.*→' | \
  grep -v '^[0-9]*:\*\*' 2>/dev/null || true)
if [[ -n "$op_read_lines" ]]; then
  missing_nonewline=$(echo "$op_read_lines" | grep -v -- '--no-newline' || true)
  if [[ -z "$missing_nonewline" ]]; then
    pass "'op read' examples include --no-newline flag"
  else
    fail "'op read' examples missing --no-newline flag"
    echo "$missing_nonewline" | while IFS= read -r line; do [[ -n "$line" ]] && printf "       %s\n" "$line"; done
  fi
else
  pass "No bare 'op read' lines to check"
fi

# --- Fish shell alternatives for process substitution ---
printf "\n${C_BOLD}Fish shell alternatives for process substitution${C_RESET}\n"

# Count process substitution uses: <(...)
proc_sub_count=$(gcount '<(' "$SKILL_MD")
# Count Fish psub mentions
psub_count=$(gcount 'psub' "$SKILL_MD")

if [[ "$proc_sub_count" -gt 0 ]]; then
  if [[ "$psub_count" -gt 0 ]]; then
    if [[ "$psub_count" -ge "$((proc_sub_count / 2))" ]]; then
      pass "Fish psub alternative provided (process substitutions: $proc_sub_count, psub mentions: $psub_count)"
    else
      fail "Insufficient Fish psub alternatives ($psub_count psub for $proc_sub_count process substitutions)"
    fi
  else
    fail "Fish psub alternatives missing: $proc_sub_count process substitutions but 0 psub mentions"
  fi
else
  pass "No process substitutions found (no Fish alternatives needed)"
fi

# --- No \$USER variable (should be \$OP_USER) ---
printf "\n${C_BOLD}No \$USER variable (prevents POSIX shadow ambiguity)${C_RESET}\n"

# \$USER in code is suspect -- should use \$OP_USER for 1Password username variables
user_var_lines=$(grep -n '\$USER\b' "$SKILL_MD" || true)
if [[ -z "$user_var_lines" ]]; then
  pass "No \$USER variable found (uses \$OP_USER instead)"
else
  fail "\$USER variable found -- should use \$OP_USER to avoid POSIX shadow"
  echo "$user_var_lines" | while IFS= read -r line; do [[ -n "$line" ]] && printf "       %s\n" "$line"; done
fi

# --- \$CLAUDECODE variable used correctly ---
printf "\n${C_BOLD}\$CLAUDECODE variable (not \$CLAUDE_SESSION)${C_RESET}\n"

if grep -q 'CLAUDECODE' "$SKILL_MD"; then
  pass "\$CLAUDECODE is referenced in skill"
else
  fail "\$CLAUDECODE should be referenced in skill (used to detect Claude Code sessions)"
fi

if grep -q 'CLAUDE_SESSION' "$SKILL_MD"; then
  fail "\$CLAUDE_SESSION found -- should use \$CLAUDECODE"
else
  pass "No \$CLAUDE_SESSION reference (correct)"
fi

# --- Error catalog format ---
printf "\n${C_BOLD}Error catalog entries format${C_RESET}\n"

# Extract the Error Catalog section (between ## Error Catalog and next ## heading)
error_catalog=$(awk '/^## Error Catalog/{f=1; next} f && /^## /{exit} f{print}' "$SKILL_MD")

# The catalog uses a code block with backtick-quoted error lines:
# "error message"   (actual double quotes at start of line in code block)
# -> cause
# -> Fix: command
# Count lines starting with double-quote (error entries in the catalog code block)
error_entries=$(echo "$error_catalog" | grep -c '^"' || true)
fix_lines=$(echo "$error_catalog" | grep -c 'Fix:' || true)
# Error catalog uses unicode right arrow for cause lines
cause_lines_count=$(echo "$error_catalog" | grep -c '^.' || true)
# Re-count: lines starting with unicode arrow (the -> cause lines use the right arrow character)
cause_lines_count=$(python3 -c "
import sys
count = 0
for line in sys.stdin:
    if line.startswith('\u2192') or line.startswith('->'):
        count += 1
sys.stdout.write(str(count) + '\n')
" <<< "$error_catalog")

if [[ "$error_entries" -gt 0 ]]; then
  pass "Error catalog has $error_entries quoted error entries"
else
  fail "Error catalog has no double-quoted error entries (expected lines starting with \")"
fi

if [[ "$fix_lines" -gt 0 && "$fix_lines" -ge "$error_entries" ]]; then
  pass "Each error entry has a Fix line ($fix_lines Fix lines for $error_entries errors)"
else
  fail "Fix lines ($fix_lines) fewer than error entries ($error_entries) -- some entries missing Fix"
fi

if [[ "$cause_lines_count" -gt 0 && "$cause_lines_count" -ge "$error_entries" ]]; then
  pass "Each error entry has a cause line ($cause_lines_count -> lines for $error_entries errors)"
else
  fail "Cause lines ($cause_lines_count) fewer than error entries ($error_entries) -- some entries missing cause"
fi

# --- Code blocks have language tags ---
printf "\n${C_BOLD}Code blocks have language tags${C_RESET}\n"

# Use awk to track code fence state and count untagged opening fences.
# Avoids backtick-in-regex issues by keeping the pattern in awk, not bash [[ =~ ]].
# Explicitly initialize counters to 0 to prevent empty-field read issues.
_awk_result=$(awk '
  BEGIN { untagged=0; fences=0; in_block=0 }
  /^```/{
    if (in_block == 0) {
      if (/^```[[:space:]]*$/) untagged++
      in_block = 1
    } else {
      in_block = 0
    }
    fences++
  }
  END { print untagged " " fences }
' "$SKILL_MD")
untagged_opens="${_awk_result%% *}"
fence_count="${_awk_result##* }"
untagged_opens="${untagged_opens:-0}"
fence_count="${fence_count:-0}"

if [[ "$untagged_opens" -eq 0 ]]; then
  pass "All code blocks have language tags (0 untagged opening fences)"
else
  fail "$untagged_opens code block(s) missing language tags (opening \`\`\` without bash/fish/etc.)"
fi

# --- No broken markdown (unclosed code blocks) ---
printf "\n${C_BOLD}No broken markdown${C_RESET}\n"

# Code fences must be balanced (even count) -- already counted above
if [[ $(( fence_count % 2 )) -eq 0 ]]; then
  pass "Code fences are balanced (even count: $fence_count)"
else
  fail "Code fences unbalanced -- likely unclosed code block ($fence_count fences, expected even)"
fi

# Markdown table separator rows: lines matching |---|--- should end with |
malformed_separators=$(grep -E '^\|.*---' "$SKILL_MD" | grep -vE '^\|.*---.*\|$' || true)
if [[ -z "$malformed_separators" ]]; then
  pass "Markdown table separators are well-formed"
else
  fail "Malformed table separator rows found"
  echo "$malformed_separators" | while IFS= read -r line; do [[ -n "$line" ]] && printf "       %s\n" "$line"; done
fi

# --- README install commands include mkdir -p ---
printf "\n${C_BOLD}README install commands include mkdir -p${C_RESET}\n"

readme="$REPO_ROOT/README.md"
if [[ -f "$readme" ]]; then
  if grep -q 'mkdir -p' "$readme"; then
    pass "README includes 'mkdir -p' in install commands"
  else
    fail "README install commands missing 'mkdir -p'"
  fi
else
  fail "README.md not found"
fi

# --- Summary ---
total=$((PASSES + FAILS))
printf "\n${C_BOLD}Content:${C_RESET} $PASSES/$total passed"
if [[ $FAILS -eq 0 ]]; then
  printf " ${C_GREEN}(all passed)${C_RESET}"
else
  printf " ${C_RED}($FAILS failed)${C_RESET}"
fi
printf "\n"

exit $FAILS
