---
name: cli
description: AgentLink CLI usage — project scaffolding, updates/upgrades, migration management, environments, deploy-to-prod, backups, and credentials. Use when the task involves running `agentlink-sh` / `agentlink` commands, managing migrations, managing environments (link, secrets, `env deploy` to prod), running or restoring backups, handling project credentials/keys, troubleshooting db apply / db migrate issues, fixing migration files, or understanding the relationship between schema files and migrations. Activate whenever the task touches the AgentLink CLI, environments, or deployment.
---

# CLI

The `agentlink-sh` CLI scaffolds new Supabase projects and updates existing ones. It handles infrastructure setup, template files, database configuration, and migration generation.

> **Running the CLI (since 1.4): prefer the project-local install.** Projects scaffolded with **1.4+** pin `agentlink-sh` as a devDependency, so the project carries its **own** CLI version — reproducible, and it never auto-jumps across a breaking major. Note the names differ: the **package** is `agentlink-sh`, the installed **binary** is `agentlink` (no `-sh`). For in-project commands (`check`, `db apply`, `db migrate`, `env deploy`, `--force-update`, …):
> - **Use `pnpm exec agentlink <cmd>`** when the dep is present (check with `pnpm exec agentlink --version`, or look for `agentlink-sh` in `package.json`).
> - **If it's missing** (a pre-1.4 project): add it with `pnpm add -D agentlink-sh`, or run `--force-update` once (it backfills the declaration), then `pnpm install`.
> - **Don't use bare `npx agentlink`** — with no local install it resolves a different npm package, not ours. Use `pnpm exec agentlink` (local) or `npx agentlink-sh@latest` (one-shot).
> - **Only `create` uses `@latest`** — a brand-new project has no local CLI yet: `npx agentlink-sh@latest <name>`.
>
> The command docs below still write `npx agentlink-sh@latest` for brevity; when a local install exists, `pnpm exec agentlink` is the equivalent and preferred form.

> **Workflow playbook:** see `references/workflows.md` for common user scenarios — "start a new project from zero," "add a prod env," "deploy to prod," "recover from a failed deploy," etc. Each entry lists what questions to ask the user and which commands to run.

---

## Prerequisites

AgentLink does NOT install its own tooling, and it does NOT require an AI coding agent (Claude Code or Cursor) to be on PATH in order to scaffold — it writes the project files and the editor config regardless, then you open the project in whichever agent you chose. It validates the tooling it needs and points users at the setup script at **https://agentlink.sh/start** if anything is missing; it never tries to `curl | bash` anything itself. This is intentional — mixing tooling installation into scaffold meant every platform-specific install failure surfaced mid-scaffold with no context.

**Check these BEFORE attempting to scaffold** — every command runs through `npx`, so a missing prerequisite makes the CLI fail or hang, and the agent must NOT fall back to hand-creating files:

| Requirement | When | Verify | If missing |
|---|---|---|---|
| **Node.js 18+** (`node` / `npx`) | **Always** — the entire CLI is `npx agentlink-sh@latest` | `node --version` | Stop and tell the user to install Node (the `npx` call otherwise times out — this is a common silent failure). Don't proceed. |
| **Supabase CLI** | Always | `supabase --version` | Point at https://agentlink.sh/start. |
| **Docker** + **`psql`** | **Local dev** (`--local`) | `docker info`, `psql --version` | Required only for the local path; cloud-only scaffolds don't need them. |
| **Supabase account** | **Cloud dev / prod** (`env add dev`/`prod`) | — (browser OAuth at `env add`) | The user must own the OAuth + project creation; the agent can't browse. |
| **Resend account** | **Transactional email** (auth emails, product email) | — | Configured per-env: `resend setup --env <env> --api-key … --email …`. Not needed to scaffold. See [Resend setup](./references/resend.md). |

> ⚠️ **If `node`/`npx` is absent, the scaffold command times out with no useful output.** That is NOT a signal to build the project by hand — it's a missing-Node signal. Surface it to the user, get Node installed, then run the CLI.

---

## Commands

### Scaffold a new project

> **🛑 Before you scaffold, ASK the user where the dev environment should live: local Docker or Supabase Cloud.** This decision picks the command — don't default silently to `--skip-env`.
> - **Cloud** → needs browser OAuth (which the agent doesn't have) → scaffold files only with `--skip-env`, then hand off `env add dev`.
> - **Local** → no browser needed → the agent runs it end-to-end with `--local` (requires Docker + `psql`).
>
> `--skip-env` is the canonical path **only after the user has chosen cloud**. It is not a blanket agent default — running it without asking silently forces the cloud path on a user who may have wanted local. See workflow #1 in `references/workflows.md`.

```bash
npx agentlink-sh@latest <name>       # interactive — handles login + project creation
npx agentlink-sh@latest .            # scaffold in current directory
```

Creates template files, config, schema files, frontend (React + TanStack Start, SPA mode), configures your chosen agent editor (Claude Code and/or Cursor), and installs the companion skills (plus the plugin in Claude Code). Cloud is the default — the wizard prompts for Supabase OAuth (browser), org selection, and region. The wizard also asks which agent editor(s) to set up.

### Scaffold without env creation (`--skip-env`)

```bash
npx agentlink-sh@latest <name> --skip-env
```

**This is the canonical path for agent-driven scaffolding when the user chose CLOUD dev** (ask first — see the scaffold-decision callout above; for local dev use `--local` and run it end-to-end). Writes all files, installs frontend + backend deps, configures the chosen agent editor (Claude Code and/or Cursor), installs the companion skills (plus the plugin in Claude Code) — but **skips every Supabase-touching step**: no OAuth (needs a browser), no project creation, no local Docker, no `.env.local` credentials, no edge-function deploy.

After scaffold completes, the user finishes setup by running this in a terminal:

```bash
pnpm exec agentlink env add dev
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
pnpm exec agentlink env add dev
# → "No agentlink.json found" menu with three choices:
#     - Run the full AgentLink scaffold (recommended) → exits, tells user to run `npx agentlink-sh@latest`
#     - Continue without full features → writes a minimal agentlink.json, runs the Supabase flow
#     - Cancel
```

If the user picks "Continue without full features," the CLI writes a minimal `agentlink.json` with `bare: true` and runs the full Supabase flow (OAuth → org pick → project create/select → credentials → `.env.local`). **No schemas applied, no server-side config (vault / PostgREST / auth hooks), no `AGENTS.md` touched** — the user's file is theirs. `env use` / `env add` all skip `writeAgentsMd` in bare mode.

What works in bare mode: `env add`/`use`/`remove`/`list`, `env config [secrets|db|auth|all]`, `db password`, `db url`. What's a no-op until the user adds content: `db apply` (skips with "supabase/database/ not found"), `env deploy` (picks up migrations/schemas/functions incrementally as they appear).

Upgrade path: `pnpm exec agentlink --force-update` converts a bare project to the full scaffold.

### Update an existing project

```bash
pnpm exec agentlink --force-update
```

Re-applies template files, patches `config.toml`, runs SQL setup, and regenerates migrations if schemas changed. Use after a CLI version upgrade or when `check` reports missing components.

### Diagnose

```bash
pnpm exec agentlink check            # Check default environment
pnpm exec agentlink check --env dev  # Check specific environment
```

Outputs JSON with `ready`, `supabase_running`, `database` (extensions, queues, functions, secrets, api_schema), and `files`. Read-only — reports problems but does not fix them.

### Component info

```bash
pnpm exec agentlink info          # Summary list
pnpm exec agentlink info <name>   # Detail for one component
```

Shows type, summary, description, signature, and related components. Use to understand what a missing component does.

### Flags

| Flag                      | Effect                                                                                                                                                                                                                      |
| ------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `--no-skills`             | Skip companion skill installation                                                                                                                                                                                           |
| `--no-frontend`           | Skip frontend scaffolding (backend only)                                                                                                                                                                                    |
| `-y, --yes`               | Auto-confirm all prompts                                                                                                                                                                                                    |
| `--local`                 | Use local Docker instead of Supabase Cloud (cloud is default)                                                                                                                                                               |
| `--skip-env`              | Scaffold files only — skip all Supabase setup (OAuth, project creation, Docker). User runs `pnpm exec agentlink env add dev` after. **Use for agent-driven scaffolding.** Mutually exclusive with `--local` / `--link`. |
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
pnpm exec agentlink db apply                    # Auto-detects DB from .env.local
pnpm exec agentlink db apply --env dev          # Target specific environment
pnpm exec agentlink db apply --db-url "postgresql://..."  # Explicit DB URL
```

Pushes your schema-file changes to the live DB — **no Docker needed**. It handles changes to existing objects, so editing a table/column (an `ALTER`) lands without a rebuild. `--legacy` falls back to a create-only mode; `--allow-destructive` is required only for row-data-loss ops (`DROP TABLE`/`COLUMN`/`SCHEMA`, `TRUNCATE`). `db apply` also applies the imperative resources (`queue/`, `config/`, `storage/`, `cron/`, `rbac/`).

### Apply imperative resources only

```bash
pnpm exec agentlink db resources                 # queue/ + config/ + storage/ + cron/ + rbac/, nothing else
pnpm exec agentlink db resources --env dev
pnpm exec agentlink db resources --prod           # push imperative resources to prod (prompts to confirm)
```

Applies **only** the imperative folders (`supabase/database/` `queue/`, `config/`, `storage/`, `cron/`, `rbac/`) — no schema diff, no type-gen. Use it after editing the pgmq queue, a cron job, storage bucket, or RBAC file when you don't want a full `db apply` (dev) or `env deploy` (prod). Idempotent. (`db rbac-sync` is the rbac-only subset.)

`--prod` (shorthand for `--env prod`) is the supported way to push an imperative-only change to prod **without** a full `env deploy` — e.g. re-running the pgmq queue self-heal, or applying a new cron/storage/rbac change. It prompts for confirmation (`--yes` to skip in CI). Since prod is migrations-only and skips declarative `db apply`, imperative folders are the ONLY path these Supabase-managed objects reach prod — `db resources --prod` runs exactly that path in isolation.

### Run SQL

```bash
pnpm exec agentlink db sql "SELECT * FROM public.profiles LIMIT 5"
pnpm exec agentlink db sql "SELECT 1" --env dev
pnpm exec agentlink db sql "SELECT 1" --json    # JSON output (cloud only)
```

### Generate types

```bash
pnpm exec agentlink db types                    # Auto-detects output path
pnpm exec agentlink db types --env dev          # From specific environment
pnpm exec agentlink db types --output types/db.ts  # Custom output path
```

### Generate migration

```bash
pnpm exec agentlink db migrate add_charts       # From default DB
pnpm exec agentlink db migrate add_charts --env dev
```

### Set database password

```bash
pnpm exec agentlink db password                  # Interactive: shows dashboard reset link + prompts
pnpm exec agentlink db password "newpassword"    # Non-interactive: sets directly
```

Shows or sets the database password for the active cloud project. The password is stored in `~/.config/agentlink/credentials.json` (per project ref). Use when the DB password was reset in the Supabase dashboard.

### Snapshot the database (`db backup`)

Packages Supabase's recommended `db dump` triplet into a single command — `roles.sql` (`--role-only`), `schema.sql` (definitions), and `data.sql` (`--use-copy --data-only -x storage.buckets_vectors -x storage.vector_indexes`). Files land under `supabase/backups/<env>/<YYYY-MM-DDTHH-MM-SS>/`; each run creates a fresh timestamped subdirectory so previous backups survive a failed new run.

```bash
pnpm exec agentlink db backup                    # Active env (cloud.default, or local if none)
pnpm exec agentlink db backup --env prod         # Target prod (shows ▲ Active env: prod if active)
pnpm exec agentlink db backup --db-url "..."     # Override URL entirely
```

On first run, appends `supabase/backups/` to the project's root `.gitignore` under an "AgentLink — database backups" comment (idempotent on re-runs). Snapshots may contain real production data, so default-gitignored is non-negotiable.

Read-only against the target DB. Works on cloud envs, local Docker, and bare projects — no `supabase/database/` or scaffolded files required. Use before risky migrations / data deletes / config changes; restore is a separate concern (no `db restore` command exists; the user does it manually with `psql -f` or `supabase db reset --db-url <other-env>` to replay onto a different env).

---

## Database Recovery

### Database rebuild (local reset + re-apply)

```bash
pnpm exec agentlink db rebuild
```

Resets the database the right way and brings it back: runs `supabase db reset` (replays the committed migrations — migration files are **never touched**) **then** re-applies the schema files and the **imperative resources** (`rbac/`, `cron/`, `storage/`). A raw `supabase db reset` replays migrations only, so it silently DROPS custom roles/permissions, cron jobs, and storage buckets/policies (those are excluded from migrations) — `db rebuild` restores them. Now that `db apply` handles changes to existing objects, **it usually handles drift on its own** (a changed column just converges, and after a raw `supabase db reset` it detects the reset and reapplies the full schema) — so `db rebuild` is for genuine recovery: a DB in a weird state, or a change `db apply` refused as data-destructive. **Same command across envs:** local resets the Docker stack; a cloud **dev** env runs `supabase db reset --db-url <dev>` (resets the remote dev DB) behind an explicit typed confirmation (`--yes` to skip). **Production is a hard block** — `db rebuild` against prod is rejected outright, no override. **The agent is blocked from running `db rebuild` (and any raw `supabase db reset`) — resets are user-initiated**; if a reset is needed, point the user at this command. If the user already ran a raw `supabase db reset`, `db apply` alone reapplies the full schema + imperative resources (it detects the reset).

> `db rebuild` no longer regenerates migration files (the old behavior, which entangled a destructive migration regeneration with the reset, and there is no longer a separate `db reset` command — `db rebuild` is the reset). Regenerating/squashing migrations is a separate `db migrate` concern.

### Database URL check

```bash
pnpm exec agentlink db url        # Show correct pooler URL from Supabase API
pnpm exec agentlink db url --fix  # Also update .env.local if it's wrong
```

Fetches the real pooler DB URL from the Supabase Management API (Supavisor, IPv4-compatible, transaction mode) and compares it with the value stored in `.env.local`. Use when `db apply` or `db sql` fails with connection errors.

---

## Migration System

### Development vs Deployment

**During development**, the agent only uses `db apply`. Schema files are the source of truth — the agent writes SQL, applies it, and keeps building. No migrations are generated during development.

**For deployment**, `env deploy` runs `db apply` + `functions deploy` against the chosen env — no migration file is generated. Migrations are a separate concern: they are a deployment _artifact_ you create explicitly when you want an auditable change record (e.g., for change review, rollback planning, or CI that replays migration history).

```bash
# Development — the agent's loop
pnpm exec agentlink db apply

# Deployment — apply current schemas + edge functions to a cloud env
pnpm exec agentlink env deploy dev
pnpm exec agentlink env deploy prod      # Prompts y/N confirm

# Optional — when the user explicitly asks for a migration artifact
pnpm exec agentlink db migrate descriptive_name
npx supabase db push                              # Push the generated migration
```

### How migrations work

The CLI uses a **two-tier migration system** because some infrastructure (extensions, DO blocks, auth-schema triggers) can't be captured by a schema diff.

**Tier 1: Template migrations (hand-crafted)** — Pre-written SQL files embedded in the CLI. Two categories:

- **Pre-start migrations** — Extensions, schema creation (`api` schema + grants). Applied automatically by `npx supabase start`.
- **Post-setup migrations** — Auth triggers (on `auth.users`). Marked as applied via `npx supabase migration repair`. (The pgmq queue is **not** a migration — it's an imperative resource in `supabase/database/queue/`, applied on every deploy incl. prod so it can self-heal a malformed queue. See `references/migration_system.md`.)

**Tier 2: Application migrations** — Captures everything in `public` and `api` schemas: tables, functions, indexes, policies, triggers. `db migrate` diffs your committed migrations against the schema files (**no Docker**) — instead of `npx supabase db diff`, which sorts schema files alphabetically and breaks on cross-file FK references. `--legacy` is a Docker-based fallback. Like `db apply`/`db rebuild`, `db migrate` refuses to **write** a migration containing a row-data-loss statement (`DROP TABLE`/`COLUMN`/`SCHEMA`, `TRUNCATE` — e.g. a table rename) without `--allow-destructive`; review the printed diff before adding the flag.

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
6. User runs `pnpm exec agentlink env add dev` in a terminal to finish setup
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
pnpm exec agentlink env deploy                      # Interactive picker — preselects cloud.default
pnpm exec agentlink env deploy dev                  # → targets dev
pnpm exec agentlink env deploy prod                 # → targets prod (requires y/N confirm)
pnpm exec agentlink env deploy prod --yes           # Skip the prod confirm (CI)
pnpm exec agentlink env deploy prod --yes --non-interactive  # Full CI form
pnpm exec agentlink env deploy dev --dry-run        # Print target without applying
```

`env deploy` is a **three-step operation**, each step gated on the corresponding `supabase/` directory existing:

1. **Migrations** — `supabase db push --db-url <pooler>` if `supabase/migrations/` and `supabase/config.toml` both exist. Idempotent (Supabase tracks applied entries in `schema_migrations` server-side). Bare projects with hand-created migrations but no `config.toml` get a loud amber "Skipping migrations" warning rather than silent `config.toml` fabrication.
2. **Schemas** — `db apply` against the target env's database, if `supabase/database/` exists.
3. **Functions** — `supabase functions deploy --project-ref <ref>`, if `supabase/functions/` exists with non-underscore-prefixed subdirectories.

Each step is skipped independently if its directory is missing. A bare project with an empty `supabase/` tree prints `Nothing to deploy — no supabase/database, supabase/migrations, or supabase/functions found.` and exits 0 rather than running through an empty deploy banner.

Does NOT generate a migration file, and does NOT mutate `manifest.cloud.default` (deploy is a one-shot action — `env use dev && env deploy prod` stays on dev afterwards).

Things `env deploy` deliberately does NOT do (belong elsewhere):

- **Vault secrets / PostgREST config / auth config.** These are applied during `env add` (initial bootstrap). For targeted re-applies without the heavier schemas/functions path, use `pnpm exec agentlink env config [secrets|db|auth|all] [env-name]` — same primitives, cloud-only, idempotent, works on bare projects. For a full reset (schemas + functions + config + verify) use `env add <name> --retry`.
- **Migration file generation.** Use `db migrate <name>` explicitly when you want an auditable artifact.
- **Clean-tree gate.** `db apply` is idempotent, so running against a dirty tree is safe; the only reviewability loss is at the migration-diff level, which `env deploy` doesn't generate anyway.
- **Data-risk analysis.** That was tied to the migration diff; use `db migrate` + review the generated SQL when you want it.

**The top-level `npx agentlink-sh@latest deploy` command has been removed.** The CLI intercepts `npx agentlink-sh@latest deploy` and `npx agentlink-sh@latest retry-deploy` with an error pointing at the new verb. CI workflows using `deploy --prod` / `deploy --ci` must migrate to `env deploy <name> --yes --non-interactive` (the `env add --setup-ci` generator emits the new form).

**The agent deploys to the active dev env (local or `dev`) freely; it does not target `prod` without explicit, in-message user approval.** Deploying edge functions to `dev` after writing them, applying schemas to `dev`, and setting `dev` edge-function secrets are all part of the agent's normal workflow — without those, the user can't actually test what the agent built. The hard boundary is production: `pnpm exec agentlink env deploy prod`, `supabase db push` against a prod URL, `supabase functions deploy` while the active env is `prod`, and `pnpm exec agentlink env use prod` are all developer-initiated. When users ask to deploy to prod, point them to `pnpm exec agentlink env deploy prod` (interactive y/N gate) or `pnpm exec agentlink env deploy prod --dry-run` (preview without applying).

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
pnpm exec agentlink env config                      # Pick subcommand + env interactively
pnpm exec agentlink env config secrets              # Subcommand given, env picker
pnpm exec agentlink env config prod                 # Rotation: "prod" isn't a valid subcommand but IS a valid env → treated as env, subcommand picker runs
pnpm exec agentlink env config secrets prod         # Both specified
pnpm exec agentlink env config auth prod            # Just auth, against prod (confirms)
pnpm exec agentlink env config all dev --yes        # Full re-apply to dev, no prompts
pnpm exec agentlink env config secrets --env prod   # --env flag still accepted (for CI)
```

**How it relates to the other env commands:**

- Lighter than `env add <name> --retry` (which also does schemas + functions + verify). Reach for `env config` when ONLY config drifted; reach for `--retry` when the whole env needs a reset.
- Orthogonal to `env deploy` (which does schemas + functions + migrations but NOT config). Run both if both changed.
- Works standalone on bare projects — the primary way bare users add server-side config incrementally without having to `--force-update`.

### Environment management

AgentLink enforces a **fixed three-environment model**: `local`, `dev`, `prod`. Nothing else is accepted.

| Env     | Meaning                   | Created by                                                                                            |
| ------- | ------------------------- | ----------------------------------------------------------------------------------------------------- |
| `local` | Local Docker Supabase     | `pnpm exec agentlink env use local` (switches to it; the Docker stack itself is `supabase start`) |
| `dev`   | The cloud development env | `pnpm exec agentlink env add dev`                                                                 |
| `prod`  | The cloud production env  | `pnpm exec agentlink env add prod`                                                                |

Attempts to add `staging`, `dev2`, `production`, etc. fail with a clear error. Legacy manifests carrying off-model names are blocked at command entry with an `env remove` hint. Inspection commands (`env list`, `env remove`) remain permissive so users can see and clean up legacy entries.

```bash
# Interactive pickers — all three accept no-name and show a selector
pnpm exec agentlink env add                         # Picker: dev / prod (linked / not linked)
pnpm exec agentlink env use                         # Picker: local (if relevant) / dev / prod
pnpm exec agentlink env deploy                      # Picker: registered cloud envs, preselects cloud.default

# Explicit
pnpm exec agentlink env add dev                     # Add or relink the cloud dev env
pnpm exec agentlink env add prod                    # Add the prod env
pnpm exec agentlink env use local                   # Switch active env to local Docker
pnpm exec agentlink env use dev                     # Switch active env to cloud dev
pnpm exec agentlink env use prod                    # Switch to prod (y/N confirm required)
pnpm exec agentlink env list                        # Show all environments + their orgs
pnpm exec agentlink env remove <name>               # Remove an env (offers to forget its DB password too)

# Non-interactive (for agents / CI)
pnpm exec agentlink env add prod --project-ref <ref> --non-interactive
pnpm exec agentlink env add dev  --project-ref <ref> --non-interactive   # Relinks dev if it exists
pnpm exec agentlink env deploy prod --yes --non-interactive              # CI-friendly deploy
pnpm exec agentlink env remove staging -y                                # Legacy cleanup allowed

# Recovery
pnpm exec agentlink env add dev --retry             # Re-apply full setup (schemas, functions, secrets, PostgREST + auth) if a previous deploy died mid-way
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

`env add <name>` handles both new environments and relinking existing ones. When the env already exists, a recovery prompt offers three actions: **Re-apply full setup** (re-runs bootstrap — schemas, functions, secrets, PostgREST + auth config — against the same project; for mid-deploy failures or config changes), **Relink to a different Supabase project** (for deleted/wrong projects, or a project transferred to a new org), or **Cancel**. The picker shows a dim hint above: _"If you just changed schemas or functions, cancel and run `pnpm exec agentlink env deploy <name>` instead."_ — steering users away from the heavier full-setup when the lighter deploy would do. When relinking lands on the **same** project already registered for the env (e.g. after a transfer), the CLI detects it and offers to keep the password on file or update it instead of forcing re-entry. `--retry` triggers the full-setup path non-interactively; `--project-ref <ref>` triggers relink; `--keep-password` reuses the stored DB password in non-interactive same-project relinks.

`env add` runs an **org-first picker** — the user picks the Supabase organization BEFORE the connect-existing-vs-create-new choice, so both paths browse the correct org's projects. The picker merges API-visible orgs with cached orgs from previous logins and offers "+ Authorize a different organization…" to add a new one. On token validation failure (401/403 — org membership revoked, integration restrictions), the CLI surfaces "▲ Stored credentials for \<org\> are no longer accepted" and kicks off re-auth automatically.

Initial project link can also be done during scaffold with the `--link` flag — see "Scaffold with `--link`" above.

### Picker visibility rules

The three env pickers behave slightly differently:

- **`env add` picker** lists `dev` and `prod`. Each row is annotated `— linked to <projectRef>` or `— not linked`. Selecting a linked env cascades into the 3-way recovery prompt (Re-apply / Relink / Cancel).
- **`env use` picker** lists cloud envs in the manifest with a ✓ next to the active one. Envs not yet in the manifest are disabled with a `run env add <name> first` hint. **`local` only appears when relevant**: it shows up when (a) local is already the active env, or (b) the project was scaffolded in local mode. Cloud-only projects won't see `local` as an option (explicit `pnpm exec agentlink env use local` still works if forced).
- **`env deploy` picker** lists every registered cloud env and preselects `cloud.default` (when it's a cloud env). Throws a clear error with an `env add` hint if no cloud env is registered.

### Clean-tree gate

`env add` and `--force-update` abort if the git working tree is dirty — rollback on a dirty tree mixes user changes with AgentLink's writes and is painful to untangle. Bypass with `--allow-dirty` when needed. **`env deploy` does NOT gate on a clean tree** — `db apply` is idempotent, so re-running against a dirty tree is safe.

---

## Multi-org credentials

Supabase OAuth tokens are **scoped to a single organization** — the consent screen in the browser picks one. AgentLink stores per-org credentials so a user working across multiple orgs (dev in org A, prod in org B) doesn't overwrite one with the other on every re-auth.

**Where credentials live**: `~/.config/agentlink/credentials.json`, with the active tokens keyed by org ID under `oauth_by_org`. Each entry carries its own access token, refresh token, expiry, and cached org name/slug. A legacy single-org `oauth` slot is still read for back-compat; a PAT (`supabase_access_token`) set via `npx agentlink-sh@latest sb token set` is the final fallback for CI.

**Where org IDs live on disk**: each `CloudEnvironment` in `agentlink.json` carries an optional `orgId`. Populated on `env add`, and lazily backfilled on older manifests when `env add`/`env use` runs. Silent when there's nothing to do (no API calls if all envs already have `orgId`). A stale `orgId` (project transferred to a new org) is now auto-corrected on `env deploy` / `env config` / `env add --retry` — `agentlink.json` is updated with a notice and the correct token re-pinned.

**Per-project credentials** live under `project_credentials[projectRef]` in the same file:

- `db_password` — entered by the user at `env add` time. Not re-fetchable from the Management API, so we persist it. File mode 0600.
- `secret_key` — the service-role-equivalent API key. Cached here so commands that need it don't re-fetch it on every invocation, and refreshed whenever the CLI fetches API keys (env add / use / retry / config + scaffold). If the user rotates the key in the Supabase dashboard, the next CLI command picks up the fresh value and overwrites the cache.

**What ends up in `.env.local`'s managed block** for cloud envs: `VITE_/NEXT_PUBLIC_SUPABASE_URL`, `VITE_/NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY`, `SUPABASE_DB_URL`, and `SUPABASE_SECRET_KEY` (server-only, no prefix — same rule as `SUPABASE_DB_URL`). All five are managed keys, so stale copies outside the block get stripped on every rewrite, preventing dev/prod env shadowing when the user runs `env use`.

**CI**: set `SUPABASE_ACCESS_TOKEN` as a repo secret — a static PAT with admin access to the relevant org. OAuth is never triggered in CI.

---

## Schema Files vs Migrations

**Schema files** (`supabase/database/`) are the source of truth for application SQL. They use idempotent patterns (`CREATE OR REPLACE`, `IF NOT EXISTS`) and are applied with `pnpm exec agentlink db apply` — **no Docker needed**. It pushes the delta to the live DB and handles changes to existing objects (an `ALTER`), so editing an object just works. The agent writes and modifies these during development. (One-off `psql -c "…"` is fine for a quick manual statement, but `db apply` is the loop.)

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
4. **Fix a broken migration** — **only if it is uncommitted AND not yet deployed to production** (confirm with the user): edit the file in `supabase/migrations/`, then repair. **If it's committed or already deployed, do NOT edit it** — migrations are forward-only (see [migration_system.md](./references/migration_system.md) → *Migrations are forward-only*). Fix the schema files and generate a **new** migration that corrects it forward.

Always prefer the CLI (`--force-update`) first. Only fix manually when the CLI can't handle the situation.

---

## Reference Files

- **[Scaffold Map](./references/scaffold-map.md)** — The deterministic starting inventory of an **already-scaffolded** project: every scaffolded table, RPC, auth/RLS helper, hook, RBAC role + permission, and frontend route/hook/component. Read this **instead of** doing a discovery pass on a freshly scaffolded project — it's version-matched, so trust it and skip reading the files. **Precondition: the project is already scaffolded (`agentlink.json` exists).** It is a map for *reading* a scaffold, never a checklist for *building* one by hand — if the project isn't scaffolded yet, run the CLI instead (see "Scaffold a new project" above).
- **[Workflows](./references/workflows.md)** — Common user scenarios as a flow-by-flow playbook: start a new project from zero, add prod, switch envs, deploy, recover from a failed deploy. Each entry lists the user trigger, questions to ask, commands to run, and watch-outs.
- **[Upgrading](./references/upgrading.md)** — Moving an existing project onto a newer AgentLink version: `check` → `--dry-run` → `--force-update` → `check`, the base-snapshot file-level merge (fast-forward / customized / conflict / preserved), and the disposable `--skip-env --skip-install` reference for base reconstruction and diffing.
- **[Upgrade to 2.0 — identity-only auth](./references/upgrade-2.0-identity-auth.md)** — The breaking 1.x → 2.0 migration runbook (identity-only auth + native MCP). What `--force-update` does *and doesn't* do at the 2.0 boundary, the removed/added objects, deleting orphaned files, the `db migrate new_auth_model` transformation, the frontend semantic merge, and the contract bump. Read this for any project crossing 2.0.
- **[Migration System](./references/migration_system.md)** — Deep dive: two-tier migrations, how `db apply` / `db migrate` work, adding extensions
- **[Troubleshooting](./references/troubleshooting.md)** — Common errors and manual fixes
- **[Resend setup](./references/resend.md)** — Per-env transactional email: source-of-truth model (FROM in `agentlink.json`, key in the secret store), `--api-key`/`--email`/`--name` flags, sticky-key rules, recipes (change display name, rotate key), and the "email not sending" debug flow
- **[Known Issues](./references/known_issues.md)** — Transient/upstream toolchain quirks (e.g. `supabase start` storage health-check flake on first start) and their workarounds — not AgentLink bugs
