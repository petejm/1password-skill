#!/usr/bin/env bash
# convert.sh — Generate tool-specific formats from canonical SKILL.md
#
# Usage: ./scripts/convert.sh [--tool <name>]
#
# Tools: gemini-cli, cursor, aider, windsurf, all (default)
# Output: integrations/<tool>/

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_SKILL="$REPO_ROOT/skills/1password/SKILL.md"
# OUT_BASE may be overridden (e.g. to a temp dir) to test generation without
# clobbering the committed integrations/ tree.
OUT_BASE="${OUT_BASE:-$REPO_ROOT/integrations}"

# Color output (respects NO_COLOR)
if [[ -z "${NO_COLOR:-}" && "${TERM:-dumb}" != "dumb" ]]; then
  C_GREEN="\033[0;32m"; C_RED="\033[0;31m"; C_CYAN="\033[0;36m"; C_RESET="\033[0m"
else
  C_GREEN="" C_RED="" C_CYAN="" C_RESET=""
fi
info()  { printf "${C_GREEN}[OK]${C_RESET}   %s\n" "$*"; }
error() { printf "${C_RED}[ERR]${C_RESET}  %s\n" "$*" >&2; }
step()  { printf "${C_CYAN}-->${C_RESET}    %s\n" "$*"; }

# Path of the artifact currently being written. Every converter writes to a temp file
# in the destination directory and renames it into place only after its assertions
# pass, so a source defect caught by converter #2 cannot leave converter #1's output
# already overwritten and #3/#4 stale. The trap removes a temp file left behind when
# an assertion exits non-zero under `set -e`.
TMP_ARTIFACT=""
cleanup_tmp_artifact() {
  [[ -n "$TMP_ARTIFACT" && -f "$TMP_ARTIFACT" ]] && rm -f "$TMP_ARTIFACT"
  return 0
}
trap cleanup_tmp_artifact EXIT INT TERM

# ---- validation helpers (fail closed: every one exits non-zero on failure) ----

# Assert the source file actually opens with a YAML frontmatter delimiter.
assert_has_frontmatter() {
  local file="$1" first=""
  IFS= read -r first < "$file" || true
  first="${first%$'\r'}"
  if [[ "$first" != "---" ]]; then
    error "$file does not start with a YAML frontmatter delimiter (---)"
    exit 1
  fi
}

# Assert a generated file exists and is non-empty.
assert_nonempty_file() {
  local file="$1" label="$2"
  if [[ ! -s "$file" ]]; then
    error "$label: generated file is missing or empty: $file"
    exit 1
  fi
}

# Assert a generated file contains an expected marker (BRE pattern).
assert_marker() {
  local file="$1" pattern="$2" label="$3"
  if ! grep -q -e "$pattern" "$file"; then
    error "$label: expected marker not found in $file: $pattern"
    exit 1
  fi
}

# Strip YAML frontmatter (---...---) from markdown, output body only
strip_frontmatter() {
  awk '/^---/{c++; if(c<=2) next} c>=2{print}' "$1"
}

# Render a string as a YAML single-quoted scalar body (caller adds the quotes).
# Single-quoted YAML has exactly one escape rule — '' means a literal apostrophe
# — and processes no backslash escapes at all, so backslashes, double quotes,
# colons, '#', and em-dashes all pass through verbatim. That makes it correct by
# construction, unlike a hand-escaped double-quoted scalar.
# Pattern and replacement are held in variables: an inline "${s//\'/\'\'}" is
# NOT portable (bash <= 4.2 / BASH_COMPAT<=4.2 skips quote removal on the
# replacement and emits the invalid escape \'), and this form is byte-identical
# on bash 3.2 through 5.x. Pure bash, so no sed/awk GNU-vs-BSD divergence.
yaml_single_quote() {
  local s="$1" sq="'" esc="''"
  printf '%s' "${s//$sq/$esc}"
}

# Extract a top-level scalar value from the YAML frontmatter.
# Handles both single-line (key: "text") and multiline block scalar (key: |) forms.
get_frontmatter_value() {
  local file="$1" key="$2"
  awk -v key="$key" '
    BEGIN {
      head_re  = "^" key ":"
      block_re = "^" key ":[[:space:]]*[|>][0-9+-]*[[:space:]]*$"
      strip_re = "^" key ":[[:space:]]*"
    }
    /^---/{f++}
    f==1 && $0 ~ head_re {
      # Block scalar only if the line ENDS with a block indicator (| |- |+ > >- >+,
      # optionally with an explicit indentation digit). A pipe anywhere else on the
      # line is just part of the text (e.g. "description: op read | jq").
      if ($0 ~ block_re) {
        # Multiline block scalar — collect all indented lines until dedent or end of frontmatter
        result = ""
        while ((getline line) > 0) {
          if (line ~ /^---/) break
          if (line ~ /^[^[:space:]]/ && line != "") break
          stripped = line
          gsub(/^[[:space:]]+/, "", stripped)
          # Drop the CR of a CRLF source. The single-line branch gets this for free
          # from its trailing-whitespace sub(); without it this branch embeds a raw
          # \r inside the generated single-quoted YAML scalar.
          sub(/\r$/, "", stripped)
          if (stripped != "") {
            if (result != "") result = result " "
            result = result stripped
          }
        }
        print result
        exit
      } else {
        # Single-line: key: "text", key: <sq>text<sq>, or bare text.
        # \047 is the apostrophe (cannot be written literally inside this awk program).
        val = $0
        sub(strip_re, "", val)
        sub(/[[:space:]]+$/, "", val)
        if (val ~ /^".*"$/) {
          print substr(val, 2, length(val) - 2)
          exit
        }
        if (val ~ /^\047.*\047$/) {
          inner = substr(val, 2, length(val) - 2)
          gsub(/\047\047/, "\047", inner)   # YAML single-quoted: doubled apostrophe means one
          print inner
          exit
        }
        # Plain (unquoted) scalar: YAML folds indented continuation lines into it with
        # a single space. Printing only the first line silently truncates a valid
        # multi-line plain scalar into a valid-LOOKING one-line value.
        while ((getline line) > 0) {
          if (line ~ /^---/) break
          if (line ~ /^[^[:space:]]/) break
          gsub(/^[[:space:]]+/, "", line)
          sub(/[[:space:]]+$/, "", line)
          if (line == "") break
          val = (val == "" ? line : val " " line)
        }
        print val
        exit
      }
    }
  ' "$file"
}

# The Cursor rule format has exactly one free-text slot (description), but SKILL.md
# splits its trigger vocabulary into a separate `when_to_use` key. Fold the two so the
# generated .mdc still carries the phrases that are supposed to trigger it.
cursor_description() {
  local desc when
  desc="$(get_frontmatter_value "$SOURCE_SKILL" description)"
  when="$(get_frontmatter_value "$SOURCE_SKILL" when_to_use)"
  if [[ -n "$when" ]]; then
    if [[ -n "$desc" ]]; then desc="$desc $when"; else desc="$when"; fi
  fi
  printf '%s' "$desc"
}

# Check everything the converters depend on BEFORE any of them writes a byte.
validate_source() {
  local desc body
  desc="$(get_frontmatter_value "$SOURCE_SKILL" description)"
  if [[ -z "$desc" ]]; then
    error "could not extract a description from $SOURCE_SKILL"
    exit 1
  fi
  body="$(strip_frontmatter "$SOURCE_SKILL")"
  if [[ -z "$body" ]]; then
    error "$SOURCE_SKILL has no content after its YAML frontmatter"
    exit 1
  fi
  if ! printf '%s\n' "$body" | grep -q '^# '; then
    error "$SOURCE_SKILL body has no top-level '# ' heading"
    exit 1
  fi
}

convert_gemini_cli() {
  local out="$OUT_BASE/gemini-cli/skills/1password"
  mkdir -p "$out"
  TMP_ARTIFACT="$out/SKILL.md.tmp.$$"
  cp "$SOURCE_SKILL" "$TMP_ARTIFACT"
  assert_nonempty_file "$TMP_ARTIFACT" "Gemini CLI"
  assert_marker "$TMP_ARTIFACT" '^description:' "Gemini CLI"
  assert_marker "$TMP_ARTIFACT" '^# ' "Gemini CLI"
  mv -f "$TMP_ARTIFACT" "$out/SKILL.md"
  TMP_ARTIFACT=""
  info "Gemini CLI: skills/1password/SKILL.md"
}

convert_cursor() {
  local out="$OUT_BASE/cursor/.cursor/rules"
  mkdir -p "$out"
  local desc desc_yaml
  desc="$(cursor_description)"
  if [[ -z "$desc" ]]; then
    error "could not extract a description from $SOURCE_SKILL"
    exit 1
  fi
  desc_yaml="$(yaml_single_quote "$desc")"
  TMP_ARTIFACT="$out/1password.mdc.tmp.$$"
  {
    printf '%s\n' "---"
    # printf, not echo: echo would reinterpret backslashes in the description.
    printf "description: '%s'\n" "$desc_yaml"
    printf '%s\n' 'globs: ""'
    printf '%s\n' "alwaysApply: true"
    printf '%s\n' "---"
    printf '\n'
    strip_frontmatter "$SOURCE_SKILL"
  } > "$TMP_ARTIFACT"
  assert_nonempty_file "$TMP_ARTIFACT" "Cursor"
  assert_marker "$TMP_ARTIFACT" "^description: '" "Cursor"
  assert_marker "$TMP_ARTIFACT" '^alwaysApply: true$' "Cursor"
  assert_marker "$TMP_ARTIFACT" '^# ' "Cursor"
  mv -f "$TMP_ARTIFACT" "$out/1password.mdc"
  TMP_ARTIFACT=""
  info "Cursor: .cursor/rules/1password.mdc"
}

convert_aider() {
  local out="$OUT_BASE/aider"
  mkdir -p "$out"
  TMP_ARTIFACT="$out/CONVENTIONS.md.tmp.$$"
  strip_frontmatter "$SOURCE_SKILL" > "$TMP_ARTIFACT"
  assert_nonempty_file "$TMP_ARTIFACT" "Aider"
  assert_marker "$TMP_ARTIFACT" '^# ' "Aider"
  mv -f "$TMP_ARTIFACT" "$out/CONVENTIONS.md"
  TMP_ARTIFACT=""
  info "Aider: CONVENTIONS.md"
}

convert_windsurf() {
  local out="$OUT_BASE/windsurf"
  mkdir -p "$out"
  TMP_ARTIFACT="$out/.windsurfrules.tmp.$$"
  strip_frontmatter "$SOURCE_SKILL" > "$TMP_ARTIFACT"
  assert_nonempty_file "$TMP_ARTIFACT" "Windsurf"
  assert_marker "$TMP_ARTIFACT" '^# ' "Windsurf"
  mv -f "$TMP_ARTIFACT" "$out/.windsurfrules"
  TMP_ARTIFACT=""
  info "Windsurf: .windsurfrules"
}

usage() {
  cat <<EOF
Usage: $(basename "$0") [--tool <name>] [--help]

Generate tool-specific formats from the canonical SKILL.md.

Options:
  --tool <name>   Tool to generate for: gemini-cli, cursor, aider, windsurf, all
                  Default: all
  --help          Show this help

Output structure:
  integrations/gemini-cli/  → skills/1password/SKILL.md (same format as Claude Code)
  integrations/cursor/      → .cursor/rules/1password.mdc
  integrations/aider/       → CONVENTIONS.md
  integrations/windsurf/    → .windsurfrules
EOF
}

main() {
  local tool="all"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --tool)
        [[ -n "${2:-}" ]] || { error "--tool requires a value"; exit 1; }
        tool="$2"; shift 2 ;;
      --help|-h) usage; exit 0 ;;
      *) error "Unknown argument: $1"; usage; exit 1 ;;
    esac
  done

  case "$tool" in
    gemini-cli|cursor|aider|windsurf|all) ;;
    *) error "Unknown tool: $tool. Valid: gemini-cli, cursor, aider, windsurf, all"; exit 1 ;;
  esac

  if [[ ! -f "$SOURCE_SKILL" ]]; then
    error "Source skill not found: $SOURCE_SKILL"
    exit 1
  fi
  if [[ ! -s "$SOURCE_SKILL" ]]; then
    error "Source skill is empty: $SOURCE_SKILL"
    exit 1
  fi
  assert_has_frontmatter "$SOURCE_SKILL"
  # Precondition for EVERY converter, checked before the first write. Without it a
  # source defect is only discovered by whichever converter happens to trip over it,
  # by which point the earlier artifacts have already been replaced.
  validate_source

  step "1password-skill converter — tool: $tool"

  case "$tool" in
    gemini-cli) convert_gemini_cli ;;
    cursor) convert_cursor ;;
    aider) convert_aider ;;
    windsurf) convert_windsurf ;;
    all)
      convert_gemini_cli
      convert_cursor
      convert_aider
      convert_windsurf
      ;;
  esac
}

main "$@"
