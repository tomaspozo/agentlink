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
CHANGELOG="$REPO_ROOT/CHANGELOG.md"

# --- Parse arguments ---
VERSION="${1:-}"
DRY_RUN=false
if [[ "${2:-}" == "--dry-run" ]]; then
  DRY_RUN=true
fi

if [[ -z "$VERSION" ]]; then
  echo "Usage: ./scripts/release.sh <version> [--dry-run]" >&2
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
  echo "Error: no content under [Unreleased] in CHANGELOG.md" >&2
  exit 1
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
  echo "  3. Bump plugin.json to $VERSION"
  echo "  4. Commit, tag $TAG, push, create GitHub release"
  exit 0
fi

# --- Confirm ---
read -rp "Release $TAG? [y/N] " confirm
if [[ "$confirm" != [yY] ]]; then
  echo "Aborted"
  exit 0
fi

cd "$REPO_ROOT"

# --- 1. Stamp changelog ---
# Replace "## [Unreleased]" with the new version header, and add a fresh [Unreleased] above it
sed -i '' "s/^## \[Unreleased\]/## [Unreleased]\n\n## [$VERSION] - $TODAY/" "$CHANGELOG"

# --- 2. Bump plugin.json ---
jq --arg v "$VERSION" '.version = $v' "$PLUGIN_JSON" > "$PLUGIN_JSON.tmp" && mv "$PLUGIN_JSON.tmp" "$PLUGIN_JSON"

# --- 3. Commit ---
git add "$CHANGELOG" "$PLUGIN_JSON"
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
echo "Done — https://github.com/agentlinksh/agent/releases/tag/$TAG"
