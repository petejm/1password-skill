# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] - 2026-04-09

### Added
- Initial public release of the 1password-skill Claude Code plugin
- Core skill document (`skills/1password/SKILL.md`) with decision-router pattern for `op` CLI usage
- Six security rules enforcing `op run` over `op read`, vault scoping, no secrets in files, and minimal credential exposure
- Error catalog covering common `op` failures, auth recovery flow, and SSH agent troubleshooting
- Shell support matrix: bash/zsh and Fish variants for all code examples
- Multi-model integration support via `scripts/convert.sh`:
  - Gemini CLI (`integrations/gemini-cli/`)
  - Cursor (`.cursor/rules/1password.mdc`)
  - Aider (`integrations/aider/CONVENTIONS.md`)
  - Windsurf (`integrations/windsurf/.windsurfrules`)
- `convert.sh` with `--tool` flag for targeted generation and dynamic description extraction from SKILL.md frontmatter
- Gemini-powered tabula rasa review script (`scripts/gemini-review.sh`) for skill quality validation
- Comprehensive test suite (110 tests) covering convert.sh and plugin structure
- Apache 2.0 license

### Fixed
- Hardened test suite against `|| true` exit code traps and narrow regex patterns (adversarial review)
- Vault name sanitization in `gemini-review.sh`
- Dynamic Cursor description extraction from multiline YAML block scalars; corrected Gemini CLI install path in README

[Unreleased]: https://github.com/petejm/1password-skill/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/petejm/1password-skill/releases/tag/v1.0.0
