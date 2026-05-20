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

| Folder | File Name | Contains |
|--------|-----------|----------|
| `public/` | `{entity_plural}.sql` | `charts.sql` — table + indexes + triggers + policies |
| `public/` | `_auth_{entity}.sql` | `_auth_tenant.sql` — `_auth_*` helper functions for an entity |
| `public/` | `{related_entities}.sql` | `multitenancy.sql` — multiple related tables with FK dependencies |
| `public/` | `_internal_admin.sql` | Shared `_internal_admin_*` utility functions |
| `public/` | `_hook_{hook_name}.sql` | Supabase auth hook PG functions |
| `api/` | `{entity_singular}.sql` | `chart.sql` — `api.*` functions + grants |
| (root) | `_schemas.sql` | `CREATE SCHEMA api;` + role grants |

- `public/` files use **plural** names (match table names)
- `api/` files use **singular** names (match entity)
- `_` prefix = shared/infrastructure files
