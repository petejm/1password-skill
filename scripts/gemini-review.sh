#!/usr/bin/env bash
# gemini-review.sh — Run tabula rasa reviews via Gemini API
#
# Usage:
#   op run --env-file=<(echo 'GEMINI_API_KEY=op://Private/Gemini API Key/credential') -- \
#     ./scripts/gemini-review.sh [--reviewer <name>] [--model <model>] [--all]
#
# Reviewers: swe, security, devrel (default: swe)
# Models: gemini-2.5-flash (default), gemini-2.5-pro

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Color output
if [[ -z "${NO_COLOR:-}" && "${TERM:-dumb}" != "dumb" ]]; then
  C_GREEN="\033[0;32m"; C_RED="\033[0;31m"; C_CYAN="\033[0;36m"
  C_YELLOW="\033[0;33m"; C_BOLD="\033[1m"; C_RESET="\033[0m"
else
  C_GREEN="" C_RED="" C_CYAN="" C_YELLOW="" C_BOLD="" C_RESET=""
fi

# Defaults
REVIEWER="swe"
MODEL="gemini-2.5-flash"
RUN_ALL=false
API_BASE="https://generativelanguage.googleapis.com/v1beta"

usage() {
  cat <<'EOF'
Usage: gemini-review.sh [OPTIONS]

Run tabula rasa reviews on the 1password-skill plugin via Gemini API.

Options:
  --reviewer <name>   Reviewer persona: swe, security, devrel (default: swe)
  --model <model>     Gemini model: gemini-2.5-pro, gemini-2.5-flash (default: gemini-2.5-pro)
  --all               Run all 3 reviewers sequentially
  --help              Show this help

Prerequisites:
  GEMINI_API_KEY must be set. Use 1Password to inject it:

  op run --env-file=<(echo 'GEMINI_API_KEY=op://Private/Gemini API Key/credential') -- \
    ./scripts/gemini-review.sh --all

  Fish shell:
  op run --env-file=(echo 'GEMINI_API_KEY=op://Private/Gemini API Key/credential' | psub) -- \
    ./scripts/gemini-review.sh --all
EOF
}

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --reviewer) REVIEWER="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    --all) RUN_ALL=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

# Validate API key
if [[ -z "${GEMINI_API_KEY:-}" ]]; then
  echo "Error: GEMINI_API_KEY not set. Use op run to inject it:"
  echo '  op run --env-file=<(echo '"'"'GEMINI_API_KEY=op://Private/Gemini API Key/credential'"'"') -- ./scripts/gemini-review.sh'
  exit 1
fi

# Validate reviewer
case "$REVIEWER" in
  swe|security|devrel) ;;
  *) echo "Error: Unknown reviewer '$REVIEWER'. Must be: swe, security, devrel"; exit 1 ;;
esac

# Validate model
case "$MODEL" in
  gemini-2.5-pro|gemini-2.5-flash) ;;
  *) echo "Error: Unknown model '$MODEL'. Must be: gemini-2.5-pro, gemini-2.5-flash"; exit 1 ;;
esac

# Bundle files into context string
bundle_files() {
  local files=(
    "skills/1password/SKILL.md"
    "plugin.json"
    "README.md"
    ".gitignore"
    "scripts/convert.sh"
  )
  local bundle=""
  for f in "${files[@]}"; do
    local path="$REPO_ROOT/$f"
    if [[ -f "$path" ]]; then
      bundle+="### File: $f"$'\n'
      bundle+="$(cat "$path")"$'\n\n'
    else
      bundle+="### File: $f"$'\n'
      bundle+="(file not found)"$'\n\n'
    fi
  done
  echo "$bundle"
}

# Reviewer prompts
get_prompt() {
  local reviewer="$1"
  local file_bundle="$2"

  case "$reviewer" in
    swe)
      cat <<EOF
You are a Senior Software Engineer reviewing a Claude Code plugin for public release. This is a tabula rasa review — assume you know nothing about this project. Review everything from scratch.

Review for:
1. Correctness — Are the op CLI commands accurate? Any wrong flags, deprecated syntax?
2. Completeness — Any common 1Password + CLI scenarios missing?
3. Plugin structure — Is plugin.json correct? Would this install correctly?
4. README quality — Clear, accurate, well-structured for public audience?
5. Consistency — Do README claims match SKILL.md content?
6. Cross-platform — Linux, macOS, Fish shell coverage gaps?

Format output as:
## P0 — Must fix before public release
## P1 — Should fix
## P2 — Nice to have
## Observations — Things that are good / noteworthy

Be thorough. Be specific. Cite file:line for every finding.

---

Here are the files to review:

$file_bundle
EOF
      ;;
    security)
      cat <<EOF
You are a Senior Security Engineer reviewing a Claude Code plugin that interacts with 1Password CLI. This is a tabula rasa review — your focus is exclusively on security.

Review for:
1. Secret exposure — Could any pattern cause secrets to be logged or persisted?
2. Command injection — Any patterns where input could be injected into shell commands?
3. Credential hygiene — Are op run / op read / op item get patterns safe?
4. Process substitution safety — Is the <(...) / psub pattern secure?
5. Auth patterns — Is the --netrc-file approach safe?
6. Scope creep — Does this skill ask Claude to do anything it shouldn't with credentials?
7. Attack surface — If a malicious user modified this skill, what's the worst they could achieve?
8. Missing warnings — Any scenarios where the skill should warn but doesn't?

Format output as:
## Critical — Security vulnerabilities
## Warning — Security concerns
## Advisory — Recommendations
## Approved — Patterns that are correctly secure

Be adversarial. Assume the worst case. Cite file:line for every finding.

---

Here are the files to review:

$file_bundle
EOF
      ;;
    devrel)
      cat <<EOF
You are a Developer Relations engineer reviewing a Claude Code plugin README for public release on GitHub. You're seeing this project for the first time.

Review for:
1. First impression — Would a developer understand what this is in 10 seconds?
2. Install experience — Is the install path clear? Any friction?
3. Value proposition — Does the README convince someone to install this?
4. Accuracy — Do README claims match actual skill content?
5. Missing sections — FAQ? Troubleshooting? Badges?
6. Tone — Professional? Approachable?
7. Discoverability — Would someone searching "1password claude code" find this?

Format output as:
## Strengths
## Issues — things to fix
## Suggestions — nice to have improvements

Be honest. This is going on GitHub where real developers will judge it.

---

Here are the files to review:

$file_bundle
EOF
      ;;
  esac
}

# Call Gemini API; echoes full raw JSON response
call_gemini_raw() {
  local prompt="$1"
  curl -s -X POST \
    "${API_BASE}/models/${MODEL}:generateContent?key=${GEMINI_API_KEY}" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg text "$prompt" '{
      contents: [{parts: [{text: $text}]}],
      generationConfig: {
        temperature: 0.3,
        maxOutputTokens: 8192
      }
    }')"
}

# Extract text from Gemini response JSON
extract_text() {
  echo "$1" | jq -r '.candidates[0].content.parts[0].text // "Error: No response generated"'
}

# Extract token counts
extract_tokens() {
  local response="$1"
  local input_tokens output_tokens
  input_tokens=$(echo "$response" | jq -r '.usageMetadata.promptTokenCount // 0')
  output_tokens=$(echo "$response" | jq -r '.usageMetadata.candidatesTokenCount // 0')
  echo "$input_tokens $output_tokens"
}

# Estimate cost based on model and token counts
estimate_cost() {
  local model="$1"
  local input_tokens="$2"
  local output_tokens="$3"

  # Pricing per 1M tokens
  local input_rate output_rate
  case "$model" in
    gemini-2.5-pro)   input_rate="1.25"; output_rate="10.00" ;;
    gemini-2.5-flash) input_rate="0.15"; output_rate="0.60" ;;
    *)                input_rate="1.25"; output_rate="10.00" ;;
  esac

  # Use awk for floating point math
  awk -v in_tok="$input_tokens" -v out_tok="$output_tokens" \
      -v in_rate="$input_rate" -v out_rate="$output_rate" \
      'BEGIN {
        cost = (in_tok / 1000000 * in_rate) + (out_tok / 1000000 * out_rate)
        printf "%.4f\n", cost
      }'
}

# Format token count as human-readable (e.g., 12K)
fmt_tokens() {
  local n="$1"
  if [[ "$n" -ge 1000 ]]; then
    echo "$((n / 1000))K"
  else
    echo "${n}"
  fi
}

# Print header for a review
print_header() {
  local reviewer="$1"
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S %Z')
  echo ""
  printf "${C_CYAN}${C_BOLD}═══════════════════════════════════════════════════${C_RESET}\n"
  printf "${C_CYAN}${C_BOLD}  Gemini TR Review — %s (%s)${C_RESET}\n" "$reviewer" "$MODEL"
  printf "${C_CYAN}  %s${C_RESET}\n" "$timestamp"
  printf "${C_CYAN}${C_BOLD}═══════════════════════════════════════════════════${C_RESET}\n"
  echo ""
}

# Print footer with token/cost info
print_footer() {
  local input_tokens="$1"
  local output_tokens="$2"
  local cost="$3"
  echo ""
  printf "${C_YELLOW}───────────────────────────────────────────────────${C_RESET}\n"
  printf "${C_YELLOW}  Tokens: %s in / %s out${C_RESET}\n" \
    "$(fmt_tokens "$input_tokens")" "$(fmt_tokens "$output_tokens")"
  printf "${C_YELLOW}  Cost: ~\$%s (estimated)${C_RESET}\n" "$cost"
  printf "${C_YELLOW}───────────────────────────────────────────────────${C_RESET}\n"
  echo ""
}

# Run a single reviewer; outputs review text; sets globals _LAST_INPUT_TOKENS, _LAST_OUTPUT_TOKENS, _LAST_COST
_LAST_INPUT_TOKENS=0
_LAST_OUTPUT_TOKENS=0
_LAST_COST="0.0000"

run_reviewer() {
  local reviewer="$1"
  local file_bundle
  file_bundle="$(bundle_files)"

  local prompt
  prompt="$(get_prompt "$reviewer" "$file_bundle")"

  print_header "$reviewer"

  printf "${C_GREEN}Calling Gemini API (model: %s)...${C_RESET}\n\n" "$MODEL"

  local raw_response
  raw_response="$(call_gemini_raw "$prompt")"

  local review_text
  review_text="$(extract_text "$raw_response")"

  # Print review content
  echo "$review_text"

  # Extract usage
  local tokens
  tokens="$(extract_tokens "$raw_response")"
  _LAST_INPUT_TOKENS="$(echo "$tokens" | cut -d' ' -f1)"
  _LAST_OUTPUT_TOKENS="$(echo "$tokens" | cut -d' ' -f2)"
  _LAST_COST="$(estimate_cost "$MODEL" "$_LAST_INPUT_TOKENS" "$_LAST_OUTPUT_TOKENS")"

  print_footer "$_LAST_INPUT_TOKENS" "$_LAST_OUTPUT_TOKENS" "$_LAST_COST"
}

# Run all reviewers and print summary
run_all() {
  local reviewers=("swe" "security" "devrel")
  declare -A summary_in_tokens
  declare -A summary_out_tokens
  declare -A summary_costs

  for r in "${reviewers[@]}"; do
    REVIEWER="$r"
    run_reviewer "$r"
    summary_in_tokens[$r]="$_LAST_INPUT_TOKENS"
    summary_out_tokens[$r]="$_LAST_OUTPUT_TOKENS"
    summary_costs[$r]="$_LAST_COST"
  done

  # Compute total cost
  local total_cost
  total_cost=$(awk \
    -v swe="${summary_costs[swe]}" \
    -v sec="${summary_costs[security]}" \
    -v dr="${summary_costs[devrel]}" \
    'BEGIN { printf "%.2f\n", swe + sec + dr }')

  echo ""
  printf "${C_BOLD}╔═══════════════════════════════════════════════════╗${C_RESET}\n"
  printf "${C_BOLD}║           Gemini TR Summary                       ║${C_RESET}\n"
  printf "${C_BOLD}╚═══════════════════════════════════════════════════╝${C_RESET}\n"
  echo ""
  printf "  %-10s  %-18s  %-13s  %s\n" "Reviewer" "Model" "Tokens" "Cost"
  printf "  %-10s  %-18s  %-13s  %s\n" "---------" "----------------" "-----------" "------"
  for r in "${reviewers[@]}"; do
    local tok_str
    tok_str="$(fmt_tokens "${summary_in_tokens[$r]}")/$(fmt_tokens "${summary_out_tokens[$r]}")"
    printf "  %-10s  %-18s  %-13s  \$%s\n" \
      "$r" "$MODEL" "$tok_str" "${summary_costs[$r]}"
  done
  echo ""
  printf "  %47s \$%s\n" "Total:" "$total_cost"
  echo ""
}

# Main
if [[ "$RUN_ALL" == "true" ]]; then
  run_all
else
  run_reviewer "$REVIEWER"
fi
