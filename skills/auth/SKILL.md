---
name: auth
description: Authentication, authorization, and tenant isolation for Supabase. Use when the task involves auth setup, sign up/sign in flows, RLS policies, row-level security, access control, permissions, roles, RBAC, multi-tenancy, tenant isolation, user profiles, OAuth, JWT claims, invitation flows, or membership management. Also use when someone asks "who can access this" or "how do I secure this table." Activate whenever the task touches auth, security policies, or tenant boundaries.
---

# Auth, RLS & Multi-Tenancy

Authentication, authorization, and tenant isolation — all enforced by the database.

## Security Model — four layers, each with one job

1. **Schema isolation** (the table boundary) — Only `api.*` functions are exposed to clients; `public` tables are unreachable via the Data API (`.from()` cannot touch them). This is what actually protects the tables.
2. **RPC permission guard** (the permission gate — PRIMARY) — Every mutating `api.*` RPC calls `public.auth_verify_access('<entity>.<action>')` as its first statement; it raises HTTP 403 when the caller's active workspace lacks the permission. **This is where permission/action authz lives.**
3. **RLS, isolation-only** (the backstop) — Every table has a cheap policy scoping rows to `tenant_id = _auth_tenant_id()` and/or `user_id = auth.uid()`. It is the safety net against a forgotten `WHERE` — in an agent-built codebase, the worst-case multi-tenant bug. **Never put permission checks in RLS** — isolation only.
4. **Frontend guard** (UX only) — `useHasPermission()` / route guards hide or redirect. Never security: the backend guard is the real gate; a user who bypasses the UI still hits the 403.

**Prerequisite under all of this — GRANTs (explicit, default-deny).** `api.*` RPCs are `SECURITY INVOKER`, so they touch `public` tables **as the caller**, which needs a Postgres table grant just to access the table at all — a separate layer from RLS (grant = "can this role touch the table?"; RLS = "which rows?"). Supabase stopped auto-granting in 2026, and AgentLink keeps default-deny: **every table you want reachable needs an explicit `GRANT SELECT, INSERT, UPDATE, DELETE … TO authenticated, service_role`** (bundled with `ENABLE ROW LEVEL SECURITY`); an ungranted table stays private. `anon` is never granted on tables (anon-facing RPCs are `SECURITY DEFINER`). For a read-only table, grant `SELECT` to authenticated only. **Functions are default-deny too** — Postgres' built-in `PUBLIC` EXECUTE is revoked, so `anon` can't call a function unless it's granted explicitly; `api.*` RPCs auto-grant `authenticated`/`service_role`, RLS helpers grant `authenticated`. See the `database` skill's table-privileges rule.

```
Client → api.member_update(...)
            1. PERFORM auth_verify_access('membership.update')  → 403 if denied   (permission gate)
            2. UPDATE ... WHERE tenant_id = _auth_tenant_id()                      (explicit scope)
                 ↓ isolation RLS on memberships still filters by tenant            (backstop)
```

**When you add a capability you touch three layers:** seed the permission key (`role_permissions`), guard the RPC, gate the frontend. RLS only ever does isolation. See the checklist near the end of this file.

### The guard helpers (`public/_authz.sql`)

- `public.auth_verify_access(p_permission text)` — **raises** (SQLSTATE `42501` → HTTP 403). Call as the first statement of every mutating RPC.
- `public.auth_has_access(p_permission text)` — **boolean**, for conditional branching inside an RPC (e.g. return a richer payload to admins).

Both wrap `public._auth_has_permission` — JWT-only (`app_metadata.permissions`, populated by `_hook_custom_access_token`), zero DB reads, evaluated against the caller's **active workspace**. Do **not** call `_auth_has_permission` in policies anymore; use `auth_verify_access` in the RPC.

```sql
-- Canonical: isolation-only RLS + permission guard in the RPC
CREATE POLICY widgets_tenant_isolation ON public.widgets
  FOR ALL TO authenticated
  USING      (tenant_id = (SELECT public._auth_tenant_id()))
  WITH CHECK (tenant_id = (SELECT public._auth_tenant_id()));

CREATE FUNCTION api.widget_update(p_id uuid, p_name text)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
BEGIN
  PERFORM public.auth_verify_access('widget.update');      -- primary deny (403)
  UPDATE public.widgets SET name = p_name
   WHERE id = p_id
     AND tenant_id = (SELECT public._auth_tenant_id());     -- explicit scope; RLS backstops
  RETURN jsonb_build_object('id', p_id, 'name', p_name);
END; $$;
-- then seed: INSERT INTO public.permissions / role_permissions ('widget.update')
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

> **Scaffolded by the CLI.** Profiles, tenants, and memberships are created automatically on signup via the `_internal_admin_handle_new_user` trigger. The SQL below is for reference — it already exists in your project. If missing, run `npx agentlink-sh@latest --force-update` — do not recreate manually.

User metadata belongs in a `profiles` table, not in Supabase Auth metadata. The trigger creates the profile and — for direct signups — a default tenant + owner membership. Invited users (created via `generateLink({ type: 'invite' })`) only get a profile; `invitation_accept()` handles adding them to the inviter's tenant. JWT claims (`tenant_id`, `tenant_role`, `permissions`) are populated automatically on every JWT mint by the custom access-token hook (`_hook_custom_access_token`) — the trigger doesn't touch `auth.users.raw_app_meta_data`:

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
    -- No raw_app_meta_data write here — the custom access-token hook
    -- (_hook_custom_access_token) reads memberships on every JWT mint and
    -- auto-selects the user's oldest membership when no per-session pin exists.
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_auth_users_new_user
  AFTER INSERT ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION public._internal_admin_handle_new_user();
```

> **Single-tenant zero-touch.** The custom access-token hook auto-selects the
> user's oldest membership when no per-session pin exists. After signup the
> first JWT minted already carries the right `tenant_id` — no `tenant_select`
> dance required. The scaffolded `useTenantGuard` covers the only edge case:
> a JWT minted *before* the AFTER-INSERT trigger materialized the membership
> row. In that case it calls `refreshSession()` once, which re-runs the hook
> against the now-present membership.

**Need to customize signup logic?** If the app requires additional work on signup (e.g., creating rows in app-specific tables, syncing with external services), override `_internal_admin_handle_new_user` by removing its `-- @agentlink` annotation block in `supabase/schemas/public/_internal_admin.sql` and modifying the function body. Keep the same function name. The other managed functions in that file (`_internal_admin_get_secret`, `set_updated_at`, etc.) remain annotated and will continue receiving CLI updates. Apply with `npx agentlink-sh@latest db apply`.

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

### Policy naming — snake_case only, never quoted

Always name policies with bare snake_case identifiers following `{role}_{action}_{scope}` (e.g., `users_read_own_charts`, `admins_delete_memberships`). Never wrap a policy name in double quotes, never include spaces, mixed case, or reserved words.

```sql
-- ❌ NOT THIS — quoted name with spaces breaks `npx agentlink-sh@latest db apply`
CREATE POLICY "Members can read own tenant" ON public.tenants ...

-- ✅ THIS
CREATE POLICY members_read_own_tenant ON public.tenants ...
```

Reason: `db apply` routes every statement through `pg-delta` → `pg-topo` → libpg_query's deparser, which strips surrounding double quotes when re-serializing identifiers. The resulting SQL reaches Postgres unquoted and fails with a syntax error on the spaces. Snake_case bare identifiers round-trip cleanly.

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

> **Scaffolded by the CLI.** The CLI scaffolds a complete multi-tenancy model including tables, RLS policies, auth helpers, and API RPCs. If missing, run `npx agentlink-sh@latest --force-update` — do not recreate manually. The agent builds application-specific tables on top of this foundation.

The multi-tenancy model uses these tables:

```
tenants           → Organizations/teams (multitenancy.sql)
memberships       → Who belongs to which tenant, with what role (multitenancy.sql)
invitations       → Pending invitations (multitenancy.sql)
session_tenants   → Per-device tenant pin, keyed on auth.sessions.id (multitenancy.sql)
roles             → Role definitions (_rbac.sql)
permissions       → Permission catalog (_rbac.sql)
role_permissions  → Role → permission matrix (_rbac.sql)
tenant-scoped tables → Every row has a tenant_id column (agent creates these)
```

**The custom access-token hook (`_hook_custom_access_token`) is the engine.** On every JWT mint (sign-in and refresh) it:

1. Reads the per-device pin from `session_tenants` keyed on the session's `session_id`.
2. Falls back to the user's oldest membership when no pin exists — single-tenant apps "just work" with no client-side selection.
3. Looks up the user's permissions in `role_permissions`.
4. Injects `tenant_id`, `tenant_role`, and `permissions` into `app_metadata`.

Tenant context comes from JWT custom claims (`auth.jwt() -> 'app_metadata' ->> 'tenant_id'`), **not** from request parameters. RLS policies use `_auth_tenant_id()` for **isolation only** (scoping rows to the active tenant). **Permission checks do not go in policies** — they live in the RPC via `public.auth_verify_access('<entity>.<action>')`. See the four-layer Security Model at the top of this file.

API RPCs live in `supabase/schemas/api/tenant.sql`: `tenant_select`, `tenant_list`, `tenant_create`, `invitation_create`, `invitation_accept`, `membership_list`. `tenant_select` writes `session_tenants` (per-device pin); `tenant_create` and `invitation_accept` also pin the new tenant to the caller's session so a single `refreshSession()` lands them inside it.

> **Load [RLS Patterns](./references/rls_patterns.md) for tenant-scoped RLS policies, RBAC, invitation flows, and patterns for new tenant-scoped tables.**

### Tenancy UX: count tenants, don't assume

The backend is always multi-tenant. The signup trigger mints a tenant
for direct signups; `invitation_accept` adds invited users to the
inviter's tenant. That's the invariant — don't try to strip, rewire,
or "simplify" it per project.

The UX rule falls out of counting `tenants.length`:

- **One tenant** (the common case for internal tools, invited-only
  portals, first-time signups, and solo users): never render a tenant
  picker. The access-token hook auto-selects the user's oldest
  membership, so the JWT already carries the right `tenant_id` from
  the very first mint. `useTenantGuard` covers the post-signup edge
  where the JWT preceded the membership row — most apps need nothing
  beyond what's scaffolded.
- **More than one tenant** (a user genuinely belongs to multiple
  workspaces): render a picker in chrome or on a dedicated switch
  page. Call `api.tenant_select` on change, then
  `await supabase.auth.refreshSession()` — the hook re-runs and the
  new JWT carries the chosen tenant + permissions. Per-device: each
  laptop/phone has its own `session_tenants` pin, so switching on one
  doesn't move the other.

When the user asks for "a signup form" or "allow signups", the
scaffolded `/auth/sign-in`, `/auth/sign-up`, `/auth/check-inbox`,
`/auth/forgot-password`, `/update-password`, `/auth/confirm`, and
`/accept-invite` routes cover the full flow. Don't add a tenant
selector to the signup flow — a new direct signup always lands in
a tenant of one.

### Membership & invitation RPC contract

The `api` schema exposes seven RPCs for managing workspace members.
Match this contract — it's wired into the scaffolded `/settings/members`
UI and the `/accept-invite` flow.

| RPC | Purpose | Permission |
|-----|---------|-----------|
| `api.membership_list()` | List members of the current tenant | `membership.read` |
| `api.membership_update_role(p_membership_id uuid, p_role text)` | Change a member's role (rejects `'owner'`; rejects self) | `membership.update` |
| `api.membership_remove(p_membership_id uuid)` | Remove a member (rejects self) | `membership.delete` |
| `api.invitation_list()` | List pending invitations for the current tenant | `invitation.create` |
| `api.invitation_create(p_email text, p_role text)` | Invite — enqueues `internal-invite-member` to send the email | `invitation.create` |
| `api.invitation_resend(p_invitation_id uuid)` | Re-enqueue the email for an existing invitation (token unchanged) | `invitation.create` |
| `api.invitation_revoke(p_invitation_id uuid)` | Cancel a pending invitation | `invitation.delete` |
| `api.invitation_accept(p_token uuid)` | Accept an invitation; idempotent on second click | (caller must be authenticated) |

All eight RPCs read the current tenant from JWT claims via
`public._auth_tenant_id()`. **Never accept `p_tenant_id` from the
client when "current tenant" is what you mean** — match the existing
convention in `tenant.sql`.

Each permission-bearing RPC enforces its permission with
`PERFORM public.auth_verify_access('<permission>')` as its first statement
(after the auth/tenant null guards) — the "Permission" column above is the
exact key it passes. `invitation_accept` is intentionally **unguarded** (the
accepter isn't a member yet; the token is the authorization). The matching
table policies are isolation-only — they no longer check the permission.

### Checklist — adding a permission-gated capability

Do all of these (the guard alone, or the frontend alone, is never enough):

1. **Seed the permission** in `public.permissions` + `public.role_permissions` (which roles get it) in `_rbac.sql`.
2. **Guard the RPC**: `PERFORM public.auth_verify_access('<key>')` as the first statement of the mutating `api.*` function; scope queries with `WHERE tenant_id = (SELECT public._auth_tenant_id())`.
3. **Isolate the table**: ensure an isolation-only RLS policy exists (tenant/ownership, no permission predicate).
4. **Gate the frontend**: route guard `requirePermission('<key>')` + control gating `useHasPermission('<key>')` (UX only).
5. **Verify** the JWT carries the key for a permitted role — the access-token hook bakes `role_permissions` → `app_metadata.permissions` on every mint.

### Role enum and the owner rule

Roles ship pre-seeded with rank-ordered hierarchy:

| Role | Rank | Invitable? | Default permissions |
|------|------|-----------|--------------------|
| `owner` | 4 | NO | All — minted only on tenant creation |
| `admin` | 3 | yes | Manage members, invitations, tenant settings (except delete) |
| `member` | 2 | yes (default) | Read teammates only |
| `viewer` | 1 | yes | Read teammates only |

`'owner'` is non-assignable — both `invitations` and
`api.membership_update_role` reject it. Owners are minted exclusively
when their tenant is created, by the `_internal_admin_handle_new_user`
trigger or `api.tenant_create`.

### JWT-expiry caveat for role changes

`trg_memberships_sync_session_tenants` keeps `session_tenants.tenant_role`
in sync when a role changes, but **in-flight JWTs hold stale claims
until expiry** (default `jwt_expiry = 3600` seconds, one hour). If you
demote a user, they keep elevated permissions until their JWT refreshes.

For sensitive immediate-effect demotions (e.g. revoking admin), call
`auth.admin.signOut(userId)` server-side after the role change to force
re-auth — requires `service_role`, so wire it through an edge function.
The scaffold doesn't ship this by default; build it when the threat
model requires sub-`jwt_expiry` propagation.

### Invitations work even when the app is single-tenant style

The invitation pipeline doesn't care whether the UI exposes a tenant
switcher. An admin invites a teammate; the teammate signs up; the
AFTER-INSERT trigger skips default-tenant creation because
`invited_at IS NOT NULL`; the teammate accepts via
`api.invitation_accept`; the membership row is created and pinned to
their current session; next refresh lands them inside the joined
workspace. No code path requires a UI picker.

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

### Troubleshooting: emails not sending

If a user reports that signup confirmations, password resets, or invitation emails aren't arriving, **check Resend configuration before debugging the edge function**. Run `npx agentlink-sh@latest check` and look at `resend_configured`:

- **`false`** — Resend isn't set up. Likely causes:
  - `.env.local` still has the placeholder `RESEND_API_KEY=re_your_api_key_here` or `RESEND_FROM_EMAIL=Your App <noreply@yourdomain.com>`.
  - Cloud mode: the project's edge-function secrets are missing `RESEND_API_KEY` (the values exist in `.env.local` but were never pushed to Supabase).

  **Fix:** tell the user to run `npx agentlink-sh@latest resend setup`. It walks them through getting an API key + verified-domain FROM address, writes both to `.env.local`, and (in cloud mode) pushes them to the edge-function secrets. Don't try to debug the `internal-send-auth-email` or `internal-invite-member` functions until this is green — they silently no-op without these vars.

- **`true`** — Resend is wired up. The issue is elsewhere. Check, in order:
  1. Edge function logs in the Supabase dashboard for actual send errors (most common: unverified FROM domain).
  2. The `pgmq.q_agentlink_tasks` queue has unprocessed messages (worker not running).
  3. The auth hook URI in `auth.config` actually points at `_hook_send_email`.

---

## Reference Files

- **[🛡️ RLS Patterns](./references/rls_patterns.md)** — Tenant-scoped policies, RBAC, multi-tenancy model, invitation flows, JWT claims

## Assets

- **[Common RLS policies](./assets/common_policies.sql)** — Reusable policy templates for new entities
