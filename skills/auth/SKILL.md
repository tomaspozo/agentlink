---
name: auth
description: Authentication, authorization, and tenant isolation for Supabase. Use when the task involves auth setup, sign up/sign in flows, RLS policies, row-level security, access control, permissions, roles, RBAC, multi-tenancy, tenant isolation, user profiles, OAuth, JWT claims, invitation flows, or membership management. Also use when someone asks "who can access this" or "how do I secure this table." Activate whenever the task touches auth, security policies, or tenant boundaries.
license: MIT
metadata:
  author: agentlink
  version: "0.1"
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

---

## Auth Patterns

### Supabase Auth is the single identity provider

- Use `auth.uid()` and `auth.jwt()` in SQL — never trust client-sent user IDs
- Session management is the frontend's responsibility
- The database only cares about the JWT — it verifies identity, not sessions

### Profile creation on sign-up

User metadata belongs in a `profiles` table, not in Supabase Auth metadata. Create profiles automatically with a trigger:

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
-- Trigger function: supabase/schemas/public/_internal.sql
-- Trigger: supabase/schemas/public/profiles.sql
CREATE OR REPLACE FUNCTION public._internal_handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER  -- required: reads from auth.users which RLS can't access
SET search_path = ''
AS $$
BEGIN
  INSERT INTO public.profiles (id, email, display_name)
  VALUES (
    NEW.id,
    NEW.email,
    COALESCE(NEW.raw_user_meta_data ->> 'full_name', split_part(NEW.email, '@', 1))
  );
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_auth_users_new_user
  AFTER INSERT ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION public._internal_handle_new_user();
```

### Profile RPCs

```sql
-- supabase/schemas/api/profile.sql
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
CREATE POLICY "Users can read own charts"
ON public.charts FOR SELECT
USING (user_id = auth.uid());

CREATE POLICY "Users can insert own charts"
ON public.charts FOR INSERT
WITH CHECK (user_id = auth.uid());

CREATE POLICY "Users can update own charts"
ON public.charts FOR UPDATE
USING (user_id = auth.uid());

CREATE POLICY "Users can delete own charts"
ON public.charts FOR DELETE
USING (user_id = auth.uid());
```

This is the simplest pattern. Use it when there's no tenant/team concept — the data is purely personal.

### With auth helper functions

When access checks are more complex than a single column comparison, use `_auth_*` functions:

```sql
-- supabase/schemas/public/_auth.sql
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
CREATE POLICY "Users can read own or public charts"
ON public.charts FOR SELECT
USING (public._auth_chart_can_read(id));
```

**When to use helpers vs inline:** Use inline `user_id = auth.uid()` when the check is a single column comparison. Use `_auth_*` helpers when the check involves joins, multiple conditions, or tenant membership lookups. Don't over-abstract — a simple `USING` clause doesn't need a function.

> **Load [RLS Patterns](./references/rls_patterns.md) for tenant-scoped policies, role-based access, and the multi-tenancy model.**

---

## Multi-Tenancy Overview

The multi-tenancy model uses three tables:

```
tenants          → The organizations/teams
memberships      → Who belongs to which tenant, with what role
tenant-scoped tables → Every row has a tenant_id column
```

Tenant context comes from JWT custom claims (`auth.jwt() -> 'app_metadata' ->> 'tenant_id'`), **not** from request parameters. RLS policies use this claim to filter rows automatically.

> **Load [RLS Patterns](./references/rls_patterns.md) for the full multi-tenancy model, tenant tables, membership management, RBAC, invitation flows, and tenant-scoped RLS policies.**

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

- **[Profile trigger SQL](./assets/profile_trigger.sql)** — Auto-create profile on sign-up
- **[Tenant tables SQL](./assets/tenant_tables.sql)** — Tenants, memberships, and invitations tables
- **[Common RLS policies](./assets/common_policies.sql)** — Reusable policy templates
