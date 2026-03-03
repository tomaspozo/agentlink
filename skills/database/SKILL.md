---
name: database
description: Schema files, migrations, and type generation for Supabase Postgres. Use when the task involves creating or modifying tables, columns, indexes, triggers, RLS policies, or database functions. Activate whenever the task touches supabase/schemas/, supabase/migrations/, or involves structural database changes.
license: MIT
compatibility: Requires Supabase CLI, psql, and Supabase MCP server
metadata:
  author: agentlink
  version: "0.1"
---

# Database

Schema files, migrations, and type generation. Architecture and core rules are in the builder agent.

---

## Schema File Organization

```
supabase/schemas/
├── _schemas.sql              # CREATE SCHEMA api; + role grants
├── public/
│   ├── charts.sql            # table + indexes + triggers + policies (all in one)
│   ├── tenants.sql
│   ├── _auth.sql             # Shared _auth_* helper functions
│   └── _internal.sql         # Shared _internal_* utility functions
└── api/
    ├── chart.sql             # api.chart_* functions + grants
    ├── tenant.sql
    └── profile.sql
```

Files are grouped by Postgres schema (`public/`, `api/`) with entity-centric files inside. Statement ordering is handled automatically by `supabase db diff --use-pg-delta`.

**Conventions:**
- `public/` files = **plural** (match table names): `charts.sql`
- `api/` files = **singular** (match entity): `chart.sql`
- `_` prefix = shared/infrastructure: `_auth.sql`, `_internal.sql`, `_schemas.sql`
- Entity files in `public/` contain everything for that entity: table, indexes, triggers, policies

**Which schema for what:**
- `api.*` — Client-facing RPCs (the only things exposed via the Data API)
- `public.*` — Tables, `_auth_*` functions, `_internal_*` functions, triggers
- `extensions.*` — All Postgres extensions. Always `CREATE EXTENSION ... WITH SCHEMA extensions`
- Never create tables in `api` — it contains functions only

---

## Development Loop

1. **Write SQL** to the appropriate schema file (see organization above)
2. **Apply live** — Run the same SQL via `psql`
3. **Fix errors** with more SQL — never reset the database
4. **Iterate** until the feature is complete

> **Companion:** If `supabase-postgres-best-practices` is available, invoke it to review schema changes before proceeding.

5. **Generate types** — `supabase gen types typescript --local > src/types/database.ts`
6. **Create migration** — `supabase db diff --use-pg-delta -f descriptive_migration_name`

> **📝 Load [Development](./references/workflow.md) for the full workflow, error handling, and worked examples (new entity, new field, triggers).**

The database is **never** reset unless the user explicitly requests it.

---

## Naming Conventions (summary)

| Object | Pattern | Example |
|--------|---------|---------|
| Tables | plural, snake_case | `public.charts`, `public.user_profiles` |
| Columns | singular, snake_case | `user_id`, `created_at` |
| Client RPCs | `api.{entity}_{action}` | `api.chart_create`, `api.chart_get_by_id` |
| Auth functions | `public._auth_{entity}_{check}` | `public._auth_chart_can_read` |
| Internal functions | `public._internal_{name}` | `public._internal_get_secret` |
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
PERFORM _internal_call_edge_function('queue-worker');

-- ✅ THIS
PERFORM public._internal_call_edge_function('queue-worker');

-- ❌ NOT THIS — bare GRANT/REVOKE
GRANT EXECUTE ON FUNCTION _internal_get_secret(text) TO service_role;

-- ✅ THIS
GRANT EXECUTE ON FUNCTION public._internal_get_secret(text) TO service_role;
```

---

## Troubleshooting

If something is missing or broken, use `check` to diagnose and `--force-update` to fix:

1. **Diagnose:** `npx create-agentlink check` → read the JSON output, look at which fields are `false`
2. **Fix:** `npx create-agentlink --force-update` → re-applies all setup (templates, config, SQL, migrations)
3. **Verify:** `npx create-agentlink check` → confirm `ready: true`

| Issue | Diagnose with `check` | Fix |
|-------|----------------------|-----|
| Missing `_internal_*` functions | `database.functions: false` | `npx create-agentlink --force-update` |
| Missing extensions (`pg_net`, `supabase_vault`) | `database.extensions: false` | `npx create-agentlink --force-update` |
| Missing vault secrets | `database.secrets: false` | `npx create-agentlink --force-update` |
| Missing `api` schema or grants | `database.api_schema: false` | `npx create-agentlink --force-update` |
| Missing `supabase/schemas/` structure | `files: false` | `npx create-agentlink --force-update` |

Use `npx create-agentlink info <component>` to understand what a missing component does before fixing it.

---

## Reference Files

- **[📝 Development](./references/workflow.md)** — Development loop, migration workflow, worked examples
- **[📋 Naming Conventions](./references/naming_conventions.md)** — Tables, columns, functions, schema files

