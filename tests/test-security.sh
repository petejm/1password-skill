#!/usr/bin/env bash
# test-security.sh — Scan published files for secrets, real hostnames, and sensitive data
#
# These are negative tests: things that must NOT be present in any committed file.
# Run from repo root: ./tests/test-security.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

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

printf "\n${C_BOLD}${C_CYAN}=== Security Tests ===${C_RESET}\n\n"

# Collect all tracked files that are part of the published skill content.
# Exclude the tests/ directory — test scripts necessarily reference the patterns
# they scan for and would cause false positives.
tracked_files=$(git -C "$REPO_ROOT" ls-files --cached --others --exclude-standard 2>/dev/null | \
  grep -v '^tests/' | \
  xargs -I{} sh -c 'test -f "'"$REPO_ROOT"'/{}" && echo "{}"' 2>/dev/null || true)

# Helper: search all tracked text files for a pattern
# Returns match lines or empty
scan_files() {
  local pattern="$1"
  local exclude_pattern="${2:-__NO_EXCLUDE__}"
  local matches=""
  while IFS= read -r rel_path; do
    [[ -z "$rel_path" ]] && continue
    local abs="$REPO_ROOT/$rel_path"
    [[ -f "$abs" ]] || continue
    # Skip binary files
    file "$abs" 2>/dev/null | grep -q "text" || continue
    local found
    found=$(grep -nE "$pattern" "$abs" 2>/dev/null || true)
    if [[ -n "$found" && "$exclude_pattern" != "__NO_EXCLUDE__" ]]; then
      found=$(echo "$found" | grep -vE "$exclude_pattern" || true)
    fi
    if [[ -n "$found" ]]; then
      matches+="$rel_path: $found"$'\n'
    fi
  done <<< "$tracked_files"
  echo "$matches"
}

# --- IP addresses ---
printf "${C_BOLD}No real IP addresses${C_RESET}\n"

# Match IPv4 pattern, exclude localhost, link-local, documentation ranges, and placeholder examples
ip_matches=$(scan_files \
  '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' \
  '(127\.0\.0\.1|0\.0\.0\.0|255\.255\.255|192\.168\.[0-9]+\.x|10\.[0-9]+\.x|1\.2\.3\.4|x\.x\.x\.x|example\.com|version)')

if [[ -z "$ip_matches" ]]; then
  pass "No real IP addresses found"
else
  fail "No real IP addresses found (matches below)"
  echo "$ip_matches" | while IFS= read -r line; do [[ -n "$line" ]] && printf "       %s\n" "$line"; done
fi

# --- Real hostnames ---
printf "\n${C_BOLD}No real hostnames${C_RESET}\n"

for hostname in "gondolin" "tailf4273"; do
  matches=$(scan_files "$hostname" || true)
  if [[ -z "$matches" ]]; then
    pass "No reference to hostname '$hostname'"
  else
    fail "No reference to hostname '$hostname'"
    echo "$matches" | while IFS= read -r line; do [[ -n "$line" ]] && printf "       %s\n" "$line"; done
  fi
done

# Tailnet names (tailXXXX pattern)
tailnet_matches=$(scan_files 'tail[a-f0-9]{4,}' || true)
if [[ -z "$tailnet_matches" ]]; then
  pass "No tailnet hostnames found (tailXXXX pattern)"
else
  fail "No tailnet hostnames found (tailXXXX pattern)"
  echo "$tailnet_matches" | while IFS= read -r line; do [[ -n "$line" ]] && printf "       %s\n" "$line"; done
fi

# --- 1Password item IDs (26-char alphanumeric) ---
printf "\n${C_BOLD}No 1Password item IDs${C_RESET}\n"

# 1P item IDs are exactly 26 lowercase alphanumeric chars
op_id_matches=$(scan_files '\b[a-z0-9]{26}\b' || true)
if [[ -z "$op_id_matches" ]]; then
  pass "No 1Password item IDs (26-char alphanumeric) found"
else
  fail "No 1Password item IDs (26-char alphanumeric) found"
  echo "$op_id_matches" | while IFS= read -r line; do [[ -n "$line" ]] && printf "       %s\n" "$line"; done
fi

# --- Real usernames ---
printf "\n${C_BOLD}No real usernames in skill content${C_RESET}\n"

# pmcdade and petejm should only appear in LICENSE copyright and README git clone URL
for username in "pmcdade" "petejm"; do
  all_matches=$(scan_files "$username" || true)
  # Filter out expected occurrences: LICENSE copyright line, README clone URL
  unexpected=$(echo "$all_matches" | \
    grep -v "LICENSE" | \
    grep -v "git clone.*github.com" | \
    grep -v "github.com/$username" || true)
  if [[ -z "$unexpected" ]]; then
    pass "Username '$username' only in expected locations (LICENSE, README clone URL)"
  else
    fail "Username '$username' found in unexpected locations"
    echo "$unexpected" | while IFS= read -r line; do [[ -n "$line" ]] && printf "       %s\n" "$line"; done
  fi
done

# --- API tokens / key prefixes ---
printf "\n${C_BOLD}No API tokens or key material${C_RESET}\n"

token_patterns=(
  'sk-[A-Za-z0-9]{20,}'
  'ghp_[A-Za-z0-9]{36}'
  'ghs_[A-Za-z0-9]{36}'
  'AKIA[0-9A-Z]{16}'
  'xoxb-[0-9]+-[A-Za-z0-9]+'
)

for pattern in "${token_patterns[@]}"; do
  matches=$(scan_files "$pattern" || true)
  if [[ -z "$matches" ]]; then
    pass "No token pattern: $pattern"
  else
    fail "No token pattern: $pattern"
    echo "$matches" | while IFS= read -r line; do [[ -n "$line" ]] && printf "       %s\n" "$line"; done
  fi
done

# --- Hardcoded home directory paths ---
printf "\n${C_BOLD}No hardcoded home directory paths${C_RESET}\n"

# /home/username/ or /Users/username/ with a real username (not example)
home_matches=$(scan_files '/home/[a-z][a-z0-9_-]+/' \
  '(/home/username|example\.com|\$HOME|~/)' || true)
if [[ -z "$home_matches" ]]; then
  pass "No hardcoded /home/username/ paths"
else
  fail "No hardcoded /home/username/ paths"
  echo "$home_matches" | while IFS= read -r line; do [[ -n "$line" ]] && printf "       %s\n" "$line"; done
fi

users_home_matches=$(scan_files '/Users/[A-Za-z][A-Za-z0-9_-]+/' \
  '(/Users/username|example\.com|\$HOME|~/)' || true)
if [[ -z "$users_home_matches" ]]; then
  pass "No hardcoded /Users/username/ paths"
else
  fail "No hardcoded /Users/username/ paths"
  echo "$users_home_matches" | while IFS= read -r line; do [[ -n "$line" ]] && printf "       %s\n" "$line"; done
fi

# --- .env files committed ---
printf "\n${C_BOLD}No .env files committed${C_RESET}\n"

env_files=$(git -C "$REPO_ROOT" ls-files --cached 2>/dev/null | grep -E '(^|/)\.env$' || true)
if [[ -z "$env_files" ]]; then
  pass "No .env files in git index"
else
  fail "No .env files in git index (found: $env_files)"
fi

# --- environment.md must not be committed ---
printf "\n${C_BOLD}environment.md not committed${C_RESET}\n"

env_md=$(git -C "$REPO_ROOT" ls-files --cached 2>/dev/null | grep 'environment\.md' || true)
if [[ -z "$env_md" ]]; then
  pass "environment.md is not tracked by git"
else
  fail "environment.md is not tracked by git (found in index: $env_md)"
fi

# environment.md should not exist in the repo at all
if [[ ! -f "$REPO_ROOT/skills/1password/environment.md" ]]; then
  pass "environment.md does not exist at skills/1password/environment.md"
else
  fail "environment.md must not exist in repo (it's gitignored for a reason)"
fi

# --- op:// references use only placeholder names ---
printf "\n${C_BOLD}op:// references use placeholder names only${C_RESET}\n"

# Allowed: VaultName, ItemName, Vault, Item, Production, Private, ExternalAPI, PostgreSQL,
#          GitHub, fieldname, credential, field, username, password, key, connection-string, token
# Disallowed: real vault/item names that look like personal infrastructure
op_refs=$(scan_files 'op://[A-Za-z]' || true)
# Check if any op:// reference uses what looks like a real vault name.
# Allowed: VaultName, Vault, Production, Private, ExternalAPI, Item, GitHub, PostgreSQL, Field (PascalCase placeholders)
# Also allow: op://vault/item/field (the generic all-lowercase documentation placeholder)
suspicious_op=$(echo "$op_refs" | \
  grep -E 'op://[A-Za-z]' | \
  grep -vE 'op://(VaultName|Vault|Production|Private|ExternalAPI|ItemName|Item|GitHub|PostgreSQL|Field)/' | \
  grep -vE 'op://vault/item/field' || true)
if [[ -z "$suspicious_op" ]]; then
  pass "op:// references use placeholder vault/item names"
else
  fail "op:// references may contain real vault/item names (review carefully)"
  echo "$suspicious_op" | while IFS= read -r line; do [[ -n "$line" ]] && printf "       %s\n" "$line"; done
fi

# --- SSH private key material ---
printf "\n${C_BOLD}No SSH private key material${C_RESET}\n"

ssh_key_matches=$(scan_files 'BEGIN (RSA|EC|OPENSSH|DSA) PRIVATE KEY' || true)
if [[ -z "$ssh_key_matches" ]]; then
  pass "No SSH private key material found"
else
  fail "No SSH private key material found"
  echo "$ssh_key_matches" | while IFS= read -r line; do [[ -n "$line" ]] && printf "       %s\n" "$line"; done
fi

# --- .gitignore blocks sensitive files ---
printf "\n${C_BOLD}.gitignore blocks sensitive files${C_RESET}\n"

gitignore="$REPO_ROOT/.gitignore"
if [[ -f "$gitignore" ]]; then
  if grep -qE 'environment\.md' "$gitignore"; then
    pass ".gitignore blocks environment.md (skills/*/environment.md pattern)"
  else
    fail ".gitignore should block environment.md (skills/*/environment.md)"
  fi

  if grep -qE '\*\.env' "$gitignore"; then
    pass ".gitignore blocks *.env files"
  else
    fail ".gitignore should block *.env files"
  fi
else
  fail ".gitignore exists (needed for security)"
fi

# --- Summary ---
total=$((PASSES + FAILS))
printf "\n${C_BOLD}Security:${C_RESET} $PASSES/$total passed"
if [[ $FAILS -eq 0 ]]; then
  printf " ${C_GREEN}(all passed)${C_RESET}"
else
  printf " ${C_RED}($FAILS failed)${C_RESET}"
fi
printf "\n"

exit $FAILS
