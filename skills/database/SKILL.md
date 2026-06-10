---
name: database
description: Schema files, migrations, and type generation for Supabase Postgres. Use when the task involves creating or modifying tables, columns, indexes, triggers, RLS policies, or database functions. Activate whenever the task touches supabase/schemas/, supabase/migrations/, or involves structural database changes.
---

# Database

Schema files, migrations, and type generation. Architecture and core rules are in the builder agent.

---

## Schema File Organization

```
supabase/schemas/
├── _schemas.sql                       # CREATE SCHEMA api; + role grants (root level)
├── _extensions.sql                    # extensions (root level)
├── public/
│   ├── tables/
│   │   ├── profiles.sql                # one table + its grants/RLS/indexes/triggers
│   │   ├── tenants.sql
│   │   └── charts.sql                  # custom entity table (example)
│   └── functions/
│       ├── _auth_tenant_id.sql         # one function per file
│       ├── _internal_admin_handle_new_user.sql
│       └── _hook_custom_access_token.sql
└── api/
    ├── tables/
    │   └── agentlink_tasks.sql         # PGMQ queue
    ├── functions/
    │   ├── tenant_create.sql           # one RPC per file
    │   ├── profile_get.sql
    │   └── chart_create.sql            # custom api.chart_create
    └── cron/
        └── process-stale-tasks.sql     # cron jobs
```

Files are **one object per file** — each table (with its grants, RLS, indexes, triggers) and each function lives in its own file, grouped by Postgres schema (`public/`, `api/`) and kind (`tables/`, `functions/`, `cron/`). Statement ordering is handled automatically: pg-delta topologically sorts statements by dependency at apply time, so file count and order are irrelevant.

**Conventions:**
- `public/tables/<table>.sql` — one table, named for the table (plural): `charts.sql`, contains the table + its indexes, triggers, grants, RLS policies
- `public/functions/<fn>.sql` — one function, named for the function: `_auth_chart_owner.sql`, `_internal_admin_handle_new_user.sql`
- `api/functions/<rpc>.sql` — one RPC, named for the function: `chart_create.sql`, `chart_get.sql`
- `_schemas.sql` and `_extensions.sql` stay at the root level
- Even tables with FK dependencies get their own files — pg-delta orders the `CREATE` statements by dependency, so `tenants.sql`, `memberships.sql`, and `invitations.sql` can each be separate

### Schema File Style Rules

- No `DROP` statements in schema files — clean declarations only
- Use: `CREATE TABLE IF NOT EXISTS`, `CREATE OR REPLACE FUNCTION`, `CREATE INDEX IF NOT EXISTS`, plain `CREATE POLICY`, plain `CREATE TRIGGER`
- Exception: use `DROP POLICY IF EXISTS` + `CREATE POLICY` for idempotent policies (policies don't support `CREATE OR REPLACE`)
- Use `record` type in `DECLARE` blocks (not `public.tablename%rowtype`) — avoids ordering issues with `pgdelta`
- `DROP` statements belong in migrations only (for renaming/cleanup)
- Reason: schema files represent desired state for `pgdelta`; unnecessary drops create phantom diffs

### Managed files (no annotations)

`-- @agentlink` annotations no longer exist — never add them. The CLI tracks managed resources via a committed base snapshot at `.agentlink/template-base/` (one entry per template file), not via inline comments. Plain SQL comments are always fine:

```sql
-- Creates a new chart for the authenticated user
CREATE OR REPLACE FUNCTION api.chart_create(...)
```

**To customize a managed function**, just edit its per-object file (e.g., `supabase/schemas/public/functions/_internal_admin_handle_new_user.sql`) and run `npx agentlink-sh@latest db apply`. On the next update the base-snapshot merge detects your edit and preserves it — silently when only you changed it, or as a surfaced conflict when the template also changed. Keep the same function name and schema. See the builder agent's "Customizing a managed function" section for the full model.

**Which schema for what:**
- `api.*` — Client-facing RPCs (the only things exposed via the Data API)
- `public.*` — Tables, `_auth_*` functions, `_internal_admin_*` functions, triggers
- `extensions.*` — All Postgres extensions. Always `CREATE EXTENSION ... WITH SCHEMA extensions`
- Never create tables in `api` — it contains functions only

**RLS on every table is ISOLATION-ONLY.** When you create a tenant-scoped table, give it `ENABLE ROW LEVEL SECURITY` and a cheap policy scoping rows to the tenant/owner — `tenant_id = (SELECT public._auth_tenant_id())` and/or `user_id = (SELECT auth.uid())`. Do **not** put permission checks (`_auth_has_permission(...)`) in policies. Permission/action authz lives in the `api.*` RPC via `public.auth_verify_access('<entity>.<action>')`. See the `auth` skill's four-layer Security Model and checklist.

**GRANT every table explicitly — default-deny.** Supabase stopped auto-granting table privileges in 2026, and AgentLink keeps that posture on purpose: a `public` table is **unreachable until you grant it**, so internal/audit/extension tables stay private (least privilege). The `api.*` RPCs are `SECURITY INVOKER` (they touch tables **as the caller**), so a table with no grant fails `42501 permission denied for table …` — and because local dev is also new-default (`config.toml` sets `auto_expose_new_tables = false`), a forgotten grant fails **immediately in dev**, not silently on prod. Grant `authenticated, service_role` (never `anon`), bundled with the RLS enable:

```sql
CREATE TABLE IF NOT EXISTS public.charts ( ... );
ALTER TABLE public.charts ENABLE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.charts TO authenticated, service_role;

-- READ-ONLY for authenticated (e.g. reference data): grant SELECT only;
-- service_role keeps full DML for seeding.
ALTER TABLE public.refs ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON public.refs TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.refs TO service_role;

-- INTERNAL table (only DEFINER / service-side code touches it): grant NOTHING
-- to authenticated — it stays unreachable through INVOKER RPCs.
ALTER TABLE public._audit_log ENABLE ROW LEVEL SECURITY;   -- no GRANT = private
```

These grants are real declarative schema: `db apply` applies them on dev, and `db migrate` carries them into the migration so they reach prod (`db push`). **Never grant `anon` on tables** — anon-facing RPCs are `SECURITY DEFINER` and run as the owner, so anon never needs a table grant. (Grants and RLS are separate layers: grant = "can the role touch the table"; RLS = "which rows.")

**Functions are default-deny too — and mostly automatic.** Postgres grants `EXECUTE` on every new function to `PUBLIC` (incl. `anon`); AgentLink revokes that so a function is callable only by roles granted explicitly. You rarely write function grants:
- **`api.*` RPCs** auto-grant `EXECUTE` to `authenticated, service_role` (the `api` schema's default privilege) — write the function, done. For an **anon-callable** RPC, add `GRANT EXECUTE ON FUNCTION api.<fn>(<args>) TO anon;` (and make it `SECURITY DEFINER` so it runs as owner). Always keep the `auth_verify_access(...)` guard — it's the real allow/deny, regardless of who can execute.
- **`public.*` helpers** are private by default. An RLS helper a policy calls needs `GRANT EXECUTE ON FUNCTION public.<fn>(<args>) TO authenticated;` (RLS evaluates it as the querying role). A `SECURITY DEFINER` helper you call from an RPC needs `GRANT EXECUTE … TO authenticated` (or `service_role`) for that caller. Trigger functions need no grant.

The CLI keeps this enforced on prod: `db migrate` appends a blanket `REVOKE EXECUTE ON ALL FUNCTIONS … FROM PUBLIC` to any migration that creates a function (Postgres's `PUBLIC` default can't be suppressed any other way, and pg-delta won't carry per-function revokes). So a new function is locked from `anon` automatically; your job is just the explicit `GRANT` for whoever *should* call it.

---

## Development Loop

1. **Write SQL** to the appropriate schema file (see organization above)
2. **Apply** — `npx agentlink-sh@latest db apply`
3. **Fix errors** with more SQL — never reset the database
4. **Iterate** until the feature is complete

> **Companion:** If `supabase-postgres-best-practices` is available, invoke it to review schema changes before proceeding.

`db apply` auto-generates TypeScript types after applying schemas. To regenerate types separately: `npx agentlink-sh@latest db types`.

The DB URL is auto-resolved from `.env.local` (written by the CLI during setup). No `--db-url` flag needed in either local or cloud mode.

**Migrations are not part of the development loop.** The agent writes SQL, applies it, and keeps building. Migrations are generated only when the user explicitly asks, or as part of a deployment workflow to promote changes to another environment. See the `cli` skill for migration commands.

> **📝 Load [Development](./references/workflow.md) for the full workflow, error handling, and worked examples (new entity, new field, triggers).**

The database is **never** reset unless the user explicitly requests it.

---

## Naming Conventions (summary)

| Object | Pattern | Example |
|--------|---------|---------|
| Tables | plural, snake_case | `public.charts`, `public.user_profiles` |
| Columns | singular, snake_case | `user_id`, `created_at` |
| Client RPCs | `api.{entity}_{action}` | `api.chart_create`, `api.chart_get_by_id` |
| Admin RPCs | `api._admin_{name}` | `api._admin_enqueue_task`, `api._admin_queue_read` |
| Auth functions | `public._auth_{entity}_{check}` | `public._auth_chart_can_read` |
| Internal admin | `public._internal_admin_{name}` | `public._internal_admin_get_secret` |
| Auth hooks | `public._hook_{hook_name}` | `public._hook_before_user_created` |
| Indexes | `idx_{table}_{columns}` | `idx_charts_user_id` |
| Policies | `{role}_{action}_{table}` | `users_read_own_charts` |
| Triggers | `trg_{table}_{event}` | `trg_charts_updated_at` |

> **📋 Load [Naming Conventions](./references/naming_conventions.md) for the full reference.**

## Always Schema-Qualify

Every table, function, and object reference in SQL must include its schema. Never use bare names — even inside function bodies, in CREATE/DROP, or in GRANT/REVOKE.

```sql
-- ❌ NOT THIS — bare table names
SELECT * FROM charts WHERE user_id = auth.uid();

-- ✅ THIS — schema-qualified
SELECT * FROM public.charts WHERE user_id = auth.uid();

-- ❌ NOT THIS — bare function definition
CREATE OR REPLACE FUNCTION _auth_chart_can_read(p_chart_id uuid) ...

-- ✅ THIS
CREATE OR REPLACE FUNCTION public._auth_chart_can_read(p_chart_id uuid) ...

-- ❌ NOT THIS — bare function call
PERFORM _internal_admin_call_edge_function('internal-queue-worker');

-- ✅ THIS
PERFORM public._internal_admin_call_edge_function('internal-queue-worker');

-- ❌ NOT THIS — bare GRANT/REVOKE
GRANT EXECUTE ON FUNCTION _internal_admin_get_secret(text) TO service_role;

-- ✅ THIS
GRANT EXECUTE ON FUNCTION public._internal_admin_get_secret(text) TO service_role;
```

---

## Troubleshooting

If something is missing or broken, use `check` to diagnose and `--force-update` to fix:

1. **Diagnose:** `npx agentlink-sh@latest check` → read the JSON output, look at which fields are `false`
2. **Fix:** `npx agentlink-sh@latest --force-update` → re-applies all setup (templates, config, SQL, migrations)
3. **Verify:** `npx agentlink-sh@latest check` → confirm `ready: true`

| Issue | Diagnose with `check` | Fix |
|-------|----------------------|-----|
| Missing `_internal_admin_*` functions | `database.functions: false` | `npx agentlink-sh@latest --force-update` |
| Missing extensions (`pg_net`, `supabase_vault`) | `database.extensions: false` | `npx agentlink-sh@latest --force-update` |
| Missing vault secrets | `database.secrets: false` | `npx agentlink-sh@latest --force-update` |
| Missing `api` schema or grants | `database.api_schema: false` | `npx agentlink-sh@latest --force-update` |
| Missing `supabase/schemas/` structure | `files: false` | `npx agentlink-sh@latest --force-update` |

Use `npx agentlink-sh@latest info <component>` to understand what a missing component does before fixing it.

---

## Reference Files

- **[📝 Development](./references/workflow.md)** — Development loop, worked examples
- **[📋 Naming Conventions](./references/naming_conventions.md)** — Tables, columns, functions, schema files

