#!/usr/bin/env bash
# run-all.sh — Run all 1password-skill test suites and print a summary report
#
# Usage: ./tests/run-all.sh [--no-color]
# Run from repo root or tests/ directory.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Color output (respects NO_COLOR env var or --no-color flag)
for arg in "$@"; do
  [[ "$arg" == "--no-color" ]] && export NO_COLOR=1
done

if [[ -z "${NO_COLOR:-}" && "${TERM:-dumb}" != "dumb" && -t 1 ]]; then
  # $'...' (ANSI-C quoting) turns \033 into a real ESC byte at assignment time, so
  # color renders whether the variable ends up in a printf FORMAT string or a %s
  # data argument (see scripts/convert.sh for why a plain "\033[...m" is not enough).
  C_GREEN=$'\033[0;32m'; C_RED=$'\033[0;31m'; C_CYAN=$'\033[0;36m'
  C_YELLOW=$'\033[0;33m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'; C_RESET=$'\033[0m'
else
  C_GREEN="" C_RED="" C_CYAN="" C_YELLOW="" C_BOLD="" C_DIM="" C_RESET=""
fi

# Test suites: display name → script path
declare -a SUITE_NAMES=("Structural" "Security" "Content" "Integration")
declare -a SUITE_SCRIPTS=(
  "$SCRIPT_DIR/test-structural.sh"
  "$SCRIPT_DIR/test-security.sh"
  "$SCRIPT_DIR/test-content.sh"
  "$SCRIPT_DIR/test-integration.sh"
)

# Results
declare -a SUITE_EXIT_CODES=()
declare -a SUITE_DURATIONS=()

TOTAL_PASS=0
TOTAL_FAIL=0
OVERALL_EXIT=0

# Probe nanosecond support ONCE. Do not infer it from the length of the result:
# BSD date (macOS) has no %N conversion, emits the literal character 'N', and still
# exits 0 — so `date +%s%N || date +%s` never takes the fallback and produces
# garbage like "1754600000N". Timing is cosmetic and must never gate test execution.
HAVE_NS=0
_ns_probe=$(date +%s%N 2>/dev/null || true)
if [[ "$_ns_probe" =~ ^[0-9]+$ && ${#_ns_probe} -gt 10 ]]; then
  HAVE_NS=1
fi

# Each suite declares its own assertion floor as `EXPECTED_MIN_ASSERTIONS=<n>`. Read it
# back here so a CRASHED suite is scored as the assertions it OWNS rather than as a
# single failure — a suite of 64 assertions that dies before the first one is not one
# failure, and reporting it as one prints a near-perfect total for a broken run.
# Falls back to 1 (the old behaviour) when the constant is absent, which is still a
# failure and still forces OVERALL_EXIT=1.
expected_for_suite() {
  local script="$1" n="" matches="" first=""
  # Read every match into a variable first, then slice it in pure bash.
  # `grep | head -1 | cut` risks SIGPIPE under pipefail: head can exit after its
  # first line while grep still has more to write (see convert.sh's
  # printf|grep -q fix for the full mechanism).
  matches=$(grep -E '^EXPECTED_MIN_ASSERTIONS=[0-9]+$' "$script" 2>/dev/null || true)
  first="${matches%%$'\n'*}"
  n="${first#*=}"
  [[ "$n" =~ ^[0-9]+$ && "$n" -gt 0 ]] || n=1
  printf '%s\n' "$n"
}

now_ticks() {
  local t
  if [[ $HAVE_NS -eq 1 ]]; then
    t=$(date +%s%N 2>/dev/null || true)
  else
    t=$(date +%s 2>/dev/null || true)
  fi
  [[ "$t" =~ ^[0-9]+$ ]] || t=0
  printf '%s\n' "$t"
}

# Header
printf '\n%s\n' "${C_BOLD}${C_CYAN}1password-skill — Test Suite${C_RESET}"
printf '%s\n' "${C_DIM}$(date '+%Y-%m-%d %H:%M:%S')${C_RESET}"
printf '%s\n\n' "${C_DIM}Repo: ${REPO_ROOT}${C_RESET}"

# Run each suite
for i in "${!SUITE_NAMES[@]}"; do
  name="${SUITE_NAMES[$i]}"
  script="${SUITE_SCRIPTS[$i]}"

  if [[ ! -f "$script" ]]; then
    printf '%s\n' "${C_RED}MISSING${C_RESET} Test script not found: ${script}"
    SUITE_EXIT_CODES+=("127")
    SUITE_DURATIONS+=("0")
    OVERALL_EXIT=1
    continue
  fi

  # Report a missing executable bit instead of silently repairing it — the runner
  # must not mutate the repo. Suites are invoked via `bash`, so the bit is optional.
  if [[ ! -x "$script" ]]; then
    printf '%s\n' "  ${C_YELLOW}WARN${C_RESET} ${script} is not executable (chmod +x it)"
  fi

  start_time=$(now_ticks)

  # Run suite, capture output and exit code
  exit_code=0
  # Propagate the interpreter actually running this script rather than doing a fresh
  # PATH lookup on `bash`. On macOS CI, if a newer Homebrew bash sits earlier in PATH
  # than /bin/bash, a bare `bash` here would silently run every suite under bash 5 while
  # the job claims to validate bash 3.2 — $BASH is bash's own path to itself, so this
  # keeps the suite pinned to whatever interpreter launched run-all.sh.
  suite_output=$(NO_COLOR="${NO_COLOR:-}" "${BASH:-bash}" "$script" 2>&1) || exit_code=$?

  end_time=$(now_ticks)

  if [[ $HAVE_NS -eq 1 ]]; then
    duration_ms=$(( (end_time - start_time) / 1000000 ))
    duration_str="${duration_ms:-0}ms"
  else
    duration_str="$(( end_time - start_time ))s"
  fi

  SUITE_EXIT_CODES+=("$exit_code")
  SUITE_DURATIONS+=("$duration_str")

  [[ $exit_code -ne 0 ]] && OVERALL_EXIT=1

  # Print suite output (already formatted by the suite script)
  echo "$suite_output"

  # Extract pass/fail counts from suite output summary line
  pass_count=$(echo "$suite_output" | grep -oE '[0-9]+/[0-9]+ passed' | grep -oE '^[0-9]+' | tail -1)
  total_count=$(echo "$suite_output" | grep -oE '[0-9]+/[0-9]+ passed' | grep -oE '/[0-9]+' | tr -d '/' | tail -1)
  [[ "$pass_count" =~ ^[0-9]+$ ]] || pass_count=0
  [[ "$total_count" =~ ^[0-9]+$ ]] || total_count=0

  # A suite that dies before printing its summary emits no 'N/M passed' line. Scraping
  # would report 0 passed / 0 failed — zero failures for a suite that never ran. Treat
  # an unparseable or zero-assertion summary as a hard error of its own.
  if [[ $total_count -eq 0 ]]; then
    unrun=$(expected_for_suite "$script")
    printf '%s\n' "  ${C_RED}CRASHED${C_RESET} ${name} produced no summary line (exit ${exit_code}) — ${unrun} assertions did not run"
    SUITE_EXIT_CODES[$i]=$(( exit_code == 0 ? 1 : exit_code ))
    TOTAL_FAIL=$(( TOTAL_FAIL + unrun ))
    OVERALL_EXIT=1
    continue
  fi

  fail_count=$(( total_count - pass_count ))

  TOTAL_PASS=$(( TOTAL_PASS + pass_count ))
  TOTAL_FAIL=$(( TOTAL_FAIL + fail_count ))
done

# Summary table
printf '\n%s\n' "${C_BOLD}${C_CYAN}╔═══════════════════════════════════════════════════╗${C_RESET}"
printf '%s\n' "${C_BOLD}${C_CYAN}║               Test Suite Summary                  ║${C_RESET}"
printf '%s\n\n' "${C_BOLD}${C_CYAN}╚═══════════════════════════════════════════════════╝${C_RESET}"

printf "  %-15s  %-8s  %-6s\n" "Suite" "Result" "Time"
printf "  %-15s  %-8s  %-6s\n" "---------------" "--------" "------"

for i in "${!SUITE_NAMES[@]}"; do
  name="${SUITE_NAMES[$i]}"
  code="${SUITE_EXIT_CODES[$i]:-?}"
  dur="${SUITE_DURATIONS[$i]:-?}"

  if [[ "$code" == "0" ]]; then
    result="${C_GREEN}PASSED${C_RESET}"
  else
    result="${C_RED}FAILED${C_RESET}"
  fi

  printf "  %-15s  " "$name"
  printf '%s' "$result"
  printf "  %-6s\n" "$dur"
done

printf '\n%s\n' "  ${C_BOLD}Total:${C_RESET} ${TOTAL_PASS} passed, ${TOTAL_FAIL} failed"

if [[ $OVERALL_EXIT -eq 0 ]]; then
  printf '\n%s\n\n' "  ${C_GREEN}${C_BOLD}All tests passed.${C_RESET}"
else
  printf '\n%s\n\n' "  ${C_RED}${C_BOLD}Some tests failed.${C_RESET}"
fi

exit $OVERALL_EXIT
