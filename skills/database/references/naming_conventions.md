# Naming Conventions

Consistent naming across all database objects.

## Contents
- Tables
- Columns
- Functions (common action verbs)
- Other Objects
- Schema File Naming

## Tables

- **Plural**, snake_case
- Examples: `charts`, `user_profiles`, `readings`, `subscriptions`

## Columns

- **Singular**, snake_case
- Primary key: `id`
- Foreign keys: `{table_singular}_id` (e.g., `user_id`, `chart_id`)
- Timestamps: `created_at`, `updated_at`
- Booleans: `is_`, `has_` prefix (e.g., `is_active`, `has_verified`)
- Soft delete: `deleted_at` (nullable timestamp)

## Functions

| Type | Pattern | Example |
|------|---------|---------|
| Business logic | `api.{entity}_{action}` | `api.chart_create`, `api.chart_get_by_id`, `api.reading_archive` |
| Auth (RLS) | `public._auth_{entity}_{check}` | `public._auth_chart_can_read`, `public._auth_reading_is_owner` |
| Internal admin | `public._internal_admin_{name}` | `public._internal_admin_get_secret`, `public._internal_admin_call_edge_function` |
| Auth hooks | `public._hook_{hook_name}` | `public._hook_before_user_created` |

### Function Actions (Common Verbs)

| Action | Use Case |
|--------|----------|
| `create` | Insert new record |
| `get_by_{field}` | Retrieve by specific field |
| `list` / `list_by_{field}` | Retrieve multiple records |
| `update` | Modify existing record |
| `delete` / `archive` | Remove or soft-delete |
| `{domain_action}` | Business operations (e.g., `close`, `assign`, `approve`) |

## Other Objects

| Object | Pattern | Example |
|--------|---------|---------|
| Indexes | `idx_{table}_{column(s)}` | `idx_charts_user_id`, `idx_readings_created_at` |
| Views | `v_{name}` | `v_active_readings`, `v_user_chart_summary` |
| Materialized Views | `mv_{name}` | `mv_daily_stats` |
| Triggers | `trg_{table}_{event}` | `trg_charts_updated_at`, `trg_readings_audit` |
| Check Constraints | `chk_{table}_{description}` | `chk_charts_valid_type` |
| Unique Constraints | `uq_{table}_{column(s)}` | `uq_users_email` |
| RLS Policies | `{role}_{action}_{scope}` — snake_case, **never quoted** | `users_read_own_charts`, `admins_delete_memberships` |

### RLS Policies — never use quoted names

Policy names must always be snake_case bare identifiers. Never wrap them in double quotes, never include spaces, mixed case, or reserved words.

```sql
-- ❌ NOT THIS — quoted name with spaces
CREATE POLICY "Members can read own tenant" ON public.tenants ...

-- ✅ THIS — snake_case bare identifier
CREATE POLICY members_read_own_tenant ON public.tenants ...
```

**Why:** `npx agentlink-sh@latest db apply` uses `pg-delta` / `pg-topo`, which parses every SQL statement through libpg_query and re-emits it via `deparseSql`. The deparser canonicalizes identifiers and silently drops the surrounding quotes — so `DROP POLICY IF EXISTS "Members can read own tenant" ON …` reaches Postgres as `DROP POLICY IF EXISTS Members can read own tenant ON …` and fails with `42601: syntax error at or near "can"`. Quoted names with spaces are effectively unusable in schema files.

## Schema File Naming

Schema files are **one object per file** — name each file for the object it contains. pg-delta topologically sorts statements by dependency at apply time, so file count and order are irrelevant.

All paths below are relative to `supabase/database/`.

| Folder | File Name | Contains |
|--------|-----------|----------|
| `schemas/public/tables/` | `{table}.sql` | `charts.sql` — one table + its grants/RLS/indexes/triggers |
| `schemas/public/functions/` | `_auth_{entity}_{check}.sql` | `_auth_chart_owner.sql` — one `_auth_*` helper |
| `schemas/public/functions/` | `_internal_{name}.sql` | `_internal_admin_handle_new_user.sql` — one internal util |
| `schemas/public/functions/` | `_hook_{hook_name}.sql` | `_hook_custom_access_token.sql` — one auth hook |
| `schemas/api/functions/` | `{entity}_{action}.sql` | `chart_create.sql` — one `api.*` RPC + its grants |
| `schemas/api/tables/` | `{table}.sql` | `agentlink_tasks.sql` — PGMQ queue table |
| `cron/` (top-level, imperative) | `{job}.sql` | `process-stale-tasks.sql` — one cron job |
| `storage/` (top-level, imperative) | `{name}.sql` | `avatars.sql` — bucket + its `storage.objects` policies |
| `schemas/api/` | `schema.sql` | `CREATE SCHEMA api;` + grants / default privileges |
| `schemas/public/` | `schema.sql` | public schema-level grants (e.g. `supabase_auth_admin` USAGE) |
| `cluster/extensions/` | `{ext}.sql` | one extension install per file (`pg_net.sql`, `pgmq.sql`, …) |
| `rbac/` | `{entity}.sql` | RBAC reference DATA (rows): `roles.sql`, `permissions.sql`, `role_permissions.sql` — each fills an `rbac_desired` staging table, synced by the reconcile (NOT pg-delta) |

- Table files are named for the table; function files are named for the function
- One object per file — never bundle multiple tables or functions into one file
- `_` prefix = shared/infrastructure files
