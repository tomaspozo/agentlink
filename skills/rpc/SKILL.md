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
- **`SECURITY INVOKER`** — runs as the caller; isolation RLS applies automatically
- **Permission gate first** — mutating RPCs `PERFORM public.auth_verify_access('<entity>.<action>')` as the first statement, then scope queries with `WHERE tenant_id = (SELECT public._auth_tenant_id())`. Permissions live in the RPC, not in RLS (which is isolation-only).
- **`SET search_path = ''`** — prevents search path injection
- **Fully qualified names** — `public.charts`, `public._auth_*`, `public._internal_admin_*` — never bare names
- **Grant EXECUTE per function — every `api` RPC** (default-deny, like tables; there is no schema-wide `GRANT ON ALL FUNCTIONS`). After the definition add `REVOKE ALL ON FUNCTION api.<fn>(<arg-types>) FROM PUBLIC;` then `GRANT EXECUTE ON FUNCTION api.<fn>(<arg-types>) TO authenticated, service_role;`. The REVOKE strips Postgres' built-in `PUBLIC` EXECUTE (so `anon` can't reach it); a forgotten grant fails fast (42501). **Anon-callable** RPC: `GRANT … TO anon, authenticated, service_role` and make it `SECURITY DEFINER`. **`api._admin_*`** (service_role-only): `REVOKE … FROM PUBLIC, anon, authenticated; GRANT EXECUTE … TO service_role` (also silences DEFINER lint 0028). See the Grants section in `references/rpc_patterns.md`.
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

Accepting a workspace invitation is a real example: the accepting user needs to *write* a `memberships` row and mark the invitation accepted — but the caller can't read the pending invitation (RLS hides invitations addressed to them by token) and can't be trusted to insert their own membership. So the privileged write goes in a `public._internal_admin_*` DEFINER helper; the `api` wrapper stays INVOKER.

```sql
-- ❌ WRONG — DEFINER in api triggers lints 0028/0029
CREATE OR REPLACE FUNCTION api.invitation_accept(p_token uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER       -- linter flags this
SET search_path = ''
AS $$
BEGIN
  -- ... bypasses RLS to read the invitation, then INSERTs a membership ...
END; $$;

-- ✅ CORRECT — INVOKER wrapper in api delegates to DEFINER helper in public
CREATE OR REPLACE FUNCTION public._internal_admin_complete_invitation(
  p_user_id uuid, p_token uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER       -- in public, not exposed → linter doesn't see it; bypasses RLS on invitations
SET search_path = ''
AS $$
DECLARE
  v_invitation record;
  v_tenant record;
BEGIN
  -- Defense in depth: never act on behalf of another user, even if called directly.
  IF (SELECT auth.uid()) IS DISTINCT FROM p_user_id THEN
    RAISE EXCEPTION 'Cannot accept invitation on behalf of another user';
  END IF;

  SELECT * INTO v_invitation
  FROM public.invitations
  WHERE token = p_token AND accepted_at IS NULL AND expires_at > now();
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Invalid or expired invitation';
  END IF;

  INSERT INTO public.memberships (tenant_id, user_id, role)
  VALUES (v_invitation.tenant_id, p_user_id, v_invitation.role)
  ON CONFLICT (tenant_id, user_id) DO NOTHING;

  UPDATE public.invitations SET accepted_at = now() WHERE id = v_invitation.id;

  SELECT * INTO v_tenant FROM public.tenants WHERE id = v_invitation.tenant_id;
  RETURN jsonb_build_object(
    'id', v_tenant.id, 'name', v_tenant.name, 'slug', v_tenant.slug, 'role', v_invitation.role
  );
END; $$;

REVOKE ALL ON FUNCTION public._internal_admin_complete_invitation(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._internal_admin_complete_invitation(uuid, uuid) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION api.invitation_accept(p_token uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER       -- api is always INVOKER
SET search_path = ''
AS $$
DECLARE
  v_user_id uuid := (SELECT auth.uid());
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;

  -- Wrapper validates the caller; helper does the RLS-bypassing write.
  RETURN public._internal_admin_complete_invitation(v_user_id, p_token);
END; $$;
```

**Why the wrapper passes `auth.uid()` and the helper re-checks it.** The wrapper is the trust boundary: it runs as the caller (INVOKER), so `auth.uid()` is the real authenticated user, and it hands that id to the helper. The helper is DEFINER — it runs as the owner and could write *any* membership, so it re-asserts `auth.uid() = p_user_id` as defense in depth: even a malicious *direct* call to the helper (bypassing the wrapper) can't forge a membership for someone else, because the id is checked against the caller's signed JWT, not trusted from the parameter. Identity-only model (2.0): the wrapper returns the tenant and the client sets it as the active workspace (`x-workspace-id`) — there is no session pin and no token re-mint.

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

**Why the explicit grant is mandatory:** like every `api` function (default-deny, per-object grants), an `_admin_*` RPC needs its own grant — but a narrower one. `REVOKE` it from everyone and `GRANT` only to `service_role`, so `authenticated`/`anon` can never reach it.

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

**Both lines are required.** `REVOKE ALL FROM PUBLIC, anon, authenticated` strips Postgres' built-in `PUBLIC` EXECUTE default (and asserts no anon/authenticated access); `GRANT EXECUTE TO service_role` grants only the service-role principal that actually needs it.

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

A bare `RAISE EXCEPTION` uses SQLSTATE `P0001`, which PostgREST maps to **HTTP 400**. The permission guard `public.auth_verify_access('x')` raises with `ERRCODE '42501'` (insufficient_privilege) → **HTTP 403**, the correct status for an authenticated-but-unauthorized caller. Use 403 for "you can't do this," 400 for "your input is wrong." The `message` surfaces verbatim in the client's `error.message`.

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
- [ ] **Permission gate**: for any permission-bearing operation, `PERFORM public.auth_verify_access('<entity>.<action>')` as the FIRST statement (after the auth/tenant null guards). This is the primary allow/deny — RLS is isolation-only and won't check the permission. Use `public.auth_has_access('<key>')` for conditional branching.
- [ ] **Scope queries explicitly**: tenant-scoped reads/writes include `WHERE tenant_id = (SELECT public._auth_tenant_id())` (and ownership `user_id` where relevant). Isolation RLS backstops a forgotten scope, but write it explicitly — don't rely on RLS as the only filter.
- [ ] Validate input parameters before use
- [ ] If you wrote a `_internal_admin_*` helper: revalidate `auth.uid() = p_user_id` inside the helper (defense in depth)
- [ ] **Grant the function** (every `api` RPC — default-deny, no schema-wide grant): client RPC → `REVOKE ALL ON FUNCTION api.<fn>(<arg-types>) FROM PUBLIC;` + `GRANT EXECUTE ON FUNCTION api.<fn>(<arg-types>) TO authenticated, service_role;`. `api._admin_*` → `REVOKE … FROM PUBLIC, anon, authenticated;` + `GRANT EXECUTE … TO service_role;`. Anon-callable → add `anon` to the GRANT. A missing grant = uncallable (42501).
- [ ] **Underlying table is granted**: because this INVOKER RPC reads/writes `public.*` AS the caller, every table it touches needs an explicit `GRANT SELECT, INSERT, UPDATE, DELETE ON public.<table> TO authenticated, service_role;` in the table's per-table file under `database/schemas/public/tables/` (default-deny — an ungranted table raises `42501 permission denied for table …`). `SELECT`-only to authenticated for read-only tables; never grant `anon`. See the `database` skill's table-privileges rule.
