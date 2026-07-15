#!/usr/bin/env bash
set -euo pipefail

# Release script — bumps the version, stamps the changelog, commits, tags, and creates a GitHub release.
#
# Usage:
#   ./scripts/release.sh <version>              # e.g. ./scripts/release.sh 0.9.0
#   ./scripts/release.sh <version> --dry-run     # preview without making changes

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGIN_JSON="$REPO_ROOT/.claude-plugin/plugin.json"
CURSOR_PLUGIN_JSON="$REPO_ROOT/.cursor-plugin/plugin.json"
CODEX_PLUGIN_JSON="$REPO_ROOT/.codex-plugin/plugin.json"
BUILDER_MD="$REPO_ROOT/agents/builder.md"
CHANGELOG="$REPO_ROOT/CHANGELOG.md"

# --- Parse arguments ---
# The plugin and the agentlink-sh CLI ship the SAME version (lockstep). The
# normal entry point is the CLI's scripts/release.sh, which calls THIS script
# with --lockstep. --lockstep skips the confirm prompt and tolerates an empty
# [Unreleased] (a CLI-only release leaves the plugin changelog empty but still
# version-bumps, so the numbers never drift). Running this script directly is
# fine for a plugin-only release, but prefer the CLI orchestrator so both repos
# move together.
VERSION="${1:-}"
DRY_RUN=false
LOCKSTEP=false
shift || true
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --lockstep) LOCKSTEP=true ;;
    *) echo "Unknown flag: $arg" >&2; exit 1 ;;
  esac
done

if [[ -z "$VERSION" ]]; then
  echo "Usage: ./scripts/release.sh <version> [--dry-run] [--lockstep]" >&2
  echo "  e.g. ./scripts/release.sh 0.9.0" >&2
  exit 1
fi

TAG="v${VERSION}"
TODAY=$(date +%Y-%m-%d)
CURRENT_VERSION=$(jq -r '.version' "$PLUGIN_JSON")

echo "Current version: $CURRENT_VERSION"
echo "New version:     $VERSION"
echo "Tag:             $TAG"
echo "Date:            $TODAY"
echo ""

# --- Validate ---
if [[ "$VERSION" == "$CURRENT_VERSION" ]]; then
  echo "Error: version $VERSION is already the current version" >&2
  exit 1
fi

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Error: version must be semver (e.g. 0.9.0)" >&2
  exit 1
fi

if git -C "$REPO_ROOT" tag -l "$TAG" | grep -q "$TAG"; then
  echo "Error: tag $TAG already exists" >&2
  echo "  To delete it: git tag -d $TAG && git push origin :refs/tags/$TAG" >&2
  exit 1
fi

if [[ -n "$(git -C "$REPO_ROOT" status --porcelain)" ]]; then
  echo "Error: working tree has uncommitted changes — commit or stash first" >&2
  exit 1
fi

# --- Check that [Unreleased] has content ---
UNRELEASED_CONTENT=$(awk '
  /^## \[Unreleased\]/ { found=1; next }
  /^## \[/ { if (found) exit }
  found { print }
' "$CHANGELOG")

if [[ -z "$(echo "$UNRELEASED_CONTENT" | sed '/^[[:space:]]*$/d')" ]]; then
  if [[ "$LOCKSTEP" == true ]]; then
    # CLI-only release: no plugin changes, but we still bump to keep versions in
    # lockstep. Inject a placeholder under [Unreleased] so the stamped version
    # section (and the GitHub release notes) isn't blank.
    PLACEHOLDER="- Version bump only — kept in lockstep with the agentlink-sh CLI (no plugin changes this release)."
    perl -0pi -e "s/(## \[Unreleased\]\n)/\$1\n$PLACEHOLDER\n/" "$CHANGELOG"
    UNRELEASED_CONTENT="$PLACEHOLDER"
  else
    echo "Error: no content under [Unreleased] in CHANGELOG.md" >&2
    exit 1
  fi
fi

# --- Preview ---
echo "--- Changelog entry ---"
echo "## [$VERSION] - $TODAY"
echo "$UNRELEASED_CONTENT"
echo "--- End ---"
echo ""

if [[ "$DRY_RUN" == true ]]; then
  echo "[dry-run] Would:"
  echo "  1. Stamp [Unreleased] → [$VERSION] - $TODAY in CHANGELOG.md"
  echo "  2. Add fresh [Unreleased] section"
  echo "  3. Bump all three plugin.json manifests (.claude-plugin + .cursor-plugin + .codex-plugin) to $VERSION"
  echo "  4. Update the AGENTLINK_VERSION stamp in agents/builder.md to $VERSION"
  echo "  5. Commit, tag $TAG, push, create GitHub release"
  exit 0
fi

# --- Confirm (skipped under --lockstep; the CLI orchestrator already confirmed) ---
if [[ "$LOCKSTEP" != true ]]; then
  read -rp "Release $TAG? [y/N] " confirm
  if [[ "$confirm" != [yY] ]]; then
    echo "Aborted"
    exit 0
  fi
fi

cd "$REPO_ROOT"

# --- 1. Stamp changelog ---
# Replace "## [Unreleased]" with the new version header, and add a fresh [Unreleased] above it
sed -i '' "s/^## \[Unreleased\]/## [Unreleased]\n\n## [$VERSION] - $TODAY/" "$CHANGELOG"

# --- 2. Bump plugin.json (the Claude Code, Cursor, and Codex manifests) ---
jq --arg v "$VERSION" '.version = $v' "$PLUGIN_JSON" > "$PLUGIN_JSON.tmp" && mv "$PLUGIN_JSON.tmp" "$PLUGIN_JSON"
jq --arg v "$VERSION" '.version = $v' "$CURSOR_PLUGIN_JSON" > "$CURSOR_PLUGIN_JSON.tmp" && mv "$CURSOR_PLUGIN_JSON.tmp" "$CURSOR_PLUGIN_JSON"
jq --arg v "$VERSION" '.version = $v' "$CODEX_PLUGIN_JSON" > "$CODEX_PLUGIN_JSON.tmp" && mv "$CODEX_PLUGIN_JSON.tmp" "$CODEX_PLUGIN_JSON"

# --- 2b. Update the AGENTLINK_VERSION stamp in builder.md (the lockstep marker
#         the agent reads to reason about contract drift). ---
perl -pi -e "s/AGENTLINK_VERSION: [0-9]+\.[0-9]+\.[0-9]+/AGENTLINK_VERSION: $VERSION/; s/\*\*AgentLink version:\*\* \`[0-9]+\.[0-9]+\.[0-9]+\`/\*\*AgentLink version:\*\* \`$VERSION\`/" "$BUILDER_MD"

# --- 3. Commit ---
git add "$CHANGELOG" "$PLUGIN_JSON" "$CURSOR_PLUGIN_JSON" "$CODEX_PLUGIN_JSON" "$BUILDER_MD"
git commit -m "$(cat <<EOF
Release $TAG

Bump version to $VERSION and stamp changelog.
EOF
)"

# --- 4. Tag and push ---
git tag "$TAG"
git push origin main
git push origin "$TAG"

# --- 5. GitHub release ---
gh release create "$TAG" \
  --title "$TAG" \
  --notes "$UNRELEASED_CONTENT"

echo ""
echo "Done — https://github.com/tomaspozo/agentlink/releases/tag/$TAG"
