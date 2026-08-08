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

# Floor on the number of assertions this suite must execute. run-all.sh only scrapes
# "N/M passed" and cannot tell 31/31 from 4/4, so a block that quietly stops running
# shrinks the denominator invisibly. Keep this EQUAL to the number of assertions the
# suite actually runs: a floor with slack in it is not a floor. run-all.sh greps this
# exact assignment out of the file, so keep it on one line with no spaces.
EXPECTED_MIN_ASSERTIONS=32

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

# Safe grep -c: returns 0 instead of 1 on no match (grep exits 1 on no match)
gcount() { grep -c "$@" 2>/dev/null || true; }
gcountE() { grep -cE "$@" 2>/dev/null || true; }

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
  printf '\n%s' "${C_BOLD}Content:${C_RESET} $PASSES/$total passed"
  if [[ $FAILS -eq 0 ]]; then
    printf '%s' " ${C_GREEN}(all passed)${C_RESET}"
  else
    printf '%s' " ${C_RED}($FAILS failed)${C_RESET}"
  fi
  printf "\n"
  # Boolean status, not a mod-256 failure count. See test-structural.sh for rationale.
  if [[ $FAILS -eq 0 ]]; then exit 0; else exit 1; fi
}

printf '\n%s\n\n' "${C_BOLD}${C_CYAN}=== Content Tests ===${C_RESET}"

# --- Dependency gate ---
# The error-catalog assertions below count lines with python3. Without this gate a
# missing interpreter yields an empty count that reads as a content defect.
printf '%s\n' "${C_BOLD}Prerequisites${C_RESET}"
if command -v python3 >/dev/null 2>&1; then
  pass "python3 is available"
else
  fail "python3 not found — error catalog assertions cannot run"
  summary_and_exit
fi
printf "\n"

skill=$(cat "$SKILL_MD")

# --- Valid op subcommands ---
printf '%s\n' "${C_BOLD}op commands use valid subcommands${C_RESET}"

# Extract every line inside a fenced code block — that is where executable examples
# live. The old extraction anchored on '^[[:space:]]*(op |`op )', so ANY prefix hid the
# command from the scan: `RESULT=$(op login --account foo)`, `sudo op login`, and every
# piped or &&-joined form were invisible.
# POSIX class [[:space:]] not \s — \s is a GNU extension and BSD grep (macOS, the
# stated target) matches it as a literal 's'.
code_block_lines=$(awk '/^```/ { in_block = !in_block; next } in_block { print }' "$SKILL_MD")
op_lines=$(printf '%s\n' "$code_block_lines" | grep -E '(^|[^A-Za-z0-9_.-])op ' || true)
op_line_count=$(printf '%s\n' "$op_lines" | grep -c '^.' || true)
[[ "$op_line_count" =~ ^[0-9]+$ ]] || op_line_count=0

# Gate on the corpus before trusting any negative result below. With an empty
# $op_lines all five deprecated-subcommand checks pass while reading nothing —
# "nothing to check" must never read as "clean".
if [[ "$op_line_count" -gt 0 ]]; then
  pass "Found $op_line_count 'op ' command lines inside fenced code blocks to scan"
else
  fail "No 'op ' command lines found inside SKILL.md code blocks — the deprecated-subcommand scan has nothing to read"
fi

# Deprecated / invalid subcommands that should not appear.
#
# Every entry here is verified absent from `op --help` on op 2.35.0, whose complete
# command list is: account, connect, document, events-api, group, item, plugin,
# service-account, user, vault (management) and completion, inject, read, run, signin,
# signout, update, whoami. `op signout` used to be in this array and is a GENUINE op
# 2.35.0 command -- `op signout --help` prints "Sign out of a 1Password account" with
# --all/--forget flags. Asserting a real command is forbidden can only ever produce a
# false FAILURE, so it was replaced by `op list `, which really is absent from the
# command list above (`op item list` / `op vault list` are the 2.x spellings and do not
# contain the substring "op list ").
invalid_subcmds=("op login" "op list " "op fetch" "op get " "op secret ")
for subcmd in "${invalid_subcmds[@]}"; do
  if [[ "$op_line_count" -eq 0 ]]; then
    fail "Cannot check for invalid subcommand '$subcmd' — no op command lines were extracted"
  elif grep -qF "$subcmd" <<< "$op_lines"; then
    fail "Invalid/deprecated op subcommand used: '$subcmd'"
  else
    pass "No invalid subcommand '$subcmd'"
  fi
done

# Valid subcommands the skill must actually TEACH.
#
# The old form of this block grepped the whole file, prose included, for each name and
# called any hit "present". That is mere occurrence, not usage: the `op whoami`
# assertion was satisfied by SKILL.md's line "do NOT reach for `op whoami`" -- a
# sentence telling the agent NOT to run the command proved the command was documented.
# Deleting every worked example while keeping one disparaging sentence would have kept
# this green. Two evidence classes replace it, one assertion each, same count as before.
#
# Class 1 -- taught by example: the command must appear at command position on an
# executable line inside a shell-tagged fenced code block. Command position means the
# match is not preceded by an identifier character, so `op run` in `stop running` or
# inside a longer word does not count; comment-only lines are stripped first so a
# commented-out `# op read ...` cannot stand in for a real example. Restricting to
# bash/sh/zsh/fish fences also excludes the ```text Error Catalog, which is prose.
shell_block_lines=$(awk '
  /^```/ {
    if (in_block == 0) {
      in_block = 1
      lang = substr($0, 4)
      sub(/[[:space:]]+$/, "", lang)
      shell = (lang == "bash" || lang == "sh" || lang == "shell" || lang == "zsh" || lang == "fish")
    } else {
      in_block = 0; shell = 0
    }
    next
  }
  in_block && shell { print }
' "$SKILL_MD" | grep -vE '^[[:space:]]*#' || true)
shell_block_count=$(printf '%s\n' "$shell_block_lines" | grep -c '^.' || true)
[[ "$shell_block_count" =~ ^[0-9]+$ ]] || shell_block_count=0

example_subcmds=("op account get" "op run" "op read" "op item get" "op account list")
for subcmd in "${example_subcmds[@]}"; do
  if [[ "$shell_block_count" -eq 0 ]]; then
    # "Nothing to read" must never read as "clean" -- with no extracted lines every
    # check below would report a missing example, but say WHY rather than blaming content.
    fail "Cannot verify '$subcmd' usage — no executable lines extracted from shell code blocks"
  elif grep -qE "(^|[^A-Za-z0-9_.-])$subcmd([^A-Za-z0-9_-]|\$)" <<< "$shell_block_lines"; then
    pass "Valid subcommand '$subcmd' is invoked in a shell code-block example"
  else
    fail "Valid subcommand '$subcmd' is never invoked in a shell code-block example (a prose mention is not usage)"
  fi
done

# Class 2 -- documented, deliberately not exampled: `op whoami` was demoted to a
# service-account carve-out (the skill tells agents to use `op account get` instead
# under desktop app integration), so it correctly has NO code-block example. Assert the
# carve-out itself: at least one line that mentions `op whoami` in a service-account
# context AND is not a prohibition. The prohibition line alone must not satisfy this.
whoami_positive=$(grep -nF 'op whoami' "$SKILL_MD" | \
  grep -iE 'service[-_ ]account' | \
  grep -viE 'do not|don.t|never|avoid|instead of|rather than' || true)
if [[ -n "$whoami_positive" ]]; then
  pass "Valid subcommand 'op whoami' is documented affirmatively as the service-account identity check"
else
  fail "'op whoami' has no affirmative service-account mention — only prohibitions, which do not document a command"
fi

# --- --reveal flag on op item get ---
printf '\n%s\n' "${C_BOLD}--reveal flag on op item get examples that retrieve passwords${C_RESET}"

# Every 'op item get' that includes '--fields' should have --reveal (excluding comments and --format json)
needs_reveal=$(grep -n 'op item get.*--fields' "$SKILL_MD" | grep -v -- '--reveal' | grep -v '^[0-9]*:[[:space:]]*#' | grep -v -- '--format json' || true)
if [[ -z "$needs_reveal" ]]; then
  pass "'op item get' with --fields always includes --reveal"
else
  fail "'op item get' with --fields missing --reveal on some lines"
  echo "$needs_reveal" | while IFS= read -r line; do [[ -n "$line" ]] && printf "       Line %s\n" "$line"; done
fi

# --- --vault flag on op item get / op item list ---
printf '\n%s\n' "${C_BOLD}--vault flag on op item get/list examples${C_RESET}"

# Floors on the example corpus. These flag checks ARE the product — the skill exists to
# teach --vault and --no-newline — and each extraction chain below is up to seven
# chained `grep -v` deep. Without a floor, one over-broad exclusion empties the set and
# the check reports green while reading nothing: deleting the examples would be a way to
# make the suite pass.
MIN_ITEM_GET_EXAMPLES=2
MIN_ITEM_LIST_EXAMPLES=2
MIN_OP_READ_EXAMPLES=3

# count_lines <text> -- number of non-empty lines
count_lines() {
  local n
  n=$(printf '%s\n' "$1" | grep -c '^.' || true)
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  printf '%s\n' "$n"
}

# Match op item get lines that look like actual commands (any indentation, including variable assignments)
# Exclude: comment lines, backtick/quote inline references, prose descriptions, Fix: pointers
item_get_lines=$(grep -n 'op item get' "$SKILL_MD" | \
  grep -v '^[0-9]*:[[:space:]]*#' | \
  grep -v '^[0-9]*:.*`op item get`' | \
  grep -v '^[0-9]*:.*"op item get"' | \
  grep -v '^[0-9]*:.*Prefer' | \
  grep -v '^[0-9]*:.*→' | \
  grep -v '^[0-9]*:\*\*' | \
  grep -v '^[0-9]*:.*op item get.*--format json' 2>/dev/null || true)
item_get_count=$(count_lines "$item_get_lines")
if [[ "$item_get_count" -ge $MIN_ITEM_GET_EXAMPLES ]]; then
  pass "SKILL.md has $item_get_count 'op item get' example lines (>= $MIN_ITEM_GET_EXAMPLES)"
else
  fail "SKILL.md has only $item_get_count 'op item get' example lines (expected >= $MIN_ITEM_GET_EXAMPLES) — examples were removed or an exclusion above is over-broad"
fi

if [[ "$item_get_count" -gt 0 ]]; then
  missing_vault=$(echo "$item_get_lines" | grep -v -- '--vault' | grep -v '^[[:space:]]*$' || true)
  if [[ -z "$missing_vault" ]]; then
    pass "'op item get' examples include --vault flag"
  else
    fail "'op item get' examples missing --vault flag"
    echo "$missing_vault" | while IFS= read -r line; do [[ -n "$line" ]] && printf "       %s\n" "$line"; done
  fi
else
  fail "No 'op item get' command lines survived extraction — the --vault check read nothing and cannot report clean"
fi

item_list_lines=$(grep -n 'op item list' "$SKILL_MD" | \
  grep -v '^[0-9]*:[[:space:]]*#' | \
  grep -v '^[0-9]*:.*`op item list`' | \
  grep -v "^[0-9]*:.*'op item list'" 2>/dev/null || true)
item_list_count=$(count_lines "$item_list_lines")
if [[ "$item_list_count" -ge $MIN_ITEM_LIST_EXAMPLES ]]; then
  pass "SKILL.md has $item_list_count 'op item list' example lines (>= $MIN_ITEM_LIST_EXAMPLES)"
else
  fail "SKILL.md has only $item_list_count 'op item list' example lines (expected >= $MIN_ITEM_LIST_EXAMPLES) — examples were removed or an exclusion above is over-broad"
fi

if [[ "$item_list_count" -gt 0 ]]; then
  missing_vault=$(echo "$item_list_lines" | grep -v -- '--vault' || true)
  if [[ -z "$missing_vault" ]]; then
    pass "'op item list' examples include --vault flag"
  else
    fail "'op item list' examples missing --vault flag"
    echo "$missing_vault" | while IFS= read -r line; do [[ -n "$line" ]] && printf "       %s\n" "$line"; done
  fi
else
  fail "No 'op item list' command lines survived extraction — the --vault check read nothing and cannot report clean"
fi

# --- --no-newline on op read ---
printf '\n%s\n' "${C_BOLD}--no-newline on op read examples${C_RESET}"

op_read_lines=$(grep -n 'op read' "$SKILL_MD" | \
  grep -v '^[0-9]*:[[:space:]]*#' | \
  grep -v '^[0-9]*:.*`op read`' | \
  grep -v "^[0-9]*:.*'op read'" | \
  grep -v '^[0-9]*:.*Prefer' | \
  grep -v '^[0-9]*:.*→' | \
  grep -v '^[0-9]*:\*\*' 2>/dev/null || true)
op_read_count=$(count_lines "$op_read_lines")
if [[ "$op_read_count" -ge $MIN_OP_READ_EXAMPLES ]]; then
  pass "SKILL.md has $op_read_count 'op read' example lines (>= $MIN_OP_READ_EXAMPLES)"
else
  fail "SKILL.md has only $op_read_count 'op read' example lines (expected >= $MIN_OP_READ_EXAMPLES) — examples were removed or an exclusion above is over-broad"
fi

if [[ "$op_read_count" -gt 0 ]]; then
  missing_nonewline=$(echo "$op_read_lines" | grep -v -- '--no-newline' || true)
  if [[ -z "$missing_nonewline" ]]; then
    pass "'op read' examples include --no-newline flag"
  else
    fail "'op read' examples missing --no-newline flag"
    echo "$missing_nonewline" | while IFS= read -r line; do [[ -n "$line" ]] && printf "       %s\n" "$line"; done
  fi
else
  fail "No 'op read' command lines survived extraction — the --no-newline check read nothing and cannot report clean"
fi

# --- Fish shell alternatives for process substitution ---
printf '\n%s\n' "${C_BOLD}Fish shell alternatives for process substitution${C_RESET}"

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
printf '\n%s\n' "${C_BOLD}No \$USER variable (prevents POSIX shadow ambiguity)${C_RESET}"

# \$USER in code is suspect -- should use \$OP_USER for 1Password username variables.
# \b is a GNU extension; anchor on surrounding context so BSD grep behaves the same.
# `\{?` catches the braced form ${USER} -- the shape most likely to appear inside a
# quoted shell string, and the one the old pattern could never match. `{` is not
# special in ERE outside an interval, so this stays BSD-safe.
user_var_lines=$(grep -nE '\$\{?USER([^A-Za-z0-9_]|$)' "$SKILL_MD" || true)
if [[ -z "$user_var_lines" ]]; then
  pass "No \$USER variable found (uses \$OP_USER instead)"
else
  fail "\$USER variable found -- should use \$OP_USER to avoid POSIX shadow"
  echo "$user_var_lines" | while IFS= read -r line; do [[ -n "$line" ]] && printf "       %s\n" "$line"; done
fi

# --- \$CLAUDECODE variable used correctly ---
printf '\n%s\n' "${C_BOLD}\$CLAUDECODE variable (not \$CLAUDE_SESSION)${C_RESET}"

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
printf '\n%s\n' "${C_BOLD}Error catalog entries format${C_RESET}"

# Extract the Error Catalog section (between ## Error Catalog and next ## heading)
error_catalog=$(awk '/^## Error Catalog/{f=1; next} f && /^## /{exit} f{print}' "$SKILL_MD")

# The catalog uses a code block with backtick-quoted error lines:
# "error message"   (actual double quotes at start of line in code block)
# -> cause
# -> Fix: command
# Count lines starting with double-quote (error entries in the catalog code block)
# Each entry is a head line (a quoted error string OR an unquoted symptom description)
# followed by exactly one arrow CAUSE line and exactly one arrow "Fix:" line, either of
# which may have indented continuation lines.
#
# Counting entry heads by '^"' alone undercounts -- the catalog also documents symptoms
# whose exact wording varies by op version, and those heads are not quoted. And counting
# every arrow line lumps causes together with Fix lines, giving a structurally 2N
# numerator that a `-ge N` threshold can never fail even with half the causes missing.
# Count heads, causes and Fix lines separately, then require exact parity.
_catalog_counts=$(python3 -c "
import sys

def is_arrow(s):
    return s.startswith('\u2192') or s.startswith('->')

lines = sys.stdin.read().split('\n')
heads = quoted = cause = fix = 0
for i, line in enumerate(lines):
    if line.startswith('\`\`\`'):
        continue
    if is_arrow(line):
        body = line.lstrip('\u2192->').strip()
        if body.startswith('Fix:'):
            fix += 1
        else:
            cause += 1
        continue
    if not line.strip():
        continue
    if line[:1] in (' ', '\t'):
        continue  # indented continuation of the previous line
    nxt = lines[i + 1] if i + 1 < len(lines) else ''
    if is_arrow(nxt):
        heads += 1
        if line.startswith('\"'):
            quoted += 1
sys.stdout.write('%d %d %d %d\n' % (heads, quoted, cause, fix))
" <<< "$error_catalog")

read -r error_entries quoted_entries cause_lines_count fix_lines <<< "$_catalog_counts"
[[ "${error_entries:-}" =~ ^[0-9]+$ ]] || error_entries=0
[[ "${quoted_entries:-}" =~ ^[0-9]+$ ]] || quoted_entries=0
[[ "${cause_lines_count:-}" =~ ^[0-9]+$ ]] || cause_lines_count=-1
[[ "${fix_lines:-}" =~ ^[0-9]+$ ]] || fix_lines=-1

if [[ "$error_entries" -gt 0 ]]; then
  pass "Error catalog has $error_entries entries ($quoted_entries quoted, $((error_entries - quoted_entries)) symptom-described)"
else
  fail "Error catalog has no entries (expected head lines followed by a '\u2192' cause line)"
fi

if [[ "$fix_lines" -eq "$error_entries" && "$error_entries" -gt 0 ]]; then
  pass "Each error entry has exactly one Fix line ($fix_lines Fix lines for $error_entries entries)"
else
  fail "Fix line count ($fix_lines) does not equal error entry count ($error_entries) -- entries missing or duplicating Fix"
fi

if [[ "$cause_lines_count" -eq "$error_entries" && "$error_entries" -gt 0 ]]; then
  pass "Each error entry has exactly one cause line ($cause_lines_count cause lines for $error_entries entries)"
else
  fail "Cause line count ($cause_lines_count) does not equal error entry count ($error_entries) -- entries missing or duplicating a cause"
fi

# --- Code blocks have language tags ---
printf '\n%s\n' "${C_BOLD}Code blocks have language tags${C_RESET}"

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
printf '\n%s\n' "${C_BOLD}No broken markdown${C_RESET}"

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
printf '\n%s\n' "${C_BOLD}README install commands include mkdir -p${C_RESET}"

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
summary_and_exit
