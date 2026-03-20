#!/usr/bin/env bash
# test-structural.sh — Validate skill structure and required content
#
# Tests that SKILL.md, plugin.json, and the decision router are correctly formed.
# Run from repo root: ./tests/test-structural.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILL_MD="$REPO_ROOT/skills/1password/SKILL.md"
PLUGIN_JSON="$REPO_ROOT/plugin.json"

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

printf "\n${C_BOLD}${C_CYAN}=== Structural Tests ===${C_RESET}\n\n"

# --- SKILL.md existence and non-empty ---
printf "${C_BOLD}SKILL.md basics${C_RESET}\n"

if [[ -f "$SKILL_MD" ]]; then
  pass "SKILL.md exists"
else
  fail "SKILL.md exists at skills/1password/SKILL.md"
fi

if [[ -s "$SKILL_MD" ]]; then
  pass "SKILL.md is non-empty"
else
  fail "SKILL.md is non-empty"
fi

# --- YAML frontmatter fields ---
printf "\n${C_BOLD}YAML frontmatter${C_RESET}\n"

# Extract content between first pair of ---
frontmatter=$(awk '/^---/{c++; if(c>2) exit} c==1 && !/^---/{print}' "$SKILL_MD")

if echo "$frontmatter" | grep -qE '^name:'; then
  pass "frontmatter has 'name' field"
else
  fail "frontmatter has 'name' field"
fi

if echo "$frontmatter" | grep -qE '^description:'; then
  pass "frontmatter has 'description' field"
else
  fail "frontmatter has 'description' field"
fi

# --- plugin.json ---
printf "\n${C_BOLD}plugin.json${C_RESET}\n"

if [[ -f "$PLUGIN_JSON" ]]; then
  pass "plugin.json exists"
else
  fail "plugin.json exists"
fi

if python3 -c "import json, sys; json.load(open('$PLUGIN_JSON'))" 2>/dev/null; then
  pass "plugin.json is valid JSON"
else
  fail "plugin.json is valid JSON"
fi

# plugin.json skill path matches actual file
skill_path=$(python3 -c "import json; d=json.load(open('$PLUGIN_JSON')); print(d['skills'][0]['path'])" 2>/dev/null || true)
if [[ -n "$skill_path" && -f "$REPO_ROOT/$skill_path" ]]; then
  pass "plugin.json skill path points to an existing file ($skill_path)"
else
  fail "plugin.json skill path points to an existing file (got: '$skill_path')"
fi

# plugin.json skill path should point to a SKILL.md file
if [[ "$(basename "$REPO_ROOT/$skill_path")" == "SKILL.md" ]]; then
  pass "plugin.json skill path points to a SKILL.md file"
else
  fail "plugin.json skill path does not point to a SKILL.md file (points to $(basename "$skill_path"))"
fi

# plugin.json version follows semver
version=$(python3 -c "import json; d=json.load(open('$PLUGIN_JSON')); print(d.get('version',''))" 2>/dev/null || true)
if echo "$version" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  pass "plugin.json version follows semver ($version)"
else
  fail "plugin.json version follows semver (got: '$version')"
fi

# --- Decision Router ---
printf "\n${C_BOLD}Decision Router${C_RESET}\n"

if grep -q "You're seeing\.\.\." "$SKILL_MD"; then
  pass "Decision router table exists (has 'You're seeing...' header)"
else
  fail "Decision router table exists (has 'You're seeing...' header)"
fi

# Extract section names referenced in the router table (→ Section Name)
# Only look at the Decision Router table — stop at the first ## heading after it.
# Router rows look like: | ... | → Section Name |
router_section=$(awk '/^# 1Password CLI — Decision Router/,/^## /' "$SKILL_MD" | head -n -1)
router_targets=$(echo "$router_section" | grep -E '\| → [A-Za-z]' | grep -oE '→ [A-Za-z][A-Za-z ]+' | sed 's/→ //' | sed 's/[[:space:]]*$//' | sort -u)

printf "\n${C_BOLD}Decision Router → Section mapping${C_RESET}\n"
if [[ -z "$router_section" ]]; then
  fail "Decision router section heading not found — expected '# 1Password CLI — Decision Router'"
else
  while IFS= read -r target; do
    # Skip "Error Catalog" as it's a special case checked separately
    [[ -z "$target" ]] && continue
    # Build regex for ## heading
    if grep -qE "^## $target" "$SKILL_MD"; then
      pass "Section '## $target' exists (referenced in router)"
    else
      fail "Section '## $target' exists (referenced in router)"
    fi
  done <<< "$router_targets"
fi

# --- Required sections ---
printf "\n${C_BOLD}Required sections${C_RESET}\n"

for section in "Error Catalog" "Security Rules"; do
  if grep -qE "^## $section" "$SKILL_MD"; then
    pass "Section '## $section' exists"
  else
    fail "Section '## $section' exists"
  fi
done

# --- Supporting files ---
printf "\n${C_BOLD}Supporting files${C_RESET}\n"

for f in "README.md" "LICENSE" ".gitignore"; do
  if [[ -f "$REPO_ROOT/$f" ]]; then
    pass "$f exists"
  else
    fail "$f exists"
  fi
done

# --- Summary ---
total=$((PASSES + FAILS))
printf "\n${C_BOLD}Structural:${C_RESET} $PASSES/$total passed"
if [[ $FAILS -eq 0 ]]; then
  printf " ${C_GREEN}(all passed)${C_RESET}"
else
  printf " ${C_RED}($FAILS failed)${C_RESET}"
fi
printf "\n"

exit $FAILS
