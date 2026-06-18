#!/usr/bin/env bash
# PreToolUse hook: block destructive Supabase database commands.
#
# Blocked commands:
#   npx supabase db reset       — destroys and recreates the local database
#   npx agentlink-sh db rebuild — resets the local DB (replays migrations) then
#                                 re-applies; same destructive reset, wrapped
#   npx supabase db push --force / -f — overwrites remote schema without diffing
#
# Exit codes:
#   0 — command is allowed
#   2 — command is blocked (message fed back to Claude)
#
# Rule source: skills/database/references/workflow.md
#   "The database is never reset unless the user explicitly requests it."

set -euo pipefail

# Read hook JSON from stdin
input=$(cat)

# Extract the Bash command from tool_input.command
command=$(echo "$input" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(data.get('tool_input', {}).get('command', ''))
" 2>/dev/null)

if [[ -z "$command" ]]; then
  exit 0
fi

# Normalize: collapse multiline commands into a single line for matching
normalized=$(echo "$command" | tr '\n' ' ' | sed 's/  */ /g')

# Block the destructive reset in any form — a raw `supabase db reset` AND the
# `agentlink db rebuild` wrapper (which runs `supabase db reset` internally),
# with npx / path / @latest prefixes and any flags. Blocking the wrapper too
# keeps the "resets are user-initiated" rule from being bypassed. Matches even
# inside chained commands (&&, ;, |) by checking the whole string.
if echo "$normalized" | grep -qE '(^|[;&|]|[[:space:]])([^[:space:]]*supabase[[:space:]]+db[[:space:]]+reset|agentlink[^[:space:]]*[[:space:]]+db[[:space:]]+rebuild)([[:space:]]|$)'; then
  echo "BLOCKED: this resets and recreates the local database (destroys its data)." >&2
  echo "" >&2
  echo "Rule: \"The database is never reset unless the user explicitly requests it.\"" >&2
  echo "Source: skills/database/references/workflow.md" >&2
  echo "" >&2
  echo "Alternative: fix errors with more SQL (psql), or 'db apply' to converge dev." >&2
  echo "If the user explicitly asked to reset, have them run it manually:" >&2
  echo "  npx agentlink-sh@latest db rebuild" >&2
  echo "(replays migrations, re-applies schema files, and restores the imperative" >&2
  echo " resources — rbac, cron, storage — that a raw 'supabase db reset' drops.)" >&2
  exit 2
fi

# Block: supabase db push --force or -f
if echo "$normalized" | grep -qE 'supabase[[:space:]]+db[[:space:]]+push[[:space:]]' && \
   echo "$normalized" | grep -qE 'supabase[[:space:]]+db[[:space:]]+push[[:space:]]+.*(-f|--force)([[:space:]]|$)'; then
  echo "BLOCKED: 'npx supabase db push --force' overwrites the remote schema without diffing." >&2
  echo "" >&2
  echo "Rule: \"The database is never reset unless the user explicitly requests it.\"" >&2
  echo "Source: skills/database/references/workflow.md" >&2
  echo "" >&2
  echo "Alternative: Use 'npx supabase db push' (without --force) to diff and apply safely." >&2
  exit 2
fi

exit 0
