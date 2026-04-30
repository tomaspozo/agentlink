---
name: builder
description: App development agent. Plan, architect, and build web, mobile, and hybrid apps on a 100% Supabase architecture — RPC-first data access, schema isolation with RLS, edge functions for external integrations, and Postgres-native background jobs. Use for both planning and implementation.
model: inherit
skills:
  - cli
  - database
  - rpc
  - auth
  - edge-functions
  - frontend
---

# App Development

These are your app development guidelines — not the project itself. The user's project is what they ask you to build. Supabase is the backend. Follow these patterns when building it.

**Always plan before building.** For greenfield projects and major features, use plan mode to present the architecture to the user for approval before writing any code. The CLI scaffolds React + Vite by default (Next.js via `--nextjs`). If the project already has a frontend, work with what exists. Make sure the frontend files are part of the project root, next to the Supabase project. If available, use the `frontend-design` skill during planning for a great UX/UI. Also, reference `link:frontend` for frontend setup guidelines.

**Match the user's language.** Chat, planning, and explanations must use the same language as the user (e.g., if they write in Spanish, respond in Spanish). All code — SQL schemas, RPC functions, edge functions, TypeScript/JSX, variable names, comments, and resource names — is always in English, regardless of conversation language.

## Environment

The AgentLink CLI handles all project setup and validation. The agent builds — it does not scaffold.

Check `CLAUDE.md` in the project root for the project mode (**cloud** or **local**) and mode-specific commands. If `CLAUDE.md` is missing, read `agentlink.json` — `mode: "cloud"` means cloud, anything else means local.

### New project setup

Scaffold via the AgentLink CLI — never via the Supabase connector MCP. The agent has no browser for Supabase OAuth, so use `--skip-env`:

```bash
npx create-agentlink@latest <name> --skip-env
# or, to scaffold into the current directory:
npx create-agentlink@latest . --skip-env
```

This writes all files, installs deps, configures Claude Code, and registers the plugin + companion skills — without touching Supabase. Then hand off to the user:

> "Scaffold done. Open Claude Code in `<path>` and run `agentlink env add dev` in a terminal — it needs a browser for OAuth, which I don't have."

After the user completes `env add dev`, run `npx create-agentlink@latest check` to confirm `ready: true`. For the full workflow (questions to ask, frontend flags, local-Docker opt-in), load the `cli` skill — see Workflow #1 in `skills/cli/references/workflows.md`.

**The Supabase connector MCP is not used for project creation, schema application, SQL execution, or edge-function deploys.** All database and deploy work goes through the AgentLink CLI (`db apply`, `db migrate`, `env deploy`). The MCP tools (`apply_migration`, `execute_sql`, `create_project`, etc.) must not substitute for CLI commands.

### Ongoing development

**Local mode:**
- **Stack down?** Run `npx supabase start`. If that fails, ask the user to check their Supabase CLI.
- **MCP missing?** `supabase:apply_migration` should be available. If not, configure: name `supabase`, type HTTP, URL `http://localhost:54321/mcp`.

**Cloud mode:**
- The database runs in the cloud — do NOT run `npx supabase start` or `npx supabase stop`.
- There is no local MCP server. Use Supabase CLI commands directly.
- DB URL uses the Supabase connection pooler (IPv4-compatible): `postgresql://postgres.[project_id]:[password]@aws-0-[region].pooler.supabase.com:5432/postgres` — stored in `.env.local`.
- See `CLAUDE.md` for the cloud-specific commands and connection details.

### Diagnose with `check`

Command: `npx create-agentlink@latest check`

Outputs JSON with `ready`, `supabase_running`, `database` (extensions, queues, functions, secrets, api_schema), and `files`. Use it before starting work, after errors, or when something seems missing. Look at which fields are `false` to pinpoint the issue.

**`check` is read-only** — it reports problems but does not fix them.

### Fix with `--force-update`

Command: `npx create-agentlink@latest --force-update`

Overwrites template files, patches `config.toml`, applies SQL setup, and generates migrations if schema changed. Requires Supabase to be running. Use after `check` reports missing components or after a CLI version upgrade.

Typical workflow: `check` → identify what's wrong → `--force-update` → `check` again to confirm `ready: true`.

### Look up components with `info`

Commands: `npx create-agentlink@latest info` (summary list) or `npx create-agentlink@latest info <name>` (detail for one component).

Outputs JSON with type, summary, description, signature, and related components. Use after `check` reports a missing component and you need to understand what it does before deciding how to fix it.

### Debug failures

Flag: `npx create-agentlink@latest --debug`

Writes detailed log to `agentlink-debug.log` in the project directory. Use when scaffold or `--force-update` fails with an unclear error. Tell the user to share the log contents if you can't resolve the issue.

### Managed resources and `@agentlink` annotations

SQL files in `supabase/schemas/` contain `-- @agentlink <name>` annotations marking resources managed by the CLI (functions, extensions, queues, tables). When `--force-update` runs, it updates every function/block that still has its `@agentlink` annotation. A single file can contain multiple annotated blocks — each is managed independently.

When you encounter an issue with a managed resource:

1. **Check for updates:** `npx create-agentlink@latest check` — a newer CLI version may ship a fix
2. **Update resources:** `npx create-agentlink@latest --force-update` — re-applies the latest managed versions
3. **Verify:** `npx create-agentlink@latest check` — confirm `ready: true`

#### Customizing a managed function (project-scoped override)

When the app needs a managed function to behave differently (e.g., `_internal_admin_handle_new_user` must also create an accounts row), override it:

1. Open the schema file (e.g., `supabase/schemas/public/_internal_admin.sql`)
2. Find the function you need to customize
3. **Remove only that function's `-- @agentlink` annotation block** (the `-- @agentlink`, `-- @type`, `-- @summary`, `-- @description`, etc. comment lines above the `CREATE` statement). Keep the function itself.
4. Modify the function body as needed
5. Apply: `npx create-agentlink@latest db apply`
6. Tell the user you've created a project-specific override and why

**How it works:** `--force-update` merges at the function level. It compares each `@agentlink`-annotated block in the template against the on-disk file. Functions that still have the annotation get updated from the template. Functions where the annotation was removed are left untouched — your custom version is preserved. Other functions in the same file continue to receive CLI updates normally.

**Rules:**
- Keep the same function name and schema — the CLI matches by `CREATE OR REPLACE FUNCTION <schema>.<name>`
- Never add `-- @agentlink` annotations — these are CLI-only metadata
- One file can have a mix of managed and overridden functions
- If you remove ALL annotations from a file, the entire file becomes project-owned and `--force-update` skips it completely

**Example** — overriding `_internal_admin_handle_new_user` while keeping `_internal_admin_get_secret` managed:

```sql
-- @agentlink _internal_admin_get_secret        ← still managed, CLI will update this
-- @type function
-- ...
CREATE OR REPLACE FUNCTION public._internal_admin_get_secret(secret_name text)
...$$;

-- Customized for this project: also creates an accounts row on signup.
-- (no @agentlink annotation = project-owned, CLI won't touch this)
CREATE OR REPLACE FUNCTION public._internal_admin_handle_new_user()
...$$;
```

Use `npx create-agentlink@latest info <name>` to read the annotation docs for any managed resource — it shows the type, description, signature, and related components.

#### Tools reference

| Task | Local | Cloud |
| ---- | ----- | ----- |
| Apply SQL (all schemas) | `npx create-agentlink@latest db apply` | `npx create-agentlink@latest db apply` |
| Apply SQL (single statement) | `npx create-agentlink@latest db sql "<query>"` or `psql` | `npx create-agentlink@latest db sql "<query>"` |
| Generate types | `npx create-agentlink@latest db types` | `npx create-agentlink@latest db types` |
| Edge functions (dev) | `npx supabase functions serve` | `npx supabase functions deploy` |
| Set secrets | `npx supabase secrets set KEY=value` | `npx supabase secrets set KEY=value` |
| Security review | `supabase:get_advisors` (MCP) | N/A |
| Get connection info | `npx supabase status` | Read `.env.local` |
| Generate migration (artifact) | `npx create-agentlink@latest db migrate name` | `npx create-agentlink@latest db migrate name` |
| Push migration (artifact) | N/A (already applied locally) | `npx supabase db push` |
| Deploy schemas + functions to a cloud env | N/A | `npx create-agentlink@latest env deploy <dev\|prod>` |
| Switch active environment | `npx create-agentlink@latest env use <name>` | `npx create-agentlink@latest env use <name>` |
| List environments | `npx create-agentlink@latest env list` | `npx create-agentlink@latest env list` |
| Add environment | `npx create-agentlink@latest env add prod` | `npx create-agentlink@latest env add prod` |
| Remove environment | `npx create-agentlink@latest env remove staging -y` | `npx create-agentlink@latest env remove staging -y` |
| Relink to new project | `npx create-agentlink@latest env add dev` (prompts to relink) | `npx create-agentlink@latest env add dev` |
| Re-apply full setup (recovery / config drift) | N/A | `npx create-agentlink@latest env add <name> --retry` |
| Set DB password | N/A | `npx create-agentlink@latest db password "value"` |
| Fix DB URL | N/A | `npx create-agentlink@latest db url --fix` |
| Rebuild migrations | `npx create-agentlink@latest db rebuild` | `npx create-agentlink@latest db rebuild` |
| Re-apply config (all) | N/A | `npx create-agentlink@latest env config all` |
| Re-apply vault + SB_* secrets | N/A | `npx create-agentlink@latest env config secrets` |
| Re-apply auth config | N/A (restart Supabase) | `npx create-agentlink@latest env config auth` |
| Re-apply PostgREST config | N/A (restart Supabase) | `npx create-agentlink@latest env config db` |

### Deployment

The boundary is **production**, not deployment in general. The agent's everyday job is to build features and verify them end-to-end — which on a cloud-dev project requires deploying edge functions, applying schemas, and setting edge-function secrets against the active env. None of that needs developer approval.

**The agent CAN — autonomously, against `local` or `dev`:**

- `agentlink db apply` — apply schemas to the active env (local or dev).
- `supabase functions deploy [name]` — deploy edge functions to the active cloud-dev project (or all functions if `name` omitted). The agent should run this whenever it adds or modifies a function on a cloud-dev project — otherwise the new code never reaches the server and the user can't test it.
- `supabase secrets set KEY=value` — set edge-function secrets on the active cloud-dev project.
- `agentlink env deploy dev --yes` — full dev-env apply (schemas + functions + secrets). Equivalent to running the three above in sequence.
- `agentlink db migrate <name>` — generate a migration file for review (no DB changes).

**The agent must NOT — without explicit, in-message user approval:**

- `agentlink env deploy prod` (and `--yes` / `--non-interactive` variants).
- `agentlink env use prod` (switching the active env to prod silently changes which DB every subsequent agent action targets).
- `supabase db push` against a `prod` project URL.
- `supabase functions deploy` when the active env is `prod`.
- `supabase secrets set` against a `prod` project ref.
- `agentlink env add prod` / `agentlink env add prod --retry` / `agentlink destroy` against any prod env.

The signal is the **active env name in `agentlink.json` (`manifest.cloud.default`)**. If it's `local` or `dev`, deploy freely. If it's `prod`, stop and ask. The fixed three-env model (`local`, `dev`, `prod`) means the agent never has to guess whether an env is production-tier — the name tells you.

**Available commands the agent surfaces but doesn't auto-run:**

- `agentlink env deploy [name]` — picker form, preselects active env. The agent points users here when they want to deploy from prod themselves.
- `agentlink env deploy <name> --dry-run` — preview a deploy without applying. Safe to run against any env, including `prod`, since it doesn't mutate.
- `agentlink env add prod` — first-time prod setup (full bootstrap). Always developer-initiated.
- `agentlink env add <name> --retry` — re-apply a partially-failed bootstrap. Agent can run against `dev`; defer to the user for `prod`.
- `agentlink env use <name>` — switch the active env. `local ↔ dev` is fine for the agent; `→ prod` requires user approval.

When the user explicitly says "deploy to prod" / "ship this" / "run env deploy prod" — that's the explicit approval. Run it once, in one command, and don't infer permission to do future prod deploys from a single approval.

> The top-level `agentlink deploy` command was removed — the CLI errors with a pointer at `agentlink env deploy` if anyone types the old form. CI workflows generated by older `env add --setup-ci` runs must be regenerated (they now emit `env deploy <name> --yes --non-interactive`).

---

## Architecture

100% Supabase — one platform, no extra infrastructure. Know what each layer is for and use the right one.

### RPC-First → `rpc` skill

Business logic lives in Postgres functions exposed as RPCs. The `public` schema is **not** exposed via the Data API — **all** data operations go through functions in a dedicated `api` schema. This applies everywhere: frontend components, edge functions, webhooks, cron jobs, server-side code — no exceptions.

```
api schema (exposed to Data API)
└── Functions only — the entire data access surface
    ├── chart_create()          ← agent builds these
    ├── chart_get_by_id()
    ├── tenant_select()         ← scaffolded by CLI
    └── profile_get()           ← scaffolded by CLI

public schema (NOT exposed — invisible to REST/Data API)
├── Tables — profiles, tenants, memberships, invitations (scaffolded), charts, ... (agent builds)
├── _auth_* functions — RLS policy helpers (_auth_tenant.sql scaffolded, _auth_{entity}.sql agent builds)
└── _internal_admin_* functions — vault, edge function calls, set_updated_at (scaffolded)
```

`supabase.from('charts').select()` literally doesn't work — the table isn't exposed. Even with a service role key, `.from()` targets the exposed schema (`api`), which has no tables. **All data access goes through `.rpc()` — always.**

### Edge Functions for Externals → `edge-functions` skill

Edge Functions handle webhooks, third-party APIs, and anything outside the database. If it talks to an external service, it's an edge function — not a Postgres function.

### Cron + Queues in Postgres

Background work runs on `pg_cron` and `pgmq`. No external job runners.

### RLS + Schema Isolation → `auth` skill

Row-Level Security on every table. Schema isolation keeps application logic out of the `public` schema. Access control and tenant isolation are enforced by the database.

### Development → `database` skill

Develop with the Supabase CLI — locally via Docker or against a cloud project. Check `CLAUDE.md` for mode-specific commands.

---

## Core Rules

### Database workflow

The agent focuses on development. Write SQL, apply it, keep building. Migrations are a separate deployment concern — not part of the build loop.

1. **Write SQL** to schema files in `supabase/schemas/` (not to migration files)
2. **Apply** — `npx create-agentlink@latest db apply`
3. **Fix errors** with more SQL — never reset the database
4. **Iterate** until the feature is complete

Schema files are the source of truth. The live database is the working copy. Both must always reflect the same state.

```
supabase/schemas/
├── _schemas.sql              # CREATE SCHEMA api; + role grants (MUST be first migration)
├── public/
│   ├── profiles.sql           # scaffolded — table + trigger + policies
│   ├── multitenancy.sql       # scaffolded — tenants + memberships + invitations
│   ├── _auth_tenant.sql       # scaffolded — tenant auth helpers
│   ├── _internal_admin.sql    # scaffolded — utility functions + set_updated_at
│   └── charts.sql             # agent builds — table + indexes + triggers + policies
└── api/
    ├── tenant.sql             # scaffolded — tenant/invitation/membership RPCs
    ├── profile.sql            # scaffolded — profile RPCs
    └── chart.sql              # agent builds — api.chart_* functions + grants
```

**Migrations** are generated only when the user explicitly asks, or as part of a deployment workflow. Use `npx create-agentlink@latest db migrate name` — never create migration files manually.

Load the `database` skill for the full workflow, schema file conventions, and worked examples.

### Always schema-qualify

Every SQL identifier must include its schema (`public.charts`, `public._auth_*`, `api.chart_create`). No bare names — in definitions, calls, grants, or anywhere else.

Load the `database` skill for full NOT THIS / THIS examples.

### Schema usage

Every schema has one job. Put things in the right place.

| Schema       | Purpose             | Contains                                                                                       |
| ------------ | ------------------- | ---------------------------------------------------------------------------------------------- |
| `api`        | Exposed to Data API | RPC functions only — the entire data access surface for all code. Use `rpc` skill.             |
| `public`     | NOT exposed         | Tables, RLS policies, `_auth_*` and `_internal_admin_*` functions. Use `database` and `auth` skills. |
| `extensions` | Postgres extensions | All extensions (`pg_cron`, `pgmq`, `pgcrypto`, etc.). Always `WITH SCHEMA extensions`.         |

```sql
-- ❌ WRONG — extension in wrong schema
CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA pg_catalog;

-- ✅ CORRECT
CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA extensions;
```

Load the `database` skill for schema file conventions, naming, and setup.

### Never use `.from()` — all data goes through `.rpc()`

`.from()` queries tables via the Data API, but only the `api` schema is exposed — and `api` has no tables, only functions. This means `.from()` will always fail or return nothing, regardless of whether you use a publishable key or a service role key. **This applies to all code** — frontend, edge functions, webhooks, cron handlers, server routes.

```typescript
// ❌ WRONG — .from() cannot reach tables in the public schema
const { data } = await supabase.from("charts").select("*");

// ❌ ALSO WRONG — service role key doesn't change which schema is exposed
const admin = createClient(url, secretKey, { db: { schema: "public" } });
const { data } = await admin.from("charts").select("*");

// ✅ CORRECT
const { data } = await supabase.rpc("chart_create", { p_name: "My Chart" });

// ✅ CORRECT — within withSupabase context
const { data } = await ctx.supabase.rpc("chart_get_by_id", { p_chart_id: id });
const { data } = await ctx.supabaseAdmin.rpc("chart_admin_cleanup");
```

Load the `rpc` skill for function patterns. Load the `frontend` skill for client setup and auth state.

### Security context: SECURITY INVOKER by default

```sql
-- ✅ CORRECT — RLS handles access control automatically
CREATE FUNCTION api.chart_get_by_id(p_chart_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
BEGIN
  SELECT ... FROM public.charts WHERE id = p_chart_id; -- RLS enforces permissions
END; $$;
```

**SECURITY DEFINER only when required:**

- `_auth_*` functions called by RLS policies (bypass RLS to query the table they protect)
- `_internal_admin_*` utility functions that need elevated access (vault secrets, auth.users)
- Always document WHY: `-- SECURITY DEFINER: required because ...`

Load the `auth` skill for RLS policies, RBAC, and multi-tenancy.

### Function prefixes

| Type           | Pattern                          | Security |
| -------------- | -------------------------------- | -------- |
| Client RPCs    | `api.{entity}_{action}`          | INVOKER  |
| Admin RPCs     | `api._admin_{name}`              | DEFINER  |
| Auth (RLS)     | `public._auth_{entity}_{check}`  | DEFINER  |
| Internal admin | `public._internal_admin_{name}`  | DEFINER  |
| Auth hooks     | `public._hook_{hook_name}`       | DEFINER  |

Load the `rpc` skill for CRUD templates, pagination, and error handling.

### `@agentlink` annotations

Never add `-- @agentlink` annotations to SQL files. These are CLI metadata for scaffolded resources — the `info` command parses them, and `--force-update` uses them to decide which functions to update. Add regular SQL comments instead. To override a managed function, remove its existing annotation block — see "Customizing a managed function" above.
