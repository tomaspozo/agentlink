---
name: cli
description: AgentLink CLI usage, project scaffolding, updates, and migration management. Use when the task involves running agentlink commands, managing migrations, troubleshooting db diff issues, fixing migration files, or understanding the relationship between schema files and migrations.
---

# CLI

The `create-agentlink` CLI scaffolds new Supabase projects and updates existing ones. It handles infrastructure setup, template files, database configuration, and migration generation.

> **Workflow playbook:** see `references/workflows.md` for common user scenarios — "start a new project from zero," "add a prod env," "deploy to prod," "recover from a failed deploy," etc. Each entry lists what questions to ask the user and which commands to run.

---

## Prerequisites

AgentLink does NOT install its own tooling. Users install Claude Code + Supabase CLI separately via the setup script at **https://agentlink.sh/start**. The CLI validates these are present and points users at the setup script if they're missing; it never tries to `curl | bash` anything itself. Same pattern as `psql`: validate, point at the install, don't auto-install. This is intentional — mixing tooling installation into scaffold meant every platform-specific install failure surfaced mid-scaffold with no context.

If a user hits `Claude Code not found on PATH` or `Supabase CLI not found`, the remediation is always:

```bash
# macOS / Linux
curl -sSf https://agentlink.sh/start | sh

# Windows (PowerShell)
iwr https://agentlink.sh/start | iex
```

Then open a new terminal (so PATH is reloaded) and retry.

---

## Commands

### Scaffold a new project

```bash
npx create-agentlink@latest <name>       # interactive — handles login + project creation
npx create-agentlink@latest .            # scaffold in current directory
```

Creates template files, config, schema files, frontend (React + Vite by default, Next.js with `--nextjs`), configures Claude Code, and installs the plugin + companion skills. Cloud is the default — the wizard prompts for Supabase OAuth (browser), org selection, and region.

### Scaffold without env creation (`--skip-env`)

```bash
npx create-agentlink@latest <name> --skip-env
```

**This is the canonical path when an AGENT is doing the scaffolding.** Writes all files, installs frontend + backend deps, configures Claude Code, installs the plugin + companion skills — but **skips every Supabase-touching step**: no OAuth (needs a browser), no project creation, no local Docker, no `.env.local` credentials, no edge-function deploy.

After scaffold completes, the user finishes setup by running this in a terminal:

```bash
npx create-agentlink@latest env add dev
```

That step does the browser OAuth, creates/links the cloud project, provisions schema + edge functions, and populates `.env.local`. The scaffolded `CLAUDE.md` surfaces this as a prominent "▶ Next step" callout at the top.

Mutually exclusive with `--local` and `--link` — all three imply different intents about env creation, so the CLI errors out if combined. Use `--skip-env` specifically for agent-driven flows; use `--link` when you already have credentials; use `--local` when the user wants a local Docker env now.

### Scaffold with `--link` (non-interactive)

```bash
npx create-agentlink@latest <name> --link \
  --project-ref <ref> \
  --db-url "<db_url>" \
  --api-url "<api_url>" \
  --publishable-key "<anon_key>" \
  --secret-key "<service_role_key>"
```

Scaffolds files + connects to an existing Supabase project + applies the full SQL setup in one step. No interactive prompts, no `supabase login`. Use when connection details are already known (e.g., from the Supabase connector MCP). Not compatible with `--skip-env` — `--link` creates an env now, `--skip-env` defers it.

### Scaffold in an existing project

```bash
cd my-project && npx create-agentlink@latest .
```

Detects the existing directory and integrates AgentLink into it. Requires a clean git working tree.

### Update an existing project

```bash
npx create-agentlink@latest --force-update
```

Re-applies template files, patches `config.toml`, runs SQL setup, and regenerates migrations if schemas changed. Use after a CLI version upgrade or when `check` reports missing components.

### Diagnose

```bash
npx create-agentlink@latest check            # Check default environment
npx create-agentlink@latest check --env dev  # Check specific environment
```

Outputs JSON with `ready`, `supabase_running`, `database` (extensions, queues, functions, secrets, api_schema), and `files`. Read-only — reports problems but does not fix them.

### Component info

```bash
npx create-agentlink@latest info          # Summary list
npx create-agentlink@latest info <name>   # Detail for one component
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
| `--skip-env` | Scaffold files only — skip all Supabase setup (OAuth, project creation, Docker). User runs `agentlink env add dev` after. **Use for agent-driven scaffolding.** Mutually exclusive with `--local` / `--link`. |
| `--force-update` | Force update even if project is up to date |
| `--link` | Non-interactive scaffold + link (requires `--project-ref`, `--db-url`, `--api-url`, `--publishable-key`, `--secret-key`). Mutually exclusive with `--skip-env`. |
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
npx create-agentlink@latest db apply                    # Auto-detects DB from .env.local
npx create-agentlink@latest db apply --env dev          # Target specific environment
npx create-agentlink@latest db apply --db-url "postgresql://..."  # Explicit DB URL
```

### Run SQL

```bash
npx create-agentlink@latest db sql "SELECT * FROM public.profiles LIMIT 5"
npx create-agentlink@latest db sql "SELECT 1" --env dev
npx create-agentlink@latest db sql "SELECT 1" --json    # JSON output (cloud only)
```

### Generate types

```bash
npx create-agentlink@latest db types                    # Auto-detects output path
npx create-agentlink@latest db types --env dev          # From specific environment
npx create-agentlink@latest db types --output types/db.ts  # Custom output path
```

### Generate migration

```bash
npx create-agentlink@latest db migrate add_charts       # From default DB
npx create-agentlink@latest db migrate add_charts --env dev
```

### Set database password

```bash
npx create-agentlink@latest db password                  # Interactive: shows dashboard reset link + prompts
npx create-agentlink@latest db password "newpassword"    # Non-interactive: sets directly
```

Shows or sets the database password for the active cloud project. The password is stored in `~/.config/agentlink/credentials.json` (per project ref). Use when the DB password was reset in the Supabase dashboard.

---

## Database Recovery

### Database rebuild

```bash
npx create-agentlink@latest db rebuild
```

Nukes all migration files, re-applies schemas via pgdelta, and regenerates a single clean migration file. For recovering from broken migration state on new projects (duplicate migrations, failed pushes, timestamp conflicts). Does not recreate the Supabase project — only resets the migration layer.

### Database URL check

```bash
npx create-agentlink@latest db url        # Show correct pooler URL from Supabase API
npx create-agentlink@latest db url --fix  # Also update .env.local if it's wrong
```

Fetches the real pooler DB URL from the Supabase Management API (Supavisor, IPv4-compatible, transaction mode) and compares it with the value stored in `.env.local`. Use when `db apply` or `db sql` fails with connection errors.

---

## Migration System

### Development vs Deployment

**During development**, the agent only uses `db apply`. Schema files are the source of truth — the agent writes SQL, applies it, and keeps building. No migrations are generated during development.

**For deployment**, `env deploy` runs `db apply` + `functions deploy` against the chosen env — no migration file is generated. Migrations are a separate concern: they are a deployment *artifact* you create explicitly when you want an auditable change record (e.g., for change review, rollback planning, or CI that replays migration history).

```bash
# Development — the agent's loop
npx create-agentlink@latest db apply

# Deployment — apply current schemas + edge functions to a cloud env
npx create-agentlink@latest env deploy dev
npx create-agentlink@latest env deploy prod      # Prompts y/N confirm

# Optional — when the user explicitly asks for a migration artifact
npx create-agentlink@latest db migrate descriptive_name
npx supabase db push                              # Push the generated migration
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

### Scaffold flow (`--skip-env` — agent-driven)

```
1. Write template files, config, frontend, migrations
2. Skip: Supabase OAuth, project creation, Docker start, SQL apply,
         migrations push, edge-functions deploy, vault secrets,
         PostgREST/auth config, .env.local Supabase block
3. Install frontend + backend deps (npm install in user's project dir)
4. Configure Claude Code (pending-env CLAUDE.md mode, Next-step callout)
5. Install plugin + companion skills
6. User runs `agentlink env add dev` in a terminal to finish setup
```

Output is a complete scaffolded repo with no env yet — the user's browser OAuth happens in the `env add dev` step afterward.

### Update flow

```
1. Write new template migrations (if any)
2. migration repair            ← mark new templates as applied
3. db apply                    ← apply schema files via pgdelta
4. db migrate update_name      ← generate migration from schema diff
```

---

## Deployment

### Deploy

```bash
npx create-agentlink@latest env deploy                      # Interactive picker — preselects cloud.default
npx create-agentlink@latest env deploy dev                  # → targets dev
npx create-agentlink@latest env deploy prod                 # → targets prod (requires y/N confirm)
npx create-agentlink@latest env deploy prod --yes           # Skip the prod confirm (CI)
npx create-agentlink@latest env deploy prod --yes --non-interactive  # Full CI form
npx create-agentlink@latest env deploy dev --dry-run        # Print target without applying
```

`env deploy` is a **thin two-step operation**: (1) apply local schemas to the target env's database via `db apply`, (2) deploy `supabase/functions/*` to that env. It is idempotent (re-running is safe), does NOT generate a migration file, and does NOT mutate `manifest.cloud.default` (deploy is a one-shot action — `env use dev && env deploy prod` stays on dev afterwards).

Things `env deploy` deliberately does NOT do (belong elsewhere):

- **Vault secrets / PostgREST config / auth config.** These are applied during `env add` (initial bootstrap). If any of those changed, use `env add <name>` → "Re-apply full setup" or `agentlink config apply`.
- **Migration file generation.** Use `db migrate <name>` explicitly when you want an auditable artifact.
- **Clean-tree gate.** `db apply` is idempotent, so running against a dirty tree is safe; the only reviewability loss is at the migration-diff level, which `env deploy` doesn't generate anyway.
- **Data-risk analysis.** That was tied to the migration diff; use `db migrate` + review the generated SQL when you want it.

**The top-level `agentlink deploy` command has been removed.** The CLI intercepts `agentlink deploy` and `agentlink retry-deploy` with an error pointing at the new verb. CI workflows using `deploy --prod` / `deploy --ci` must migrate to `env deploy <name> --yes --non-interactive` (the `env add --setup-ci` generator emits the new form).

**The agent does not deploy.** Deployment is initiated by the developer. When users ask to deploy, point them to `agentlink env deploy` (interactive picker) or `agentlink env deploy <dev|prod>` (explicit target).

### Environment management

AgentLink enforces a **fixed three-environment model**: `local`, `dev`, `prod`. Nothing else is accepted.

| Env | Meaning | Created by |
|-----|---------|-----------|
| `local` | Local Docker Supabase | `agentlink env use local` (switches to it; the Docker stack itself is `supabase start`) |
| `dev` | The cloud development env | `agentlink env add dev` |
| `prod` | The cloud production env | `agentlink env add prod` |

Attempts to add `staging`, `dev2`, `production`, etc. fail with a clear error. Legacy manifests carrying off-model names are blocked at command entry with an `env remove` hint. Inspection commands (`env list`, `env remove`) remain permissive so users can see and clean up legacy entries.

```bash
# Interactive pickers — all three accept no-name and show a selector
npx create-agentlink@latest env add                         # Picker: dev / prod (linked / not linked)
npx create-agentlink@latest env use                         # Picker: local (if relevant) / dev / prod
npx create-agentlink@latest env deploy                      # Picker: registered cloud envs, preselects cloud.default

# Explicit
npx create-agentlink@latest env add dev                     # Add/relink the cloud dev env
npx create-agentlink@latest env add prod                    # Add the prod env
npx create-agentlink@latest env use local                   # Switch active env to local Docker
npx create-agentlink@latest env use dev                     # Switch active env to cloud dev
npx create-agentlink@latest env use prod                    # Switch to prod (y/N confirm required)
npx create-agentlink@latest env list                        # Show all environments + their orgs
npx create-agentlink@latest env remove <name>               # Remove an env (offers to forget its DB password too)

# Non-interactive (for agents / CI)
npx create-agentlink@latest env add prod --project-ref <ref> --non-interactive
npx create-agentlink@latest env add dev  --project-ref <ref> --non-interactive   # Relinks dev if it exists
npx create-agentlink@latest env deploy prod --yes --non-interactive              # CI-friendly deploy
npx create-agentlink@latest env remove staging -y                                # Legacy cleanup allowed

# Recovery
npx create-agentlink@latest env add dev --retry             # Re-apply full setup (schemas, functions, secrets, PostgREST + auth) if a previous deploy died mid-way
```

`env use <name>` rewrites the managed block of `.env.local` so downstream `db apply` / `functions serve` / `db sql` hit the right env, and persists `manifest.cloud.default` so every subsequent command resolves the same target. User-added variables outside the block are preserved.

`env use prod` is **allowed** but gated behind an amber warning + y/N confirmation (defaults to No):

```
▲ Using prod as your active dev environment is NOT recommended.
  Your .env.local will point at production — any app or test you run
  locally will hit real data.
? Continue? (y/N)
```

After confirming, every subsequent `env deploy` / `db apply` / `db sql` / `db rebuild` prints an `▲ Active env: prod` banner at the top as a persistent reminder across terminals and agent sessions.

`env add <name>` handles both new environments and relinking existing ones. When the env already exists, a recovery prompt offers three actions: **Re-apply full setup** (re-runs bootstrap — schemas, functions, secrets, PostgREST + auth config — against the same project; for mid-deploy failures or config changes), **Relink to a different Supabase project** (for deleted/wrong projects), or **Cancel**. The picker shows a dim hint above: *"If you just changed schemas or functions, cancel and run `agentlink env deploy <name>` instead."* — steering users away from the heavier full-setup when the lighter deploy would do. `--retry` triggers the full-setup path non-interactively; `--project-ref <ref>` triggers relink.

`env add` / `env relink` run an **org-first picker** — the user picks the Supabase organization BEFORE the connect-existing-vs-create-new choice, so both paths browse the correct org's projects. The picker merges API-visible orgs with cached orgs from previous logins and offers "+ Authorize a different organization…" to add a new one. On token validation failure (401/403 — org membership revoked, integration restrictions), the CLI surfaces "▲ Stored credentials for \<org\> are no longer accepted" and kicks off re-auth automatically.

Initial project link can also be done during scaffold with the `--link` flag — see "Scaffold with `--link`" above.

> `env relink` still works as a deprecated alias and prints a warning. Prefer `env add`.

### Picker visibility rules

The three env pickers behave slightly differently:

- **`env add` picker** lists `dev` and `prod`. Each row is annotated `— linked to <projectRef>` or `— not linked`. Selecting a linked env cascades into the 3-way recovery prompt (Re-apply / Relink / Cancel).
- **`env use` picker** lists cloud envs in the manifest with a ✓ next to the active one. Envs not yet in the manifest are disabled with a `run env add <name> first` hint. **`local` only appears when relevant**: it shows up when (a) local is already the active env, or (b) the project was scaffolded in local mode. Cloud-only projects won't see `local` as an option (explicit `agentlink env use local` still works if forced).
- **`env deploy` picker** lists every registered cloud env and preselects `cloud.default` (when it's a cloud env). Throws a clear error with an `env add` hint if no cloud env is registered.

### Clean-tree gate

`env add`, `env relink`, and `--force-update` abort if the git working tree is dirty — rollback on a dirty tree mixes user changes with AgentLink's writes and is painful to untangle. Bypass with `--allow-dirty` when needed. **`env deploy` does NOT gate on a clean tree** — `db apply` is idempotent, so re-running against a dirty tree is safe.

---

## Multi-org credentials

Supabase OAuth tokens are **scoped to a single organization** — the consent screen in the browser picks one. AgentLink stores per-org credentials so a user working across multiple orgs (dev in org A, prod in org B) doesn't overwrite one with the other on every re-auth.

**Where credentials live**: `~/.config/agentlink/credentials.json`, with the active tokens keyed by org ID under `oauth_by_org`. Each entry carries its own access token, refresh token, expiry, and cached org name/slug. A legacy single-org `oauth` slot is still read for back-compat; a PAT (`supabase_access_token`) set via `agentlink sb token set` is the final fallback for CI.

**Where org IDs live on disk**: each `CloudEnvironment` in `agentlink.json` carries an optional `orgId`. Populated on `env add`, lazily backfilled on older manifests when `env add`/`env relink`/`env use` runs (and when `env add <name>` triggers the internal retry flow for recovery) — the CLI walks stored org tokens, probes `GET /v1/projects` for each, matches returned project IDs against envs missing `orgId`, and persists the match. Silent when nothing to do (no API calls if all envs already have `orgId`).

**CI**: set `SUPABASE_ACCESS_TOKEN` as a repo secret — a static PAT with admin access to the relevant org. OAuth is never triggered in CI.

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

- **[Workflows](./references/workflows.md)** — Common user scenarios as a flow-by-flow playbook: start a new project from zero, add prod, switch envs, deploy, recover from a failed deploy. Each entry lists the user trigger, questions to ask, commands to run, and watch-outs.
- **[Migration System](./references/migration_system.md)** — Deep dive: two-tier migrations, how db diff works, adding extensions
- **[Troubleshooting](./references/troubleshooting.md)** — Common errors and manual fixes
