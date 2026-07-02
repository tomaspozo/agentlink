---
name: auth
description: Authentication, authorization, and tenant isolation for Supabase. Use when the task involves auth setup, sign up/sign in flows, RLS policies, row-level security, access control, permissions, roles, RBAC, multi-tenancy, tenant isolation, workspace context, the x-workspace-id header, session_context, user profiles, OAuth, JWT claims, invitation flows, or membership management. Also use when someone asks "who can access this" or "how do I secure this table." Activate whenever the task touches auth, security policies, or tenant boundaries.
---

# Auth, RLS & Multi-Tenancy

Authentication, authorization, and tenant isolation — all enforced by the database.

## Security Model — four layers, each with one job

1. **Schema isolation** (the table boundary) — Only `api.*` functions are exposed to clients; `public` tables are unreachable via the Data API (`.from()` cannot touch them). This is what actually protects the tables.
2. **RPC permission guard** (the permission gate — PRIMARY) — Every mutating `api.*` RPC calls `public.auth_verify_access('<entity>.<action>')` as its first statement; it raises HTTP 403 when the caller's active workspace lacks the permission. **This is where permission/action authz lives.**
3. **RLS, isolation-only** (the backstop) — Every table has a cheap policy scoping rows to `tenant_id = _auth_tenant_id()` and/or `user_id = auth.uid()`. It is the safety net against a forgotten `WHERE` — in an agent-built codebase, the worst-case multi-tenant bug. **Never put permission checks in RLS** — isolation only.
4. **Frontend guard** (UX only) — `useHasPermission()` / route guards hide or redirect. Never security: the backend guard is the real gate; a user who bypasses the UI still hits the 403.

**Prerequisite under all of this — GRANTs (explicit, default-deny).** `api.*` RPCs are `SECURITY INVOKER`, so they touch `public` tables **as the caller**, which needs a Postgres table grant just to access the table at all — a separate layer from RLS (grant = "can this role touch the table?"; RLS = "which rows?"). Supabase stopped auto-granting in 2026, and AgentLink keeps default-deny: **every table you want reachable needs an explicit `GRANT SELECT, INSERT, UPDATE, DELETE … TO authenticated, service_role`** (bundled with `ENABLE ROW LEVEL SECURITY`); an ungranted table stays private. `anon` is never granted on tables (anon-facing RPCs are `SECURITY DEFINER`). For a read-only table, grant `SELECT` to authenticated only. **Functions are default-deny too, granted per object** (no schema-wide `GRANT ON ALL FUNCTIONS`) — each function `REVOKE`s the built-in `PUBLIC` EXECUTE and `GRANT`s only its roles: `api.*` client RPCs → `authenticated, service_role`; `api._admin_*` → `service_role`; RLS helpers → `authenticated`. See the `database` skill's table-privileges rule and the `rpc` skill's Grants section.

```
Client → api.member_update(...)
            1. PERFORM auth_verify_access('membership.update')  → 403 if denied   (permission gate)
            2. UPDATE ... WHERE tenant_id = _auth_tenant_id()                      (explicit scope)
                 ↓ isolation RLS on memberships still filters by tenant            (backstop)
```

**When you add a capability you touch three layers:** declare the permission key (in `supabase/database/rbac/`), guard the RPC, gate the frontend. RLS only ever does isolation. See the checklist near the end of this file.

---

## The identity-only model — how a workspace is resolved

**The JWT proves identity only.** It carries **no tenant and no permissions**. The active workspace is asserted **per request** by the client via an `x-workspace-id` header, validated server-side, and pinned into a transaction-local GUC that every helper reads. This is the canonical model — a fresh AgentLink scaffold *is* this. Nothing tenant-related lives in the token: there is no access-token claim hook, no per-device workspace-pin table, and no server-side "select workspace" RPC. If a project still has those objects, they're stale machinery to remove.

**The request lifecycle:**

1. The client attaches `Authorization: Bearer <jwt>` (identity) **and** `x-workspace-id: <uuid>` (active workspace) to every Data-API request.
2. PostgREST runs `public._auth_pre_request()` once per request — the **db-pre-request hook**, wired by `ALTER ROLE authenticator SET pgrst.db_pre_request = 'public._auth_pre_request'` (shipped in `supabase/database/config/db_pre_request.sql`). It validates that `auth.uid()` is a **member** of the asserted workspace, then `set_config('request.tenant_id', <id>, true)` — transaction-local. No header → reset the GUC and return (deny by default). Non-member → `RAISE … ERRCODE '42501'` → **HTTP 403**.
3. `public._auth_tenant_id()` reads that GUC; RLS `USING (tenant_id = _auth_tenant_id())` scopes every row; `auth_verify_access()` / `_auth_has_permission()` gate writes — both derive fresh from `(auth.uid(), resolved workspace)`.
4. The client reads role + permissions from **`api.session_context()`** for the active workspace — *not* from the token. It returns `{ tenant_id, name, slug, role, permissions[] }`, or an empty context when no workspace is asserted (fresh sign-in → render the workspace picker). Switching workspace = sending a different header + re-fetching `session_context`. **No token re-mint, no session refresh.**

### The 8 security non-negotiables

Each is a hard rule — the places a bug leaks data across tenants — with the WHY. Do not relax them.

1. **Workspace context lives in a *transaction-local* GUC** (`set_config(…, true)` / `SET LOCAL`), never a session GUC. A plain `SET` / `false` third arg persists on the pooled connection and bleeds one request's workspace into the **next user's** request — the worst failure in the system, gated by a single boolean. This is user-A-reads-user-B.
2. **One GUC is the single source of truth.** Only `_auth_pre_request` writes `request.tenant_id`; everything else reads it via `_auth_tenant_id()`. If row-scoping and the permission guard resolved the workspace independently they could disagree (permission checked against A, rows scoped to B → confused-deputy write). Never read the header in app code.
3. **The asserted workspace is membership-validated server-side.** `x-workspace-id` is client-asserted and trusted only after `_auth_pre_request` confirms `memberships(user = auth.uid(), tenant = header)`. Never trust it off the wire.
4. **Fail closed.** A malformed/non-UUID header aborts the request — it never falls through to "some other workspace." Let the exception propagate; never swallow it.
5. **Resolved-NULL means deny, not allow.** No header → `_auth_tenant_id()` is NULL → RLS matches no rows and `_auth_has_permission()` is false. Never let an empty/NULL workspace slip past a guard.
6. **Aggregate / cross-workspace reads go through `SECURITY DEFINER` RPCs** that explicitly filter `tenant_id IN (SELECT tenant_id FROM memberships WHERE user_id = auth.uid())` — not broad client table reads, and never by overloading the single-tenant RLS predicate with a second mode.
7. **The MCP server forwards the user's JWT; `service_role` is NEVER the user-scoped path.** With the user JWT, PostgREST + RLS + `auth_verify_access` stay the enforcement boundary. With `service_role`, RLS is bypassed and isolation reduces to "the MCP TypeScript is bug-free" — a confused-deputy waiting to happen. No `supabaseAdmin` in a tool.
8. **No header → short-circuit with zero extra DB work.** A request that asserts no workspace does no membership read — it resets the GUC and returns. Cheap and unmistakably deny (rule 5).

### The guard helpers (`public/_authz.sql`)

- `public.auth_verify_access(p_permission text)` — **raises** (SQLSTATE `42501` → HTTP 403). Call as the first statement of every mutating RPC.
- `public.auth_has_access(p_permission text)` — **boolean**, for conditional branching inside an RPC (e.g. return a richer payload to admins).

Both wrap `public._auth_has_permission`, which derives the answer **fresh** on every request from `(caller, active workspace)` — one indexed probe into `memberships ⋈ role_permissions`, no JWT claim, nothing to go stale. Evaluated against the caller's **active workspace** (the one resolved from the `x-workspace-id` header). Do **not** call `_auth_has_permission` in policies; use `auth_verify_access` in the RPC.

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
-- then declare 'widget.update' in supabase/database/rbac/{permissions,role_permissions}.sql
```

### Grants on the `api` schema

`USAGE` on the `api` schema is granted to `anon`, `authenticated`, and
`service_role`. That is NOT the security boundary — it just lets each
role resolve the schema name so PostgREST can find the function you're
calling. Pages that render before the session attaches (public home,
marketing content) need `anon` to have USAGE or every RPC reply is
`permission denied for schema api`.

`EXECUTE` on each function IS the security boundary, and it's granted
**per object** — there is no schema-wide `GRANT ON ALL FUNCTIONS` (a blanket
grant gets applied after the per-function REVOKEs on `db apply`, overriding them
and exposing `api._admin_*` on dev). Every `api` function carries its own grant:

```sql
-- client RPC (default for authenticated users; RLS filters rows)
REVOKE ALL ON FUNCTION api.<fn>(<arg-types>) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.<fn>(<arg-types>) TO authenticated, service_role;
```

`anon` never receives EXECUTE unless you add it. When a function is
intentionally public (a status page, public metrics, an unauthenticated
signup-adjacent RPC), grant it explicitly and make it `SECURITY DEFINER`:

```sql
REVOKE ALL ON FUNCTION api.public_metrics() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.public_metrics() TO anon, authenticated, service_role;
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

> **Scaffolded by the CLI.** Profiles, tenants, and memberships are created automatically on signup via the `_internal_admin_handle_new_user` trigger. The SQL below is for reference — it already exists in your project. If missing, run `pnpm exec agentlink --force-update` — do not recreate manually.

User metadata belongs in a `profiles` table, not in Supabase Auth metadata. The trigger (`_internal_admin_handle_new_user`, AFTER INSERT on `auth.users`) creates the profile and — for **direct** signups only — a default tenant + owner membership. Invited users (created via `generateLink({ type: 'invite' })`, so `invited_at IS NOT NULL`) get only a profile; `invitation_accept()` adds them to the inviter's tenant. The trigger writes **no** `raw_app_meta_data` — nothing tenant-related lives in the JWT in 2.0; the active workspace is asserted per request.

```sql
-- supabase/database/schemas/public/tables/profiles.sql (scaffolded)
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

> **Zero-touch, no picker for solo users.** After a direct signup the user has exactly one membership. The client asserts that workspace via `x-workspace-id` (the frontend resolves it from `session_context` / the user's memberships) — no selection UI and no session refresh. There's no "JWT minted before the membership row" race to paper over, because the token never carried the tenant.

**Need to customize signup logic?** Edit the function body in `supabase/database/schemas/public/functions/_internal_admin_handle_new_user.sql` (keep the same name — the update flow preserves your edits here), then `pnpm exec agentlink db apply`. The full scaffolded body + the `profile_get` / `profile_update` RPCs are in **[RLS Patterns → Signup trigger & profile RPCs](./references/rls_patterns.md)** — don't recreate them; they already exist.

---

## RLS Policies

RLS is always enabled on every table. Policies filter rows based on who's asking.

### Policy naming — snake_case only, never quoted

Always name policies with bare snake_case identifiers following `{role}_{action}_{scope}` (e.g., `users_read_own_charts`, `admins_delete_memberships`). Never wrap a policy name in double quotes, never include spaces, mixed case, or reserved words.

```sql
-- ❌ NOT THIS — quoted name with spaces breaks `pnpm exec agentlink db apply`
CREATE POLICY "Members can read own tenant" ON public.tenants ...

-- ✅ THIS
CREATE POLICY members_read_own_tenant ON public.tenants ...
```

Reason: `db apply` re-serializes every statement and strips surrounding double quotes from identifiers when it does. The resulting SQL reaches Postgres unquoted and fails with a syntax error on the spaces. Snake_case bare identifiers round-trip cleanly.

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
-- supabase/database/schemas/public/tables/charts.sql
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
-- supabase/database/schemas/public/functions/_auth_chart_can_read.sql
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

> **Scaffolded by the CLI.** The CLI scaffolds a complete multi-tenancy model including tables, RLS policies, auth helpers, and API RPCs. If missing, run `pnpm exec agentlink --force-update` — do not recreate manually. The agent builds application-specific tables on top of this foundation.

The multi-tenancy model uses these tables:

```
tenants           → Organizations/teams (public/tables/tenants.sql)
memberships       → Who belongs to which tenant, with what role (public/tables/memberships.sql)
invitations       → Pending invitations (public/tables/invitations.sql)
roles             → Role table (public/tables/roles.sql); rows in rbac/roles.sql
permissions       → Permission table (public/tables/permissions.sql); rows in rbac/permissions.sql
role_permissions  → Role→permission table (public/tables/role_permissions.sql); rows in rbac/role_permissions.sql
tenant-scoped tables → Every row has a tenant_id column (agent creates these)
```

There is **no per-device workspace-pin table** — the active workspace isn't stored server-side at all. It's asserted per request via `x-workspace-id`, resolved by the `_auth_pre_request` hook into the transaction-local `request.tenant_id` GUC (see "The identity-only model" at the top of this file). `_auth_tenant_id()` reads that GUC; RLS uses it for **isolation only** (scoping rows to the active workspace). **Permission checks do not go in policies** — they live in the RPC via `public.auth_verify_access('<entity>.<action>')`.

API RPCs live one-per-file under `supabase/database/schemas/api/functions/` (e.g. `session_context.sql`, `tenant_list.sql`, `tenant_create.sql`, `tenant_update.sql`, `tenant_delete.sql`, `invitation_create.sql`, `invitation_accept.sql`, `membership_list.sql`). They resolve "current workspace" from `_auth_tenant_id()` — **never accept a `p_tenant_id` for the active workspace**. The client reads role + permissions from `api.session_context()`; there is no server-side "select workspace" RPC and no session refresh — switching workspace is a client variable change (a different header).

> **Load [RLS Patterns](./references/rls_patterns.md) for tenant-scoped RLS policies, RBAC, invitation flows, and patterns for new tenant-scoped tables.**

### Tenancy UX: count tenants, don't assume

The backend is always multi-tenant. The signup trigger mints a tenant
for direct signups; `invitation_accept` adds invited users to the
inviter's tenant. That's the invariant — don't try to strip, rewire,
or "simplify" it per project.

The UX rule falls out of counting `tenants.length`:

- **One tenant** (the common case for internal tools, invited-only
  portals, first-time signups, and solo users): never render a
  workspace picker. The client asserts the user's single workspace via
  `x-workspace-id` on every request (resolved from their memberships /
  `session_context`) — no selection UI needed. Because the token never
  carried the tenant, there's no post-signup race to guard against.
- **More than one tenant** (a user genuinely belongs to multiple
  workspaces): render a picker in chrome or on a dedicated switch
  page. Switching is a **client variable change** — on the frontend
  it's `useWorkspace().setActive(id)` (the scaffolded workspace
  context), which updates the active-workspace store the global `fetch`
  wrapper reads to set `x-workspace-id`, then re-fetches
  `api.session_context()` for the new role + permissions. **No
  server-side workspace-select RPC, no session refresh, no token
  re-mint.** (Client depth lives in the `frontend` skill —
  `useWorkspace`/`setActive`, the fetch wrapper.) Because context is per request,
  the same session can even act in different workspaces on different
  requests (this is what makes the MCP agent path native).

When the user asks for "a signup form" or "allow signups", the
scaffolded `/auth/sign-in`, `/auth/sign-up`, `/auth/check-inbox`,
`/auth/forgot-password`, `/update-password`, `/auth/confirm`, and
`/accept-invite` routes cover the full flow. Don't add a tenant
selector to the signup flow — a new direct signup always lands in
a tenant of one.

### Membership & invitation RPC contract

The `api` schema exposes eight RPCs for managing workspace members.
Match this contract — it's wired into the scaffolded `/settings/members`
UI and the `/accept-invite` flow.

| RPC | Purpose | Permission |
|-----|---------|-----------|
| `api.membership_list()` | List members of the current tenant | `membership.read` |
| `api.membership_update_role(p_membership_id uuid, p_role text)` | Change a member's role (rejects `'owner'`; rejects self) | `membership.update` |
| `api.membership_remove(p_membership_id uuid)` | Remove a member (rejects self) | `membership.delete` |
| `api.invitation_list()` | List pending invitations for the current tenant | `invitation.create` |
| `api.invitation_create(p_email text, p_role text)` | Invite — sends the workspace-invite email via `api._admin_send_email('invite', …)` → `internal-send-email` | `invitation.create` |
| `api.invitation_resend(p_invitation_id uuid)` | Re-enqueue the email for an existing invitation (token unchanged) | `invitation.create` |
| `api.invitation_revoke(p_invitation_id uuid)` | Cancel a pending invitation | `invitation.delete` |
| `api.invitation_accept(p_token uuid)` | Accept an invitation; idempotent on second click | (caller must be authenticated) |

All eight RPCs read the current workspace from the request GUC via
`public._auth_tenant_id()` (the value the pre-request hook pinned from
`x-workspace-id`). **Never accept `p_tenant_id` from the client when
"current workspace" is what you mean** — match the existing convention
in the scaffolded `tenant_*` RPCs under `database/schemas/api/functions/`.

Each permission-bearing RPC enforces its permission with
`PERFORM public.auth_verify_access('<permission>')` as its first statement
(after the auth/tenant null guards) — the "Permission" column above is the
exact key it passes. `invitation_accept` is intentionally **unguarded** (the
accepter isn't a member yet; the token is the authorization). The matching
table policies are isolation-only — they no longer check the permission.

### Checklist — adding a permission-gated capability

Do all of these (the guard alone, or the frontend alone, is never enough):

1. **Declare the permission** in `supabase/database/rbac/permissions.sql` and bind it to roles in `supabase/database/rbac/role_permissions.sql` (each file fills the `rbac_desired` staging table — just add `VALUES` rows). **Apply it**: `pnpm exec agentlink db apply` (applies rbac alongside schema) or `db resources` (rbac + cron + storage only); both also run on every `env deploy`. The reconcile converges the DB to exactly the declared set — **full reconcile**: removing a row REVOKES that permission on every env (incl. prod). NB: these rows are reference data in `rbac/`, *not* in the table files under `schemas/public/tables/` — those define structure only and never carry row data. (This is distinct from a SQL **GRANT** on a table/function, which is DDL in the object's own schema file.)
2. **Guard the RPC**: `PERFORM public.auth_verify_access('<key>')` as the first statement of the mutating `api.*` function; scope queries with `WHERE tenant_id = (SELECT public._auth_tenant_id())`.
3. **Isolate the table**: ensure an isolation-only RLS policy exists (tenant/ownership, no permission predicate).
4. **Gate the frontend**: route guard `requirePermission('<key>')` + control gating `useHasPermission('<key>')` (UX only).
5. **Verify** a permitted role resolves the key — `api.session_context()` (with the workspace asserted) returns it in `permissions[]`, and `auth_verify_access('<key>')` passes for that role. It's derived fresh from `role_permissions`, so a re-seed takes effect on the next request.

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

### Role changes take effect on the next request

Permissions are derived fresh from `(user, workspace)` on every request —
they are **not** baked into the JWT — so a demotion takes effect on the
caller's **next request**, with no `jwt_expiry` propagation window and
nothing to go stale. This deletes the entire stale-permissions class of
bug that JWT-baked claims had.

The one thing a role change doesn't do is tear down a *live* session: an
in-flight request already inside a transaction finishes. For a hard cut
(fully terminate an ejected member's session), call
`auth.admin.signOut(userId)` server-side after the change — requires
`service_role`, so wire it through an edge function. The scaffold doesn't
ship this by default; build it when the threat model requires it.

### Invitations work even when the app is single-tenant style

The invitation pipeline doesn't care whether the UI exposes a workspace
switcher. An admin invites a teammate; the teammate signs up; the
AFTER-INSERT trigger skips default-tenant creation because
`invited_at IS NOT NULL`; the teammate accepts via
`api.invitation_accept`; the membership row is created. The client then
asserts the joined workspace via `x-workspace-id` on its next request
(setting it active and re-fetching `session_context`) — no re-mint, no
picker required.

---

## Email Hooks with Resend

> This section covers **auth** emails only (signup confirm, magic link, recovery, email change) — the ones GoTrue triggers. For **app-driven** emails (welcome, "export ready", receipts, alerts), use the [notifications skill](../notifications/SKILL.md): `api._admin_send_email(...)` → `internal-send-email`, same queue, different path.

Supabase Auth Hooks let you replace the default email sender with a custom Send Email hook backed by Resend. Three companion skills handle this integration:

- **`resend-skills`** — Resend API integration and sending logic
- **`email-best-practices`** — Deliverability, formatting, and content guidelines
- **`react-email`** — Email template components with React Email

If these companions are available, defer email hook implementation and template setup to them. Install all three:

```bash
npx skills add resend/resend-skills resend/email-best-practices resend/react-email
```

**How Resend is configured (per environment):** the FROM address is the source of truth in `agentlink.json` under `cloud.environments.<env>.resend.fromEmail`; the API key lives only in that env's Supabase secret store (never in git or `.env.local`). For the full model — secret vs non-secret, local resend-box vs cloud SMTP, the `--api-key`/`--email`/`--name` flags, and how to change just the display name — see **[Resend setup](../cli/references/resend.md)** in the CLI skill.

### Troubleshooting: emails not sending

If a user reports that signup confirmations, password resets, or invitation emails aren't arriving, **verify Resend is configured for that environment before debugging the edge function.** Resend is per-env now — there's no `check` flag for it. Instead:

1. **Read `agentlink.json`** → `cloud.environments.<env>.resend`. If absent, Resend was never set up for that env.
   - **Fix:** tell the user to run `pnpm exec agentlink resend setup --env <env>` (first time needs `--api-key` + `--email` together, or a saved default account). Don't debug `internal-send-auth-email` / `internal-send-email` until this exists — they silently no-op without the secret.
2. **Validate the secret is actually pushed** (debug): confirm the env's Supabase edge-function secret store contains `RESEND_API_KEY`. If the manifest has a `resend` block but the secret is missing (e.g. a manual dashboard wipe), re-run `resend setup --env <env>` to force a re-push.
3. If both are green, the issue is elsewhere — check, in order:
   1. Edge function logs in the Supabase dashboard for actual send errors (most common: FROM domain not verified under the API key's Resend account).
   2. The `pgmq.q_agentlink_tasks` queue has unprocessed messages (worker not running).
   3. The auth hook URI in `auth.config` actually points at `_hook_send_email`.

---

## Reference Files

- **[🛡️ RLS Patterns](./references/rls_patterns.md)** — Request lifecycle, tenant-scoped policies, RBAC, multi-tenancy model (`_auth_pre_request`, `session_context`), signup trigger & profile RPCs, invitation flows

## Assets

- **[Common RLS policies](./assets/common_policies.sql)** — Reusable policy templates for new entities
