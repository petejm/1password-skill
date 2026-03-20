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
OUT_BASE="$REPO_ROOT/integrations"

# Color output (respects NO_COLOR)
if [[ -z "${NO_COLOR:-}" && "${TERM:-dumb}" != "dumb" ]]; then
  C_GREEN="\033[0;32m"; C_RED="\033[0;31m"; C_CYAN="\033[0;36m"; C_RESET="\033[0m"
else
  C_GREEN="" C_RED="" C_CYAN="" C_RESET=""
fi
info()  { printf "${C_GREEN}[OK]${C_RESET}   %s\n" "$*"; }
error() { printf "${C_RED}[ERR]${C_RESET}  %s\n" "$*" >&2; }
step()  { printf "${C_CYAN}-->${C_RESET}    %s\n" "$*"; }

# Strip YAML frontmatter (---...---) from markdown, output body only
strip_frontmatter() {
  awk '/^---/{c++; if(c<=2) next} c>=2{print}' "$1"
}

# Extract description from YAML frontmatter
# Handles both single-line (description: "text") and multiline block scalar (description: |)
get_description() {
  local file="$1"
  awk '
    /^---/{f++}
    f==1 && /^description:/ {
      if (/\|/) {
        # Multiline block scalar — grab the first non-empty indented line
        while ((getline line) > 0) {
          gsub(/^[[:space:]]+/, "", line)
          if (line != "") { print line; exit }
        }
      } else {
        # Single-line: description: "text" or description: text
        sub(/^description:[[:space:]]*/, "")
        gsub(/^"|"$/, "")
        print
        exit
      }
    }
  ' "$file"
}

convert_gemini_cli() {
  local out="$OUT_BASE/gemini-cli/skills/1password"
  mkdir -p "$out"
  cp "$SOURCE_SKILL" "$out/SKILL.md"
  info "Gemini CLI: skills/1password/SKILL.md"
}

convert_cursor() {
  local out="$OUT_BASE/cursor/.cursor/rules"
  mkdir -p "$out"
  local desc
  desc="$(get_description "$SOURCE_SKILL")"
  {
    echo "---"
    echo "description: \"$desc\""
    echo 'globs: ""'
    echo "alwaysApply: true"
    echo "---"
    echo ""
    strip_frontmatter "$SOURCE_SKILL"
  } > "$out/1password.mdc"
  info "Cursor: .cursor/rules/1password.mdc"
}

convert_aider() {
  local out="$OUT_BASE/aider"
  mkdir -p "$out"
  strip_frontmatter "$SOURCE_SKILL" > "$out/CONVENTIONS.md"
  info "Aider: CONVENTIONS.md"
}

convert_windsurf() {
  local out="$OUT_BASE/windsurf"
  mkdir -p "$out"
  strip_frontmatter "$SOURCE_SKILL" > "$out/.windsurfrules"
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
