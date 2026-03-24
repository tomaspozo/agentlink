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
├── _schemas.sql              # CREATE SCHEMA api; + role grants
├── public/
│   ├── profiles.sql           # table + indexes + triggers + policies
│   ├── multitenancy.sql       # tenants + memberships + invitations (FK order)
│   ├── charts.sql             # custom entity table (example)
│   ├── _auth_tenant.sql       # Scaffolded _auth_* tenant helpers
│   ├── _auth_chart.sql        # Custom _auth_* helpers (if needed)
│   └── _internal_admin.sql    # Shared _internal_admin_* utility functions
└── api/
    ├── tenant.sql             # Scaffolded api.tenant_* + invitation + membership RPCs
    ├── profile.sql            # Scaffolded api.profile_* RPCs
    └── chart.sql              # Custom api.chart_* functions
```

Files are grouped by Postgres schema (`public/`, `api/`) with entity-centric files inside. Statement ordering is handled automatically by `pgdelta declarative apply`.

**Conventions:**
- `public/` files = **plural** (match table names): `charts.sql`
- `api/` files = **singular** (match entity): `chart.sql`
- `_` prefix = shared/infrastructure: `_auth_{entity}.sql`, `_internal_admin.sql`, `_schemas.sql`
- Entity files in `public/` contain everything for that entity: table, indexes, triggers, policies
- Tables with FK dependencies that must be created in order go in a single file (e.g., `multitenancy.sql` for tenants → memberships → invitations)

### Schema File Style Rules

- No `DROP` statements in schema files — clean declarations only
- Use: `CREATE TABLE IF NOT EXISTS`, `CREATE OR REPLACE FUNCTION`, `CREATE INDEX IF NOT EXISTS`, plain `CREATE POLICY`, plain `CREATE TRIGGER`
- Exception: use `DROP POLICY IF EXISTS` + `CREATE POLICY` for idempotent policies (policies don't support `CREATE OR REPLACE`)
- Use `record` type in `DECLARE` blocks (not `public.tablename%rowtype`) — avoids ordering issues with `pgdelta`
- `DROP` statements belong in migrations only (for renaming/cleanup)
- Reason: schema files represent desired state for `pgdelta`; unnecessary drops create phantom diffs

### `@agentlink` Annotations

Never add `-- @agentlink` comment annotations to SQL files. These are reserved metadata for CLI-scaffolded resources only — the CLI's `info` command parses them. The agent can add regular SQL comments but must never use the `-- @agentlink` prefix.

```sql
-- @agentlink my_function    ← WRONG, agent must not add this
-- @type function             ← WRONG
```

Regular comments are fine:
```sql
-- Creates a new chart for the authenticated user
CREATE OR REPLACE FUNCTION api.chart_create(...)
```

**Which schema for what:**
- `api.*` — Client-facing RPCs (the only things exposed via the Data API)
- `public.*` — Tables, `_auth_*` functions, `_internal_admin_*` functions, triggers
- `extensions.*` — All Postgres extensions. Always `CREATE EXTENSION ... WITH SCHEMA extensions`
- Never create tables in `api` — it contains functions only

---

## Development Loop

1. **Write SQL** to the appropriate schema file (see organization above)
2. **Apply** — `npx @agentlink.sh/cli@latest db apply`
3. **Fix errors** with more SQL — never reset the database
4. **Iterate** until the feature is complete

> **Companion:** If `supabase-postgres-best-practices` is available, invoke it to review schema changes before proceeding.

`db apply` auto-generates TypeScript types after applying schemas. To regenerate types separately: `npx @agentlink.sh/cli@latest db types`.

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
| Policies | descriptive English | `"Users can read own charts"` |
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
PERFORM _internal_admin_call_edge_function('queue-worker');

-- ✅ THIS
PERFORM public._internal_admin_call_edge_function('queue-worker');

-- ❌ NOT THIS — bare GRANT/REVOKE
GRANT EXECUTE ON FUNCTION _internal_admin_get_secret(text) TO service_role;

-- ✅ THIS
GRANT EXECUTE ON FUNCTION public._internal_admin_get_secret(text) TO service_role;
```

---

## Troubleshooting

If something is missing or broken, use `check` to diagnose and `--force-update` to fix:

1. **Diagnose:** `npx @agentlink.sh/cli@latest check` → read the JSON output, look at which fields are `false`
2. **Fix:** `npx @agentlink.sh/cli@latest --force-update` → re-applies all setup (templates, config, SQL, migrations)
3. **Verify:** `npx @agentlink.sh/cli@latest check` → confirm `ready: true`

| Issue | Diagnose with `check` | Fix |
|-------|----------------------|-----|
| Missing `_internal_admin_*` functions | `database.functions: false` | `npx @agentlink.sh/cli@latest --force-update` |
| Missing extensions (`pg_net`, `supabase_vault`) | `database.extensions: false` | `npx @agentlink.sh/cli@latest --force-update` |
| Missing vault secrets | `database.secrets: false` | `npx @agentlink.sh/cli@latest --force-update` |
| Missing `api` schema or grants | `database.api_schema: false` | `npx @agentlink.sh/cli@latest --force-update` |
| Missing `supabase/schemas/` structure | `files: false` | `npx @agentlink.sh/cli@latest --force-update` |

Use `npx @agentlink.sh/cli@latest info <component>` to understand what a missing component does before fixing it.

---

## Reference Files

- **[📝 Development](./references/workflow.md)** — Development loop, worked examples
- **[📋 Naming Conventions](./references/naming_conventions.md)** — Tables, columns, functions, schema files

