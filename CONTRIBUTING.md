# Contributing

## Development

The plugin has no build step. Files are consumed directly by Claude Code's plugin system. To test locally:

```bash
claude --plugin-dir ./
```

### Project structure

```
.claude-plugin/plugin.json   # Plugin manifest (name, version, metadata)
agents/builder.md             # Main agent definition
skills/                       # Domain skills (database, rpc, auth, edge-functions, frontend)
hooks/                        # PreToolUse hooks (block destructive DB commands)
scripts/release.sh            # Release automation
settings.json                 # Default agent config
```

## Changelog

This project follows [Keep a Changelog](https://keepachangelog.com/) conventions.

As you work, add entries under `## [Unreleased]` at the top of `CHANGELOG.md`. Use the standard sections:

- **Added** — new features
- **Changed** — changes to existing functionality
- **Removed** — removed features
- **Fixed** — bug fixes

```markdown
## [Unreleased]

### Added

- New thing that was added

### Changed

- Existing thing that was modified
```

Don't add a version number or date — the release script handles that.

## Releasing

Releases are cut with `scripts/release.sh`. The script handles the full flow:

1. Stamps `[Unreleased]` → `[X.Y.Z] - YYYY-MM-DD` in CHANGELOG.md
2. Adds a fresh `[Unreleased]` section at the top
3. Bumps the version in `.claude-plugin/plugin.json`
4. Commits, tags, and pushes
5. Creates a GitHub release with the changelog entry as release notes

### Steps

```bash
# 1. Make sure everything is committed
git status

# 2. Preview what will happen
./scripts/release.sh 0.9.0 --dry-run

# 3. Cut the release
./scripts/release.sh 0.9.0
```

### Rules

- The version must be valid semver (`X.Y.Z`)
- The `[Unreleased]` section must have content — the script won't create an empty release
- The working tree must be clean — commit or stash changes first
- The tag must not already exist

### Versioning

This project uses [Semantic Versioning](https://semver.org/):

- **Patch** (`0.8.1`) — bug fixes, typo corrections, minor wording improvements
- **Minor** (`0.9.0`) — new features, new skills, significant workflow changes
- **Major** (`1.0.0`) — breaking changes to the plugin interface or agent behavior

The version in `.claude-plugin/plugin.json` is the source of truth. The release script keeps the git tag and GitHub release in sync with it.
