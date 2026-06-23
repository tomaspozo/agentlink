# RLS Patterns

Row-Level Security policies and the multi-tenancy model.

## Contents
- Policy Fundamentals
- User-Owns-Row Pattern
- Tenant-Scoped Pattern
- Role-Based Access (RBAC)
- Multi-Tenancy Model (tables, memberships, JWT claims)
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

## Tenant-Scoped Pattern

Every tenant-scoped table has a `tenant_id` column. RLS reads the tenant from JWT claims.

### Reading tenant context from JWT

Custom claims live in `app_metadata`. They're populated on every JWT mint by the **custom access-token hook** (`public._hook_custom_access_token`) — which reads the user's per-device tenant pin from `public.session_tenants` (or falls back to their oldest membership for single-tenant apps), then injects:

- `app_metadata.tenant_id` — the active tenant for this device
- `app_metadata.tenant_role` — the user's role in that tenant
- `app_metadata.permissions` — array of permission names the role holds

```sql
-- Extract tenant_id from JWT
(auth.jwt() -> 'app_metadata' ->> 'tenant_id')::uuid
```

### Tenant-scoped policies

```sql
DROP POLICY IF EXISTS members_read_projects ON public.projects;
CREATE POLICY members_read_projects
ON public.projects FOR SELECT
USING (
  tenant_id = (auth.jwt() -> 'app_metadata' ->> 'tenant_id')::uuid
);

DROP POLICY IF EXISTS members_insert_projects ON public.projects;
CREATE POLICY members_insert_projects
ON public.projects FOR INSERT
WITH CHECK (
  tenant_id = (auth.jwt() -> 'app_metadata' ->> 'tenant_id')::uuid
);
```

For cleaner policies, extract the claim into a helper:

```sql
CREATE OR REPLACE FUNCTION public._auth_tenant_id()
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT (auth.jwt() -> 'app_metadata' ->> 'tenant_id')::uuid;
$$;
```

Then policies become:

```sql
DROP POLICY IF EXISTS members_read_projects ON public.projects;
CREATE POLICY members_read_projects
ON public.projects FOR SELECT
USING (tenant_id = public._auth_tenant_id());
```

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

RBAC rows are **reference data**, not schema — they live in `supabase/database/rbac/`, NOT in the table files under `schemas/public/tables/` (which define structure only). Each rbac file fills the `rbac_desired` staging table; the reconcile step (`db apply`, and every `env deploy`) converges the DB to **exactly** the declared set. **Full reconcile**: a row you remove is REVOKED on every env, including prod — which is the only way revokes reach prod, since migrations carry DDL only (never row data).

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

The custom access-token hook reads `role_permissions` and bakes the user's permissions into JWT `app_metadata.permissions`. `_auth_has_permission` then becomes a pure jsonb membership check — no table read at policy-evaluation time:

```sql
-- supabase/database/schemas/public/functions/_auth_has_permission.sql (scaffolded)
CREATE OR REPLACE FUNCTION public._auth_has_permission(p_permission text)
RETURNS boolean LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = '' AS $$
BEGIN
  RETURN COALESCE(
    (auth.jwt()->'app_metadata'->'permissions') ? p_permission,
    false
  );
END;
$$;
```

### Authorization guards — `auth_verify_access` / `auth_has_access`

`_auth_has_permission` (above) is the JWT-only engine. You don't call it
directly anymore — you call the guards in `public/_authz.sql`, which wrap it:

- `public.auth_verify_access(p_permission text)` → **raises** `42501` (HTTP 403) when the permission is absent. First statement of every mutating RPC.
- `public.auth_has_access(p_permission text)` → **boolean**, for conditional branching inside an RPC.

Both are JWT-only (zero DB reads), evaluated against the caller's **active workspace**.

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
  IF v_tenant_id IS NULL THEN RAISE EXCEPTION 'No tenant selected'; END IF;
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

The legacy hierarchical check is still scaffolded for cases where you want "any role at admin or above" semantics. It reads `rank` from the roles table — the hierarchy is data, not a hardcoded ladder. `LANGUAGE sql STABLE` so the planner can inline it inside RLS predicates:

```sql
-- supabase/database/schemas/public/functions/_auth_has_role.sql (scaffolded)
CREATE OR REPLACE FUNCTION public._auth_has_role(p_minimum_role text)
RETURNS boolean LANGUAGE sql STABLE SECURITY INVOKER SET search_path = '' AS $$
  SELECT COALESCE(
    (SELECT rank FROM public.roles WHERE name = public._auth_tenant_role())
      >=
    (SELECT rank FROM public.roles WHERE name = p_minimum_role),
    false
  );
$$;
```

**Prefer permission checks (`auth_verify_access('<key>')` in the RPC)** over role hierarchy — they map to capabilities (what someone can *do*), not seniority. Use `_auth_has_role` only when you genuinely want a hierarchy (e.g. an admin dashboard that shows different sections based on rank); it reads the JWT too and can be called from an RPC or a `auth_has_access`-style branch — but it is not for permission gating.

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

-- Per-device tenant pin — keyed on the auth.sessions row, so each device's
-- tenant choice is independent. The custom access-token hook reads this on
-- every JWT mint to populate app_metadata.tenant_id.
CREATE TABLE IF NOT EXISTS public.session_tenants (
  session_id  UUID PRIMARY KEY REFERENCES auth.sessions(id) ON DELETE CASCADE,
  user_id     UUID NOT NULL REFERENCES auth.users(id)       ON DELETE CASCADE,
  tenant_id   UUID NOT NULL REFERENCES public.tenants(id)   ON DELETE CASCADE,
  tenant_role TEXT NOT NULL REFERENCES public.roles(name)   ON UPDATE CASCADE,
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.session_tenants ENABLE ROW LEVEL SECURITY;
```

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

-- Memberships: scope to the active tenant (isolation)
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

### Setting tenant context — per-device via the access-token hook

Tenant selection is **per device**, not per user. Each `auth.sessions` row (one per active login on phone, laptop, etc.) has its own `public.session_tenants` pin. The custom access-token hook reads this on every JWT mint and bakes the choice into `app_metadata.tenant_id` / `tenant_role` / `permissions`. Switching on phone never moves the laptop's pin.

The hook also auto-falls-back to the user's oldest membership when no pin exists, so single-tenant apps never need to call `tenant_select` — the very first JWT carries the right tenant.

```sql
-- Privileged helper — reads session_id from auth.jwt() inside the function
-- (NOT a parameter). Supabase signs the JWT, so the session_id we read is
-- guaranteed to belong to the calling user; that removes the need for an
-- auth.sessions ownership check (which would require SELECT on auth.sessions
-- — NOT granted to postgres on Supabase Cloud) without weakening security.
CREATE OR REPLACE FUNCTION public._internal_admin_set_session_tenant(
  p_user_id uuid, p_tenant_id uuid, p_role text
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_session_id uuid;
BEGIN
  IF (SELECT auth.uid()) IS DISTINCT FROM p_user_id THEN
    RAISE EXCEPTION 'Cannot set session tenant for another user';
  END IF;

  v_session_id := NULLIF((SELECT auth.jwt()->>'session_id'), '')::uuid;
  IF v_session_id IS NULL THEN
    RAISE EXCEPTION 'No session — JWT is missing session_id';
  END IF;

  INSERT INTO public.session_tenants (session_id, user_id, tenant_id, tenant_role, updated_at)
  VALUES (v_session_id, p_user_id, p_tenant_id, p_role, now())
  ON CONFLICT (session_id) DO UPDATE
    SET tenant_id   = EXCLUDED.tenant_id,
        tenant_role = EXCLUDED.tenant_role,
        user_id     = EXCLUDED.user_id,  -- safety: rewrite to caller's
        updated_at  = now();
END; $$;

-- API wrapper — INVOKER, validates membership, delegates the pin write
CREATE OR REPLACE FUNCTION api.tenant_select(p_tenant_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
DECLARE
  v_user_id uuid := (SELECT auth.uid());
  v_role text;
BEGIN
  -- Reads memberships under RLS — relies on users_read_own_memberships policy.
  SELECT role INTO v_role FROM public.memberships
   WHERE tenant_id = p_tenant_id AND user_id = v_user_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Not a member of this tenant'; END IF;

  PERFORM public._internal_admin_set_session_tenant(v_user_id, p_tenant_id, v_role);

  RETURN jsonb_build_object('id', p_tenant_id, 'role', v_role);
END; $$;
```

**Why no `session_id` parameter on the helper.** Supabase Cloud locks down `auth.sessions` (owned by `supabase_auth_admin`, not granted to `postgres`), so the original "validate the session belongs to the user" check failed with permission denied. Reading `session_id` from `auth.jwt()` inside the DEFINER function is strictly better: the JWT is signed, so the session_id we read is by construction the caller's real session — there's no parameter to spoof.

After calling this, the client refreshes the session — the hook re-runs and the new JWT carries the chosen tenant:

```typescript
// Client-side after tenant selection
await supabase.rpc("tenant_select", { p_tenant_id: tenantId });
await supabase.auth.refreshSession();  // hook injects new tenant_id + permissions
```

### Membership changes auto-sync to session pins

A trigger on `public.memberships` keeps `session_tenants` in sync:
- **Role change** → updates `tenant_role` on every pin for that (user, tenant) so next refresh has the new permissions.
- **Membership delete** → removes the pin so the user falls back to another tenant (or none) on next refresh.

In-flight JWTs keep their old claims until the next refresh (standard JWT limitation, mitigated by `jwt_expiry`). For fast-revoke needs, shorten `jwt_expiry` in `config.toml`.

---

## Invitation Flow

> **Scaffolded by the CLI** as one file per RPC under `supabase/database/schemas/api/functions/` (`invitation_create.sql`, `invitation_accept.sql`, …). These RPCs already exist.

### Invite (admin sends)

The api wrapper is INVOKER. It resolves the caller's tenant from JWT claims and delegates the insert + email enqueue to a `_internal_admin_*` helper that bypasses RLS on `public.invitations`.

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
  -- membership row (DEFINER bypasses RLS) and check it against role_permissions
  -- — guards against stale JWT claims for users with multiple tenants.
  DECLARE v_caller_role text;
  BEGIN
    SELECT role INTO v_caller_role FROM public.memberships
     WHERE tenant_id = p_tenant_id AND user_id = p_user_id;
    IF v_caller_role IS NULL THEN RAISE EXCEPTION 'Not a member of this tenant'; END IF;
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
  IF v_tenant_id IS NULL THEN RAISE EXCEPTION 'No tenant selected'; END IF;
  RETURN public._internal_admin_create_invitation(v_user_id, v_tenant_id, p_email, p_role);
END; $$;
```

### Accept (invited user)

The token lookup needs to bypass RLS on `public.invitations` (the accepting user isn't an admin of the inviting tenant yet, so they can't read invitations under normal RLS). All the privileged work — token validation, membership insert, JWT claim update — lives in the `_internal_admin_*` helper.

```sql
-- Privileged helper — bypasses RLS to validate the token and write claims
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

  -- No JWT claim writes — the api wrapper pins the new tenant to the caller's
  -- session via _internal_admin_set_session_tenant, then a single client-side
  -- refreshSession() lands them inside the joined workspace.

  RETURN jsonb_build_object(
    'id', v_tenant.id, 'name', v_tenant.name, 'slug', v_tenant.slug,
    'role', v_invitation.role
  );
END; $$;

REVOKE ALL ON FUNCTION public._internal_admin_complete_invitation(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._internal_admin_complete_invitation(uuid, uuid) TO authenticated, service_role;

-- API wrapper — INVOKER, delegates the membership write, then pins the tenant
CREATE OR REPLACE FUNCTION api.invitation_accept(p_token uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
DECLARE
  v_user_id    uuid := (SELECT auth.uid());
  v_session_id uuid := NULLIF(auth.jwt()->>'session_id', '')::uuid;
  v_result     jsonb;
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  v_result := public._internal_admin_complete_invitation(v_user_id, p_token);
  IF v_session_id IS NOT NULL THEN
    PERFORM public._internal_admin_set_session_tenant(
      v_user_id, (v_result->>'id')::uuid, v_result->>'role'
    );
  END IF;
  RETURN v_result;
END; $$;
```

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

If you need a function to explicitly act as service role, use `SECURITY DEFINER` and document why.

---

## Performance

RLS predicates run on every query. Index the columns used in policies:

```sql
-- For user-owns-row pattern
CREATE INDEX IF NOT EXISTS idx_charts_user_id ON public.charts(user_id);

-- For tenant-scoped pattern
CREATE INDEX IF NOT EXISTS idx_projects_tenant_id ON public.projects(tenant_id);
CREATE INDEX IF NOT EXISTS idx_memberships_tenant_user
  ON public.memberships(tenant_id, user_id);

-- For JWT claim extraction (if checking membership directly)
CREATE INDEX IF NOT EXISTS idx_memberships_user_id ON public.memberships(user_id);
```

Without these indexes, RLS policies cause sequential scans on every query.

---

## Testing Policies

Verify policies work by testing as different roles:

```sql
-- Test as authenticated user with specific ID
SET request.jwt.claims = '{"sub": "user-uuid-here", "role": "authenticated", "app_metadata": {"tenant_id": "tenant-uuid"}}';
SET role = 'authenticated';

-- Try to read — should only see own/tenant rows
SELECT * FROM public.charts;

-- Try to read another user's data — should return empty
SET request.jwt.claims = '{"sub": "different-user-uuid", "role": "authenticated"}';
SELECT * FROM public.charts;

-- Reset
RESET role;
RESET request.jwt.claims;
```

Run these via `psql` to verify policies during development.
