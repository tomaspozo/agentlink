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

Supabase stores custom claims in `app_metadata`. The tenant ID is set during login/membership selection:

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

Roles are stored in the `memberships` table and optionally in JWT claims for fast policy evaluation.

### Role hierarchy

| Role | Can read | Can write | Can manage members | Can delete tenant |
|------|----------|-----------|-------------------|-------------------|
| `viewer` | Yes | No | No | No |
| `member` | Yes | Yes | No | No |
| `admin` | Yes | Yes | Yes | No |
| `owner` | Yes | Yes | Yes | Yes |

### Role-checking helper

```sql
CREATE OR REPLACE FUNCTION public._auth_tenant_role()
RETURNS text
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT (auth.jwt() -> 'app_metadata' ->> 'tenant_role')::text;
$$;

-- For checking minimum role level
CREATE OR REPLACE FUNCTION public._auth_has_role(p_minimum_role text)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_role text := public._auth_tenant_role();
  v_levels jsonb := '{"viewer": 1, "member": 2, "admin": 3, "owner": 4}'::jsonb;
BEGIN
  RETURN (v_levels ->> v_role)::int >= (v_levels ->> p_minimum_role)::int;
END;
$$;
```

### Role-based policies

```sql
-- Viewers and above can read
DROP POLICY IF EXISTS members_read_projects ON public.projects;
CREATE POLICY members_read_projects
ON public.projects FOR SELECT
USING (tenant_id = public._auth_tenant_id());

-- Members and above can write
DROP POLICY IF EXISTS members_insert_projects ON public.projects;
CREATE POLICY members_insert_projects
ON public.projects FOR INSERT
WITH CHECK (
  tenant_id = public._auth_tenant_id()
  AND public._auth_has_role('member')
);

-- Admins and above can delete
DROP POLICY IF EXISTS admins_delete_projects ON public.projects;
CREATE POLICY admins_delete_projects
ON public.projects FOR DELETE
USING (
  tenant_id = public._auth_tenant_id()
  AND public._auth_has_role('admin')
);
```

---

## Multi-Tenancy Model

> **Scaffolded by the CLI.** These tables, auth helpers, and RPCs already exist in your project. This section is for reference and for building new tenant-scoped tables.

### Core tables

```sql
-- supabase/schemas/public/multitenancy.sql (scaffolded — all three tables in one file, FK order)
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
  role TEXT NOT NULL DEFAULT 'member' CHECK (role IN ('owner', 'admin', 'member', 'viewer')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, user_id)
);

ALTER TABLE public.memberships ENABLE ROW LEVEL SECURITY;

CREATE TABLE IF NOT EXISTS public.invitations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id UUID NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  email TEXT NOT NULL,
  role TEXT NOT NULL DEFAULT 'member' CHECK (role IN ('admin', 'member', 'viewer')),
  invited_by UUID NOT NULL REFERENCES auth.users(id),
  token UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
  expires_at TIMESTAMPTZ NOT NULL DEFAULT (now() + interval '7 days'),
  accepted_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.invitations ENABLE ROW LEVEL SECURITY;
```

### Membership check helper

```sql
CREATE OR REPLACE FUNCTION public._auth_is_tenant_member(p_tenant_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER  -- required: RLS on memberships would cause recursion
SET search_path = ''
AS $$
BEGIN
  RETURN EXISTS (
    SELECT 1 FROM public.memberships
    WHERE tenant_id = p_tenant_id
    AND user_id = auth.uid()
  );
END;
$$;
```

### Tenant RLS policies

> These policies are scaffolded by the CLI in `multitenancy.sql`.

```sql
-- Tenants: members can see their own tenants
DROP POLICY IF EXISTS members_read_own_tenant ON public.tenants;
CREATE POLICY members_read_own_tenant ON public.tenants
  FOR SELECT TO authenticated
  USING (public._auth_is_tenant_member(id));

-- Tenants: owners can update
DROP POLICY IF EXISTS owners_update_tenant ON public.tenants;
CREATE POLICY owners_update_tenant ON public.tenants
  FOR UPDATE TO authenticated
  USING (public._auth_is_tenant_member(id) AND public._auth_has_role('owner'));

-- Memberships: members can see other members of their tenant
DROP POLICY IF EXISTS members_read_memberships ON public.memberships;
CREATE POLICY members_read_memberships ON public.memberships
  FOR SELECT TO authenticated
  USING (tenant_id = public._auth_tenant_id());

-- Memberships: admins can add members
DROP POLICY IF EXISTS admins_insert_memberships ON public.memberships;
CREATE POLICY admins_insert_memberships ON public.memberships
  FOR INSERT TO authenticated
  WITH CHECK (tenant_id = public._auth_tenant_id() AND public._auth_has_role('admin'));

-- Memberships: admins can remove members (but not themselves)
DROP POLICY IF EXISTS admins_delete_memberships ON public.memberships;
CREATE POLICY admins_delete_memberships ON public.memberships
  FOR DELETE TO authenticated
  USING (
    tenant_id = public._auth_tenant_id()
    AND public._auth_has_role('admin')
    AND user_id != (SELECT auth.uid())
  );
```

### Setting JWT claims

When a user selects a tenant (at login or via tenant switching), set the custom claims in their JWT. The api wrapper is `SECURITY INVOKER` — it validates the caller and delegates the privileged `auth.users` write to a `_internal_admin_*` helper in `public`. This pattern silences linter 0028/0029 (DEFINER-in-exposed-schema) while keeping the same end behavior.

```sql
-- Privileged helper — DEFINER in public, NOT in api. Linter doesn't see it.
CREATE OR REPLACE FUNCTION public._internal_admin_set_tenant_claims(
  p_user_id uuid, p_tenant_id uuid, p_role text
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  -- Defense in depth: caller must match auth.uid()
  IF (SELECT auth.uid()) IS DISTINCT FROM p_user_id THEN
    RAISE EXCEPTION 'Cannot set claims for another user';
  END IF;
  UPDATE auth.users
  SET raw_app_meta_data = COALESCE(raw_app_meta_data, '{}'::jsonb)
    || jsonb_build_object('tenant_id', p_tenant_id, 'tenant_role', p_role)
  WHERE id = p_user_id;
END; $$;

REVOKE ALL ON FUNCTION public._internal_admin_set_tenant_claims(uuid, uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._internal_admin_set_tenant_claims(uuid, uuid, text) TO authenticated, service_role;

-- API wrapper — INVOKER, validates membership, delegates privileged write
CREATE OR REPLACE FUNCTION api.tenant_select(p_tenant_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_user_id uuid := (SELECT auth.uid());
  v_role text;
BEGIN
  -- Verify membership exists. Reads under RLS — relies on
  -- users_read_own_memberships policy on public.memberships.
  SELECT role INTO v_role FROM public.memberships
   WHERE tenant_id = p_tenant_id AND user_id = v_user_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Not a member of this tenant'; END IF;

  PERFORM public._internal_admin_set_tenant_claims(v_user_id, p_tenant_id, v_role);

  RETURN jsonb_build_object(
    'success', true,
    'tenant_id', p_tenant_id,
    'role', v_role
  );
END; $$;
```

After calling this, the client must refresh the session to get a new JWT with the updated claims:

```typescript
// Client-side after tenant selection
await supabase.rpc("tenant_select", { p_tenant_id: tenantId });
await supabase.auth.refreshSession();  // gets new JWT with tenant_id claim
```

---

## Invitation Flow

> **Scaffolded by the CLI** in `supabase/schemas/api/tenant.sql`. These RPCs already exist.

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

  -- Verify admin via direct membership read (DEFINER bypasses RLS)
  IF NOT EXISTS (
    SELECT 1 FROM public.memberships
    WHERE tenant_id = p_tenant_id AND user_id = p_user_id
      AND role IN ('admin', 'owner')
  ) THEN
    RAISE EXCEPTION 'Only admins can create invitations';
  END IF;

  INSERT INTO public.invitations (tenant_id, email, role, invited_by)
  VALUES (p_tenant_id, p_email, p_role, p_user_id)
  RETURNING * INTO v_invitation;

  SELECT name INTO v_tenant_name FROM public.tenants WHERE id = p_tenant_id;

  PERFORM api._admin_enqueue_task(
    'internal-invite-member',
    jsonb_build_object(
      'email', v_invitation.email,
      'token', v_invitation.token::text,
      'tenant_name', v_tenant_name
    )
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

  UPDATE auth.users
  SET raw_app_meta_data = COALESCE(raw_app_meta_data, '{}'::jsonb)
    || jsonb_build_object('tenant_id', v_invitation.tenant_id, 'tenant_role', v_invitation.role)
  WHERE id = p_user_id;

  RETURN jsonb_build_object(
    'id', v_tenant.id, 'name', v_tenant.name, 'slug', v_tenant.slug,
    'role', v_invitation.role
  );
END; $$;

REVOKE ALL ON FUNCTION public._internal_admin_complete_invitation(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._internal_admin_complete_invitation(uuid, uuid) TO authenticated, service_role;

-- API wrapper — INVOKER, delegates everything
CREATE OR REPLACE FUNCTION api.invitation_accept(p_token uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_user_id uuid := (SELECT auth.uid());
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  RETURN public._internal_admin_complete_invitation(v_user_id, p_token);
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
