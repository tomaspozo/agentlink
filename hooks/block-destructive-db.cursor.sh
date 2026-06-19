#!/usr/bin/env bash
# Cursor beforeShellExecution hook: block destructive Supabase database commands.
#
# This is the Cursor-format counterpart of block-destructive-db.sh (Claude Code).
# Same rule and same destructive-command matching; only the I/O contract differs:
#   - stdin: Cursor sends the command at the top-level `command` field
#            (Claude sends it at `tool_input.command`).
#   - block: Cursor expects exit 0 with a JSON {"permission":"deny", ...} on stdout
#            (Claude blocks with exit code 2 + a stderr message).
#
# Blocked commands:
#   npx supabase db reset       — destroys and recreates the local database
#   npx agentlink-sh db rebuild — resets the local DB (replays migrations) then
#                                 re-applies; same destructive reset, wrapped
#   npx supabase db push --force / -f — overwrites remote schema without diffing
#
# Rule source: skills/database/references/workflow.md
#   "The database is never reset unless the user explicitly requests it."

set -euo pipefail

# Read hook JSON from stdin
input=$(cat)

# Extract the shell command from the top-level `command` field
command=$(echo "$input" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(data.get('command', ''))
" 2>/dev/null)

if [[ -z "$command" ]]; then
  exit 0
fi

# Emit a Cursor deny verdict and exit 0. Builds JSON via python3 so the
# multi-line messages are escaped correctly.
deny() {
  AGENT_MSG="$1" USER_MSG="$2" python3 -c "
import os, json
print(json.dumps({
    'permission': 'deny',
    'agent_message': os.environ['AGENT_MSG'],
    'user_message': os.environ['USER_MSG'],
}))
"
  exit 0
}

# Normalize: collapse multiline commands into a single line for matching
normalized=$(echo "$command" | tr '\n' ' ' | sed 's/  */ /g')

# Block the destructive reset in any form — a raw `supabase db reset` AND the
# `agentlink db rebuild` wrapper (which runs `supabase db reset` internally),
# with npx / path / @latest prefixes and any flags. Blocking the wrapper too
# keeps the "resets are user-initiated" rule from being bypassed. Matches even
# inside chained commands (&&, ;, |) by checking the whole string.
if echo "$normalized" | grep -qE '(^|[;&|]|[[:space:]])([^[:space:]]*supabase[[:space:]]+db[[:space:]]+reset|agentlink[^[:space:]]*[[:space:]]+db[[:space:]]+rebuild)([[:space:]]|$)'; then
  deny \
"BLOCKED: this resets and recreates the local database (destroys its data).

Rule: \"The database is never reset unless the user explicitly requests it.\"
Source: skills/database/references/workflow.md

Alternative: fix errors with more SQL (psql), or 'db apply' to converge dev.
If the user explicitly asked to reset, have them run it manually:
  npx agentlink-sh@latest db rebuild
(replays migrations, re-applies schema files, and restores the imperative
 resources — rbac, cron, storage — that a raw 'supabase db reset' drops.)" \
"Agent Link blocked a destructive database reset. Run it yourself in a terminal if you really need it: npx agentlink-sh@latest db rebuild"
fi

# Block: supabase db push --force or -f
if echo "$normalized" | grep -qE 'supabase[[:space:]]+db[[:space:]]+push[[:space:]]' && \
   echo "$normalized" | grep -qE 'supabase[[:space:]]+db[[:space:]]+push[[:space:]]+.*(-f|--force)([[:space:]]|$)'; then
  deny \
"BLOCKED: 'npx supabase db push --force' overwrites the remote schema without diffing.

Rule: \"The database is never reset unless the user explicitly requests it.\"
Source: skills/database/references/workflow.md

Alternative: Use 'npx supabase db push' (without --force) to diff and apply safely." \
"Agent Link blocked 'supabase db push --force'. Use 'npx supabase db push' (without --force) to diff and apply safely."
fi

exit 0
