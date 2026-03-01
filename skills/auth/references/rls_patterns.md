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
CREATE POLICY "read own" ON charts FOR SELECT
USING (user_id = auth.uid());

-- WITH CHECK: "can I insert this row?"
CREATE POLICY "insert own" ON charts FOR INSERT
WITH CHECK (user_id = auth.uid());

-- UPDATE needs both: USING filters which rows you can target, WITH CHECK validates the result
CREATE POLICY "update own" ON charts FOR UPDATE
USING (user_id = auth.uid())
WITH CHECK (user_id = auth.uid());
```

**RLS is always enabled.** Every table gets `ALTER TABLE ... ENABLE ROW LEVEL SECURITY;` in its schema file. No exceptions.

---

## User-Owns-Row Pattern

The simplest pattern. Each row has a `user_id` column, each user sees only their own data.

```sql
-- Four policies cover all CRUD operations
CREATE POLICY "Users can read own charts"
ON public.charts FOR SELECT
USING (user_id = auth.uid());

CREATE POLICY "Users can insert own charts"
ON public.charts FOR INSERT
WITH CHECK (user_id = auth.uid());

CREATE POLICY "Users can update own charts"
ON public.charts FOR UPDATE
USING (user_id = auth.uid())
WITH CHECK (user_id = auth.uid());

CREATE POLICY "Users can delete own charts"
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
CREATE POLICY "Tenant members can read projects"
ON public.projects FOR SELECT
USING (
  tenant_id = (auth.jwt() -> 'app_metadata' ->> 'tenant_id')::uuid
);

CREATE POLICY "Tenant members can insert projects"
ON public.projects FOR INSERT
WITH CHECK (
  tenant_id = (auth.jwt() -> 'app_metadata' ->> 'tenant_id')::uuid
);
```

For cleaner policies, extract the claim into a helper:

```sql
CREATE OR REPLACE FUNCTION _auth_tenant_id()
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
CREATE POLICY "Tenant members can read projects"
ON public.projects FOR SELECT
USING (tenant_id = _auth_tenant_id());
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
CREATE OR REPLACE FUNCTION _auth_tenant_role()
RETURNS text
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT (auth.jwt() -> 'app_metadata' ->> 'tenant_role')::text;
$$;

-- For checking minimum role level
CREATE OR REPLACE FUNCTION _auth_has_role(p_minimum_role text)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_role text := _auth_tenant_role();
  v_levels jsonb := '{"viewer": 1, "member": 2, "admin": 3, "owner": 4}'::jsonb;
BEGIN
  RETURN (v_levels ->> v_role)::int >= (v_levels ->> p_minimum_role)::int;
END;
$$;
```

### Role-based policies

```sql
-- Viewers and above can read
CREATE POLICY "Tenant members can read projects"
ON public.projects FOR SELECT
USING (tenant_id = _auth_tenant_id());

-- Members and above can write
CREATE POLICY "Members can insert projects"
ON public.projects FOR INSERT
WITH CHECK (
  tenant_id = _auth_tenant_id()
  AND _auth_has_role('member')
);

-- Admins and above can delete
CREATE POLICY "Admins can delete projects"
ON public.projects FOR DELETE
USING (
  tenant_id = _auth_tenant_id()
  AND _auth_has_role('admin')
);
```

---

## Multi-Tenancy Model

### Core tables

```sql
-- supabase/schemas/public/tenants.sql
CREATE TABLE IF NOT EXISTS public.tenants (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  slug text UNIQUE NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.tenants ENABLE ROW LEVEL SECURITY;

-- supabase/schemas/public/memberships.sql
CREATE TABLE IF NOT EXISTS public.memberships (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  role text NOT NULL DEFAULT 'member' CHECK (role IN ('viewer', 'member', 'admin', 'owner')),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, user_id)
);

ALTER TABLE public.memberships ENABLE ROW LEVEL SECURITY;

-- supabase/schemas/public/invitations.sql
CREATE TABLE IF NOT EXISTS public.invitations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  email text NOT NULL,
  role text NOT NULL DEFAULT 'member' CHECK (role IN ('viewer', 'member', 'admin')),
  invited_by uuid NOT NULL REFERENCES auth.users(id),
  token text UNIQUE NOT NULL DEFAULT encode(gen_random_bytes(32), 'hex'),
  expires_at timestamptz NOT NULL DEFAULT now() + interval '7 days',
  accepted_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.invitations ENABLE ROW LEVEL SECURITY;
```

### Membership check helper

```sql
CREATE OR REPLACE FUNCTION _auth_is_tenant_member(p_tenant_id uuid)
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

```sql
-- Tenants: members can see their own tenants
CREATE POLICY "Members can read own tenants"
ON public.tenants FOR SELECT
USING (_auth_is_tenant_member(id));

-- Memberships: members can see other members of their tenant
CREATE POLICY "Members can read tenant memberships"
ON public.memberships FOR SELECT
USING (tenant_id = _auth_tenant_id());

-- Memberships: only admins can manage members
CREATE POLICY "Admins can manage memberships"
ON public.memberships FOR INSERT
WITH CHECK (
  tenant_id = _auth_tenant_id()
  AND _auth_has_role('admin')
);
```

### Setting JWT claims

When a user selects a tenant (at login or via tenant switching), set the custom claims in their JWT:

```sql
CREATE OR REPLACE FUNCTION api.tenant_select(p_tenant_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER  -- required: updates auth.users metadata
SET search_path = ''
AS $$
DECLARE
  v_membership record;
BEGIN
  -- Verify membership exists
  SELECT * INTO v_membership
  FROM public.memberships
  WHERE tenant_id = p_tenant_id AND user_id = auth.uid();

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Not a member of this tenant';
  END IF;

  -- Set tenant context in JWT claims
  UPDATE auth.users
  SET raw_app_meta_data = raw_app_meta_data
    || jsonb_build_object(
      'tenant_id', p_tenant_id,
      'tenant_role', v_membership.role
    )
  WHERE id = auth.uid();

  RETURN jsonb_build_object(
    'success', true,
    'tenant_id', p_tenant_id,
    'role', v_membership.role
  );
END;
$$;
```

After calling this, the client must refresh the session to get a new JWT with the updated claims:

```typescript
// Client-side after tenant selection
await supabase.rpc("tenant_select", { p_tenant_id: tenantId });
await supabase.auth.refreshSession();  // gets new JWT with tenant_id claim
```

---

## Invitation Flow

### Invite (admin sends)

```sql
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
  v_invitation record;
BEGIN
  IF NOT _auth_has_role('admin') THEN
    RAISE EXCEPTION 'Only admins can invite members';
  END IF;

  -- Check for existing membership
  IF EXISTS (
    SELECT 1 FROM public.memberships m
    JOIN auth.users u ON u.id = m.user_id
    WHERE m.tenant_id = _auth_tenant_id() AND u.email = p_email
  ) THEN
    RAISE EXCEPTION 'User is already a member';
  END IF;

  INSERT INTO public.invitations (tenant_id, email, role, invited_by)
  VALUES (_auth_tenant_id(), p_email, p_role, auth.uid())
  RETURNING * INTO v_invitation;

  -- Send invitation email via edge function
  PERFORM public._internal_call_edge_function(
    'send-invitation',
    jsonb_build_object(
      'email', p_email,
      'token', v_invitation.token,
      'tenant_id', _auth_tenant_id()
    )
  );

  RETURN jsonb_build_object('success', true, 'invitation_id', v_invitation.id);
END;
$$;
```

### Accept (invited user)

```sql
CREATE OR REPLACE FUNCTION api.invitation_accept(p_token text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER  -- required: creates membership and reads invitations across tenants
SET search_path = ''
AS $$
DECLARE
  v_invitation record;
BEGIN
  -- Find and validate invitation
  SELECT * INTO v_invitation
  FROM public.invitations
  WHERE token = p_token
    AND accepted_at IS NULL
    AND expires_at > now();

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Invalid or expired invitation';
  END IF;

  -- Create membership
  INSERT INTO public.memberships (tenant_id, user_id, role)
  VALUES (v_invitation.tenant_id, auth.uid(), v_invitation.role)
  ON CONFLICT (tenant_id, user_id) DO NOTHING;

  -- Mark invitation as accepted
  UPDATE public.invitations
  SET accepted_at = now()
  WHERE id = v_invitation.id;

  RETURN jsonb_build_object(
    'success', true,
    'tenant_id', v_invitation.tenant_id,
    'role', v_invitation.role
  );
END;
$$;
```

---

## Common Patterns

### Public read, authenticated write

```sql
CREATE POLICY "Anyone can read published posts"
ON public.posts FOR SELECT
USING (status = 'published');

CREATE POLICY "Authors can insert posts"
ON public.posts FOR INSERT
WITH CHECK (user_id = auth.uid());
```

### Service-role bypass

Service role bypasses RLS by default — no special policy needed. This is used by `_internal_*` functions and edge functions with `ctx.adminClient`.

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
