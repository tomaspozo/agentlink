---
name: rpc
description: RPC-first data access for Supabase. Use when the task involves creating, modifying, or debugging database functions (RPCs), writing CRUD operations, implementing pagination, search, filtering, batch operations, or any data access logic. Also use when the task mentions business logic functions, input validation in functions, error handling in RPCs, or returning data from the database. Activate whenever the task involves writing SQL functions that clients call via supabase.rpc().
license: MIT
metadata:
  author: agentlink
  version: "0.1"
---

# RPC-First Data Access

Every client operation is a function in the `api` schema. No direct table queries. No views. The `api` schema is the only schema exposed via the Supabase Data API — tables in `public` are invisible to clients.

```typescript
// ❌ Impossible — public schema is not exposed
const { data } = await supabase.from("charts").select("*");

// ✅ The only way — calls api.chart_get_by_user()
const { data } = await supabase.rpc("chart_get_by_user");
```

## Function Anatomy

Every client-facing function follows this structure:

```sql
CREATE OR REPLACE FUNCTION api.chart_get_by_id(p_chart_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_result jsonb;
BEGIN
  SELECT jsonb_build_object(
    'id', c.id,
    'name', c.name,
    'created_at', c.created_at
  ) INTO v_result
  FROM public.charts c
  WHERE c.id = p_chart_id;

  IF v_result IS NULL THEN
    RAISE EXCEPTION 'Chart not found: %', p_chart_id;
  END IF;

  RETURN v_result;
END;
$$;
```

**Key rules:**
- **`api.` schema** — all client-facing functions live here
- **`SECURITY INVOKER`** — RLS applies automatically, no manual `auth.uid()` filtering
- **`SET search_path = ''`** — prevents search path injection
- **Fully qualified names** — `public.charts`, `public._auth_*`, `public._internal_*` — never bare names
- **No per-function `GRANT EXECUTE`** — schema-level default privileges in `_schemas.sql` handle this automatically
- **`p_` prefix** on parameters, `v_` prefix on local variables

## Security Context

**Default: SECURITY INVOKER** — the function runs as the calling user. RLS policies filter data automatically. This is correct for all client-facing functions.

**Exception: SECURITY DEFINER** — only for:
- `_auth_*` functions called by RLS policies (they need to query the table they protect)
- `_internal_*` utilities needing elevated access (vault secrets, edge function calls)
- Always add: `-- SECURITY DEFINER: required because ...`

```sql
-- This goes in public schema, NOT api — it's not client-facing
CREATE OR REPLACE FUNCTION public._auth_chart_can_read(p_chart_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER  -- required: called by RLS policies on the charts table
SET search_path = ''
AS $$
BEGIN
  RETURN EXISTS (
    SELECT 1 FROM public.charts
    WHERE id = p_chart_id AND user_id = auth.uid()
  );
END;
$$;
```

> **Load [RPC Patterns](./references/rpc_patterns.md) for CRUD templates, pagination, search, error handling, batch operations, and multi-table patterns.**

---

## CRUD Quick Reference

| Operation | Function name | Returns |
|-----------|--------------|---------|
| Create | `api.chart_create(...)` | `jsonb` (new record) |
| Get by ID | `api.chart_get_by_id(uuid)` | `jsonb` (single record) |
| List | `api.chart_list(...)` | `jsonb` (array + pagination) |
| Update | `api.chart_update(uuid, ...)` | `jsonb` (updated record) |
| Delete | `api.chart_delete(uuid)` | `jsonb` (success/error) |

**Naming:** `{entity}_{action}` — use `create`, `get_by_{field}`, `list`, `list_by_{field}`, `update`, `delete`, or domain verbs like `close`, `archive`, `approve`.

---

## Error Handling

Use `RAISE EXCEPTION` for errors. The client receives a structured error via PostgREST:

```sql
-- In the function
RAISE EXCEPTION 'Chart not found: %', p_chart_id;

-- Client receives
{ "error": { "message": "Chart not found: abc-123", "code": "P0001" } }
```

For operations that can partially succeed, return structured jsonb:

```sql
RETURN jsonb_build_object(
  'success', true,
  'chart_id', v_chart_id
);
```

---

## Reference Files

- **[📡 RPC Patterns](./references/rpc_patterns.md)** — Full CRUD templates, pagination (cursor + offset), search/filtering, batch operations, multi-table operations, input validation, return types

## Security Checklist

- [ ] Function in `api` schema (not `public`)
- [ ] `SECURITY INVOKER` (unless `_auth_*` or `_internal_*`)
- [ ] `SET search_path = ''`
- [ ] Fully qualified names — tables (`public.tablename`) and function calls (`public._auth_*`, `public._internal_*`)
- [ ] Don't manually filter by `auth.uid()` in INVOKER functions — RLS does this
- [ ] Validate input parameters before use
