# RLS Patterns

Row-Level Security policies and the identity-only multi-tenancy model.

## Contents
- Policy Fundamentals
- User-Owns-Row Pattern
- The request lifecycle (how a workspace is resolved)
- Tenant-Scoped Pattern
- Role-Based Access (RBAC)
- Multi-Tenancy Model (tables, `_auth_pre_request`, `session_context`)
- Signup trigger & profile RPCs (scaffolded reference bodies)
- Invitation Flow
- Common Patterns (public read, service-role bypass)
- Performance (indexes for RLS)
- Testing Policies

---

## Policy Fundamentals

RLS has two clause types:

- **`USING`** — filters which existing rows the user can see/modify (SELECT, UPDATE, DELETE)
- **`WITH CHECK`** — validates new/modified rows on write (INSERT, UPDATE)

```sql
-- USING: "which rows can I read?"
DROP POLICY IF EXISTS users_read_own_charts ON public.charts;
CREATE POLICY users_read_own_charts ON public.charts FOR SELECT
USING (user_id = auth.uid());

-- WITH CHECK: "can I insert this row?"
DROP POLICY IF EXISTS users_insert_own_charts ON public.charts;
CREATE POLICY users_insert_own_charts ON public.charts FOR INSERT
WITH CHECK (user_id = auth.uid());

-- UPDATE needs both: USING filters which rows you can target, WITH CHECK validates the result
DROP POLICY IF EXISTS users_update_own_charts ON public.charts;
CREATE POLICY users_update_own_charts ON public.charts FOR UPDATE
USING (user_id = auth.uid())
WITH CHECK (user_id = auth.uid());
```

**RLS is always enabled.** Every table gets `ALTER TABLE ... ENABLE ROW LEVEL SECURITY;` in its schema file. No exceptions.

---

## User-Owns-Row Pattern

The simplest pattern. Each row has a `user_id` column, each user sees only their own data.

```sql
-- Four policies cover all CRUD operations
DROP POLICY IF EXISTS users_read_own_charts ON public.charts;
CREATE POLICY users_read_own_charts
ON public.charts FOR SELECT
USING (user_id = auth.uid());

DROP POLICY IF EXISTS users_insert_own_charts ON public.charts;
CREATE POLICY users_insert_own_charts
ON public.charts FOR INSERT
WITH CHECK (user_id = auth.uid());

DROP POLICY IF EXISTS users_update_own_charts ON public.charts;
CREATE POLICY users_update_own_charts
ON public.charts FOR UPDATE
USING (user_id = auth.uid())
WITH CHECK (user_id = auth.uid());

DROP POLICY IF EXISTS users_delete_own_charts ON public.charts;
CREATE POLICY users_delete_own_charts
ON public.charts FOR DELETE
USING (user_id = auth.uid());
```

**Use when:** Personal data, no team/org concept. Profiles, personal settings, individual user content.

---

## The request lifecycle (how a workspace is resolved)

The identity-only model rests on **one transaction-local GUC** — `request.tenant_id` — carrying the resolved workspace, set once per request and read everywhere. The JWT proves **identity only** (who the caller is); it carries **no tenant and no permissions**. The active workspace is asserted **per request** by the client.

1. The client attaches `Authorization: Bearer <jwt>` (identity) **and** `x-workspace-id: <uuid>` (active workspace) to every Data-API request.
2. PostgREST runs `public._auth_pre_request()` once per request (the **db-pre-request hook**, wired by `ALTER ROLE authenticator SET pgrst.db_pre_request = 'public._auth_pre_request'`). It:
   - **No header** → resets the GUC to empty (transaction-local) and returns with zero extra DB reads → deny by default.
   - **Non-member** → `RAISE EXCEPTION … ERRCODE '42501'` → **HTTP 403**.
   - **Member** → `set_config('request.tenant_id', <id>, true)` — pins the workspace **transaction-local**.
3. `public._auth_tenant_id()` reads that GUC. RLS `USING (tenant_id = _auth_tenant_id())` scopes every row; `public._auth_has_permission()` / `public.auth_verify_access()` gate writes — both derive fresh from `(auth.uid(), resolved workspace)`.
4. The client reads role + permissions from `api.session_context()` for the active workspace — **not** from the token. Switching workspace is just sending a different header: **no token re-mint, no session refresh**.

> This is the trust boundary for the whole identity-vs-context split: the JWT proves WHO; the pre-request hook resolves WHICH workspace, server-side, from a header the client asserts but cannot be trusted on.

---

## Tenant-Scoped Pattern

Every tenant-scoped table has a `tenant_id` column. RLS reads the resolved workspace from the request GUC via `public._auth_tenant_id()`.

### Reading tenant context

`public._auth_tenant_id()` (scaffolded) returns the workspace resolved for **this** request — the value the pre-request hook pinned into `request.tenant_id` after validating membership. There is deliberately **no JWT fallback**: the token carries no tenant claim, so supplying the workspace per request via the header *is* the contract.

```sql
-- supabase/database/schemas/public/functions/_auth_tenant_id.sql (scaffolded)
CREATE OR REPLACE FUNCTION public._auth_tenant_id()
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = ''
AS $$
  -- The resolved workspace for THIS request. missing_ok := true makes an unset
  -- GUC return NULL instead of raising; NULLIF guards the empty-string reset the
  -- pre-request hook writes when no workspace is asserted. NULL → deny by default:
  -- a tenant_id equality against NULL is never true, so no rows are visible.
  SELECT NULLIF(current_setting('request.tenant_id', true), '')::uuid;
$$;
```

**The signature is unchanged from 1.x** — only the internals moved from reading the JWT to reading the GUC. So every existing RLS policy body and RPC scope clause `tenant_id = _auth_tenant_id()` keeps working untouched.

### Tenant-scoped policies

```sql
DROP POLICY IF EXISTS members_read_projects ON public.projects;
CREATE POLICY members_read_projects
ON public.projects FOR SELECT
USING (tenant_id = (SELECT public._auth_tenant_id()));

DROP POLICY IF EXISTS members_insert_projects ON public.projects;
CREATE POLICY members_insert_projects
ON public.projects FOR INSERT
WITH CHECK (tenant_id = (SELECT public._auth_tenant_id()));
```

Wrap the helper in `(SELECT ...)` so the planner promotes it to an InitPlan (one evaluation per query, not per row) — see the RLS-performance note below.

---

## Role-Based Access (RBAC)

> **Scaffolded by the CLI.** Three lookup tables — `public.roles`, `public.permissions`, `public.role_permissions` — plus `_auth_has_permission(text)` and the `auth_verify_access` / `auth_has_access` guards (`public/_authz.sql`). The default seed ships four roles (`owner`, `admin`, `member`, `viewer`) with a sensible permission matrix.

> **Where permissions are checked: in the RPC, not in RLS.** The primary
> permission gate is `public.auth_verify_access('<entity>.<action>')`, called
> as the first statement of every mutating `api.*` RPC (raises HTTP 403). RLS
> is **isolation-only** (`tenant_id`/ownership) — a backstop, never the place
> you check a permission. This section's examples follow that split.

### Why three tables instead of enums

Postgres enums are append-only — you can't rename, remove, or reorder values without rebuilding the type. App permissions grow constantly (`charts.create`, `billing.read`, ...), so we model role and permission *sets* as data:

```sql
-- supabase/database/schemas/public/tables/roles.sql (scaffolded — excerpt; each RBAC table is its own file)
CREATE TABLE public.roles (
  name TEXT PRIMARY KEY, rank INT NOT NULL,
  description TEXT, invitable BOOLEAN NOT NULL DEFAULT true
);

CREATE TABLE public.permissions (
  name TEXT PRIMARY KEY, description TEXT
);

CREATE TABLE public.role_permissions (
  role_name       TEXT REFERENCES public.roles(name)       ON UPDATE CASCADE ON DELETE CASCADE,
  permission_name TEXT REFERENCES public.permissions(name) ON UPDATE CASCADE ON DELETE CASCADE,
  PRIMARY KEY (role_name, permission_name)
);
```

Renaming a role propagates everywhere via `ON UPDATE CASCADE`. Adding a permission is one INSERT. The FKs catch typos at write time, giving the same safety enums would.

### Adding a domain permission

RBAC rows are **reference data**, not schema — they live in `supabase/database/rbac/`, NOT in the table files under `schemas/public/tables/` (which define structure only). Each rbac file fills the `rbac_desired` staging table; the reconcile step (`db apply`, and every `env deploy`) converges the DB to **exactly** the declared set. **Full reconcile**: a row you remove is REVOKED on every env, including prod — and because permissions are now derived fresh per request, a revoke takes effect on the **next request**, not the next token refresh.

```sql
-- supabase/database/rbac/permissions.sql — add your rows to the VALUES list:
INSERT INTO rbac_desired (name, description) VALUES
  -- … base permissions …
  ('charts.create', 'Create charts'),
  ('charts.delete', 'Delete charts');
```

```sql
-- supabase/database/rbac/role_permissions.sql — bind to roles. Explicit, no
-- computed inheritance: list every (role, perm) pair. This keeps
-- non-hierarchical roles (e.g. a future 'billing_admin') possible.
INSERT INTO rbac_desired (role_name, permission_name) VALUES
  -- … base bindings …
  ('owner',  'charts.create'), ('owner',  'charts.delete'),
  ('admin',  'charts.create'), ('admin',  'charts.delete'),
  ('member', 'charts.create');
```

Then sync (automatic on deploy, or run `agentlink db rbac-sync` to apply now).

### `_auth_has_permission` — the primary RBAC primitive

Permissions are **derived fresh** on every request from `(caller, resolved workspace)` — one indexed probe into `memberships ⋈ role_permissions`. Nothing is baked into the JWT, so nothing goes stale:

```sql
-- supabase/database/schemas/public/functions/_auth_has_permission.sql (scaffolded)
CREATE OR REPLACE FUNCTION public._auth_has_permission(p_permission text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  -- caller          → auth.uid()               (the token proves identity)
  -- resolved tenant → public._auth_tenant_id() (the per-request GUC)
  -- DEFINER so the lookup sees memberships/role_permissions past the caller's
  -- RLS, but it is hard-scoped to auth.uid() + the resolved tenant. If no
  -- workspace is asserted, _auth_tenant_id() is NULL → EXISTS is false → denied.
  SELECT EXISTS (
    SELECT 1
    FROM public.memberships m
    JOIN public.role_permissions rp ON rp.role_name = m.role
    WHERE m.user_id   = (SELECT auth.uid())
      AND m.tenant_id = (SELECT public._auth_tenant_id())
      AND rp.permission_name = p_permission
  );
$$;
```

**The signature `_auth_has_permission(text)` is unchanged from 1.x** — only the internals moved from a JWT membership check to a fresh `(user, workspace)` lookup. Every call site keeps working.

### Authorization guards — `auth_verify_access` / `auth_has_access`

`_auth_has_permission` (above) is the engine. You don't call it directly — you
call the guards in `public/_authz.sql`, which wrap it:

- `public.auth_verify_access(p_permission text)` → **raises** `42501` (HTTP 403) when the permission is absent. First statement of every mutating RPC.
- `public.auth_has_access(p_permission text)` → **boolean**, for conditional branching inside an RPC.

Both derive the permission fresh from the caller and the request's resolved workspace (one indexed lookup) — evaluated against the caller's **active workspace**.

### Permissions go in the RPC, not the policy

The table gets ONE isolation-only policy; the permission is checked in the RPC.

```sql
-- TABLE: isolation-only RLS (backstop). No permission predicate.
DROP POLICY IF EXISTS projects_tenant_isolation ON public.projects;
CREATE POLICY projects_tenant_isolation
ON public.projects FOR ALL TO authenticated
USING      (tenant_id = (SELECT public._auth_tenant_id()))
WITH CHECK (tenant_id = (SELECT public._auth_tenant_id()));

-- RPC: the permission gate is the first statement.
CREATE OR REPLACE FUNCTION api.project_create(p_name text)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
DECLARE v_tenant_id uuid := public._auth_tenant_id();
BEGIN
  IF v_tenant_id IS NULL THEN RAISE EXCEPTION 'No workspace asserted'; END IF;
  PERFORM public.auth_verify_access('projects.create');          -- 403 if denied
  INSERT INTO public.projects (tenant_id, name) VALUES (v_tenant_id, p_name);
  ...
END; $$;
```

Reads that should hard-deny without a permission (e.g. a members list) guard
the same way: `PERFORM public.auth_verify_access('membership.read')` at the top
of the read RPC. Reads that should silently return empty instead can branch on
`public.auth_has_access(...)` and return `'[]'::jsonb`.

### Role hierarchy via `_auth_has_role`

The hierarchical check is scaffolded for cases where you want "any role at admin or above" semantics. It reads `rank` from the roles table — the hierarchy is data, not a hardcoded ladder. `LANGUAGE sql STABLE` so the planner can inline it inside RLS predicates:

```sql
-- supabase/database/schemas/public/functions/_auth_has_role.sql (scaffolded)
CREATE OR REPLACE FUNCTION public._auth_has_role(p_minimum_role text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT COALESCE(
    (SELECT rank FROM public.roles WHERE name = public._auth_tenant_role())
      >=
    (SELECT rank FROM public.roles WHERE name = p_minimum_role),
    false
  );
$$;
```

`_auth_tenant_role()` derives the caller's role from their membership in the
resolved workspace (same `(user, workspace)` lookup as the permission helper).
**Prefer permission checks (`auth_verify_access('<key>')` in the RPC)** over role
hierarchy — they map to capabilities (what someone can *do*), not seniority. Use
`_auth_has_role` only when you genuinely want a hierarchy (e.g. an admin
dashboard that shows different sections based on rank); it is not for permission
gating.

### Wrap `_auth_*` helpers in `(SELECT ...)` inside RLS predicates

When calling `_auth_tenant_id()` (or any helper) from a USING/WITH CHECK clause, wrap the call in a subquery so the planner promotes it to an InitPlan (one evaluation per query, not per row):

```sql
-- ✅ CORRECT — InitPlan, single evaluation
USING (tenant_id = (SELECT public._auth_tenant_id()))

-- ❌ AVOID — bare call may be re-evaluated per row in some plans
USING (tenant_id = public._auth_tenant_id())
```

The helper is `LANGUAGE sql STABLE` so the planner can also inline it — but the wrap is universal best practice and matches Supabase's documented RLS-performance pattern. (Isolation policies are typically just this one predicate — permissions are enforced in the RPC, so policies stay simple.)

---

## Multi-Tenancy Model

> **Scaffolded by the CLI.** These tables, auth helpers, and RPCs already exist in your project. This section is for reference and for building new tenant-scoped tables.

### Core tables

```sql
-- scaffolded one object per file under supabase/database/schemas/public/tables/
--   (tenants.sql, memberships.sql, invitations.sql, …); db apply resolves FK order
CREATE TABLE IF NOT EXISTS public.tenants (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  slug TEXT NOT NULL UNIQUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.tenants ENABLE ROW LEVEL SECURITY;

CREATE TABLE IF NOT EXISTS public.memberships (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id UUID NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  role TEXT NOT NULL DEFAULT 'member' REFERENCES public.roles(name) ON UPDATE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, user_id)
);

ALTER TABLE public.memberships ENABLE ROW LEVEL SECURITY;

CREATE TABLE IF NOT EXISTS public.invitations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id UUID NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  email TEXT NOT NULL,
  role TEXT NOT NULL DEFAULT 'member' REFERENCES public.roles(name) ON UPDATE CASCADE
    CHECK (role <> 'owner'),
  invited_by UUID NOT NULL REFERENCES auth.users(id),
  token UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
  expires_at TIMESTAMPTZ NOT NULL DEFAULT (now() + interval '7 days'),
  accepted_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.invitations ENABLE ROW LEVEL SECURITY;
```

There is **no per-device workspace-pin table** in 2.0. The active workspace is not pinned per device — it's asserted per request via the `x-workspace-id` header and resolved into the transaction-local `request.tenant_id` GUC. Nothing about the active workspace is stored server-side between requests.

### Membership check helper

```sql
CREATE OR REPLACE FUNCTION public._auth_is_tenant_member(p_tenant_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  -- DEFINER: required because RLS on memberships would cause recursion when
  -- this is called by a policy on the tenants table. SQL STABLE so the
  -- planner can inline this inside RLS predicates.
  SELECT EXISTS (
    SELECT 1 FROM public.memberships
    WHERE tenant_id = p_tenant_id
      AND user_id = (SELECT auth.uid())
  );
$$;
```

### `_auth_pre_request` — the per-request workspace resolver

This is the engine of the identity-only model — the db-pre-request hook that turns the client-asserted `x-workspace-id` header into a validated, transaction-local GUC. It is `SECURITY DEFINER` (it reads `memberships` past RLS) but hard-scoped to `auth.uid()`.

```sql
-- supabase/database/schemas/public/functions/_auth_pre_request.sql (scaffolded)
CREATE OR REPLACE FUNCTION public._auth_pre_request()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_header text;
  v_tenant uuid;
BEGIN
  -- The client asserts the active workspace via the x-workspace-id header.
  v_header := NULLIF(
    current_setting('request.headers', true)::json ->> 'x-workspace-id', ''
  );

  -- No header → reset the GUC (tx-local) and return with ZERO extra reads.
  IF v_header IS NULL THEN
    PERFORM set_config('request.tenant_id', '', true);
    RETURN;
  END IF;

  -- Fail closed: a non-UUID header raises here and aborts the request.
  v_tenant := v_header::uuid;

  -- Membership-validate the asserted workspace against auth.uid() before trust.
  IF NOT EXISTS (
    SELECT 1 FROM public.memberships
    WHERE tenant_id = v_tenant AND user_id = (SELECT auth.uid())
  ) THEN
    -- 42501 → PostgREST HTTP 403.
    RAISE EXCEPTION 'Not a member of workspace %', v_tenant
      USING ERRCODE = '42501';
  END IF;

  -- Pin TRANSACTION-LOCAL (third arg true). A plain SET / false would persist on
  -- the pooled connection and bleed into the NEXT user's request.
  PERFORM set_config('request.tenant_id', v_tenant::text, true);
END;
$$;
```

**The wiring is not in a schema file.** `ALTER ROLE authenticator SET pgrst.db_pre_request = 'public._auth_pre_request'` (+ `NOTIFY pgrst, 'reload config'`) is a role-level setting — pg-delta can't model it, so it lives in the **4th imperative folder**, `supabase/database/config/db_pre_request.sql`, applied idempotently on every deploy alongside `storage/`, `cron/`, and `rbac/`. If you ever drop such a statement into `schemas/**.sql` it silently never applies → every request resolves no workspace → prod denies by default.

### `session_context` — the client's source of role + permissions

Because permissions are no longer in the JWT, the frontend can't decode them from the token. It calls `api.session_context()` with the active workspace asserted via the header; the RPC returns the role + permission set for `(caller, that workspace)`. This is the single source the UI uses for `useHasPermission()` and to show the active workspace — it re-fetches whenever the client switches workspace (a local variable change), so it can never go stale.

```sql
-- supabase/database/schemas/api/functions/session_context.sql (scaffolded)
-- Returns: { tenant_id, name, slug, role, permissions[] } for the resolved
-- workspace, or an empty context ({ tenant_id: null, role: null,
-- permissions: [] }) when no workspace is asserted (fresh sign-in → the client
-- renders the workspace picker). SECURITY INVOKER — every read is the caller's
-- own data, so RLS is a sufficient backstop.
```

### Tenant RLS policies

> These policies are scaffolded by the CLI in `multitenancy.sql`.

These are **isolation-only** (tenant membership / tenant scope, plus the cheap
self-protection rule). The permission for each action (`tenant.update`,
`membership.read`, `membership.delete`, ...) is enforced in the corresponding
`api.*` RPC via `auth_verify_access`, **not** here.

```sql
-- Tenants: members can see / act on their own tenants (isolation by membership)
DROP POLICY IF EXISTS members_read_own_tenant ON public.tenants;
CREATE POLICY members_read_own_tenant ON public.tenants
  FOR SELECT TO authenticated
  USING ((SELECT public._auth_is_tenant_member(id)));

DROP POLICY IF EXISTS authorized_update_tenant ON public.tenants;
CREATE POLICY authorized_update_tenant ON public.tenants
  FOR UPDATE TO authenticated
  USING ((SELECT public._auth_is_tenant_member(id)));
  -- tenant.update is checked in the RPC, not here.

-- Memberships: scope to the active workspace (isolation)
DROP POLICY IF EXISTS members_read_memberships ON public.memberships;
CREATE POLICY members_read_memberships ON public.memberships
  FOR SELECT TO authenticated
  USING (tenant_id = (SELECT public._auth_tenant_id()));

DROP POLICY IF EXISTS authorized_insert_memberships ON public.memberships;
CREATE POLICY authorized_insert_memberships ON public.memberships
  FOR INSERT TO authenticated
  WITH CHECK (tenant_id = (SELECT public._auth_tenant_id()));

DROP POLICY IF EXISTS authorized_delete_memberships ON public.memberships;
CREATE POLICY authorized_delete_memberships ON public.memberships
  FOR DELETE TO authenticated
  USING (
    tenant_id = (SELECT public._auth_tenant_id())
    AND user_id != (SELECT auth.uid())  -- can't remove yourself (cheap business rule)
  );
-- membership.read / membership.delete are checked in the RPC via auth_verify_access.
```

### Switching workspace is a client variable change

There is **no server-side "select workspace" RPC and no session refresh** in 2.0. To switch workspace, the client changes the active-workspace value it injects as `x-workspace-id` (the frontend does this via a global `fetch` wrapper reading the active-workspace store) and re-fetches `api.session_context()`. The next request resolves the new workspace server-side. Role changes take effect on the **next request** — nothing is baked into a token to go stale — so there is no JWT-expiry propagation window for permission changes.

For an immediate hard cut (e.g. terminating an ejected member's live session entirely), call `auth.admin.signOut(userId)` server-side via an edge function (`service_role`); the scaffold doesn't ship this by default.

---

## Signup trigger & profile RPCs (scaffolded reference bodies)

> **Scaffolded by the CLI** — these already exist in your project. Bodies are here for reference; don't recreate them. If missing, run `pnpm exec agentlink --force-update`.

### Signup trigger — `_internal_admin_handle_new_user`

Creates the profile and — for direct signups only — a default tenant + owner membership. Invited users (`invited_at IS NOT NULL`, set by `generateLink({ type: 'invite' })`) get only a profile; `invitation_accept()` adds them to the inviter's tenant. **No `raw_app_meta_data` write** — nothing tenant-related lives in the JWT anymore; the workspace is asserted per request.

```sql
-- supabase/database/schemas/public/functions/_internal_admin_handle_new_user.sql (scaffolded)
CREATE OR REPLACE FUNCTION public._internal_admin_handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER  -- required: reads from auth.users which RLS can't access
SET search_path = ''
AS $$
DECLARE
  v_display_name text;
  v_tenant_id uuid;
  v_slug text;
BEGIN
  v_display_name := COALESCE(
    NEW.raw_user_meta_data->>'display_name',
    NEW.raw_user_meta_data->>'full_name',
    NEW.raw_user_meta_data->>'name',
    split_part(NEW.email, '@', 1)
  );

  -- Create profile (always — every user needs one)
  INSERT INTO public.profiles (id, email, display_name, avatar_url)
  VALUES (
    NEW.id,
    NEW.email,
    v_display_name,
    COALESCE(
      NEW.raw_user_meta_data->>'avatar_url',
      NEW.raw_user_meta_data->>'picture'
    )
  );

  -- Only create a default tenant for direct signups. Invited users join the
  -- inviter's tenant via invitation_accept().
  IF NEW.invited_at IS NULL THEN
    v_slug := regexp_replace(lower(split_part(NEW.email, '@', 1)), '[^a-z0-9]', '-', 'g')
      || '-' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 8);

    INSERT INTO public.tenants (name, slug)
    VALUES (v_display_name || '''s Workspace', v_slug)
    RETURNING id INTO v_tenant_id;

    INSERT INTO public.memberships (tenant_id, user_id, role)
    VALUES (v_tenant_id, NEW.id, 'owner');
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_auth_users_new_user
  AFTER INSERT ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION public._internal_admin_handle_new_user();
```

**Customizing signup:** edit this file's function body (keep the same name — the update flow preserves your edits here), then `pnpm exec agentlink db apply`.

### Profile RPCs — `profile_get` / `profile_update`

```sql
-- supabase/database/schemas/api/functions/profile_get.sql (scaffolded)
CREATE OR REPLACE FUNCTION api.profile_get()
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
DECLARE v_result jsonb;
BEGIN
  SELECT jsonb_build_object(
    'id', p.id, 'email', p.email,
    'display_name', p.display_name, 'avatar_url', p.avatar_url
  ) INTO v_result
  FROM public.profiles p
  WHERE p.id = auth.uid();
  RETURN v_result;
END;
$$;

CREATE OR REPLACE FUNCTION api.profile_update(
  p_display_name text DEFAULT NULL,
  p_avatar_url text DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
BEGIN
  UPDATE public.profiles
  SET display_name = COALESCE(p_display_name, display_name),
      avatar_url   = COALESCE(p_avatar_url, avatar_url),
      updated_at   = now()
  WHERE id = auth.uid();
  RETURN api.profile_get();
END;
$$;
```

---

## Invitation Flow

> **Scaffolded by the CLI** as one file per RPC under `supabase/database/schemas/api/functions/` (`invitation_create.sql`, `invitation_accept.sql`, …). These RPCs already exist.

### Invite (admin sends)

The api wrapper is INVOKER. It resolves the caller's workspace from the request GUC (`_auth_tenant_id()`) and delegates the insert + email enqueue to a `_internal_admin_*` helper that bypasses RLS on `public.invitations`.

```sql
-- Privileged helper — handles the cross-cutting work atomically
CREATE OR REPLACE FUNCTION public._internal_admin_create_invitation(
  p_user_id uuid, p_tenant_id uuid, p_email text, p_role text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_invitation record;
  v_tenant_name text;
BEGIN
  IF (SELECT auth.uid()) IS DISTINCT FROM p_user_id THEN
    RAISE EXCEPTION 'Cannot create invitation on behalf of another user';
  END IF;

  -- Verify caller holds invitation.create. We resolve the role from the actual
  -- membership row (DEFINER bypasses RLS) and check it against role_permissions.
  DECLARE v_caller_role text;
  BEGIN
    SELECT role INTO v_caller_role FROM public.memberships
     WHERE tenant_id = p_tenant_id AND user_id = p_user_id;
    IF v_caller_role IS NULL THEN RAISE EXCEPTION 'Not a member of this workspace'; END IF;
    IF NOT EXISTS (
      SELECT 1 FROM public.role_permissions
       WHERE role_name = v_caller_role AND permission_name = 'invitation.create'
    ) THEN
      RAISE EXCEPTION 'Your role does not permit creating invitations';
    END IF;

    -- The invited role must be marked invitable (default seed: 'owner' is not).
    IF NOT (SELECT invitable FROM public.roles WHERE name = p_role) THEN
      RAISE EXCEPTION 'Role % cannot be assigned via invitation', p_role;
    END IF;
  END;

  INSERT INTO public.invitations (tenant_id, email, role, invited_by)
  VALUES (p_tenant_id, p_email, p_role, p_user_id)
  RETURNING * INTO v_invitation;

  SELECT name INTO v_tenant_name FROM public.tenants WHERE id = p_tenant_id;

  PERFORM api._admin_send_email(
    'invite',
    v_invitation.email,
    jsonb_build_object(
      'token', v_invitation.token::text,
      'tenant_name', v_tenant_name
    )
    -- no dedupe_key: a resend must always deliver
  );

  RETURN jsonb_build_object(
    'id', v_invitation.id,
    'email', v_invitation.email,
    'role', v_invitation.role,
    'token', v_invitation.token,
    'expires_at', v_invitation.expires_at
  );
END; $$;

REVOKE ALL ON FUNCTION public._internal_admin_create_invitation(uuid, uuid, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._internal_admin_create_invitation(uuid, uuid, text, text) TO authenticated, service_role;

-- API wrapper — thin INVOKER, just resolves args and delegates
CREATE OR REPLACE FUNCTION api.invitation_create(
  p_email text,
  p_role text DEFAULT 'member'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_user_id uuid := (SELECT auth.uid());
  v_tenant_id uuid := public._auth_tenant_id();
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF v_tenant_id IS NULL THEN RAISE EXCEPTION 'No workspace asserted'; END IF;
  RETURN public._internal_admin_create_invitation(v_user_id, v_tenant_id, p_email, p_role);
END; $$;
```

### Accept (invited user)

The token lookup needs to bypass RLS on `public.invitations` (the accepting user isn't a member of the inviting tenant yet, so they can't read invitations under normal RLS). All the privileged work — token validation, membership insert — lives in the `_internal_admin_*` helper. **No JWT/session pin write**: the new member simply asserts the joined workspace via `x-workspace-id` on their next request (the client sets it as the active workspace and re-fetches `session_context`).

```sql
-- Privileged helper — bypasses RLS to validate the token and insert membership
CREATE OR REPLACE FUNCTION public._internal_admin_complete_invitation(
  p_user_id uuid, p_token uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_invitation record;
  v_tenant record;
BEGIN
  IF (SELECT auth.uid()) IS DISTINCT FROM p_user_id THEN
    RAISE EXCEPTION 'Cannot accept invitation on behalf of another user';
  END IF;

  SELECT * INTO v_invitation
  FROM public.invitations
  WHERE token = p_token AND accepted_at IS NULL AND expires_at > now();
  IF NOT FOUND THEN RAISE EXCEPTION 'Invalid or expired invitation'; END IF;

  INSERT INTO public.memberships (tenant_id, user_id, role)
  VALUES (v_invitation.tenant_id, p_user_id, v_invitation.role)
  ON CONFLICT (tenant_id, user_id) DO NOTHING;

  UPDATE public.invitations SET accepted_at = now() WHERE id = v_invitation.id;
  SELECT * INTO v_tenant FROM public.tenants WHERE id = v_invitation.tenant_id;

  RETURN jsonb_build_object(
    'id', v_tenant.id, 'name', v_tenant.name, 'slug', v_tenant.slug,
    'role', v_invitation.role
  );
END; $$;

REVOKE ALL ON FUNCTION public._internal_admin_complete_invitation(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._internal_admin_complete_invitation(uuid, uuid) TO authenticated, service_role;

-- API wrapper — INVOKER, delegates the membership write. The client sets the
-- joined workspace as active (x-workspace-id) after this returns — no re-mint.
CREATE OR REPLACE FUNCTION api.invitation_accept(p_token uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
DECLARE
  v_user_id uuid := (SELECT auth.uid());
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  RETURN public._internal_admin_complete_invitation(v_user_id, p_token);
END; $$;
```

`invitation_accept` is intentionally **unguarded** by `auth_verify_access` — the accepter isn't a member yet, so the token *is* the authorization. It is idempotent on a second click (`ON CONFLICT DO NOTHING`).

---

## Common Patterns

### Public read, authenticated write

```sql
DROP POLICY IF EXISTS anon_read_published_posts ON public.posts;
CREATE POLICY anon_read_published_posts
ON public.posts FOR SELECT
USING (status = 'published');

DROP POLICY IF EXISTS authors_insert_posts ON public.posts;
CREATE POLICY authors_insert_posts
ON public.posts FOR INSERT
WITH CHECK (user_id = auth.uid());
```

### Service-role bypass

Service role bypasses RLS by default — no special policy needed. This is used by `_internal_admin_*` functions and edge functions with `ctx.supabaseAdmin`.

If you need a function to explicitly act as service role, use `SECURITY DEFINER` and document why. Note the MCP path deliberately does **not** use `service_role` for user tools (see the non-negotiables in `SKILL.md`) — it forwards the user's JWT so RLS + `auth_verify_access` stay the enforcement boundary.

---

## Performance

RLS predicates run on every query. Index the columns used in policies:

```sql
-- For user-owns-row pattern
CREATE INDEX IF NOT EXISTS idx_charts_user_id ON public.charts(user_id);

-- For tenant-scoped pattern
CREATE INDEX IF NOT EXISTS idx_projects_tenant_id ON public.projects(tenant_id);

-- Backs both the pre-request membership check AND _auth_has_permission's
-- (user, workspace) lookup — the hot path of every request.
CREATE INDEX IF NOT EXISTS idx_memberships_tenant_user
  ON public.memberships(tenant_id, user_id);

-- For membership lookups by user
CREATE INDEX IF NOT EXISTS idx_memberships_user_id ON public.memberships(user_id);
```

Without these indexes, RLS policies cause sequential scans on every query.

---

## Testing Policies

Verify policies work by testing as different roles. Because the active workspace now lives in the `request.tenant_id` GUC (set by the pre-request hook, not baked in the JWT), set it explicitly with `set_config(..., true)` inside a transaction:

```sql
BEGIN;
-- Identity only — the JWT carries NO tenant/permissions in 2.0.
SET LOCAL request.jwt.claims = '{"sub": "user-uuid-here", "role": "authenticated"}';
SET LOCAL role = 'authenticated';
-- Assert the active workspace the way the pre-request hook would (tx-local).
SELECT set_config('request.tenant_id', 'tenant-uuid-here', true);

-- Should only see rows in that workspace
SELECT * FROM public.projects;

-- Resolve NO workspace → deny by default (no rows)
SELECT set_config('request.tenant_id', '', true);
SELECT * FROM public.projects;  -- empty
COMMIT;
```

Run these via `psql` to verify policies during development. To exercise the full membership-validation path (403 on a workspace you don't belong to), hit the running stack over HTTP with an `x-workspace-id` header rather than setting the GUC by hand.
