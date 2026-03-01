#!/usr/bin/env bash
# PreToolUse hook: block destructive Supabase database commands.
#
# Blocked commands:
#   supabase db reset   — destroys and recreates the local database
#   supabase db push --force / -f — overwrites remote schema without diffing
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

# Block: supabase db reset (with any flags)
# Matches even inside chained commands (&&, ;, |) by checking the whole string
if echo "$normalized" | grep -qE '(^|[;&|])[[:space:]]*(supabase|[^[:space:]]*supabase)[[:space:]]+db[[:space:]]+reset([[:space:]]|$)'; then
  echo "BLOCKED: 'supabase db reset' destroys and recreates the local database." >&2
  echo "" >&2
  echo "Rule: \"The database is never reset unless the user explicitly requests it.\"" >&2
  echo "Source: skills/database/references/workflow.md" >&2
  echo "" >&2
  echo "Alternative: Fix errors with more SQL via psql." >&2
  echo "If the user explicitly asked for a reset, ask them to run it manually." >&2
  exit 2
fi

# Block: supabase db push --force or -f
if echo "$normalized" | grep -qE 'supabase[[:space:]]+db[[:space:]]+push[[:space:]]' && \
   echo "$normalized" | grep -qE 'supabase[[:space:]]+db[[:space:]]+push[[:space:]]+.*(-f|--force)([[:space:]]|$)'; then
  echo "BLOCKED: 'supabase db push --force' overwrites the remote schema without diffing." >&2
  echo "" >&2
  echo "Rule: \"The database is never reset unless the user explicitly requests it.\"" >&2
  echo "Source: skills/database/references/workflow.md" >&2
  echo "" >&2
  echo "Alternative: Use 'supabase db push' (without --force) to diff and apply safely." >&2
  exit 2
fi

exit 0
