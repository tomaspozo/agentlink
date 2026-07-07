---
name: database
description: Schema files, migrations, and type generation for Supabase Postgres. Use when the task involves creating or modifying tables, columns, indexes, triggers, RLS policies, grants, or database functions, or the imperative cron/storage/rbac/config folders (cron jobs, storage buckets, RBAC reference data, role-level settings like db_pre_request). Activate whenever the task touches supabase/database/, supabase/migrations/, or involves structural database changes.
---

# Database

Schema files, migrations, and type generation. Architecture and core rules are in the builder agent.

---

## Schema File Organization

```
supabase/database/
├── cluster/
│   └── extensions/                     # one file per extension (cluster-level)
│       ├── pg_graphql.sql
│       ├── pg_net.sql
│       ├── pg_cron.sql
│       └── pgmq.sql
├── rbac/                               # RBAC reference DATA (rows, not schema)
│   ├── roles.sql                       # synced by the RBAC reconcile, NOT by db apply
│   ├── permissions.sql
│   └── role_permissions.sql
├── config/                             # role-level settings pg-delta can't model (imperative)
│   └── db_pre_request.sql              # ALTER ROLE authenticator SET pgrst.db_pre_request
├── queue/                              # pgmq queues — imperative, prod-safe, self-healing
│   └── agentlink_tasks.sql             # DO $$ … pgmq.create('agentlink_tasks') … $$
├── cron/                               # pg_cron jobs — imperative
│   └── process-stale-tasks.sql         # fires the queue worker every minute
├── storage/                            # buckets + storage.objects policies — imperative
│   └── avatars.sql
└── schemas/                            # DECLARATIVE — applied by db apply / diffed into migrations
    ├── api/                            # functions only — never create tables here
    │   ├── schema.sql                  # CREATE SCHEMA api + grants / default privileges
    │   └── functions/
    │       ├── tenant_create.sql       # one RPC per file
    │       ├── profile_get.sql
    │       └── chart_create.sql        # custom api.chart_create
    └── public/
        ├── schema.sql                  # public schema-level grants (e.g. supabase_auth_admin USAGE)
        ├── tables/
        │   ├── profiles.sql            # one table + its grants/RLS/indexes/triggers
        │   ├── tenants.sql
        │   └── charts.sql              # custom entity table (example)
        └── functions/
            ├── _auth_tenant_id.sql     # one function per file
            ├── _internal_admin_handle_new_user.sql
            └── _hook_before_user_created.sql
```

Files are **one object per file** — each table (with its grants, RLS, indexes, triggers) and each function lives in its own file, grouped by Postgres schema (`schemas/public/`, `schemas/api/`) and kind (`tables/`, `functions/`). Statement ordering is handled automatically: `db apply` resolves dependency order at apply time, so file count and order are irrelevant. The top-level `cron/`, `storage/`, `rbac/`, and `config/` folders are **imperative** — applied at deploy, not by `db apply`'s schema diff (see below).

**Conventions:**
- `schemas/<schema>/tables/<table>.sql` — one table, named for the table (plural): `charts.sql`, contains the table + its indexes, triggers, grants, RLS policies
- `schemas/<schema>/functions/<fn>.sql` — one function, named for the function: `_auth_chart_owner.sql`, `_internal_admin_handle_new_user.sql`, `chart_create.sql`
- `schemas/<schema>/schema.sql` — the `CREATE SCHEMA` (for `api`) plus that schema's grants / default privileges; `public/schema.sql` holds only public's schema-level grants (public already exists, so it's not `CREATE`d)
- `cluster/extensions/<ext>.sql` — one file per extension (cluster-level, not schema-scoped)
- Even tables with FK dependencies get their own files — `db apply` orders the `CREATE` statements by dependency, so `tenants.sql`, `memberships.sql`, and `invitations.sql` can each be separate

### Where to put new objects (create / edit guidelines)

When creating or editing schema objects, put each in its own file under `supabase/database/`. `db apply` resolves dependency order at apply time, so don't worry about file naming for ordering.

| Creating / editing | File |
|---|---|
| A table (+ its grants, `ENABLE ROW LEVEL SECURITY`, policies, indexes, triggers — all in this one file) | `supabase/database/schemas/<schema>/tables/<table>.sql` |
| An RPC or any function (+ its `REVOKE`/`GRANT EXECUTE`) | `supabase/database/schemas/<schema>/functions/<name>.sql` |
| A new extension | `supabase/database/cluster/extensions/<ext>.sql` |
| A new schema, or schema-level grants / default privileges | `supabase/database/schemas/<schema>/schema.sql` |
| A cron job (`cron.schedule(...)`) | `supabase/database/cron/<name>.sql` (imperative — see below). The job's body calls `public._internal_admin_call_edge_function('internal-<worker>')`; it never makes the outbound HTTP itself — `pg_net` only wakes the worker. See the [edge-functions](../edge-functions/SKILL.md) outbound-HTTP rule and [recipes.md](../../agents/references/recipes.md) for worked examples |
| A storage bucket + its `storage.objects` policies | `supabase/database/storage/<name>.sql` (imperative — see below) |
| RBAC reference data — roles / permissions / role→permission bindings (rows) | `supabase/database/rbac/<entity>.sql` (imperative — see below) |
| A role-level setting / `ALTER ROLE … SET` (e.g. `pgrst.db_pre_request`) | `supabase/database/config/<name>.sql` (imperative — see below) |
| Seed / default rows (any other `INSERT`/`UPDATE`/`DELETE`) | **NOT** a schema file — see the DDL-only rule below |

**🛑 Declarative schema files are DDL ONLY — never put seed/data DML in them.** Files under `supabase/database/schemas/` define structure (`CREATE`/`ALTER` of tables, functions, policies, …). A standalone `INSERT`/`UPDATE`/`DELETE`/`MERGE`/`TRUNCATE` in a schema file is a **mistake**: `db apply` only applies structure (table/function/policy definitions), not row data, so the statement is **silently dropped** and the data never reaches the database (the CLI now hard-errors on it, naming the file + line). This is exactly why `rbac/` exists — reference data is rows, not schema. Seed/default data belongs in one of:
- **`supabase/seed.sql`** — local dev seed, replayed by `db rebuild` / `supabase db reset`. Local only.
- **A migration** — reference data that must reach prod (author the `INSERT` directly in the migration; idempotent `ON CONFLICT DO NOTHING`).
- **`supabase/database/rbac/`** — roles / permissions / role→permission bindings (the dedicated reference-data reconcile).
- (Inside a function body, `INSERT`/`UPDATE` is fine — that's part of the function's DDL, not a standalone seed.)

**Imperative folders — `cron/`, `storage/`, `rbac/`, `config/`.** These four top-level folders under `supabase/database/` are **excluded** from `db apply`'s schema diff *and* from the migration diff, and applied imperatively by the deploy step on **every** path — `db apply` (local/dev), `db rebuild`, and **every `env deploy`** (all envs incl. prod, which is migrations-only). Reason: the `cron` and `storage` schemas are excluded from `db apply`'s schema diff and from migrations, so `cron.schedule()`, buckets, and storage policies never survive a migration; RBAC is reference DATA, not DDL; and role-level settings (`ALTER ROLE … SET`) aren't catalog objects pg-delta can diff or generate. This deploy step is the only path that reliably reaches prod — **do not** hand-append these to migration files. To apply just these folders without a full `db apply` (e.g. after editing a cron job or bucket), run `pnpm exec agentlink db resources`.

- **`cron/` and `storage/` must be IDEMPOTENT** (they re-run on every deploy): `cron.schedule(name, …)` upserts by job name (`cron.unschedule(name)` to remove); storage buckets use `INSERT … ON CONFLICT (id) DO UPDATE`; storage policies use `DROP POLICY IF EXISTS` + `CREATE POLICY`. Each folder's files run in sorted order, one transaction per folder.
- **`rbac/` is reference DATA, not schema.** The roles/permissions/role_permissions *tables* live in `schemas/public/tables/` (structure only). Their *rows* live in `rbac/<entity>.sql`, each filling an `rbac_desired` staging table, converged to **exactly** the declared set: **full reconcile** for permissions + bindings (a removed row is REVOKED everywhere — the only way revokes reach prod); roles are **upsert-only** (a referenced role can't be deleted: `memberships.role` FKs into `roles(name)`).
- **`config/` is role-level settings pg-delta can't model** — idempotent, non-catalog SQL. It ships `config/db_pre_request.sql` (`ALTER ROLE authenticator SET pgrst.db_pre_request = 'public._auth_pre_request'; NOTIFY pgrst, 'reload config';`), which wires the per-request multitenancy resolver. **🛑 An `ALTER ROLE … SET` / `db_pre_request` line has no schema-file home:** it's a role-level GUC, not a catalog object, so `db apply` and `db migrate` **ignore it** — dropped into a `schemas/**.sql` file it is **silently never applied**. On prod that means PostgREST never runs `_auth_pre_request`, so **every request resolves no workspace** → `_auth_tenant_id()` is NULL → RLS matches no rows and `_auth_has_permission()` is false → the whole app fails deny-by-default. Put such statements in `config/` (idempotent: `ALTER ROLE … SET` is last-write-wins), where the deploy step applies them on every env incl. prod.

**🛑 Editing `cron/`, `storage/`, `rbac/`, or `config/`? The workflow is: edit the file → APPLY it.** A change to these folders does nothing until applied, and they are **excluded from the schema diff** — so `db apply`'s schema step won't carry them, and a `cron.schedule()`/bucket/policy/RBAC row/`ALTER ROLE` dropped into a `schemas/` file silently never runs. After editing:
- `pnpm exec agentlink db apply` applies them **alongside** your schema (the normal dev loop already covers them — `db apply` runs the imperative step too), **or**
- `pnpm exec agentlink db resources` applies **only** `config/` + `storage/` + `cron/` + `rbac/` (no schema diff, no type-gen) — reach for this when that's *all* you changed (`db rbac-sync` is the rbac-only subset).
On deploy they go out with every `env deploy`. Concretely:

| You're changing… | Edit | Then |
|---|---|---|
| A cron job | `cron/<name>.sql` (`cron.schedule(...)`) | `db apply` or `db resources` |
| A storage **bucket** or its `storage.objects` **policies** | `storage/<name>.sql` | `db apply` or `db resources` |
| An **RBAC permission** key, or a role→permission **binding** | `rbac/permissions.sql`, `rbac/role_permissions.sql` | `db apply` or `db resources` |
| A **role-level setting** (`ALTER ROLE … SET`, e.g. `pgrst.db_pre_request`) | `config/<name>.sql` | `db apply` or `db resources` |

**🛑 Removing an already-deployed `cron/` or `storage/` resource — deprecate the file, don't just delete it.** Deleting a `cron/` or `storage/` `.sql` file does **nothing** to a database that already has the resource: the imperative step only *applies* the files present — unlike `rbac/`, it never reconciles deletions. The job keeps firing / the bucket keeps existing on local, dev, **and prod**. Use a **tombstone** so the removal travels through the normal deploy path:

1. Rename `<name>.sql` → `deprecated-<name>.sql` (one resource per file, so the file *is* the resource).
2. Comment out the original `cron.schedule(...)` / bucket `INSERT` + policies so the imperative step stops re-creating it.
3. Add a header line: *why* it's deprecated, and "safe to delete this file after the next release, once every env has deployed past it."
4. Then, **by resource type**:
   - **Cron** — append an **idempotent** unschedule. It re-runs on every deploy, so it must no-op when the job is already gone. The bare `cron.unschedule('<name>')` **THROWS** when absent → rolls back the whole cron folder on the next run; use the `jobid` form instead:
     ```sql
     SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname = '<name>';
     ```
     This removes the job from every env on the next `db apply` / `env deploy`, then cleanly no-ops.
   - **Storage** — add **NO removal SQL**. Deleting a bucket in SQL (`DELETE FROM storage.buckets`) orphans its objects, which keep counting against the user's Supabase **Storage usage** (a common, hard-to-diagnose billing/support issue). Instead, **tell the user** to delete the bucket from the Supabase **dashboard** (Storage → Buckets) so its objects cascade properly. The leftover `storage.objects` policy is inert once the bucket is gone (it filters on a `bucket_id` that matches no rows) — leave it, or have the user remove it in the dashboard too.
5. Apply the tombstone like any imperative change (`db apply` or `db resources`; it also ships with every `env deploy`). Once every long-lived env has deployed it, the `deprecated-*` file is safe to delete.

**Two different "permissions" — don't confuse them:**
- A **GRANT** on a table/function (who may `SELECT` / `EXECUTE` it) is **DDL** → it lives in that object's own `schemas/<schema>/{tables,functions}/<obj>.sql` file and applies with **`db apply`**. Changing who can run an RPC at the SQL level = edit its function file + `db apply`.
- The **RBAC permission model** (the `auth_verify_access('entity.action')` keys your RPCs check, and their role bindings) is **reference data** → it lives in `rbac/permissions.sql` + `rbac/role_permissions.sql` and applies with **`db resources`** (or `db apply` / `env deploy`). Adding a new gated capability = add the permission key + binding here, *and* call `auth_verify_access(...)` in the RPC (which is a schema-file change).

- One object per file. A table file is **self-contained**: table definition + constraints + indexes + `ENABLE ROW LEVEL SECURITY` + policies + triggers + grants all live together.
- To edit an existing object, edit its file in place (don't create a parallel file) — then run `pnpm exec agentlink db apply`.

### Migrating an existing `supabase/schemas/` project to `supabase/database/`

Older projects keep declarative SQL under `supabase/schemas/`. The home moved to `supabase/database/` (matching Supabase's `db … generate` default). On `--force-update`, the CLI recreates the **scaffolded** objects under `supabase/database/` and **leaves your old `supabase/schemas/` exactly where it is — untouched, but no longer applied** (`db apply` reads `supabase/database/` only). It then asks the user to have you finish the move. When asked, do this:

1. **Move each CUSTOM object** — anything the app added, i.e. NOT the scaffolded set (`tenants`/`memberships`/`invitations`/`profiles`/`roles`/`permissions`/`role_permissions`, the `api.*` RPCs, `_auth_*` / `_internal_*` / `_hook_*` functions, `agentlink_tasks`, `process-stale-tasks`), which already exists under `database/`. Place each in one object per file:
   - table → `supabase/database/schemas/<schema>/tables/<table>.sql` (table + its grants, `ENABLE ROW LEVEL SECURITY`, policies, indexes, triggers — all together)
   - function / RPC → `supabase/database/schemas/<schema>/functions/<name>.sql`
   - extension → `supabase/database/cluster/extensions/<ext>.sql`
   - `CREATE SCHEMA` / schema-level grants → `supabase/database/schemas/<schema>/schema.sql`
   - cron job → `supabase/database/cron/<name>.sql` (imperative)
   - storage bucket + policies → `supabase/database/storage/<name>.sql` (imperative)
   Split any consolidated/multi-object files into one-object-per-file as you go. `db apply` resolves dependency order, so file naming/order doesn't matter.
2. **Apply:** `pnpm exec agentlink db apply` — confirm the `database/` tree applies cleanly.
3. **Delete `supabase/schemas/`** once everything is migrated and applying — nothing else references it.

Never relocate `supabase/schemas/` into `.agentlink/.incoming/` — that directory is gitignored and cleared on the next update.

### Schema File Style Rules

- No `DROP` statements in schema files — clean declarations only
- Use: `CREATE TABLE IF NOT EXISTS`, `CREATE OR REPLACE FUNCTION`, `CREATE INDEX IF NOT EXISTS`, plain `CREATE POLICY`, plain `CREATE TRIGGER`
- Exception: use `DROP POLICY IF EXISTS` + `CREATE POLICY` for idempotent policies (policies don't support `CREATE OR REPLACE`)
- Use `record` type in `DECLARE` blocks (not `public.tablename%rowtype`) — avoids `db apply` dependency-ordering issues
- `DROP` statements belong in migrations only (for renaming/cleanup)
- Reason: schema files represent the desired state `db apply` converges the database to; unnecessary drops create phantom diffs

### Customizing CLI-shipped files

There are **no inline annotations** — never add `-- @agentlink` comments. Plain SQL comments are always fine:

```sql
-- Creates a new chart for the authenticated user
CREATE OR REPLACE FUNCTION api.chart_create(...)
```

**To customize a CLI-shipped file**, just edit its per-object file in place (e.g., `supabase/database/schemas/public/functions/_internal_admin_handle_new_user.sql`), keep the same function name and schema, and run `pnpm exec agentlink db apply`. The next CLI update preserves your edit — silently when only you changed it, or as a surfaced conflict when the template also changed. (Leave the `.agentlink/` directory alone — it's CLI-managed state, not something to hand-edit.) See the builder agent's "Customizing a managed function" section for the full model.

**Which schema for what:**
- `api.*` — Client-facing RPCs (the only things exposed via the Data API)
- `public.*` — Tables, `_auth_*` functions, `_internal_admin_*` functions, triggers
- `extensions.*` — All Postgres extensions. Always `CREATE EXTENSION ... WITH SCHEMA extensions`
- Never create tables in `api` — it contains functions only

**RLS on every table is ISOLATION-ONLY.** When you create a tenant-scoped table, give it `ENABLE ROW LEVEL SECURITY` and a cheap policy scoping rows to the tenant/owner — `tenant_id = (SELECT public._auth_tenant_id())` and/or `user_id = (SELECT auth.uid())`. Do **not** put permission checks (`_auth_has_permission(...)`) in policies. Permission/action authz lives in the `api.*` RPC via `public.auth_verify_access('<entity>.<action>')`. See the `auth` skill's four-layer Security Model and checklist.

**A permission-gated write must NOT be directly writable by `authenticated`.** The isolation-only split is safe *only* when the RLS policy is the complete authorization for that write. RLS never sees an `auth_verify_access('<entity>.<action>')` check, so if that check is what gates a write, the isolation policy is a *weaker* gate than the RPC — and a direct `supabase.from('t').update(...)` (or any client that reaches the table) skips the permission entirely. Match the grant to how the write actually happens:
- **Written by a `SECURITY DEFINER` helper** (`_internal_admin_*`, runs as owner, bypasses RLS) → grant that write (`INSERT`/`UPDATE`/`DELETE`) to `service_role` only. `authenticated` never touches the table for that op; a stray `… UPDATE … TO authenticated` here is dead weight that becomes a live bypass the day the `api`-only schema boundary slips.
- **Written directly by a `SECURITY INVOKER` RPC** (as the caller) → `authenticated` needs the grant and the isolation policy is the table-level gate. Use this *only* when tenant/owner isolation is the whole authorization (no per-action permission).
- **The tell:** if the RPC guards a write with `auth_verify_access(...)`, route that write through a `SECURITY DEFINER` helper and grant it to `service_role` only — not a direct INVOKER write with an `authenticated` grant. `SELECT` (and `INSERT`/`DELETE` when isolation genuinely is the whole check) stays grantable to `authenticated` as normal.

**GRANT every table explicitly — default-deny.** Supabase stopped auto-granting table privileges in 2026, and AgentLink keeps that posture on purpose: a `public` table is **unreachable until you grant it**, so internal/audit/extension tables stay private (least privilege). The `api.*` RPCs are `SECURITY INVOKER` (they touch tables **as the caller**), so a table with no grant fails `42501 permission denied for table …` — and because local dev is also new-default (`config.toml` sets `auto_expose_new_tables = false`), a forgotten grant fails **immediately in dev**, not silently on prod. Grant `authenticated, service_role` (never `anon`), bundled with the RLS enable:

```sql
CREATE TABLE IF NOT EXISTS public.charts ( ... );
ALTER TABLE public.charts ENABLE ROW LEVEL SECURITY;
-- Full DML to authenticated is right ONLY when isolation is the whole authz.
-- If a write is gated by auth_verify_access(...) in the RPC, grant that write
-- to service_role only and do it via a SECURITY DEFINER helper (see rule above).
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

**Functions are default-deny too — grant each one explicitly.** Postgres grants `EXECUTE` on every new function to `PUBLIC` (incl. `anon`); each function `REVOKE`s that and `GRANT`s only its intended roles. There is **no** schema-wide `GRANT ON ALL FUNCTIONS` — a blanket grant gets applied after the per-function REVOKEs on `db apply`, overriding them (exposing `api._admin_*` on dev), so grants are per-object, like tables.
- **`api.*` RPCs** — after the definition: `REVOKE ALL ON FUNCTION api.<fn>(<arg-types>) FROM PUBLIC;` + `GRANT EXECUTE ON FUNCTION api.<fn>(<arg-types>) TO authenticated, service_role;`. Anon-callable → add `anon` to the GRANT and make it `SECURITY DEFINER`; `_admin_*` → `REVOKE … FROM PUBLIC, anon, authenticated;` + `GRANT … TO service_role`. A missing grant = uncallable (42501). Always keep the `auth_verify_access(...)` guard — it's the real allow/deny, regardless of who can execute.
- **`public.*` helpers** are private by default. An RLS helper a policy calls needs `GRANT EXECUTE ON FUNCTION public.<fn>(<args>) TO authenticated;` (RLS evaluates it as the querying role). A `SECURITY DEFINER` helper you call from an RPC needs `GRANT EXECUTE … TO authenticated` (or `service_role`) for that caller. Trigger functions need no grant.

The CLI keeps this enforced on prod: `db migrate` appends a blanket `REVOKE EXECUTE ON ALL FUNCTIONS … FROM PUBLIC` to any migration that creates a function (Postgres's `PUBLIC` default can't be suppressed any other way, and migrations don't carry per-function revokes). So a new function is locked from `anon` automatically; your job is just the explicit `GRANT` for whoever *should* call it.

---

## Development Loop

1. **Write SQL** to the appropriate schema file (see organization above)
2. **Apply** — `pnpm exec agentlink db apply`
3. **Fix errors** with more SQL — never reset the database
4. **Iterate** until the feature is complete

> **Companion:** If `supabase-postgres-best-practices` is available, invoke it to review schema changes before proceeding.

`db apply` auto-generates TypeScript types after applying schemas. To regenerate types separately: `pnpm exec agentlink db types`.

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

1. **Diagnose:** `pnpm exec agentlink check` → read the JSON output, look at which fields are `false`
2. **Fix:** `pnpm exec agentlink --force-update` → re-applies all setup (templates, config, SQL, migrations)
3. **Verify:** `pnpm exec agentlink check` → confirm `ready: true`

| Issue | Diagnose with `check` | Fix |
|-------|----------------------|-----|
| Missing `_internal_admin_*` functions | `database.functions: false` | `pnpm exec agentlink --force-update` |
| Missing extensions (`pg_net`, `supabase_vault`) | `database.extensions: false` | `pnpm exec agentlink --force-update` |
| Missing vault secrets | `database.secrets: false` | `pnpm exec agentlink --force-update` |
| Missing `api` schema or grants | `database.api_schema: false` | `pnpm exec agentlink --force-update` |
| Missing `supabase/database/` structure | `files: false` | `pnpm exec agentlink --force-update` |

Use `pnpm exec agentlink info <component>` to understand what a missing component does before fixing it.

---

## Reference Files

- **[📝 Development](./references/workflow.md)** — Development loop, worked examples
- **[📋 Naming Conventions](./references/naming_conventions.md)** — Tables, columns, functions, schema files

