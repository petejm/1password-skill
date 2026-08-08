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

# Floor on the number of assertions this suite must execute. run-all.sh only scrapes
# "N/M passed" and cannot tell 24/24 from 3/3, so a block that quietly stops running
# shrinks the denominator invisibly. Keep this EQUAL to the number of assertions the
# suite actually runs: a floor with slack in it is not a floor. run-all.sh greps this
# exact assignment out of the file, so keep it on one line with no spaces.
EXPECTED_MIN_ASSERTIONS=26

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
  printf '\n%s' "${C_BOLD}Security:${C_RESET} $PASSES/$total passed"
  if [[ $FAILS -eq 0 ]]; then
    printf '%s' " ${C_GREEN}(all passed)${C_RESET}"
  else
    printf '%s' " ${C_RED}($FAILS failed)${C_RESET}"
  fi
  printf "\n"
  # Boolean status, not a mod-256 failure count. See test-structural.sh for rationale.
  if [[ $FAILS -eq 0 ]]; then exit 0; else exit 1; fi
}

printf '\n%s\n\n' "${C_BOLD}${C_CYAN}=== Security Tests ===${C_RESET}"

# Collect all tracked files that are part of the published skill content.
# Exclude the tests/ directory — test scripts necessarily reference the patterns
# they scan for and would cause false positives.
#
# This corpus is a PRECONDITION, not best-effort. Every failure mode of the old
# `... || true` pipeline (git absent, not a work tree, xargs failure) produced an
# empty list, and an empty list made every negative scan below report "clean". A
# secret scanner that silently disables itself is worse than no scanner.
printf '%s\n' "${C_BOLD}Scan corpus${C_RESET}"

git_ls_status=0
raw_files=$(git -C "$REPO_ROOT" ls-files --cached --others --exclude-standard 2>/dev/null) || git_ls_status=$?

if [[ $git_ls_status -ne 0 ]]; then
  fail "git ls-files failed (exit $git_ls_status) in $REPO_ROOT — cannot build the security scan corpus; refusing to report clean"
  summary_and_exit
fi

tracked_files=""
while IFS= read -r _rel; do
  [[ -z "$_rel" ]] && continue
  case "$_rel" in tests/*) continue ;; esac
  [[ -f "$REPO_ROOT/$_rel" ]] || continue
  tracked_files="${tracked_files}${_rel}"$'\n'
done <<< "$raw_files"

corpus_count=$(printf '%s' "$tracked_files" | grep -c '^.' || true)
[[ "$corpus_count" =~ ^[0-9]+$ ]] || corpus_count=0

if [[ "$corpus_count" -lt 1 ]]; then
  fail "security scan corpus is empty — git ls-files returned nothing scannable; refusing to report clean"
  summary_and_exit
fi
pass "Security scan corpus is non-empty ($corpus_count files)"

# Partition the corpus into scannable and unscannable ONCE, up front, and account for
# every file. The old code made this decision per-file inside scan_files with
# `file "$abs" | grep -q text || continue`: a single tracked file that `file` did not
# call "text" (anything containing a NUL byte is classified "data") was then scanned by
# NOTHING, silently, in a repo whose secret scan is a shipped guarantee. The canary
# below only ever proved that at least ONE file was read, so it cannot see a one-file
# skip -- and a one-file skip is the leaking case.
#
# `grep -Iq .` is POSIX-portable binary detection built into grep itself (BSD and GNU
# alike), so the skip decision is made by the same tool, on the same bytes, that does
# the searching. An empty file has no lines to match and is not binary; treat it as
# scannable (there is nothing in it to leak).
scannable_files=""
skipped_files=""
scannable_count=0
skipped_count=0
while IFS= read -r _rel; do
  [[ -z "$_rel" ]] && continue
  if [[ ! -s "$REPO_ROOT/$_rel" ]] || grep -Iq . "$REPO_ROOT/$_rel" 2>/dev/null; then
    scannable_files="${scannable_files}${_rel}"$'\n'
    scannable_count=$((scannable_count + 1))
  else
    skipped_files="${skipped_files}${_rel}"$'\n'
    skipped_count=$((skipped_count + 1))
  fi
done <<< "$tracked_files"

if [[ "$scannable_count" -eq "$corpus_count" ]]; then
  pass "All $corpus_count corpus files are scannable text (0 skipped)"
else
  fail "$skipped_count of $corpus_count corpus files are not scannable text and would be searched by nothing — the scans below do not cover them"
  printf '%s' "$skipped_files" | while IFS= read -r line; do [[ -n "$line" ]] && printf "       %s\n" "$line"; done
fi

# Helper: search every scannable file for a pattern.
# Returns match lines or empty.
scan_files() {
  local pattern="$1"
  local exclude_pattern="${2:-__NO_EXCLUDE__}"
  local matches=""
  while IFS= read -r rel_path; do
    [[ -z "$rel_path" ]] && continue
    local abs="$REPO_ROOT/$rel_path"
    [[ -f "$abs" ]] || continue
    local found
    found=$(grep -nE "$pattern" "$abs" 2>/dev/null || true)
    if [[ -n "$found" && "$exclude_pattern" != "__NO_EXCLUDE__" ]]; then
      found=$(echo "$found" | grep -vE "$exclude_pattern" || true)
    fi
    if [[ -n "$found" ]]; then
      matches+="$rel_path: $found"$'\n'
    fi
  done <<< "$scannable_files"
  echo "$matches"
}

# --- Scanner canary ---
# Every assertion below trusts an EMPTY result as "clean". Prove the scanner actually
# reads file contents first by searching for a string that is certain to be present.
# This is a floor, not a coverage proof: it shows at least ONE file was read. Coverage
# is what the scannable-vs-corpus count above asserts.
canary_hits=$(scan_files '1Password' || true)
if [[ -n "$canary_hits" ]]; then
  pass "Scanner canary: known string '1Password' found in the corpus (scanner is reading files)"
else
  fail "Scanner canary FAILED: '1Password' not found in any of $scannable_count scannable files — the scanner is reading nothing; every clean result below would be meaningless"
  summary_and_exit
fi

# --- IP addresses ---
printf '\n%s\n' "${C_BOLD}No real IP addresses${C_RESET}"

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
printf '\n%s\n' "${C_BOLD}No real hostnames${C_RESET}"

# Assembled from fragments so this file does not itself publish the names it
# exists to keep out of the repo. It previously did: both literals reached the
# public GitHub copy and this check could never see them, because scan_files
# skips tests/ — so the guard was blind to precisely one file, its own.
# The loop variable still holds the full name, so scanning behaviour is
# unchanged.
for hostname in "gondo""lin" "tail""f4273"; do
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
printf '\n%s\n' "${C_BOLD}No 1Password item IDs${C_RESET}"

# 1P item IDs are exactly 26 alphanumeric chars (mixed case).
# \b is a GNU extension with no portable ERE equivalent (BSD grep treats it as a
# literal 'b'), so anchor on surrounding context instead.
op_id_matches=$(scan_files '(^|[^a-zA-Z0-9])[a-zA-Z0-9]{26}([^a-zA-Z0-9]|$)' || true)
if [[ -z "$op_id_matches" ]]; then
  pass "No 1Password item IDs (26-char alphanumeric, mixed case) found"
else
  fail "No 1Password item IDs (26-char alphanumeric, mixed case) found"
  echo "$op_id_matches" | while IFS= read -r line; do [[ -n "$line" ]] && printf "       %s\n" "$line"; done
fi

# --- Real usernames ---
printf '\n%s\n' "${C_BOLD}No real usernames in skill content${C_RESET}"

# pmcdade and petejm should only appear as public publishing identifiers: the LICENSE
# copyright line, the GitHub clone/repo URL, and the plugin marketplace name used in the
# documented install commands. Those last forms are load-bearing — a marketplace plugin
# cannot be installed without naming its owner — so they are allowlisted by their exact
# shape, not by a bare `grep -v <username>`. A leak in any other shape (a /home/<user>/
# path, an email, a vault or account name) still fails this assertion.
for username in "pmcdade" "petejm"; do
  all_matches=$(scan_files "$username" || true)
  unexpected=$(echo "$all_matches" | \
    grep -v "LICENSE" | \
    grep -v "git clone.*github.com" | \
    grep -v "github.com/$username" | \
    grep -v "\"name\": \"$username-plugins\"" | \
    grep -v "plugin marketplace add $username/1password-skill" | \
    grep -v "plugin install 1password-skill@$username-plugins" || true)
  if [[ -z "$unexpected" ]]; then
    pass "Username '$username' only in expected locations (LICENSE, repo URL, marketplace id)"
  else
    fail "Username '$username' found in unexpected locations"
    echo "$unexpected" | while IFS= read -r line; do [[ -n "$line" ]] && printf "       %s\n" "$line"; done
  fi
done

# --- API tokens / key prefixes ---
printf '\n%s\n' "${C_BOLD}No API tokens or key material${C_RESET}"

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
printf '\n%s\n' "${C_BOLD}No hardcoded home directory paths${C_RESET}"

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
printf '\n%s\n' "${C_BOLD}No .env files committed${C_RESET}"

env_files=$(git -C "$REPO_ROOT" ls-files --cached 2>/dev/null | grep -E '(^|/)\.env$' || true)
if [[ -z "$env_files" ]]; then
  pass "No .env files in git index"
else
  fail "No .env files in git index (found: $env_files)"
fi

# --- environment.md must not be committed ---
printf '\n%s\n' "${C_BOLD}environment.md not committed${C_RESET}"

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

# --- secret references bracket the vault segment ---
printf '\n%s\n' "${C_BOLD}secret references bracket the vault segment${C_RESET}"

# Replaces a hand-curated allowlist of "clearly fake" vault names (VaultName,
# MyVault, DevVault, ...). That list had to grow forever and could never be
# sound: a placeholder like Vault or GitHub is indistinguishable from a real
# vault somebody actually has. Bracketing is DECIDABLE rather than enumerated,
# because a real vault name can never begin with '<'.
#
# Leak-shaped = the scheme followed by an unbracketed segment and a '/'. A bare
# prose mention has no path and is correctly ignored, which matters a great deal
# in a repo whose entire subject is this syntax -- you cannot write about the
# scheme without naming it.
#
# The pattern is assembled from parts so this file never contains the literal
# string it searches for. An exclusion for tests/ would work too, but it would
# also hide a genuine finding in the test suite itself.
_op_scheme='op:'
_op_leak="${_op_scheme}//[^<[:space:]]+/"
suspicious_op=$(scan_files "$_op_leak" || true)
if [[ -z "$suspicious_op" ]]; then
  pass "secret references write the vault as <vault>"
else
  fail "secret references must write the vault as <vault> (found unbracketed)"
  echo "$suspicious_op" | while IFS= read -r line; do [[ -n "$line" ]] && printf "       %s\n" "$line"; done
fi

# --- SSH private key material ---
printf '\n%s\n' "${C_BOLD}No SSH private key material${C_RESET}"

ssh_key_matches=$(scan_files 'BEGIN (RSA|EC|OPENSSH|DSA) PRIVATE KEY' || true)
if [[ -z "$ssh_key_matches" ]]; then
  pass "No SSH private key material found"
else
  fail "No SSH private key material found"
  echo "$ssh_key_matches" | while IFS= read -r line; do [[ -n "$line" ]] && printf "       %s\n" "$line"; done
fi

# --- .gitignore blocks sensitive files ---
printf '\n%s\n' "${C_BOLD}.gitignore blocks sensitive files${C_RESET}"

gitignore="$REPO_ROOT/.gitignore"
if [[ -f "$gitignore" ]]; then
  # Match an actual ignore RULE, not a comment. .gitignore carries an explanatory
  # comment containing this filename; grepping the whole file would let the comment
  # alone satisfy the assertion and make it impossible to fail.
  #
  # Capture the comment-stripped rules once, then grep them via here-string.
  # `grep -v ... | grep -q ...` risks SIGPIPE under pipefail: the second grep can
  # exit the instant it matches while the first grep still has more to write.
  gitignore_rules=$(grep -vE '^[[:space:]]*#' "$gitignore")
  if grep -qE 'environment\.md' <<< "$gitignore_rules"; then
    pass ".gitignore blocks environment.md (skills/*/environment.md pattern)"
  else
    fail ".gitignore should block environment.md (skills/*/environment.md)"
  fi

  # Same comment-stripping as the environment.md rule above. Grepping the whole file
  # lets an explanatory comment that merely names `*.env` satisfy the assertion that
  # `*.env` is ignored, which is mere occurrence rather than an actual ignore rule.
  if grep -qE '\*\.env' <<< "$gitignore_rules"; then
    pass ".gitignore blocks *.env files"
  else
    fail ".gitignore should block *.env files"
  fi
else
  fail ".gitignore exists (needed for security)"
fi

# --- No pipeline under `pipefail` feeds an early-exit consumer ---
# `producer | grep -q ...` (or `| grep -m N` or `| head`) is a correctness bug, not
# style: those consumers exit the INSTANT they have what they need, closing the pipe.
# Under `set -o pipefail` the producer's resulting SIGPIPE termination (128+13=141)
# becomes the whole PIPELINE's exit status -- reporting a MATCH as a FAILURE. This is
# the exact bug behind scripts/convert.sh's old
# `printf '%s\n' "$body" | grep -q '^# '`: a byte-identical, perfectly valid SKILL.md
# intermittently "failed" validation precisely because the match won the race. This
# check exists to keep that class of bug from coming back anywhere in the repo.
printf '\n%s\n' "${C_BOLD}No pipeline under pipefail feeds an early-exit consumer${C_RESET}"

# Every script that sets pipefail, except this one. test-security.sh necessarily
# quotes the forbidden shape in the comment above and in the detection regex below --
# scanning it would trip its own check. Same rationale as the tests/ exclusion in the
# scan corpus built earlier in this file ("test scripts necessarily reference the
# patterns they scan for and would cause false positives").
_pipefail_scripts=""
for _pf_script in "$REPO_ROOT"/tests/*.sh "$REPO_ROOT"/scripts/*.sh; do
  [[ -f "$_pf_script" ]] || continue
  [[ "$(basename "$_pf_script")" == "$(basename "${BASH_SOURCE[0]}")" ]] && continue
  grep -qE 'pipefail' "$_pf_script" 2>/dev/null || continue
  _pipefail_scripts="${_pipefail_scripts}${_pf_script}"$'\n'
done

# Text-based scan, not a real bash parser -- it does not understand heredocs or
# quoted strings, so a fixture that literally contains "| head" as example TEXT could
# false-positive. None does today (checked by hand); if one ever does, narrow the
# exclusion for that file rather than deleting this check.
_bad_pipe_hits=""
while IFS= read -r _pf_script; do
  [[ -z "$_pf_script" ]] && continue
  _hits=$(awk '
    /^[[:space:]]*#/ { next }                  # whole-line comments are not live code
    {
      line = $0
      # `||` is logical OR, not a pipeline -- a command after it does not read the
      # previous command'\''s stdout, so it cannot SIGPIPE it. Collapse every `||`
      # first so a real `|` is never mistaken for the second half of `||`.
      gsub(/\|\|/, "OO", line)
      if (line ~ /\|[[:space:]]*(grep[[:space:]]+-[A-Za-z]*q|grep[[:space:]]+-[A-Za-z]*m|head)([[:space:]]|$)/) {
        print FILENAME ":" NR ": " $0
      }
    }
  ' "$_pf_script" 2>/dev/null)
  [[ -n "$_hits" ]] && _bad_pipe_hits="${_bad_pipe_hits}${_hits}"$'\n'
done <<< "$_pipefail_scripts"

if [[ -z "$_bad_pipe_hits" ]]; then
  pass "No pipeline under pipefail feeds an early-exit consumer (grep -q, grep -m, head)"
else
  fail "Pipeline(s) under pipefail feed an early-exit consumer -- the producer's SIGPIPE reports a MATCH as a FAILURE"
  printf '%s' "$_bad_pipe_hits" | while IFS= read -r line; do [[ -n "$line" ]] && printf "       %s\n" "$line"; done
fi

# --- Summary ---
summary_and_exit
