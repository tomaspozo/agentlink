---
name: auth
description: Authentication, authorization, and tenant isolation for Supabase. Use when the task involves auth setup, sign up/sign in flows, RLS policies, row-level security, access control, permissions, roles, RBAC, multi-tenancy, tenant isolation, user profiles, OAuth, JWT claims, invitation flows, or membership management. Also use when someone asks "who can access this" or "how do I secure this table." Activate whenever the task touches auth, security policies, or tenant boundaries.
---

# Auth, RLS & Multi-Tenancy

Authentication, authorization, and tenant isolation — all enforced by the database.

## Security Model

Three layers work together:

1. **`api` schema** (primary boundary) — Only functions in `api` are exposed to clients. Tables are invisible. This is the broadest access control.
2. **RLS policies** (defense-in-depth) — Even if a function queries a table, RLS filters rows by user/tenant. This catches bugs in function logic.
3. **`_auth_*` functions** (policy helpers) — Complex access checks used by RLS policies. Live in `public`, not exposed to clients.

```
Client → api.chart_get_by_id()  → RLS filters by user → returns only allowed rows
                                     ↓
                              _auth_chart_can_read()  ← called by RLS policy
```

### Grants on the `api` schema

`USAGE` on the `api` schema is granted to `anon`, `authenticated`, and
`service_role`. That is NOT the security boundary — it just lets each
role resolve the schema name so PostgREST can find the function you're
calling. Pages that render before the session attaches (public home,
marketing content) need `anon` to have USAGE or every RPC reply is
`permission denied for schema api`.

`EXECUTE` on each function IS the security boundary. The scaffold
defaults are:

- `GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA api TO authenticated, service_role;`
- `ALTER DEFAULT PRIVILEGES IN SCHEMA api GRANT EXECUTE ON FUNCTIONS TO authenticated, service_role;`

`anon` never receives EXECUTE by default. When a function is
intentionally public (a status page, public metrics, an unauthenticated
signup-adjacent RPC), grant it explicitly:

```sql
GRANT EXECUTE ON FUNCTION api.public_metrics() TO anon;
```

Think of it this way: USAGE opens the door; EXECUTE decides who walks
through per function.

---

## Auth Patterns

### Supabase Auth is the single identity provider

- Use `auth.uid()` and `auth.jwt()` in SQL — never trust client-sent user IDs
- Session management is the frontend's responsibility
- The database only cares about the JWT — it verifies identity, not sessions

### Profile creation on sign-up

> **Scaffolded by the CLI.** Profiles, tenants, and memberships are created automatically on signup via the `_internal_admin_handle_new_user` trigger. The SQL below is for reference — it already exists in your project. If missing, run `npx create-agentlink@latest --force-update` — do not recreate manually.

User metadata belongs in a `profiles` table, not in Supabase Auth metadata. The trigger creates the profile and — for direct signups — a default tenant, owner membership, and JWT claims. Invited users (created via `generateLink({ type: 'invite' })`) only get a profile; `invitation_accept()` handles adding them to the inviter's tenant:

```sql
-- supabase/schemas/public/profiles.sql
CREATE TABLE IF NOT EXISTS public.profiles (
  id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  email text,
  display_name text,
  avatar_url text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
```

```sql
-- Trigger function: supabase/schemas/public/_internal_admin.sql (scaffolded)
-- Trigger: supabase/schemas/public/profiles.sql (scaffolded)
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

  -- Only create a default tenant for direct signups.
  -- Invited users (invited_at IS NOT NULL, set by generateLink) join
  -- the inviter's tenant via invitation_accept().
  IF NEW.invited_at IS NULL THEN
    v_slug := regexp_replace(lower(split_part(NEW.email, '@', 1)), '[^a-z0-9]', '-', 'g')
      || '-' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 8);

    INSERT INTO public.tenants (name, slug)
    VALUES (v_display_name || '''s Workspace', v_slug)
    RETURNING id INTO v_tenant_id;

    INSERT INTO public.memberships (tenant_id, user_id, role)
    VALUES (v_tenant_id, NEW.id, 'owner');

    UPDATE auth.users
    SET raw_app_meta_data = COALESCE(raw_app_meta_data, '{}'::jsonb) || jsonb_build_object(
      'tenant_id', v_tenant_id,
      'tenant_role', 'owner'
    )
    WHERE id = NEW.id;
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_auth_users_new_user
  AFTER INSERT ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION public._internal_admin_handle_new_user();
```

> **Post-signup JWT race.** This trigger writes `tenant_id` into
> `raw_app_meta_data` AFTER Supabase issues the first JWT. The session
> returned from `supabase.auth.signUp()` therefore has a stale token —
> `_auth_tenant_id()` returns NULL and every tenant-scoped RPC fails
> until the token refreshes. Two-part client fix:
>
> 1. In the sign-up handler, call `await supabase.auth.refreshSession()`
>    right after `signUp()` succeeds and before navigating into the app.
> 2. In gated pages that read tenant-scoped data, use the scaffolded
>    `useTenantGuard` hook (`src/hooks/use-tenant-guard.ts`) as a
>    safety net — when the JWT lacks `tenant_id`, it calls
>    `tenant_list` → `tenant_select` → `refreshSession()` and exposes
>    `{ ready, error }` so queries can gate on `ready`.
>
> See the frontend skill's "Post-signup & the useTenantGuard hook"
> section for the TS side.

**Need to customize signup logic?** If the app requires additional work on signup (e.g., creating rows in app-specific tables, syncing with external services), override `_internal_admin_handle_new_user` by removing its `-- @agentlink` annotation block in `supabase/schemas/public/_internal_admin.sql` and modifying the function body. Keep the same function name. The other managed functions in that file (`_internal_admin_get_secret`, `set_updated_at`, etc.) remain annotated and will continue receiving CLI updates. Apply with `npx create-agentlink@latest db apply`.

### Profile RPCs

> **Scaffolded by the CLI** in `supabase/schemas/api/profile.sql`.

```sql
-- supabase/schemas/api/profile.sql (scaffolded)
CREATE OR REPLACE FUNCTION api.profile_get()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_result jsonb;
BEGIN
  SELECT jsonb_build_object(
    'id', p.id,
    'email', p.email,
    'display_name', p.display_name,
    'avatar_url', p.avatar_url
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
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
BEGIN
  UPDATE public.profiles
  SET
    display_name = COALESCE(p_display_name, display_name),
    avatar_url = COALESCE(p_avatar_url, avatar_url),
    updated_at = now()
  WHERE id = auth.uid();

  RETURN api.profile_get();
END;
$$;
```

---

## RLS Policies

RLS is always enabled on every table. Policies filter rows based on who's asking.

### Choosing a policy pattern

| Scenario | Pattern | Example |
|----------|---------|---------|
| User owns the row | `user_id = auth.uid()` | Personal data (profiles, settings) |
| User is a member of the tenant | `_auth_*` helper function | Team/org data |
| Public read, auth write | `true` for SELECT, `auth.uid()` for INSERT | Blog posts, public listings |
| Admin only | `_auth_*` checks role | Admin operations |

### Simple: user-owns-row

When the table has a `user_id` column and each row belongs to one user:

```sql
-- supabase/schemas/public/charts.sql
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
USING (user_id = auth.uid());

DROP POLICY IF EXISTS users_delete_own_charts ON public.charts;
CREATE POLICY users_delete_own_charts
ON public.charts FOR DELETE
USING (user_id = auth.uid());
```

This is the simplest pattern. Use it when there's no tenant/team concept — the data is purely personal.

### With auth helper functions

When access checks are more complex than a single column comparison, use `_auth_*` functions:

```sql
-- supabase/schemas/public/_auth_chart.sql
CREATE OR REPLACE FUNCTION public._auth_chart_can_read(p_chart_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER  -- required: called by RLS on the table it queries
SET search_path = ''
AS $$
BEGIN
  RETURN EXISTS (
    SELECT 1 FROM public.charts
    WHERE id = p_chart_id
    AND (user_id = auth.uid() OR is_public = true)
  );
END;
$$;

-- Policy uses the function
DROP POLICY IF EXISTS users_read_own_or_public_charts ON public.charts;
CREATE POLICY users_read_own_or_public_charts
ON public.charts FOR SELECT
USING (public._auth_chart_can_read(id));
```

**When to use helpers vs inline:** Use inline `user_id = auth.uid()` when the check is a single column comparison. Use `_auth_*` helpers when the check involves joins, multiple conditions, or tenant membership lookups. Don't over-abstract — a simple `USING` clause doesn't need a function.

> **Load [RLS Patterns](./references/rls_patterns.md) for tenant-scoped policies, role-based access, and the multi-tenancy model.**

---

## Multi-Tenancy Overview

> **Scaffolded by the CLI.** The CLI scaffolds a complete multi-tenancy model including tables, RLS policies, auth helpers, and API RPCs. If missing, run `npx create-agentlink@latest --force-update` — do not recreate manually. The agent builds application-specific tables on top of this foundation.

The multi-tenancy model uses three tables (all in `supabase/schemas/public/multitenancy.sql`):

```
tenants          → The organizations/teams
memberships      → Who belongs to which tenant, with what role
invitations      → Pending invitations to join a tenant
tenant-scoped tables → Every row has a tenant_id column (agent creates these)
```

On signup, `_internal_admin_handle_new_user()` automatically creates a default tenant and owner membership, and sets JWT claims. Auth helpers live in `supabase/schemas/public/_auth_tenant.sql`. API RPCs (6 functions: `tenant_select`, `tenant_list`, `tenant_create`, `invitation_create`, `invitation_accept`, `membership_list`) live in `supabase/schemas/api/tenant.sql`.

Tenant context comes from JWT custom claims (`auth.jwt() -> 'app_metadata' ->> 'tenant_id'`), **not** from request parameters. RLS policies use this claim to filter rows automatically.

> **Load [RLS Patterns](./references/rls_patterns.md) for tenant-scoped RLS policies, RBAC, invitation flows, and patterns for new tenant-scoped tables.**

### Tenancy UX: count tenants, don't assume

The backend is always multi-tenant. The signup trigger mints a tenant
for direct signups; `invitation_accept` adds invited users to the
inviter's tenant. That's the invariant — don't try to strip, rewire,
or "simplify" it per project.

The UX rule falls out of counting `tenants.length`:

- **One tenant** (the common case for internal tools, invited-only
  portals, first-time signups, and solo users): never render a tenant
  picker. Default to `tenants[0]`. `useTenantGuard` already does this
  on mount, so most apps need nothing beyond what's scaffolded.
- **More than one tenant** (a user genuinely belongs to multiple
  workspaces): render a picker in chrome or on a dedicated switch
  page. Call `api.tenant_select` on change, then
  `await supabase.auth.refreshSession()` so the new JWT carries the
  updated claim.

When the user asks for "a signup form" or "allow signups", the
scaffolded `/login` route and `useTenantGuard` cover it. Don't add a
tenant selector to the signup flow — a new direct signup always
lands in a tenant of one.

---

## Email Hooks with Resend

Supabase Auth Hooks let you replace the default email sender with a custom Send Email hook backed by Resend. Three companion skills handle this integration:

- **`resend-skills`** — Resend API integration and sending logic
- **`email-best-practices`** — Deliverability, formatting, and content guidelines
- **`react-email`** — Email template components with React Email

If these companions are available, defer email hook implementation and template setup to them. Install all three:

```bash
npx skills add resend/resend-skills resend/email-best-practices resend/react-email
```

---

## Reference Files

- **[🛡️ RLS Patterns](./references/rls_patterns.md)** — Tenant-scoped policies, RBAC, multi-tenancy model, invitation flows, JWT claims

## Assets

- **[Common RLS policies](./assets/common_policies.sql)** — Reusable policy templates for new entities
