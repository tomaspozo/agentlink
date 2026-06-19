---
name: cli
description: AgentLink CLI usage, project scaffolding, updates, and migration management. Use when the task involves running `npx agentlink-sh@latest` commands, managing migrations, troubleshooting db apply / db migrate issues, fixing migration files, or understanding the relationship between schema files and migrations.
---

# CLI

The `agentlink-sh` CLI scaffolds new Supabase projects and updates existing ones. It handles infrastructure setup, template files, database configuration, and migration generation. Every invocation runs through `npx agentlink-sh@latest` — there's no install step.

> **Workflow playbook:** see `references/workflows.md` for common user scenarios — "start a new project from zero," "add a prod env," "deploy to prod," "recover from a failed deploy," etc. Each entry lists what questions to ask the user and which commands to run.

---

## Prerequisites

AgentLink does NOT install its own tooling, and it does NOT require an AI coding agent (Claude Code or Cursor) to be on PATH in order to scaffold — it writes the project files and the editor config regardless, then you open the project in whichever agent you chose. What it _does_ need is the Supabase CLI (and `psql` for local Docker). It validates those and points users at the setup script at **https://agentlink.sh/start** if they're missing; it never tries to `curl | bash` anything itself. This is intentional — mixing tooling installation into scaffold meant every platform-specific install failure surfaced mid-scaffold with no context.

---

## Commands

### Scaffold a new project

```bash
npx agentlink-sh@latest <name>       # interactive — handles login + project creation
npx agentlink-sh@latest .            # scaffold in current directory
```

Creates template files, config, schema files, frontend (React + TanStack Start, SPA mode), configures your chosen agent editor (Claude Code and/or Cursor), and installs the companion skills (plus the plugin in Claude Code). Cloud is the default — the wizard prompts for Supabase OAuth (browser), org selection, and region. The wizard also asks which agent editor(s) to set up.

### Scaffold without env creation (`--skip-env`)

```bash
npx agentlink-sh@latest <name> --skip-env
```

**This is the canonical path when an AGENT is doing the scaffolding.** Writes all files, installs frontend + backend deps, configures the chosen agent editor (Claude Code and/or Cursor), installs the companion skills (plus the plugin in Claude Code) — but **skips every Supabase-touching step**: no OAuth (needs a browser), no project creation, no local Docker, no `.env.local` credentials, no edge-function deploy.

After scaffold completes, the user finishes setup by running this in a terminal:

```bash
npx agentlink-sh@latest env add dev
```

That step does the browser OAuth, creates/links the cloud project, provisions schema + edge functions, and populates `.env.local`. The scaffolded `AGENTS.md` surfaces this as a prominent "▶ Next step" callout at the top.

Mutually exclusive with `--local` and `--link` — all three imply different intents about env creation, so the CLI errors out if combined. Use `--skip-env` specifically for agent-driven flows; use `--link` when you already have credentials; use `--local` when the user wants a local Docker env now.

### Scaffold with `--link` (non-interactive)

```bash
npx agentlink-sh@latest <name> --link \
  --project-ref <ref> \
  --db-url "<db_url>" \
  --api-url "<api_url>" \
  --publishable-key "<anon_key>" \
  --secret-key "<service_role_key>"
```

Scaffolds files + connects to an existing Supabase project + applies the full SQL setup in one step. No interactive prompts, no `supabase login`. Use when connection details are already known (e.g., from the Supabase connector MCP). Not compatible with `--skip-env` — `--link` creates an env now, `--skip-env` defers it.

### Scaffold in an existing project

```bash
cd my-project && npx agentlink-sh@latest .
```

Detects the existing directory and integrates AgentLink into it. Requires a clean git working tree.

### Bare mode — env management without the full scaffold

For users who want Supabase env plumbing (OAuth, project create/select, `.env.local` wiring) but NOT the AgentLink scaffold (schemas, RLS helpers, RPC layout, skills), running `env add` in a non-scaffolded directory opts into **bare mode**:

```bash
cd my-existing-app
npx agentlink-sh@latest env add dev
# → "No agentlink.json found" menu with three choices:
#     - Run the full AgentLink scaffold (recommended) → exits, tells user to run `npx agentlink-sh@latest`
#     - Continue without full features → writes a minimal agentlink.json, runs the Supabase flow
#     - Cancel
```

If the user picks "Continue without full features," the CLI writes a minimal `agentlink.json` with `bare: true` and runs the full Supabase flow (OAuth → org pick → project create/select → credentials → `.env.local`). **No schemas applied, no server-side config (vault / PostgREST / auth hooks), no `AGENTS.md` touched** — the user's file is theirs. `env use` / `env add` / `env relink` all skip `writeAgentsMd` in bare mode.

What works in bare mode: `env add`/`use`/`remove`/`list`, `env config [secrets|db|auth|all]`, `db password`, `db url`. What's a no-op until the user adds content: `db apply` (skips with "supabase/database/ not found"), `env deploy` (picks up migrations/schemas/functions incrementally as they appear).

Upgrade path: `npx agentlink-sh@latest --force-update` converts a bare project to the full scaffold.

### Update an existing project

```bash
npx agentlink-sh@latest --force-update
```

Re-applies template files, patches `config.toml`, runs SQL setup, and regenerates migrations if schemas changed. Use after a CLI version upgrade or when `check` reports missing components.

### Diagnose

```bash
npx agentlink-sh@latest check            # Check default environment
npx agentlink-sh@latest check --env dev  # Check specific environment
```

Outputs JSON with `ready`, `supabase_running`, `database` (extensions, queues, functions, secrets, api_schema), and `files`. Read-only — reports problems but does not fix them.

### Component info

```bash
npx agentlink-sh@latest info          # Summary list
npx agentlink-sh@latest info <name>   # Detail for one component
```

Shows type, summary, description, signature, and related components. Use to understand what a missing component does.

### Flags

| Flag                      | Effect                                                                                                                                                                                                                      |
| ------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `--no-skills`             | Skip companion skill installation                                                                                                                                                                                           |
| `--no-frontend`           | Skip frontend scaffolding (backend only)                                                                                                                                                                                    |
| `-y, --yes`               | Auto-confirm all prompts                                                                                                                                                                                                    |
| `--local`                 | Use local Docker instead of Supabase Cloud (cloud is default)                                                                                                                                                               |
| `--skip-env`              | Scaffold files only — skip all Supabase setup (OAuth, project creation, Docker). User runs `npx agentlink-sh@latest env add dev` after. **Use for agent-driven scaffolding.** Mutually exclusive with `--local` / `--link`. |
| `--force-update`          | Force update even if project is up to date                                                                                                                                                                                  |
| `--link`                  | Non-interactive scaffold + link (requires `--project-ref`, `--db-url`, `--api-url`, `--publishable-key`, `--secret-key`). Mutually exclusive with `--skip-env`.                                                             |
| `--project-ref <ref>`     | Supabase project reference ID (used with `--link`)                                                                                                                                                                          |
| `--db-url <url>`          | Database connection URL (used with `--link`)                                                                                                                                                                                |
| `--api-url <url>`         | Supabase API URL (used with `--link`)                                                                                                                                                                                       |
| `--publishable-key <key>` | Supabase publishable/anon key (used with `--link`)                                                                                                                                                                          |
| `--secret-key <key>`      | Supabase secret/service role key (used with `--link`)                                                                                                                                                                       |
| `--prompt <prompt>`       | What to build (passed to Claude Code on launch)                                                                                                                                                                             |
| `--resume`                | Resume a previously failed scaffold                                                                                                                                                                                         |
| `--non-interactive`       | Error instead of prompting when info is missing                                                                                                                                                                             |
| `--debug`                 | Write detailed log to `agentlink-debug.log`                                                                                                                                                                                 |

---

## Database Operations

### Apply schemas

```bash
npx agentlink-sh@latest db apply                    # Auto-detects DB from .env.local
npx agentlink-sh@latest db apply --env dev          # Target specific environment
npx agentlink-sh@latest db apply --db-url "postgresql://..."  # Explicit DB URL
```

Pushes your schema-file changes to the live DB — **no Docker needed**. It handles changes to existing objects, so editing a table/column (an `ALTER`) lands without a rebuild. `--legacy` falls back to a create-only mode; `--allow-destructive` is required only for row-data-loss ops (`DROP TABLE`/`COLUMN`/`SCHEMA`, `TRUNCATE`).

### Run SQL

```bash
npx agentlink-sh@latest db sql "SELECT * FROM public.profiles LIMIT 5"
npx agentlink-sh@latest db sql "SELECT 1" --env dev
npx agentlink-sh@latest db sql "SELECT 1" --json    # JSON output (cloud only)
```

### Generate types

```bash
npx agentlink-sh@latest db types                    # Auto-detects output path
npx agentlink-sh@latest db types --env dev          # From specific environment
npx agentlink-sh@latest db types --output types/db.ts  # Custom output path
```

### Generate migration

```bash
npx agentlink-sh@latest db migrate add_charts       # From default DB
npx agentlink-sh@latest db migrate add_charts --env dev
```

### Set database password

```bash
npx agentlink-sh@latest db password                  # Interactive: shows dashboard reset link + prompts
npx agentlink-sh@latest db password "newpassword"    # Non-interactive: sets directly
```

Shows or sets the database password for the active cloud project. The password is stored in `~/.config/agentlink/credentials.json` (per project ref). Use when the DB password was reset in the Supabase dashboard.

### Snapshot the database (`db backup`)

Packages Supabase's recommended `db dump` triplet into a single command — `roles.sql` (`--role-only`), `schema.sql` (definitions), and `data.sql` (`--use-copy --data-only -x storage.buckets_vectors -x storage.vector_indexes`). Files land under `supabase/backups/<env>/<YYYY-MM-DDTHH-MM-SS>/`; each run creates a fresh timestamped subdirectory so previous backups survive a failed new run.

```bash
npx agentlink-sh@latest db backup                    # Active env (cloud.default, or local if none)
npx agentlink-sh@latest db backup --env prod         # Target prod (shows ▲ Active env: prod if active)
npx agentlink-sh@latest db backup --db-url "..."     # Override URL entirely
```

On first run, appends `supabase/backups/` to the project's root `.gitignore` under an "AgentLink — database backups" comment (idempotent on re-runs). Snapshots may contain real production data, so default-gitignored is non-negotiable.

Read-only against the target DB. Works on cloud envs, local Docker, and bare projects — no `supabase/database/` or scaffolded files required. Use before risky migrations / data deletes / config changes; restore is a separate concern (no `db restore` command exists; the user does it manually with `psql -f` or `supabase db reset --db-url <other-env>` to replay onto a different env).

---

## Database Recovery

### Database rebuild (local reset + re-apply)

```bash
npx agentlink-sh@latest db rebuild
```

Resets the database the right way and brings it back: runs `supabase db reset` (replays the committed migrations — migration files are **never touched**) **then** re-applies the schema files and the **imperative resources** (`rbac/`, `cron/`, `storage/`). A raw `supabase db reset` replays migrations only, so it silently DROPS custom roles/permissions, cron jobs, and storage buckets/policies (those are excluded from migrations) — `db rebuild` restores them. Now that `db apply` handles changes to existing objects, **it usually handles drift on its own** (a changed column just converges, and after a raw `supabase db reset` it detects the reset and reapplies the full schema) — so `db rebuild` is for genuine recovery: a DB in a weird state, or a change `db apply` refused as data-destructive. **Same command across envs:** local resets the Docker stack; a cloud **dev** env runs `supabase db reset --db-url <dev>` (resets the remote dev DB) behind an explicit typed confirmation (`--yes` to skip). **Production is a hard block** — `db rebuild` against prod is rejected outright, no override. **The agent is blocked from running `db rebuild` (and any raw `supabase db reset`) — resets are user-initiated**; if a reset is needed, point the user at this command. If the user already ran a raw `supabase db reset`, `db apply` alone reapplies the full schema + imperative resources (it detects the reset).

> `db rebuild` no longer regenerates migration files (the old behavior, which entangled a destructive migration regeneration with the reset, and there is no longer a separate `db reset` command — `db rebuild` is the reset). Regenerating/squashing migrations is a separate `db migrate` concern.

### Database URL check

```bash
npx agentlink-sh@latest db url        # Show correct pooler URL from Supabase API
npx agentlink-sh@latest db url --fix  # Also update .env.local if it's wrong
```

Fetches the real pooler DB URL from the Supabase Management API (Supavisor, IPv4-compatible, transaction mode) and compares it with the value stored in `.env.local`. Use when `db apply` or `db sql` fails with connection errors.

---

## Migration System

### Development vs Deployment

**During development**, the agent only uses `db apply`. Schema files are the source of truth — the agent writes SQL, applies it, and keeps building. No migrations are generated during development.

**For deployment**, `env deploy` runs `db apply` + `functions deploy` against the chosen env — no migration file is generated. Migrations are a separate concern: they are a deployment _artifact_ you create explicitly when you want an auditable change record (e.g., for change review, rollback planning, or CI that replays migration history).

```bash
# Development — the agent's loop
npx agentlink-sh@latest db apply

# Deployment — apply current schemas + edge functions to a cloud env
npx agentlink-sh@latest env deploy dev
npx agentlink-sh@latest env deploy prod      # Prompts y/N confirm

# Optional — when the user explicitly asks for a migration artifact
npx agentlink-sh@latest db migrate descriptive_name
npx supabase db push                              # Push the generated migration
```

### How migrations work

The CLI uses a **two-tier migration system** because some infrastructure (extensions, DO blocks, auth-schema triggers) can't be captured by a schema diff.

**Tier 1: Template migrations (hand-crafted)** — Pre-written SQL files embedded in the CLI. Two categories:

- **Pre-start migrations** — Extensions, schema creation (`api` schema + grants). Applied automatically by `npx supabase start`.
- **Post-setup migrations** — Queues (`pgmq.create()` uses DO blocks), auth triggers (on `auth.users`). Marked as applied via `npx supabase migration repair`.

**Tier 2: Application migrations** — Captures everything in `public` and `api` schemas: tables, functions, indexes, policies, triggers. `db migrate` diffs your committed migrations against the schema files (**no Docker**) — instead of `npx supabase db diff`, which sorts schema files alphabetically and breaks on cross-file FK references. `--legacy` is a Docker-based fallback.

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
4. Configure Claude Code (pending-env AGENTS.md mode, Next-step callout)
5. Install plugin + companion skills
6. User runs `npx agentlink-sh@latest env add dev` in a terminal to finish setup
```

Output is a complete scaffolded repo with no env yet — the user's browser OAuth happens in the `env add dev` step afterward.

### Update flow

```
1. Write new template migrations (if any)
2. migration repair            ← mark new templates as applied
3. db apply                    ← converge schema files onto the DB (ALTER-aware, no Docker)
4. db migrate update_name      ← generate migration from schema diff
```

---

## Deployment

### Deploy

```bash
npx agentlink-sh@latest env deploy                      # Interactive picker — preselects cloud.default
npx agentlink-sh@latest env deploy dev                  # → targets dev
npx agentlink-sh@latest env deploy prod                 # → targets prod (requires y/N confirm)
npx agentlink-sh@latest env deploy prod --yes           # Skip the prod confirm (CI)
npx agentlink-sh@latest env deploy prod --yes --non-interactive  # Full CI form
npx agentlink-sh@latest env deploy dev --dry-run        # Print target without applying
```

`env deploy` is a **three-step operation**, each step gated on the corresponding `supabase/` directory existing:

1. **Migrations** — `supabase db push --db-url <pooler>` if `supabase/migrations/` and `supabase/config.toml` both exist. Idempotent (Supabase tracks applied entries in `schema_migrations` server-side). Bare projects with hand-created migrations but no `config.toml` get a loud amber "Skipping migrations" warning rather than silent `config.toml` fabrication.
2. **Schemas** — `db apply` against the target env's database, if `supabase/database/` exists.
3. **Functions** — `supabase functions deploy --project-ref <ref>`, if `supabase/functions/` exists with non-underscore-prefixed subdirectories.

Each step is skipped independently if its directory is missing. A bare project with an empty `supabase/` tree prints `Nothing to deploy — no supabase/database, supabase/migrations, or supabase/functions found.` and exits 0 rather than running through an empty deploy banner.

Does NOT generate a migration file, and does NOT mutate `manifest.cloud.default` (deploy is a one-shot action — `env use dev && env deploy prod` stays on dev afterwards).

Things `env deploy` deliberately does NOT do (belong elsewhere):

- **Vault secrets / PostgREST config / auth config.** These are applied during `env add` (initial bootstrap). For targeted re-applies without the heavier schemas/functions path, use `npx agentlink-sh@latest env config [secrets|db|auth|all] [env-name]` — same primitives, cloud-only, idempotent, works on bare projects. For a full reset (schemas + functions + config + verify) use `env add <name> --retry`.
- **Migration file generation.** Use `db migrate <name>` explicitly when you want an auditable artifact.
- **Clean-tree gate.** `db apply` is idempotent, so running against a dirty tree is safe; the only reviewability loss is at the migration-diff level, which `env deploy` doesn't generate anyway.
- **Data-risk analysis.** That was tied to the migration diff; use `db migrate` + review the generated SQL when you want it.

**The top-level `npx agentlink-sh@latest deploy` command has been removed.** The CLI intercepts `npx agentlink-sh@latest deploy` and `npx agentlink-sh@latest retry-deploy` with an error pointing at the new verb. CI workflows using `deploy --prod` / `deploy --ci` must migrate to `env deploy <name> --yes --non-interactive` (the `env add --setup-ci` generator emits the new form).

**The agent deploys to the active dev env (local or `dev`) freely; it does not target `prod` without explicit, in-message user approval.** Deploying edge functions to `dev` after writing them, applying schemas to `dev`, and setting `dev` edge-function secrets are all part of the agent's normal workflow — without those, the user can't actually test what the agent built. The hard boundary is production: `npx agentlink-sh@latest env deploy prod`, `supabase db push` against a prod URL, `supabase functions deploy` while the active env is `prod`, and `npx agentlink-sh@latest env use prod` are all developer-initiated. When users ask to deploy to prod, point them to `npx agentlink-sh@latest env deploy prod` (interactive y/N gate) or `npx agentlink-sh@latest env deploy prod --dry-run` (preview without applying).

### Server-side config (`env config`)

Three independent subsystems, each re-applying the same setup `env add` runs. Use for targeted re-applies without the heavier schemas/functions path of `env add --retry`. Cloud-only; idempotent; works on bare projects.

| Subcommand | What it does                                                                                                                                                                                                                                   |
| ---------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `secrets`  | Seeds `SUPABASE_URL` / `SUPABASE_PUBLISHABLE_KEY` / `SUPABASE_SECRET_KEY` into Postgres Vault. Edge functions read these from the platform-injected `SUPABASE_*` env vars directly — no `SB_*` mirror is set or maintained (removed in v0.26). |
| `db`       | PATCHes PostgREST to expose the `api` schema.                                                                                                                                                                                                  |
| `auth`     | PATCHes auth config (hooks + signup settings). On bare projects the hook refs point at scaffolded `_hook_*` pg-functions that don't exist yet; Supabase returns a clear API error rather than silently misconfiguring.                         |
| `all`      | Runs all three in order.                                                                                                                                                                                                                       |

Both positionals are optional; omit either for an interactive picker:

```bash
# Shape: env config [subcommand] [env-name]
npx agentlink-sh@latest env config                      # Pick subcommand + env interactively
npx agentlink-sh@latest env config secrets              # Subcommand given, env picker
npx agentlink-sh@latest env config prod                 # Rotation: "prod" isn't a valid subcommand but IS a valid env → treated as env, subcommand picker runs
npx agentlink-sh@latest env config secrets prod         # Both specified
npx agentlink-sh@latest env config auth prod            # Just auth, against prod (confirms)
npx agentlink-sh@latest env config all dev --yes        # Full re-apply to dev, no prompts
npx agentlink-sh@latest env config secrets --env prod   # --env flag still accepted (for CI)
```

**How it relates to the other env commands:**

- Lighter than `env add <name> --retry` (which also does schemas + functions + verify). Reach for `env config` when ONLY config drifted; reach for `--retry` when the whole env needs a reset.
- Orthogonal to `env deploy` (which does schemas + functions + migrations but NOT config). Run both if both changed.
- Works standalone on bare projects — the primary way bare users add server-side config incrementally without having to `--force-update`.

### Environment management

AgentLink enforces a **fixed three-environment model**: `local`, `dev`, `prod`. Nothing else is accepted.

| Env     | Meaning                   | Created by                                                                                            |
| ------- | ------------------------- | ----------------------------------------------------------------------------------------------------- |
| `local` | Local Docker Supabase     | `npx agentlink-sh@latest env use local` (switches to it; the Docker stack itself is `supabase start`) |
| `dev`   | The cloud development env | `npx agentlink-sh@latest env add dev`                                                                 |
| `prod`  | The cloud production env  | `npx agentlink-sh@latest env add prod`                                                                |

Attempts to add `staging`, `dev2`, `production`, etc. fail with a clear error. Legacy manifests carrying off-model names are blocked at command entry with an `env remove` hint. Inspection commands (`env list`, `env remove`) remain permissive so users can see and clean up legacy entries.

```bash
# Interactive pickers — all three accept no-name and show a selector
npx agentlink-sh@latest env add                         # Picker: dev / prod (linked / not linked)
npx agentlink-sh@latest env use                         # Picker: local (if relevant) / dev / prod
npx agentlink-sh@latest env deploy                      # Picker: registered cloud envs, preselects cloud.default

# Explicit
npx agentlink-sh@latest env add dev                     # Add/relink the cloud dev env
npx agentlink-sh@latest env add prod                    # Add the prod env
npx agentlink-sh@latest env use local                   # Switch active env to local Docker
npx agentlink-sh@latest env use dev                     # Switch active env to cloud dev
npx agentlink-sh@latest env use prod                    # Switch to prod (y/N confirm required)
npx agentlink-sh@latest env list                        # Show all environments + their orgs
npx agentlink-sh@latest env remove <name>               # Remove an env (offers to forget its DB password too)

# Non-interactive (for agents / CI)
npx agentlink-sh@latest env add prod --project-ref <ref> --non-interactive
npx agentlink-sh@latest env add dev  --project-ref <ref> --non-interactive   # Relinks dev if it exists
npx agentlink-sh@latest env deploy prod --yes --non-interactive              # CI-friendly deploy
npx agentlink-sh@latest env remove staging -y                                # Legacy cleanup allowed

# Recovery
npx agentlink-sh@latest env add dev --retry             # Re-apply full setup (schemas, functions, secrets, PostgREST + auth) if a previous deploy died mid-way
```

`env use <name>` rewrites the managed block of `.env.local` so downstream `db apply` / `functions serve` / `db sql` hit the right env, and persists `manifest.cloud.default` so every subsequent command resolves the same target. User-added variables outside the block are preserved.

`env use <same-env>` (running it on the env you're already on) is **not a no-op** — it re-fetches the API keys, re-resolves the pooler URL, and rewrites the managed block. This is the path users take after rotating the publishable / secret key in the Supabase dashboard, or whenever they suspect `.env.local` has drifted. Output reads `Refreshed <name>` instead of `Switched to <name>`. Prod confirmation is skipped on this path — the user is already on prod, and the persistent `▲ Active env: prod` banner on every data-touching command keeps the live-data risk visible.

`env use prod` is **allowed** but gated behind an amber warning + y/N confirmation (defaults to No):

```
▲ Using prod as your active dev environment is NOT recommended.
  Your .env.local will point at production — any app or test you run
  locally will hit real data.
? Continue? (y/N)
```

After confirming, every subsequent `env deploy` / `db apply` / `db sql` / `db rebuild` prints an `▲ Active env: prod` banner at the top as a persistent reminder across terminals and agent sessions.

`env add <name>` handles both new environments and relinking existing ones. When the env already exists, a recovery prompt offers three actions: **Re-apply full setup** (re-runs bootstrap — schemas, functions, secrets, PostgREST + auth config — against the same project; for mid-deploy failures or config changes), **Relink to a different Supabase project** (for deleted/wrong projects), or **Cancel**. The picker shows a dim hint above: _"If you just changed schemas or functions, cancel and run `npx agentlink-sh@latest env deploy <name>` instead."_ — steering users away from the heavier full-setup when the lighter deploy would do. `--retry` triggers the full-setup path non-interactively; `--project-ref <ref>` triggers relink.

`env add` / `env relink` run an **org-first picker** — the user picks the Supabase organization BEFORE the connect-existing-vs-create-new choice, so both paths browse the correct org's projects. The picker merges API-visible orgs with cached orgs from previous logins and offers "+ Authorize a different organization…" to add a new one. On token validation failure (401/403 — org membership revoked, integration restrictions), the CLI surfaces "▲ Stored credentials for \<org\> are no longer accepted" and kicks off re-auth automatically.

Initial project link can also be done during scaffold with the `--link` flag — see "Scaffold with `--link`" above.

> `env relink` still works as a deprecated alias and prints a warning. Prefer `env add`.

### Picker visibility rules

The three env pickers behave slightly differently:

- **`env add` picker** lists `dev` and `prod`. Each row is annotated `— linked to <projectRef>` or `— not linked`. Selecting a linked env cascades into the 3-way recovery prompt (Re-apply / Relink / Cancel).
- **`env use` picker** lists cloud envs in the manifest with a ✓ next to the active one. Envs not yet in the manifest are disabled with a `run env add <name> first` hint. **`local` only appears when relevant**: it shows up when (a) local is already the active env, or (b) the project was scaffolded in local mode. Cloud-only projects won't see `local` as an option (explicit `npx agentlink-sh@latest env use local` still works if forced).
- **`env deploy` picker** lists every registered cloud env and preselects `cloud.default` (when it's a cloud env). Throws a clear error with an `env add` hint if no cloud env is registered.

### Clean-tree gate

`env add`, `env relink`, and `--force-update` abort if the git working tree is dirty — rollback on a dirty tree mixes user changes with AgentLink's writes and is painful to untangle. Bypass with `--allow-dirty` when needed. **`env deploy` does NOT gate on a clean tree** — `db apply` is idempotent, so re-running against a dirty tree is safe.

---

## Multi-org credentials

Supabase OAuth tokens are **scoped to a single organization** — the consent screen in the browser picks one. AgentLink stores per-org credentials so a user working across multiple orgs (dev in org A, prod in org B) doesn't overwrite one with the other on every re-auth.

**Where credentials live**: `~/.config/agentlink/credentials.json`, with the active tokens keyed by org ID under `oauth_by_org`. Each entry carries its own access token, refresh token, expiry, and cached org name/slug. A legacy single-org `oauth` slot is still read for back-compat; a PAT (`supabase_access_token`) set via `npx agentlink-sh@latest sb token set` is the final fallback for CI.

**Where org IDs live on disk**: each `CloudEnvironment` in `agentlink.json` carries an optional `orgId`. Populated on `env add`, and lazily backfilled on older manifests when `env add`/`env relink`/`env use` runs. Silent when there's nothing to do (no API calls if all envs already have `orgId`).

**Per-project credentials** live under `project_credentials[projectRef]` in the same file:

- `db_password` — entered by the user at `env add` time. Not re-fetchable from the Management API, so we persist it. File mode 0600.
- `secret_key` — the service-role-equivalent API key. Cached here so commands that need it don't re-fetch it on every invocation, and refreshed whenever the CLI fetches API keys (env add / use / relink / retry / config + scaffold). If the user rotates the key in the Supabase dashboard, the next CLI command picks up the fresh value and overwrites the cache.

**What ends up in `.env.local`'s managed block** for cloud envs: `VITE_/NEXT_PUBLIC_SUPABASE_URL`, `VITE_/NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY`, `SUPABASE_DB_URL`, and `SUPABASE_SECRET_KEY` (server-only, no prefix — same rule as `SUPABASE_DB_URL`). All five are managed keys, so stale copies outside the block get stripped on every rewrite, preventing dev/prod env shadowing when the user runs `env use`.

**CI**: set `SUPABASE_ACCESS_TOKEN` as a repo secret — a static PAT with admin access to the relevant org. OAuth is never triggered in CI.

---

## Schema Files vs Migrations

**Schema files** (`supabase/database/`) are the source of truth for application SQL. They use idempotent patterns (`CREATE OR REPLACE`, `IF NOT EXISTS`) and are applied with `npx agentlink-sh@latest db apply` — **no Docker needed**. It pushes the delta to the live DB and handles changes to existing objects (an `ALTER`), so editing an object just works. The agent writes and modifies these during development. (One-off `psql -c "…"` is fine for a quick manual statement, but `db apply` is the loop.)

**Migrations** (`supabase/migrations/`) are the deployment record for production. They're generated by `db migrate`: it diffs your committed migrations against the schema files (**no Docker**). `npx supabase db diff` is deliberately not used (it sorts schema files alphabetically and breaks on cross-file FK references). See [migration_system.md](./references/migration_system.md) for the baseline details and `--legacy`.

Schema files are **one object per file** under `supabase/database/` (`schemas/<schema>/tables/<table>.sql`, `schemas/<schema>/functions/<fn>.sql`, plus `schemas/<schema>/schema.sql` and `cluster/extensions/<ext>.sql`). Order doesn't matter: `db apply` resolves dependency order automatically, so file count and naming are irrelevant. The top-level `cron/`, `storage/`, and `rbac/` folders are **imperative** — excluded from `db apply`'s schema diff and from migrations, applied by the deploy step instead.

`db apply` keeps gitignored CLI state under `.agentlink/` (don't hand-edit it); it self-heals if that state goes stale — e.g. after a raw `supabase db reset`.

---

## The template base snapshot

The CLI keeps a committed snapshot of the exact templates it last shipped at `.agentlink/template-base/`. It's the reference the update flow diffs against to decide, per file, whether to fast-forward a pristine file or preserve one you customized.

- **Committed to git** — `.agentlink/template-base/` is checked in; `.agentlink/.incoming/` (conflict reconcile scratch) is gitignored.
- **Never hand-edit it** — the CLI writes it after each successful update.
- **Deleting it is fail-safe** — with no base, nothing is overwritten (every differing file is preserved). The next successful update rewrites it, it's `git restore`-able, and it can be reconstructed by re-scaffolding the `appliedVersion` recorded in `agentlink.json` (`npx agentlink-sh@<appliedVersion> <name> --skip-env --skip-install`). See `references/upgrading.md`.

## When to Fix Manually

The CLI handles most cases, but if it fails or produces incorrect results, the agent can intervene:

1. **Write a migration file directly** — Create `supabase/migrations/<timestamp>_<name>.sql` with the correct SQL
2. **Mark it as applied** — `npx supabase migration repair <version> --status applied --local` (or `--linked` for cloud)
3. **Apply SQL via psql** — `psql <db_url> -c "SQL"` or pipe a schema file
4. **Fix a broken migration** — Edit the file in `supabase/migrations/`, then repair

Always prefer the CLI (`--force-update`) first. Only fix manually when the CLI can't handle the situation.

---

## Reference Files

- **[Scaffold Map](./references/scaffold-map.md)** — The deterministic starting inventory of a fresh project: every scaffolded table, RPC, auth/RLS helper, hook, RBAC role + permission, and frontend route/hook/component. Read this **instead of** doing a discovery pass on a freshly scaffolded project — it's version-matched, so trust it and skip reading the files.
- **[Workflows](./references/workflows.md)** — Common user scenarios as a flow-by-flow playbook: start a new project from zero, add prod, switch envs, deploy, recover from a failed deploy. Each entry lists the user trigger, questions to ask, commands to run, and watch-outs.
- **[Upgrading](./references/upgrading.md)** — Moving an existing project onto a newer AgentLink version: `check` → `--dry-run` → `--force-update` → `check`, the base-snapshot file-level merge (fast-forward / customized / conflict / preserved), and the disposable `--skip-env --skip-install` reference for base reconstruction and diffing.
- **[Migration System](./references/migration_system.md)** — Deep dive: two-tier migrations, how `db apply` / `db migrate` work, adding extensions
- **[Troubleshooting](./references/troubleshooting.md)** — Common errors and manual fixes
- **[Known Issues](./references/known_issues.md)** — Transient/upstream toolchain quirks (e.g. `supabase start` storage health-check flake on first start) and their workarounds — not AgentLink bugs
