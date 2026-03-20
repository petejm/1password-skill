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
  C_GREEN="\033[0;32m"; C_RED="\033[0;31m"; C_CYAN="\033[0;36m"
  C_YELLOW="\033[0;33m"; C_BOLD="\033[1m"; C_DIM="\033[2m"; C_RESET="\033[0m"
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

# Header
printf "\n${C_BOLD}${C_CYAN}1password-skill — Test Suite${C_RESET}\n"
printf "${C_DIM}%s${C_RESET}\n" "$(date '+%Y-%m-%d %H:%M:%S')"
printf "${C_DIM}Repo: %s${C_RESET}\n\n" "$REPO_ROOT"

# Run each suite
for i in "${!SUITE_NAMES[@]}"; do
  name="${SUITE_NAMES[$i]}"
  script="${SUITE_SCRIPTS[$i]}"

  if [[ ! -f "$script" ]]; then
    printf "${C_RED}MISSING${C_RESET} Test script not found: %s\n" "$script"
    SUITE_EXIT_CODES+=("127")
    SUITE_DURATIONS+=("0")
    OVERALL_EXIT=1
    continue
  fi

  if [[ ! -x "$script" ]]; then
    chmod +x "$script"
  fi

  start_time=$(date +%s%N 2>/dev/null || date +%s)

  # Run suite, capture output and exit code
  exit_code=0
  suite_output=$(NO_COLOR="${NO_COLOR:-}" "$script" 2>&1) || exit_code=$?

  end_time=$(date +%s%N 2>/dev/null || date +%s)

  # Calculate duration in ms (falls back to seconds if %N not supported)
  if [[ ${#start_time} -gt 10 ]]; then
    duration_ms=$(( (end_time - start_time) / 1000000 ))
    duration_str="${duration_ms}ms"
  else
    duration_str="$((end_time - start_time))s"
  fi

  SUITE_EXIT_CODES+=("$exit_code")
  SUITE_DURATIONS+=("$duration_str")

  [[ $exit_code -ne 0 ]] && OVERALL_EXIT=1

  # Print suite output (already formatted by the suite script)
  echo "$suite_output"

  # Extract pass/fail counts from suite output summary line
  pass_count=$(echo "$suite_output" | grep -oE '[0-9]+/[0-9]+ passed' | grep -oE '^[0-9]+' | tail -1 || echo 0)
  total_count=$(echo "$suite_output" | grep -oE '[0-9]+/[0-9]+ passed' | grep -oE '/[0-9]+' | tr -d '/' | tail -1 || echo 0)
  fail_count=$(( total_count - pass_count ))

  TOTAL_PASS=$(( TOTAL_PASS + pass_count ))
  TOTAL_FAIL=$(( TOTAL_FAIL + fail_count ))
done

# Summary table
printf "\n${C_BOLD}${C_CYAN}╔═══════════════════════════════════════════════════╗${C_RESET}\n"
printf "${C_BOLD}${C_CYAN}║               Test Suite Summary                  ║${C_RESET}\n"
printf "${C_BOLD}${C_CYAN}╚═══════════════════════════════════════════════════╝${C_RESET}\n\n"

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
  printf "${result}"
  printf "  %-6s\n" "$dur"
done

printf "\n  ${C_BOLD}Total:${C_RESET} %d passed, %d failed\n" "$TOTAL_PASS" "$TOTAL_FAIL"

if [[ $OVERALL_EXIT -eq 0 ]]; then
  printf "\n  ${C_GREEN}${C_BOLD}All tests passed.${C_RESET}\n\n"
else
  printf "\n  ${C_RED}${C_BOLD}Some tests failed.${C_RESET}\n\n"
fi

exit $OVERALL_EXIT
