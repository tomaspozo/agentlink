# Contributing

## Development

The plugin has no build step — files are consumed directly. It's triple-format: the same directory installs in Claude Code, Cursor, and Codex, sharing the skills, references, assets, and the destructive-DB hook.

**One spine, three restatements.** Each host guarantees the core architecture rules load by a different mechanism, so the same spine exists three times — **change one, consider the other two**:

| Host | Always-on mechanism | File |
|---|---|---|
| Claude Code | `settings.json` forces `"agent": "agentlink:builder"` | `agents/builder.md` |
| Cursor | `alwaysApply: true` rule (the builder agent is user-selectable, not forced) | `rules/agentlink.mdc` |
| Codex | skill description matching (no `agents` / `rules` field exists) | `codex/skills/builder/SKILL.md` |

Codex's is the weakest guarantee — its skill only loads if the model matches the description — which is why that `description` is front-loaded with trigger words.

**Test in Claude Code:**

```bash
claude --plugin-dir ./
```

**Test in Cursor:** copy this directory into Cursor's local-plugins folder, then reload. Cursor only loads a plugin whose files live **inside** `~/.cursor/plugins/local/` — it rejects a symlink that points outside that folder (`loadUserLocalPlugin … rejected: symlink target … is outside …/.cursor/plugins/local`), so use a real copy and re-sync after edits:

```bash
rsync -a --delete --exclude '.git' --exclude '.env*' --exclude 'agentlink-debug.log' \
  ./ ~/.cursor/plugins/local/agentlink/
```

Then restart Cursor (or run **Developer: Reload Window**). Verify the `agentlink` agent and the seven skills are selectable, the always-on `agentlink` rule is active, and a `npx supabase db reset` is blocked by the hook. Re-run the `rsync` after each change to pick it up.

**Test in Codex:** add this directory as a local marketplace, then install from it:

```bash
codex plugin marketplace add ./          # a local path, owner/repo[@ref], or a Git URL
codex plugin add agentlink@tomaspozo
```

The marketplace lives at `.agents/plugins/marketplace.json` — **not** in `.codex-plugin/`, which holds only the plugin manifest. `.agents/` is otherwise gitignored (it's where companion skills install locally), so `.gitignore` re-includes that one file explicitly; if you move it, keep the negation in sync or the marketplace silently stops shipping. Start a new thread after reinstalling so Codex picks up changed skills.

> **Heads up:** Cursor also imports Claude Code plugins from `~/.claude/plugins`. If you've installed AgentLink in Claude Code (`agentlink@tomaspozo`, formerly `link@agentlink`), it appears in Cursor too — distinct from this local copy. Test from a workspace where the Claude Code install isn't active, or uninstall it there, to avoid two entries.

### Project structure

```
.claude-plugin/plugin.json    # Claude Code manifest (name, version, metadata)
.cursor-plugin/plugin.json    # Cursor manifest (mirrors the Claude one + explicit component paths)
.codex-plugin/plugin.json     # Codex manifest (skills array + hooks + `interface` block)
agents/builder.md             # Main agent definition (Claude Code)
skills/                       # Domain skills, shared by all three hosts
                              #   (cli, database, rpc, auth, edge-functions, frontend, notifications)
codex/skills/builder/         # Codex-only builder skill — Codex has no `agents` field.
                              #   Kept out of skills/ so Claude/Cursor don't see a
                              #   duplicate of the builder agent.
rules/agentlink.mdc           # Cursor always-on rule (routing + non-negotiables; keep it short,
                              #   it rides in every request)
hooks/hooks.json              # Claude Code + Codex hook registry (PreToolUse → block destructive
                              #   DB commands). Codex reuses it verbatim — its hook contract
                              #   matches Claude's and it reads CLAUDE_PLUGIN_ROOT.
hooks/cursor.hooks.json       # Cursor hook registry (beforeShellExecution → same guard)
scripts/release.sh            # Release automation
settings.json                 # Default agent config (Claude Code)
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
3. Bumps the version in all three manifests (`.claude-plugin`, `.cursor-plugin`, `.codex-plugin`)
4. Commits, tags, and pushes
5. Creates a GitHub release with the changelog entry as release notes

### Steps

```bash
# 1. Make sure everything is committed
git status

# 2. Preview what will happen
./scripts/release.sh 1.0.0 --dry-run

# 3. Cut the release
./scripts/release.sh 1.0.0
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

The version in `.claude-plugin/plugin.json` is the source of truth. The release script keeps `.cursor-plugin/plugin.json`, `.codex-plugin/plugin.json`, the git tag, and the GitHub release in sync with it. If you add a fourth host, wire its manifest into `scripts/release.sh` or its version silently drifts.
