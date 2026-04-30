---
name: rpc
description: RPC-first data access for Supabase. Use when the task involves creating, modifying, or debugging database functions (RPCs), writing CRUD operations, implementing pagination, search, filtering, batch operations, or any data access logic. Also use when the task mentions business logic functions, input validation in functions, error handling in RPCs, or returning data from the database. Activate whenever the task involves writing SQL functions called via supabase.rpc().
---

# RPC-First Data Access

**Every data operation is a function in the `api` schema.** No `.from()`. No direct table queries. No views. The `api` schema is the only schema exposed via the Supabase Data API — tables in `public` are invisible. This applies to all code: frontend components, edge functions, webhooks, cron jobs, server routes — no exceptions.

```typescript
// ❌ WRONG — .from() cannot reach tables (public schema is not exposed)
const { data } = await supabase.from("charts").select("*");

// ❌ ALSO WRONG — even with service role key, .from() won't reach public tables
const admin = createClient(url, secretKey, { db: { schema: "public" } });
const { data } = await admin.from("charts").select("*");

// ✅ CORRECT
const { data } = await supabase.rpc("chart_get_by_user");

// ✅ CORRECT — within withSupabase context
const { data } = await ctx.supabase.rpc("chart_get_by_user");
const { data } = await ctx.supabaseAdmin.rpc("chart_admin_cleanup");
```

## Function Anatomy

Every `api` schema function follows this structure:

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
- **`api.` schema** — all data access functions live here
- **`SECURITY INVOKER`** — RLS applies automatically, no manual `auth.uid()` filtering
- **`SET search_path = ''`** — prevents search path injection
- **Fully qualified names** — `public.charts`, `public._auth_*`, `public._internal_admin_*` — never bare names
- **No per-function `GRANT EXECUTE` for client RPCs** — schema-level default privileges in `_schemas.sql` automatically grant EXECUTE on every new function in `api` to `anon`, `authenticated`, and `service_role`. **Exception:** `api._admin_*` functions MUST add an explicit `REVOKE … FROM PUBLIC, anon, authenticated; GRANT EXECUTE … TO service_role` block to override the schema defaults — otherwise they're silently exposed to anon and the DEFINER linter (0028) fires. See "Admin-only RPCs" below.
- **`p_` prefix** on parameters, `v_` prefix on local variables

## Security Context

**Mandatory rule: every function in the `api` schema is `SECURITY INVOKER`. No exceptions.**

The Supabase database linter (lints 0028 and 0029) flags any `SECURITY DEFINER` function in an exposed schema that's executable by `anon` or `authenticated`. Even if your function carefully validates `auth.uid()` internally, the linter (correctly) treats the API surface as a security perimeter. The fix isn't to argue with the linter — it's to keep the privilege boundary out of `api` entirely.

**Pattern: api wrapper (INVOKER) → `_internal_admin_*` helper (DEFINER)**

When a client RPC genuinely needs to do something privileged — write to `auth.users`, bypass RLS to validate a token, call a `service_role`-gated helper — split the work:

1. The api function is `SECURITY INVOKER`. It validates the caller (gets `auth.uid()`, checks RLS-readable preconditions, raises if anything's off).
2. It then calls a `public._internal_admin_*` helper for the privileged side-effect.
3. The helper is `SECURITY DEFINER` but lives in `public` — which is **not** exposed via PostgREST, so the linter doesn't see it.
4. The helper revalidates `auth.uid() = p_user_id` as defense-in-depth (defends against direct calls bypassing the wrapper) and then does the privileged write.

```sql
-- ❌ WRONG — DEFINER in api triggers lints 0028/0029
CREATE OR REPLACE FUNCTION api.tenant_select(p_tenant_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER       -- linter flags this
SET search_path = ''
AS $$
BEGIN
  -- ... checks membership, then UPDATE auth.users ...
END; $$;

-- ✅ CORRECT — INVOKER wrapper in api delegates to DEFINER helper in public
CREATE OR REPLACE FUNCTION public._internal_admin_set_tenant_claims(
  p_user_id uuid, p_tenant_id uuid, p_role text
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER       -- in public, not exposed → linter doesn't see it
SET search_path = ''
AS $$
BEGIN
  -- Defense in depth: caller must match auth.uid()
  IF (SELECT auth.uid()) IS DISTINCT FROM p_user_id THEN
    RAISE EXCEPTION 'Cannot set claims for another user';
  END IF;
  UPDATE auth.users SET raw_app_meta_data = ... WHERE id = p_user_id;
END; $$;

REVOKE ALL ON FUNCTION public._internal_admin_set_tenant_claims(uuid, uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._internal_admin_set_tenant_claims(uuid, uuid, text) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION api.tenant_select(p_tenant_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER       -- api is always INVOKER
SET search_path = ''
AS $$
DECLARE
  v_user_id uuid := (SELECT auth.uid());
  v_role text;
BEGIN
  SELECT role INTO v_role FROM public.memberships
   WHERE tenant_id = p_tenant_id AND user_id = v_user_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Not a member of this tenant'; END IF;

  PERFORM public._internal_admin_set_tenant_claims(v_user_id, p_tenant_id, v_role);
  RETURN ...;
END; $$;
```

**Where DEFINER is allowed:**

| Location | Purpose | Linter? |
|---|---|---|
| `public._auth_*` | RLS policy helpers (must bypass RLS to query the table they protect) | Hidden — public not exposed |
| `public._internal_admin_*` | Privileged side-effects (vault, auth.users writes, calling service_role-gated functions) | Hidden — public not exposed |
| `public._hook_*` | Auth hooks granted only to `supabase_auth_admin` | Hidden — granted to a non-API role |
| `api._admin_*` | Admin-only RPCs revoked from anon/authenticated, granted only to `service_role` | Silent — linter respects explicit revokes |

**Never** put a DEFINER function in `api` and grant it to `anon` or `authenticated`. If the function genuinely needs DEFINER, it belongs in `public` with a thin INVOKER wrapper in `api`.

```sql
-- Common helper pattern for RLS — lives in public, called by RLS policies
CREATE OR REPLACE FUNCTION public._auth_chart_can_read(p_chart_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER  -- required: called by RLS policies on the charts table
SET search_path = ''
AS $$
BEGIN
  RETURN EXISTS (
    SELECT 1 FROM public.charts
    WHERE id = p_chart_id AND user_id = (SELECT auth.uid())
  );
END;
$$;
```

### Admin-only RPCs (`api._admin_*`)

When an RPC is called only by trusted server-side code — edge functions using `supabaseAdmin.rpc()`, cron handlers, the queue worker, etc. — and **never** by a logged-in user, name it `api._admin_{action}` and lock it down with explicit grants.

**Why the explicit grants are mandatory:** the schema-level defaults in `_schemas.sql` automatically grant EXECUTE on every new function in `api` to `anon`, `authenticated`, and `service_role`. For client RPCs that's correct — RLS does the filtering. For admin RPCs (which are typically `SECURITY DEFINER` so they can bypass RLS), the auto-grant to anon/authenticated would expose privileged operations to the API surface, and lints 0028/0029 fire. You override the defaults with an explicit `REVOKE` + a narrow `GRANT`.

```sql
-- ✅ CORRECT — admin-only RPC with explicit grants
CREATE OR REPLACE FUNCTION api._admin_purge_old_records(p_older_than_days int)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER       -- bypasses RLS to delete across all tenants
SET search_path = ''
AS $$
DECLARE v_count int;
BEGIN
  DELETE FROM public.audit_logs
   WHERE created_at < now() - (p_older_than_days || ' days')::interval;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

REVOKE ALL ON FUNCTION api._admin_purge_old_records(int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION api._admin_purge_old_records(int) TO service_role;
```

**Both lines are required.** `REVOKE ALL FROM PUBLIC, anon, authenticated` strips the auto-grant; `GRANT EXECUTE TO service_role` re-grants only to the service-role principal that actually needs it. Without the REVOKE, anon retains EXECUTE despite the GRANT (because grants don't override defaults — only revokes do).

**When to use `api._admin_*` vs. `public._internal_admin_*`:**

- **`api._admin_*`** — when the function must be reachable via PostgREST `.rpc()` (i.e. invoked from an edge function via `supabaseAdmin.rpc("_admin_foo")`).
- **`public._internal_admin_*`** — when the function is called only from within the database (RLS policies, triggers, other functions). Not exposed via the Data API at all.

If you're not sure, prefer `public._internal_admin_*`. The `api._admin_*` form exists for the narrow case where edge functions need to reach the helper.

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
- [ ] `SECURITY INVOKER` — **always** in `api`. If you need DEFINER for a side-effect, put it in `public._internal_admin_*` and call it from your INVOKER wrapper.
- [ ] `SET search_path = ''`
- [ ] Fully qualified names — tables (`public.tablename`) and function calls (`public._auth_*`, `public._internal_admin_*`)
- [ ] Don't manually filter by `auth.uid()` in INVOKER functions — RLS does this
- [ ] Validate input parameters before use
- [ ] If you wrote a `_internal_admin_*` helper: revalidate `auth.uid() = p_user_id` inside the helper (defense in depth)
- [ ] If your function name starts with `api._admin_*`: explicit `REVOKE ALL ON FUNCTION ... FROM PUBLIC, anon, authenticated;` AND `GRANT EXECUTE ON FUNCTION ... TO service_role;` — overrides the schema-level default that auto-grants EXECUTE to anon/authenticated
