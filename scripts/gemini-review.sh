#!/usr/bin/env bash
# gemini-review.sh — Run tabula rasa reviews via Gemini API
#
# Usage:
#   op run --env-file=<(echo 'GEMINI_API_KEY=op://YourVault/Gemini API Key/credential') -- \
#     ./scripts/gemini-review.sh [--reviewer <name>] [--model <model>] [--all]
#
# Reviewers: swe, security, devrel (default: swe)
# Models: any model the Gemini API accepts (default: gemini-2.5-flash)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Scratch dir for the request body and the curl config that carries the API key.
# mktemp -d creates it 0700, so the key is never world-readable and never in argv.
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gemini-review.XXXXXX")"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

# Color output
if [[ -z "${NO_COLOR:-}" && "${TERM:-dumb}" != "dumb" ]]; then
  # $'...' (ANSI-C quoting) turns \033 into a real ESC byte at assignment time, so
  # color renders whether the variable ends up in a printf FORMAT string or a %s
  # data argument (see scripts/convert.sh for why a plain "\033[...m" is not enough).
  C_GREEN=$'\033[0;32m'; C_RED=$'\033[0;31m'; C_CYAN=$'\033[0;36m'
  C_YELLOW=$'\033[0;33m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
else
  C_GREEN="" C_RED="" C_CYAN="" C_YELLOW="" C_BOLD="" C_RESET=""
fi

# Defaults
REVIEWER="swe"
MODEL="gemini-2.5-flash"
RUN_ALL=false
API_BASE="https://generativelanguage.googleapis.com/v1beta"
# Thinking models spend part of the output budget on reasoning tokens, so a
# small budget silently truncates the review. Override if a reviewer runs long.
MAX_OUTPUT_TOKENS="${GEMINI_MAX_OUTPUT_TOKENS:-32768}"
PRICING_URL="https://ai.google.dev/gemini-api/docs/pricing"
PRICING_VERIFIED="2026-08-07"
if [[ -n "${GEMINI_PRICE_IN:-}" && -n "${GEMINI_PRICE_OUT:-}" ]]; then
  PRICE_NOTE="GEMINI_PRICE_* override"
else
  PRICE_NOTE="rates as of $PRICING_VERIFIED"
fi

usage() {
  cat <<'EOF'
Usage: gemini-review.sh [OPTIONS]

Run tabula rasa reviews on the 1password-skill plugin via Gemini API.

Options:
  --reviewer <name>   Reviewer persona: swe, security, devrel (default: swe)
  --model <model>     Any model the Gemini API accepts, e.g. gemini-2.5-flash,
                      gemini-2.5-pro (default: gemini-2.5-flash)
  --all               Run all 3 reviewers sequentially
  --help              Show this help

Environment:
  GEMINI_MAX_OUTPUT_TOKENS  Output token budget per review (default: 32768)
  GEMINI_PRICE_IN           USD per 1M input tokens, for the cost estimate
  GEMINI_PRICE_OUT          USD per 1M output tokens, for the cost estimate
                            Current rates: https://ai.google.dev/gemini-api/docs/pricing

Prerequisites:
  GEMINI_API_KEY must be set. Use 1Password to inject it:

  op run --env-file=<(echo 'GEMINI_API_KEY=op://YourVault/Gemini API Key/credential') -- \
    ./scripts/gemini-review.sh --all

  Fish shell:
  op run --env-file=(echo 'GEMINI_API_KEY=op://YourVault/Gemini API Key/credential' | psub) -- \
    ./scripts/gemini-review.sh --all
EOF
}

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --reviewer)
      [[ -n "${2:-}" ]] || { echo "Error: --reviewer requires a value" >&2; exit 1; }
      REVIEWER="$2"; shift 2 ;;
    --model)
      [[ -n "${2:-}" ]] || { echo "Error: --model requires a value" >&2; exit 1; }
      MODEL="$2"; shift 2 ;;
    --all) RUN_ALL=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

# Validate API key
if [[ -z "${GEMINI_API_KEY:-}" ]]; then
  echo "Error: GEMINI_API_KEY not set. Use op run to inject it:" >&2
  echo '  op run --env-file=<(echo '"'"'GEMINI_API_KEY=op://YourVault/Gemini API Key/credential'"'"') -- ./scripts/gemini-review.sh' >&2
  exit 1
fi

# The key is written into a double-quoted curl config value, where exactly two
# characters are special (backslash escapes, double quote terminates) and
# whitespace/newlines would truncate or corrupt the header. Reject those up
# front rather than hand-escaping them: Gemini API keys never contain them, and
# escaping a backslash through bash parameter substitution is a portability trap.
case "$GEMINI_API_KEY" in
  *[[:space:]]*)
    echo "Error: GEMINI_API_KEY contains whitespace — check the 1Password field for a stray newline." >&2
    exit 1 ;;
  *\\*|*'"'*)
    echo 'Error: GEMINI_API_KEY contains a backslash or double quote — not a valid Gemini API key.' >&2
    exit 1 ;;
esac

# Validate reviewer
case "$REVIEWER" in
  swe|security|devrel) ;;
  *) echo "Error: Unknown reviewer '$REVIEWER'. Must be: swe, security, devrel" >&2; exit 1 ;;
esac

# Validate model. Deliberately open: a closed allow-list here would reject every
# future model and force a code edit. Let the API be the authority on names.
case "$MODEL" in
  */*|"")
    echo "Error: invalid model name '$MODEL'" >&2; exit 1 ;;
  gemini-*) ;;
  *)
    echo "Warning: '$MODEL' is not a gemini-* model name; passing it to the API anyway." >&2 ;;
esac

# Validate output token budget
case "$MAX_OUTPUT_TOKENS" in
  ''|*[!0-9]*)
    echo "Error: GEMINI_MAX_OUTPUT_TOKENS must be a positive integer (got '$MAX_OUTPUT_TOKENS')" >&2
    exit 1 ;;
esac

# Bundle files into context string
bundle_files() {
  local files=(
    "skills/1password/SKILL.md"
    ".claude-plugin/plugin.json"
    "README.md"
    ".gitignore"
    "scripts/convert.sh"
    "integrations/gemini-cli/skills/1password/SKILL.md"
    "integrations/cursor/.cursor/rules/1password.mdc"
    "integrations/aider/CONVENTIONS.md"
    "integrations/windsurf/.windsurfrules"
  )
  local bundle="" f path missing=0
  for f in "${files[@]}"; do
    path="$REPO_ROOT/$f"
    # A missing file is a hard error: a "(file not found)" placeholder invites the
    # reviewer to render a verdict on a file it was never sent.
    if [[ ! -f "$path" ]]; then
      echo "Error: review bundle file missing: $f" >&2
      missing=$((missing + 1))
      continue
    fi
    bundle+="### File: $f"$'\n'
    bundle+="$(cat "$path")"$'\n\n'
  done
  if [[ "$missing" -gt 0 ]]; then
    echo "Error: $missing bundle file(s) missing — aborting rather than shipping an incomplete review bundle." >&2
    return 1
  fi
  printf '%s\n' "$bundle"
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

# Call Gemini API; echoes the raw JSON response. Fails closed on a transport
# error, a non-2xx status, or an API-level error object.
call_gemini_raw() {
  local prompt="$1"
  local body_file="$TMP_DIR/request.json"
  local cfg_file="$TMP_DIR/curl.cfg"

  jq -n --arg text "$prompt" --argjson max "$MAX_OUTPUT_TOKENS" '{
    contents: [{parts: [{text: $text}]}],
    generationConfig: {
      temperature: 0.3,
      maxOutputTokens: $max
    }
  }' > "$body_file"

  # The API key goes in a curl config file, never in argv and never in the URL:
  # argv is readable by any local process via ps, and a query parameter is
  # additionally recorded by every proxy and access log along the way.
  # Double-quoted config value; the key was validated at startup to contain no
  # backslash, double quote, or whitespace, so no escaping is needed here.
  printf 'header = "x-goog-api-key: %s"\n' "$GEMINI_API_KEY" > "$cfg_file"

  local raw http_code
  if ! raw="$(curl --config "$cfg_file" \
      --silent --show-error \
      --request POST \
      --url "${API_BASE}/models/${MODEL}:generateContent" \
      --header "Content-Type: application/json" \
      --data-binary "@$body_file" \
      --write-out '\n%{http_code}')"; then
    echo "Error: Gemini API request failed (curl transport error)" >&2
    return 1
  fi

  http_code="${raw##*$'\n'}"
  raw="${raw%$'\n'*}"

  case "$http_code" in
    2[0-9][0-9]) ;;
    *)
      echo "Error: Gemini API returned HTTP $http_code for model '$MODEL'" >&2
      printf '%s\n' "$raw" | jq -r '.error.message // .' >&2 || printf '%s\n' "$raw" >&2
      return 1 ;;
  esac

  printf '%s\n' "$raw"
}

# Extract text from Gemini response JSON (joins all parts; empty if none)
extract_text() {
  printf '%s' "$1" | jq -r '[.candidates[0].content.parts[]? | .text // empty] | join("")'
}

# Extract the candidate finish reason ("MISSING" if the response has none)
extract_finish_reason() {
  printf '%s' "$1" | jq -r '.candidates[0].finishReason // "MISSING"'
}

# Extract token counts
extract_tokens() {
  local response="$1"
  local input_tokens output_tokens
  input_tokens=$(echo "$response" | jq -r '.usageMetadata.promptTokenCount // 0')
  output_tokens=$(echo "$response" | jq -r '.usageMetadata.candidatesTokenCount // 0')
  echo "$input_tokens $output_tokens"
}

# Estimate cost based on model and token counts.
# Echoes a dollar figure, or the literal string "unknown" when no rate is on
# file for the model — a wrong number is worse than an admitted gap.
estimate_cost() {
  local model="$1"
  local input_tokens="$2"
  local output_tokens="$3"

  # Pricing per 1M tokens. Source: $PRICING_URL, last verified $PRICING_VERIFIED.
  # These go stale; GEMINI_PRICE_IN / GEMINI_PRICE_OUT override without a code edit.
  local input_rate output_rate
  if [[ -n "${GEMINI_PRICE_IN:-}" && -n "${GEMINI_PRICE_OUT:-}" ]]; then
    input_rate="$GEMINI_PRICE_IN"; output_rate="$GEMINI_PRICE_OUT"
  else
    case "$model" in
      gemini-2.5-pro)
        # Two tiers, split at 200K input tokens.
        if [[ "$input_tokens" -gt 200000 ]]; then
          input_rate="2.50"; output_rate="15.00"
        else
          input_rate="1.25"; output_rate="10.00"
        fi ;;
      gemini-2.5-flash) input_rate="0.30"; output_rate="2.50" ;;
      *) echo "unknown"; return 0 ;;
    esac
  fi

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
  printf '%s\n' "${C_CYAN}${C_BOLD}═══════════════════════════════════════════════════${C_RESET}"
  printf '%s\n' "${C_CYAN}${C_BOLD}  Gemini TR Review — ${reviewer} (${MODEL})${C_RESET}"
  printf '%s\n' "${C_CYAN}  ${timestamp}${C_RESET}"
  printf '%s\n' "${C_CYAN}${C_BOLD}═══════════════════════════════════════════════════${C_RESET}"
  echo ""
}

# Print footer with token/cost info
print_footer() {
  local input_tokens="$1"
  local output_tokens="$2"
  local cost="$3"
  echo ""
  printf '%s\n' "${C_YELLOW}───────────────────────────────────────────────────${C_RESET}"
  printf '%s\n' "${C_YELLOW}  Tokens: $(fmt_tokens "$input_tokens") in / $(fmt_tokens "$output_tokens") out${C_RESET}"
  if [[ "$cost" == "unknown" ]]; then
    printf '%s\n' "${C_YELLOW}  Cost: unknown — no rate on file for ${MODEL}${C_RESET}"
    printf '%s\n' "${C_YELLOW}         set GEMINI_PRICE_IN / GEMINI_PRICE_OUT (see ${PRICING_URL})${C_RESET}"
  else
    printf '%s\n' "${C_YELLOW}  Cost: ~\$${cost} (estimate; ${PRICE_NOTE})${C_RESET}"
  fi
  printf '%s\n' "${C_YELLOW}───────────────────────────────────────────────────${C_RESET}"
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

  printf '%s\n\n' "${C_GREEN}Calling Gemini API (model: ${MODEL})...${C_RESET}"

  local raw_response
  raw_response="$(call_gemini_raw "$prompt")"

  local review_text
  review_text="$(extract_text "$raw_response")"

  # Print review content (whatever arrived, even if truncated)
  printf '%s\n' "$review_text"

  # A truncated or filtered review must not look like a successful one.
  local finish_reason
  finish_reason="$(extract_finish_reason "$raw_response")"
  if [[ "$finish_reason" != "STOP" ]]; then
    printf '%s\n' "${C_RED}Error: review incomplete — finishReason=${finish_reason}${C_RESET}" >&2
    if [[ "$finish_reason" == "MAX_TOKENS" ]]; then
      echo "  Thinking tokens count against the output budget. Retry with a larger one:" >&2
      echo "  GEMINI_MAX_OUTPUT_TOKENS=$((MAX_OUTPUT_TOKENS * 2)) $0 --reviewer $reviewer" >&2
    fi
    exit 1
  fi
  if [[ -z "$review_text" ]]; then
    printf '%s\n' "${C_RED}Error: Gemini returned no review text${C_RESET}" >&2
    exit 1
  fi

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
  # Parallel indexed arrays keyed by loop position — bash 3.2 has no associative
  # arrays, and `declare -A` is a hard error there.
  local summary_in summary_out summary_costs
  summary_in=(); summary_out=(); summary_costs=()

  local r i
  for r in "${reviewers[@]}"; do
    REVIEWER="$r"
    run_reviewer "$r"
    summary_in+=("$_LAST_INPUT_TOKENS")
    summary_out+=("$_LAST_OUTPUT_TOKENS")
    summary_costs+=("$_LAST_COST")
  done

  # Compute total cost, skipping any reviewer whose model has no rate on file
  # Accumulate at full precision; rounding each addition would drift the total.
  local total_cost="0.000000" unpriced=0 c
  for c in "${summary_costs[@]}"; do
    if [[ "$c" == "unknown" ]]; then
      unpriced=$((unpriced + 1))
      continue
    fi
    total_cost="$(awk -v a="$total_cost" -v b="$c" 'BEGIN { printf "%.6f\n", a + b }')"
  done
  total_cost="$(awk -v a="$total_cost" 'BEGIN { printf "%.4f\n", a }')"

  echo ""
  printf '%s\n' "${C_BOLD}╔═══════════════════════════════════════════════════╗${C_RESET}"
  printf '%s\n' "${C_BOLD}║           Gemini TR Summary                       ║${C_RESET}"
  printf '%s\n' "${C_BOLD}╚═══════════════════════════════════════════════════╝${C_RESET}"
  echo ""
  printf "  %-10s  %-18s  %-13s  %s\n" "Reviewer" "Model" "Tokens" "Cost"
  printf "  %-10s  %-18s  %-13s  %s\n" "---------" "----------------" "-----------" "------"
  local tok_str cost_str
  i=0
  while [[ "$i" -lt "${#reviewers[@]}" ]]; do
    tok_str="$(fmt_tokens "${summary_in[$i]}")/$(fmt_tokens "${summary_out[$i]}")"
    if [[ "${summary_costs[$i]}" == "unknown" ]]; then
      cost_str="unknown"
    else
      cost_str="\$${summary_costs[$i]}"
    fi
    printf "  %-10s  %-18s  %-13s  %s\n" \
      "${reviewers[$i]}" "$MODEL" "$tok_str" "$cost_str"
    i=$((i + 1))
  done
  echo ""
  printf "  %47s \$%s\n" "Total:" "$total_cost"
  if [[ "$unpriced" -gt 0 ]]; then
    printf "  %47s %s\n" "" "(excludes $unpriced review(s) with no rate on file)"
  fi
  echo ""
}

# Main
if [[ "$RUN_ALL" == "true" ]]; then
  run_all
else
  run_reviewer "$REVIEWER"
fi
