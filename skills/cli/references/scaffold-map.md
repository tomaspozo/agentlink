# Scaffold Map — what every fresh project ships with

> **🛑 This is an inventory of what the CLI ALREADY created — NOT a checklist to build by hand.**
> If these files don't exist yet (no `agentlink.json` in the project root), the project is
> **not scaffolded** — STOP and run the CLI (`npx agentlink-sh@latest`, see the `cli` skill).
> Never hand-create the tables, RPCs, helpers, routes, or config listed below: the CLI lays
> them down deterministically along with config, migrations, and env wiring you can't
> reproduce by copying this file. This map is only for *reading* an already-scaffolded
> project, never for *recreating* one.

This is the **starting inventory** the CLI lays down for a brand-new project. It is
**deterministic and version-matched**: the CLI in this repo and these skills ship
together, so a freshly scaffolded project always has exactly the files below.

**Use this to skip the discovery pass.** On a fresh scaffold you do not need to read
the scaffolded files to learn the layout — trust this map. Only read source when the
project has already grown (you added entities/RPCs) and you need to confirm a delta,
or when something contradicts this map (which means the project diverged or the CLI
version is older — check `appliedVersion` in `agentlink.json`).

What is **not** here is the app itself. A fresh scaffold has the multi-tenant +
auth + RBAC plumbing below and nothing domain-specific. The product's tables, RPCs,
routes, and permissions are what you build.

---

## Database (`supabase/database/`)

One object per file. `db apply` resolves dependency order at apply time, so file order is
irrelevant.

### Extensions (`cluster/extensions/`)
`pg_graphql`, `pg_net`, `pg_cron`, `pgmq` — all `WITH SCHEMA extensions`.

### `public` tables (`schemas/public/tables/`) — NOT exposed to the Data API
| Table | Purpose |
|---|---|
| `profiles` | Per-user profile, 1:1 with `auth.users` |
| `tenants` | The workspace/tenant entity |
| `memberships` | (user, tenant, role) — a user's role within a tenant; `role` FKs `roles(name)` |
| `invitations` | Pending tenant invites, role-on-acceptance + expiry |
| `roles` | RBAC roles (reconciled from `rbac/roles.sql`) |
| `permissions` | RBAC permission keys (reconciled from `rbac/permissions.sql`) |
| `role_permissions` | (role, permission) matrix (reconciled from `rbac/role_permissions.sql`) |
| `session_tenants` | Tracks which tenant a session is pinned to (for JWT tenant claim) |

### `api` schema (`schemas/api/`) — the ONLY schema exposed to the Data API
- `tables/agentlink_tasks.sql` — PGMQ-backed task queue.
- **RPCs** (`functions/`), all callable via `supabase.rpc(...)`:
  - Tenants: `tenant_create`, `tenant_list`, `tenant_select`
  - Profile: `profile_get`, `profile_update`
  - Memberships: `membership_list`, `membership_update_role`, `membership_remove`
  - Invitations: `invitation_create`, `invitation_list`, `invitation_preview`,
    `invitation_accept`, `invitation_resend`, `invitation_revoke`
  - Queue admin (`api._admin_*`, service_role): `_admin_enqueue_task`,
    `_admin_queue_read`, `_admin_queue_archive`, `_admin_queue_delete`

### `public` functions (`schemas/public/functions/`) — internal, never exposed
- **Auth / RLS helpers** (`_auth_*`): `_auth_tenant_id`, `_auth_tenant_role`,
  `_auth_has_role`, `_auth_has_permission`, `_auth_is_tenant_member`.
- **Permission guards** (call these from your RPCs): `auth_has_access(permission)`
  → boolean; `auth_verify_access(permission)` → raises 403 if missing. Every
  mutating `api.*` RPC calls `auth_verify_access('<entity>.<action>')` first.
- **Auth hooks** (`_hook_*`): `_hook_custom_access_token` (mints
  `app_metadata.tenant_id` + `app_metadata.permissions` into the JWT on every
  token), `_hook_before_user_created`, `_hook_send_email`.
- **Internal admin** (`_internal_admin_*`, SECURITY DEFINER): `handle_new_user`,
  `create_tenant`, `create_invitation`, `complete_invitation`, `resend_invitation`,
  `set_session_tenant`, `sync_session_tenants_on_membership`, `get_secret`,
  `call_edge_function`.
- `set_updated_at` — generic `updated_at` trigger function.

### Imperative resources (`cron/`, `storage/`, `rbac/`) — applied at deploy, NOT in migrations
These three top-level folders under `supabase/database/` are **excluded** from
`db apply`'s schema diff and from the migration diff, and applied imperatively on
every deploy (all envs incl. prod) by the deploy step. Reason: the `cron` and
`storage` schemas are filtered out of migration plans, and RBAC is reference
*data*. Put new objects here (not under `schemas/`):
- `cron/` — `cron.schedule(...)` jobs. Scaffolded: `process-stale-tasks.sql`
  (fires the queue worker every minute). Must be **idempotent** (`cron.schedule`
  upserts by job name).
- `storage/` — buckets + `storage.objects` policies. Scaffolded: `avatars.sql`
  (example private per-user bucket — edit or delete it). Must be **idempotent**
  (`INSERT … ON CONFLICT DO UPDATE`; `DROP POLICY IF EXISTS` + `CREATE POLICY`).
- `rbac/` — RBAC reference data (see below).

---

## RBAC seed (`supabase/database/rbac/`)

Reconciled by `db rbac-sync` (and on every `env deploy`), **not** by `db apply`.

**Roles** (rank): `owner` (4) · `admin` (3) · `member` (2) · `viewer` (1).
All except `owner` are invitable.

**Permissions** seeded by default: `tenant.update`, `tenant.delete`,
`membership.read`, `membership.update`, `membership.delete`, `invitation.create`,
`invitation.delete`.

**Default matrix:** `owner` = everything · `admin` = everything except
`tenant.delete` · `member` = `membership.read` · `viewer` = `membership.read`.

To add a capability: add the key to `permissions.sql`, bind it to roles in
`role_permissions.sql`, guard the RPC with `auth_verify_access('<key>')`, and gate
the UI with `useHasPermission('<key>')`.

> Permissions do a **full reconcile**: any key/pair not listed is REVOKED on next
> deploy. Roles are upsert-only (never auto-deleted, because memberships FK them).

---

## Frontend (`vite/src/`) — React + TanStack Start (SPA mode)

### Routes (`routes/`)
- `__root.tsx` — shell (prerendered) + app providers; inline theme bootstrap script.
- `index.tsx` — auth-aware landing / entry.
- `_anon.tsx` + children — unauthenticated: `sign-in`, `sign-up`, `forgot-password`,
  `check-inbox`.
- `_auth.tsx` + children — authenticated: `dashboard`, `forbidden`,
  `settings/members`.
- Standalone: `accept-invite`, `auth.confirm`, `update-password`.

### Auth & permissions (the parts you'll reuse most)
- `contexts/auth-context.tsx` — `AuthProvider` + `useAuth()` → `{ user, session, loading }`.
- `hooks/use-has-permission.ts` — `useHasPermission(perm, mode?)`. Reads permissions
  from the JWT (`app_metadata.permissions`). **UX only — fails safe to `false`.**
- `components/require-permission.tsx` — `<RequirePermission permission=...>` wrapper.
  Convention: **hide** nav the user can't use; **disable** (not hide) mutating buttons.
- `hooks/use-tenant-guard.ts` — gates UI until the tenant JWT claim is ready
  (fresh-signup refresh window).
- `lib/jwt.ts` — `readPermissions(session)` and tenant-claim readers.
- `lib/supabase.ts` — the browser client. **All data access is `supabase.rpc(...)`;
  `.from()` never works (only `api`, which has no tables, is exposed).**
- `lib/auth/` — flow hooks: sign-in/up, magic-link, reset/update-password,
  verify-otp, resend-email, accept-invitation, invitation-preview.

> ⚠️ Permission hooks/guards are **UX only**. The real gate is
> `auth_verify_access()` inside every mutating RPC (returns 403). Never weaken a
> backend guard because the UI hides a control; never rely on the UI for security.

### UI building blocks
- `components/ui/` — curated shadcn primitives: button, dialog, alert-dialog,
  dropdown-menu, tooltip, switch, badge, card, input, label, skeleton, table,
  select, separator, tabs, popover, sheet, command, input-group, checkbox,
  radio-group, textarea, accordion, avatar, scroll-area. **Need another?**
  `npx shadcn@latest add <name> --yes` (`components.json` is pre-wired) — never
  hand-roll a primitive or use a native element when shadcn ships one.
- App components: `topbar`, `user-menu`, `workspace-menu`, `page-shell` (page
  wrapper), `page-header` (eyebrow + title + description + actions hero),
  `auth-shell`, `empty-state`, `list-skeleton`, `error-boundary`, `not-found`,
  `create-workspace-dialog`, `invite-member-dialog`, `invite-context-banner`,
  `check-inbox-card`, `forms/form-field`, `app-toaster`.
- **Page anatomy:** every gated page is `PageShell` → `PageHeader` → content;
  lists use shadcn `Table`, pickers use shadcn `Select`. `routes/_auth/settings/members.tsx`
  is the canonical reference page (Table + Select + Badge + PageHeader).
- `config/navigation.ts`, `config/labels.ts` — nav + copy config.
- `types/database.ts` (generated by `db types`), `types/models.ts`.

---

## What you add on top

A fresh scaffold = the plumbing above, nothing domain-specific. To build a feature:
**table(s) + RLS + grants → `api.*` RPCs (guarded) → permission keys → generate
types → routes/components**. Follow the `database`, `rpc`, `auth`, and `frontend`
skills for each step.
