---
name: cli
description: AgentLink CLI usage, project scaffolding, updates, and migration management. Use when the task involves running agentlink commands, managing migrations, troubleshooting db diff issues, fixing migration files, or understanding the relationship between schema files and migrations.
---

# CLI

The `@agentlink.sh/cli` CLI scaffolds new Supabase projects and updates existing ones. It handles infrastructure setup, template files, database configuration, and migration generation.

---

## Commands

### Scaffold a new project

```bash
npx @agentlink.sh/cli@latest <name>       # interactive — handles login + project creation
npx @agentlink.sh/cli@latest .            # scaffold in current directory
```

Creates template files, config, schema files, frontend (React + Vite by default, Next.js with `--nextjs`), configures Claude Code, and installs the plugin + companion skills.

### Scaffold with `--link` (non-interactive)

```bash
npx @agentlink.sh/cli@latest <name> --link \
  --project-ref <ref> \
  --db-url "<db_url>" \
  --api-url "<api_url>" \
  --publishable-key "<anon_key>" \
  --secret-key "<service_role_key>"
```

Scaffolds files + connects to an existing Supabase project + applies the full SQL setup in one step. No interactive prompts, no `supabase login`. Use when connection details are already known (e.g., from the Supabase connector MCP).

### Scaffold in an existing project

```bash
cd my-project && npx @agentlink.sh/cli@latest .
```

Detects the existing directory and integrates AgentLink into it. Requires a clean git working tree.

### Update an existing project

```bash
npx @agentlink.sh/cli@latest --force-update
```

Re-applies template files, patches `config.toml`, runs SQL setup, and regenerates migrations if schemas changed. Use after a CLI version upgrade or when `check` reports missing components.

### Diagnose

```bash
npx @agentlink.sh/cli@latest check            # Check default environment
npx @agentlink.sh/cli@latest check --env dev  # Check specific environment
```

Outputs JSON with `ready`, `supabase_running`, `database` (extensions, queues, functions, secrets, api_schema), and `files`. Read-only — reports problems but does not fix them.

### Component info

```bash
npx @agentlink.sh/cli@latest info          # Summary list
npx @agentlink.sh/cli@latest info <name>   # Detail for one component
```

Shows type, summary, description, signature, and related components. Use to understand what a missing component does.

### Flags

| Flag | Effect |
|------|--------|
| `--no-skills` | Skip companion skill installation |
| `--nextjs` | Use Next.js instead of Vite for frontend |
| `--no-frontend` | Skip frontend scaffolding (backend only) |
| `--no-launch` | Skip launching Claude Code after scaffold |
| `-y, --yes` | Auto-confirm all prompts |
| `--local` | Use local Docker instead of Supabase Cloud (cloud is default) |
| `--force-update` | Force update even if project is up to date |
| `--link` | Non-interactive scaffold + link (requires `--project-ref`, `--db-url`, `--api-url`, `--publishable-key`, `--secret-key`) |
| `--project-ref <ref>` | Supabase project reference ID (used with `--link`) |
| `--db-url <url>` | Database connection URL (used with `--link`) |
| `--api-url <url>` | Supabase API URL (used with `--link`) |
| `--publishable-key <key>` | Supabase publishable/anon key (used with `--link`) |
| `--secret-key <key>` | Supabase secret/service role key (used with `--link`) |
| `--prompt <prompt>` | What to build (passed to Claude Code on launch) |
| `--resume` | Resume a previously failed scaffold |
| `--non-interactive` | Error instead of prompting when info is missing |
| `--debug` | Write detailed log to `agentlink-debug.log` |

---

## Database Operations

### Apply schemas

```bash
npx @agentlink.sh/cli@latest db apply                    # Auto-detects DB from .env.local
npx @agentlink.sh/cli@latest db apply --env dev          # Target specific environment
npx @agentlink.sh/cli@latest db apply --db-url "postgresql://..."  # Explicit DB URL
```

### Run SQL

```bash
npx @agentlink.sh/cli@latest db sql "SELECT * FROM public.profiles LIMIT 5"
npx @agentlink.sh/cli@latest db sql "SELECT 1" --env dev
npx @agentlink.sh/cli@latest db sql "SELECT 1" --json    # JSON output (cloud only)
```

### Generate types

```bash
npx @agentlink.sh/cli@latest db types                    # Auto-detects output path
npx @agentlink.sh/cli@latest db types --env dev          # From specific environment
npx @agentlink.sh/cli@latest db types --output types/db.ts  # Custom output path
```

### Generate migration

```bash
npx @agentlink.sh/cli@latest db migrate add_charts       # From default DB
npx @agentlink.sh/cli@latest db migrate add_charts --env dev
```

### Set database password

```bash
npx @agentlink.sh/cli@latest db password                  # Interactive: shows dashboard reset link + prompts
npx @agentlink.sh/cli@latest db password "newpassword"    # Non-interactive: sets directly
```

Shows or sets the database password for the active cloud project. The password is stored in `~/.config/agentlink/credentials.json` (per project ref). Use when the DB password was reset in the Supabase dashboard.

---

## Database Recovery

### Database rebuild

```bash
npx @agentlink.sh/cli@latest db rebuild
```

Nukes all migration files, re-applies schemas via pgdelta, and regenerates a single clean migration file. For recovering from broken migration state on new projects (duplicate migrations, failed pushes, timestamp conflicts). Does not recreate the Supabase project — only resets the migration layer.

### Database URL check

```bash
npx @agentlink.sh/cli@latest db url        # Show correct pooler URL from Supabase API
npx @agentlink.sh/cli@latest db url --fix  # Also update .env.local if it's wrong
```

Fetches the real pooler DB URL from the Supabase Management API (Supavisor, IPv4-compatible, transaction mode) and compares it with the value stored in `.env.local`. Use when `db apply` or `db sql` fails with connection errors.

---

## Migration System

### Development vs Deployment

**During development**, the agent only uses `db apply`. Schema files are the source of truth — the agent writes SQL, applies it, and keeps building. No migrations are generated during development.

**For deployment**, migrations capture changes for promotion to other environments (staging, production). They are generated only when the user explicitly asks.

```bash
# Development — the agent's loop
npx @agentlink.sh/cli@latest db apply

# Deployment — when the user asks for a migration
npx @agentlink.sh/cli@latest db migrate descriptive_name

# Cloud deployment — push after generating
npx supabase db push
```

### How migrations work

The CLI uses a **two-tier migration system** because `npx supabase db diff` cannot capture everything.

**Tier 1: Template migrations (hand-crafted)** — Pre-written SQL files embedded in the CLI. Two categories:

- **Pre-start migrations** — Extensions, schema creation (`api` schema + grants). Applied automatically by `npx supabase start`.
- **Post-setup migrations** — Queues (`pgmq.create()` uses DO blocks), auth triggers (on `auth.users`). Marked as applied via `npx supabase migration repair`.

**Tier 2: Application migrations (generated by `pgdelta`)** — Captures everything in `public` and `api` schemas: tables, functions, indexes, policies, triggers. Uses `pgdelta` instead of `npx supabase db diff` to avoid alphabetical ordering issues with cross-file FK references.

### Scaffold flow (interactive)

```
1. Interactive wizard — login, project creation, region selection
2. Write template files, config, frontend, migrations
3. Start Supabase (local) or create cloud project
4. Apply SQL, generate application migration
5. Write post-setup migrations, mark as applied
6. Configure Claude Code, install plugin + skills
```

### Scaffold flow (`--link`)

```
1. Write template files, config, frontend, migrations
2. Connect to existing Supabase project using provided flags
3. Link project (supabase link --project-ref)
4. Push all migrations (pre-start + application + post-setup)
5. Store vault secrets, set edge function secrets
6. Deploy edge functions, configure PostgREST + auth
7. Configure Claude Code, install plugin + skills
```

No interactive prompts. All connection details come from `--link` flags.

### Update flow

```
1. Write new template migrations (if any)
2. migration repair            ← mark new templates as applied
3. db apply                    ← apply schema files via pgdelta
4. db migrate update_name      ← generate migration from schema diff
```

---

## Deployment

### Deploy to production

```bash
npx @agentlink.sh/cli@latest deploy                          # Interactive — diff, validate, push
npx @agentlink.sh/cli@latest deploy --dry-run                # Preview without applying
npx @agentlink.sh/cli@latest deploy --env staging            # Target a specific environment
npx @agentlink.sh/cli@latest deploy --ci                     # Non-interactive for CI/CD
npx @agentlink.sh/cli@latest deploy --ci --allow-warnings    # CI: proceed past data-risk warnings
npx @agentlink.sh/cli@latest deploy --setup-ci               # Scaffold GitHub Actions workflow
```

The `deploy` command:
1. Diffs dev database schema against the target environment
2. Generates and saves a migration file to `supabase/migrations/`
3. Validates the migration (schema-only test)
4. Analyzes for data risks (DROP TABLE, NOT NULL without DEFAULT, etc.)
5. Pushes: migration + all edge functions + missing secrets

**The agent does not deploy.** Deployment is initiated by the developer. When users ask about deploying, point them to `agentlink deploy`.

### Environment management

```bash
# Interactive
npx @agentlink.sh/cli@latest env add prod                # Connect a production cloud project
npx @agentlink.sh/cli@latest env add dev                 # Add a cloud dev environment
npx @agentlink.sh/cli@latest env use local               # Switch to local Docker for dev
npx @agentlink.sh/cli@latest env use dev                 # Switch to cloud dev
npx @agentlink.sh/cli@latest env list                    # Show all environments
npx @agentlink.sh/cli@latest env relink dev              # Relink dev to a new project (keeps migrations)
npx @agentlink.sh/cli@latest env remove staging          # Remove an environment

# Non-interactive (for agents / CI)
npx @agentlink.sh/cli@latest env add prod --project-ref <ref> --non-interactive
npx @agentlink.sh/cli@latest env relink dev --project-ref <ref> --non-interactive
npx @agentlink.sh/cli@latest env remove staging -y
```

The initial project link can also be done during scaffold with the `--link` flag — see "Scaffold with `--link`" above.

`env use` switches the active dev environment by rewriting the managed section of `.env.local`. User-added variables are preserved across switches. `env use prod` is blocked — use `deploy` instead.

`env relink` connects an environment to a new Supabase project while keeping all existing migrations intact. Used when the cloud project was deleted, the DB URL is wrong, or you need to point at a different project. It updates credentials, `.env.local`, links, pushes all migrations, and deploys edge functions.

---

## Schema Files vs Migrations

**Schema files** (`supabase/schemas/`) are the source of truth for application SQL. They use idempotent patterns (`CREATE OR REPLACE`, `IF NOT EXISTS`) and are applied via `psql`. The agent writes and modifies these during development.

**Migrations** (`supabase/migrations/`) are the deployment record for production. They are generated by `db diff`, which compares the live database against a shadow database built from existing migrations + `schema_paths`.

The `schema_paths` setting in `config.toml` tells `db diff` where to find schema files:

```toml
[db.migrations]
schema_paths = ["./schemas/_schemas.sql", "./schemas/_extensions.sql", "./schemas/**/*.sql"]
```

`db diff` bridges the two: it reads schema files to know the desired state, replays migrations on a shadow DB for the current state, and outputs the delta.

---

## When to Fix Manually

The CLI handles most cases, but if it fails or produces incorrect results, the agent can intervene:

1. **Write a migration file directly** — Create `supabase/migrations/<timestamp>_<name>.sql` with the correct SQL
2. **Mark it as applied** — `npx supabase migration repair <version> --status applied --local` (or `--linked` for cloud)
3. **Apply SQL via psql** — `psql <db_url> -c "SQL"` or pipe a schema file
4. **Fix a broken migration** — Edit the file in `supabase/migrations/`, then repair

Always prefer the CLI (`--force-update`) first. Only fix manually when the CLI can't handle the situation.

---

## Reference Files

- **[Migration System](./references/migration_system.md)** — Deep dive: two-tier migrations, how db diff works, adding extensions
- **[Troubleshooting](./references/troubleshooting.md)** — Common errors and manual fixes
