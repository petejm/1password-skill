#!/usr/bin/env bash
# test-structural.sh — Validate skill structure and required content
#
# Tests that SKILL.md, plugin.json, and the decision router are correctly formed.
# Run from repo root: ./tests/test-structural.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILL_MD="$REPO_ROOT/skills/1password/SKILL.md"
# plugin.json may live at repo root (legacy) or .claude-plugin/ (current convention,
# per Claude Code's --plugin-dir auto-discovery). Prefer .claude-plugin/ if present.
if [[ -f "$REPO_ROOT/.claude-plugin/plugin.json" ]]; then
  PLUGIN_JSON="$REPO_ROOT/.claude-plugin/plugin.json"
else
  PLUGIN_JSON="$REPO_ROOT/plugin.json"
fi

PASSES=0
FAILS=0

# Floor on the number of assertions this suite must execute. run-all.sh only scrapes
# "N/M passed" and cannot tell 28/28 from 3/3, so a block that quietly stops running
# shrinks the denominator invisibly.
#
# One block here is data-driven: the router-target loop runs once per parsed router row.
# The floor is therefore (fixed assertions) + ROUTER_MIN_TARGETS, the guaranteed
# minimum, so adding or removing router ROWS does not require touching this number --
# ROUTER_MIN_TARGETS is what guards a collapsed parse. Deleting any fixed assertion
# still trips it. run-all.sh greps this exact assignment out of the file, so keep it on
# one line with no spaces.
EXPECTED_MIN_ASSERTIONS=25

# Color output (respects NO_COLOR)
if [[ -z "${NO_COLOR:-}" && "${TERM:-dumb}" != "dumb" && -t 1 ]]; then
  C_GREEN="\033[0;32m"; C_RED="\033[0;31m"; C_CYAN="\033[0;36m"; C_BOLD="\033[1m"; C_RESET="\033[0m"
else
  C_GREEN="" C_RED="" C_CYAN="" C_BOLD="" C_RESET=""
fi

pass() { PASSES=$((PASSES + 1)); printf "  ${C_GREEN}PASS${C_RESET} %s\n" "$1"; }
fail() { FAILS=$((FAILS + 1));  printf "  ${C_RED}FAIL${C_RESET} %s\n" "$1"; }

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
  printf "\n${C_BOLD}Structural:${C_RESET} $PASSES/$total passed"
  if [[ $FAILS -eq 0 ]]; then
    printf " ${C_GREEN}(all passed)${C_RESET}"
  else
    printf " ${C_RED}($FAILS failed)${C_RESET}"
  fi
  printf "\n"
  # Normalize to a boolean status: `exit $FAILS` wraps mod 256 (exactly 256 failures
  # would exit 0) and conflates test failures with script errors. run-all.sh parses
  # the real counts from the 'N/M passed' line above, so nothing needs the number.
  if [[ $FAILS -eq 0 ]]; then exit 0; else exit 1; fi
}

printf "\n${C_BOLD}${C_CYAN}=== Structural Tests ===${C_RESET}\n\n"

# --- Dependency gate ---
# python3 is required for the JSON and YAML assertions below. Without this gate a
# missing interpreter reads as a content defect instead of a tooling failure.
printf "${C_BOLD}Prerequisites${C_RESET}\n"
if command -v python3 >/dev/null 2>&1; then
  pass "python3 is available"
else
  fail "python3 not found — JSON and frontmatter assertions cannot run"
  summary_and_exit
fi

HAVE_PYYAML=0
if python3 -c "import yaml" >/dev/null 2>&1; then
  HAVE_PYYAML=1
fi
printf "\n"

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

# grep only proves a line starts with 'description:'; it cannot tell valid YAML from
# a string with a broken escape. Feed the block to a real parser.
if [[ $HAVE_PYYAML -eq 1 ]]; then
  if printf '%s\n' "$frontmatter" | python3 -c "
import sys, yaml
d = yaml.safe_load(sys.stdin.read())
sys.exit(0 if isinstance(d, dict) else 1)
" 2>/dev/null; then
    pass "SKILL.md frontmatter parses as a YAML mapping"
  else
    fail "SKILL.md frontmatter is not parseable YAML (or is not a mapping)"
  fi
else
  fail "PyYAML not installed — cannot validate frontmatter YAML (pip install pyyaml)"
fi

# --- plugin.json ---
printf "\n${C_BOLD}plugin.json${C_RESET}\n"

if [[ -f "$PLUGIN_JSON" ]]; then
  pass "plugin.json exists"
else
  fail "plugin.json exists"
fi

PLUGIN_JSON_VALID=0
if python3 -c "import json, sys; json.load(open(sys.argv[1]))" "$PLUGIN_JSON" 2>/dev/null; then
  PLUGIN_JSON_VALID=1
  pass "plugin.json is valid JSON"
else
  fail "plugin.json is valid JSON"
fi

# Skills are AUTO-DISCOVERED from skills/<name>/SKILL.md. Commit 21c0995 removed the
# plugin.json `skills` array because it is not part of the plugin schema; these
# assertions replace the ones that read d['skills'][0]['path'].
if [[ -f "$REPO_ROOT/skills/1password/SKILL.md" ]]; then
  pass "skills/1password/SKILL.md exists (auto-discovery path)"
else
  fail "skills/1password/SKILL.md exists (auto-discovery path)"
fi

if [[ $PLUGIN_JSON_VALID -eq 1 ]]; then
  # Negative assertion: the invalid schema key must not come back.
  skills_key=$(python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
print('present' if 'skills' in d else 'absent')
" "$PLUGIN_JSON" 2>/dev/null)
  if [[ "$skills_key" == "absent" ]]; then
    pass "plugin.json declares no 'skills' array (skills are auto-discovered)"
  else
    fail "plugin.json must not declare a 'skills' array (got: '$skills_key') — invalid for the plugin schema, removed in 21c0995"
  fi

  author_shape=$(python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
a = d.get('author')
ok = (isinstance(a, dict)
      and isinstance(a.get('name'), str) and a.get('name')
      and isinstance(a.get('url'), str) and a.get('url'))
print('ok' if ok else 'bad')
" "$PLUGIN_JSON" 2>/dev/null)
  if [[ "$author_shape" == "ok" ]]; then
    pass "plugin.json 'author' is an object with non-empty name and url"
  else
    fail "plugin.json 'author' must be an object with non-empty 'name' and 'url' (got: '$author_shape')"
  fi

  # plugin.json version follows semver
  version=$(python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
print(d.get('version', ''))
" "$PLUGIN_JSON" 2>/dev/null)
  if echo "$version" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    pass "plugin.json version follows semver ($version)"
  else
    fail "plugin.json version follows semver (got: '$version')"
  fi
else
  fail "plugin.json 'skills' key check skipped — plugin.json is not valid JSON"
  fail "plugin.json 'author' shape check skipped — plugin.json is not valid JSON"
  fail "plugin.json version check skipped — plugin.json is not valid JSON"
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
# Awk's range pattern includes the closing `## ` line; strip it. Use `sed '$d'`
# instead of `head -n -1` because BSD head (macOS) doesn't support negative counts.
# Character class widened from [A-Za-z ] so section names containing digits or
# hyphens are not silently dropped from the parse.
router_section=$(awk '/^# 1Password CLI [—-] Decision Router/,/^## /' "$SKILL_MD" | sed '$d')
router_targets=$(echo "$router_section" | grep -E '\| → [A-Za-z0-9]' | grep -oE '→ [A-Za-z0-9][A-Za-z0-9 -]*' | sed 's/→ //' | sed 's/[[:space:]]*$//' | sort -u)
router_target_count=$(printf '%s\n' "$router_targets" | grep -c '^.' || true)
[[ "$router_target_count" =~ ^[0-9]+$ ]] || router_target_count=0

# Minimum number of router rows the table is expected to map to sections. A parse that
# yields 1 of 7 is a format change, not a passing test — without this floor the loop
# below would simply run fewer assertions and report success.
ROUTER_MIN_TARGETS=5

printf "\n${C_BOLD}Decision Router → Section mapping${C_RESET}\n"
if [[ -z "$router_section" ]]; then
  fail "Decision router section heading not found — expected '# 1Password CLI [—-] Decision Router'"
elif [[ "$router_target_count" -eq 0 ]]; then
  fail "Decision router table parsed to zero targets — row format changed (expected rows like '| trigger | → Section Name |')"
else
  if [[ "$router_target_count" -ge $ROUTER_MIN_TARGETS ]]; then
    pass "Decision router table parsed $router_target_count section targets (>= $ROUTER_MIN_TARGETS)"
  else
    fail "Decision router table parsed only $router_target_count targets (expected >= $ROUTER_MIN_TARGETS) — partial parse, row format likely changed"
  fi

  while IFS= read -r target; do
    [[ -z "$target" ]] && continue
    # Anchor BOTH ends of the heading. An unanchored `^## $target` is a prefix match:
    # renaming `## SSH Agent` to `## SSH Agent Stuff` left this assertion GREEN even
    # though the router row `→ SSH Agent` now points at no section. Only a rename that
    # also changed the prefix could turn it red, so the check was strictly weaker than
    # the guarantee it advertises ("the section this row points at exists").
    # `[[:space:]]*$` allows trailing whitespace and nothing else. Targets are built
    # from the [A-Za-z0-9][A-Za-z0-9 -]* class above, so they carry no ERE metacharacter
    # ('-' is literal outside a bracket expression).
    if grep -qE "^## ${target}[[:space:]]*$" "$SKILL_MD"; then
      pass "Section '## $target' exists (referenced in router)"
    else
      fail "Section '## $target' exists (referenced in router)"
    fi
  done <<< "$router_targets"
fi

# --- Required sections ---
printf "\n${C_BOLD}Required sections${C_RESET}\n"

# Same whole-heading anchor as the router loop above: an unanchored prefix match would
# accept `## Error Catalog Notes` as satisfying "## Error Catalog exists".
for section in "Error Catalog" "Security Rules"; do
  if grep -qE "^## ${section}[[:space:]]*$" "$SKILL_MD"; then
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
summary_and_exit
