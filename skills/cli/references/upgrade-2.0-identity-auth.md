# Upgrading a project to 2.0 — identity-only auth + native MCP

2.0 is a **breaking** change to the auth model. This is the migration runbook for taking an existing 1.x project onto it. It is more than a `--force-update`: the normal update reconciles `supabase/` but does **not** delete removed files, reconcile the frontend, run the auth migration, or bump the contract. Those are the steps below.

> Validated end-to-end on a real 1.2.0 project (a task manager with its own `projects`/`tasks` domain). The domain rode through untouched.

---

## What changes

**1.x (JWT-baked tenant):** the active workspace + a permissions array were baked into the JWT (`app_metadata.tenant_id`), pinned per device by a `session_tenants` table and a `_hook_custom_access_token` auth hook. Switching workspace meant `tenant_select` → `refreshSession` (a token re-mint). An MCP session was stuck on one workspace.

**2.0 (identity-only):** the JWT proves *identity only*. The active workspace is asserted **per request** via an `x-workspace-id` header, validated server-side by the PostgREST db-pre-request hook `public._auth_pre_request`, which pins a transaction-local GUC. Permissions are derived fresh from `(user, workspace)`. A native per-user MCP server (the `mcp` edge function) is a first-class client.

| Removed | Added |
|---|---|
| `public.session_tenants` (table + policy) | `public._auth_pre_request()` (the resolver) |
| `public._hook_custom_access_token` | `api.session_context()` (role + permissions for the active workspace) |
| `public._internal_admin_set_session_tenant` | `api.tenant_update` / `api.tenant_delete` |
| `public._internal_admin_sync_session_tenants_on_membership` (+ its trigger) | `supabase/database/config/db_pre_request.sql` (the `ALTER ROLE … SET pgrst.db_pre_request`) |
| `api.tenant_select` | `supabase/functions/mcp` + `functions/_shared/mcp.ts` |

## The one thing that makes this tractable: the auth interface is stable

`public._auth_tenant_id()` and `public._auth_has_permission(text)` keep their **signatures** — only their internals change (they read the tx-local GUC instead of JWT claims). So every domain RLS policy (`tenant_id = _auth_tenant_id()`) and every domain RPC keeps working with **no change**. The same holds on the frontend: `useHasPermission()`, `useWorkspace()`, etc. keep their signatures, so domain routes survive. **The migration touches the auth layer, not the app.** (On the validated project the generated migration had *zero* references to the domain tables/RPCs.)

## Why `--force-update` isn't the whole story

`--force-update` reconciles the `supabase/` tree (schema, functions, `config.toml`) via the maintained 3-way merge — use it for that part. But:

- Its **contract-drift guard hard-stops** once the running CLI is ≥ 2.0.0 (that is the entire point of the `2.0.0` boundary). A dedicated `upgrade` command crosses it deliberately via `allowContractUpgrade`. If you run the reconcile with a **pre-2.0 CLI**, the guard is dormant and it still applies 2.0-content templates.
- It does **not delete orphaned files** — schema files removed upstream (the five old-auth files) and renamed function dirs (`internal-invite-member` → `internal-send-email`) stay on disk and would re-create objects. Delete them by hand.
- `upgrade-cleanup.ts` has **no 2.0 DROP entries** — you don't need them: the generated migration carries the DROPs.
- It is **`supabase/`-only** — the frontend is a separate, **semantic merge** (see below).

## The runbook

1. **Branch + clean tree.** `git checkout -b upgrade-2.0`.
2. **Backend reconcile.** `--force-update` (pre-2.0 CLI, guard dormant), or copy the 2.0 template's `supabase/database/**`, `supabase/functions/**`, and `config/` framework files over the project — **preserving** customized `rbac/*` and all domain files (different paths, so they aren't touched). **Do not overwrite** `supabase/migrations/…_initial_agentlink_scaffold.sql` — the *old* baseline must stay so the migration diff can see old→new.
3. **Delete orphans:** the 5 removed auth schema files, `src/lib/jwt.ts`, `src/lib/last-tenant.ts`, and the renamed `functions/internal-invite-member/`.
4. **`config.toml`:** remove `[auth.hook.custom_access_token]`; add `[auth.oauth_server]`, `[functions.mcp]`, `[functions.internal-send-email]`; set `site_url = "env(APP_URL)"`. (`updateConfigToml` does these idempotently.)
5. **Frontend:** add the new framework files (`contexts/workspace-context`, `lib/{active-workspace,session-context,account}`, `routes/_auth/account/{profile,connections}`, `routes/{no-workspace,oauth.consent}`, `routes/_auth/settings/workspace`, `components/{app-mark,connect-mcp-dialog}`); overwrite the changed framework files (`lib/supabase` — it injects `x-workspace-id`; `topbar`, `user-menu`, `workspace-menu`, guards, `lib/auth/*`, `__root`, `_auth`). **Semantic-merge** the domain-customized ones — usually `types/database.ts` + `types/models.ts` (drop `tenant_select`, add `session_context`/`tenant_update`/`tenant_delete`; keep your domain types), and check `config/navigation.ts` (must export `isNavItemActive`) + `dashboard.tsx`.
6. **Generate the migration:** `pnpm exec agentlink db migrate new_auth_model`. The offline converger replays the 1.x baseline, diffs it against the 2.0 schema files, and writes the transformation (`DROP` old, `CREATE` new). The `ALTER ROLE` (config/) and RBAC data are **not** in the migration — they stay imperative.
7. **Bump the contract:** `agentlink.json` → `version`/`appliedVersion` `2.0.0`.
8. **Env + client config:** `.env.local` gets `MCP_OAUTH_ISSUER`, `MCP_PUBLIC_URL` (and `APP_URL` if absent); `.mcp.json` gets the app's MCP server keyed by the project slug (`{ "type": "http", "url": ".../functions/v1/mcp" }`); `.claude/settings.local.json` pre-allows `mcp__<slug>__*` for the 10 admin tools.
9. **Deploy:** `db push` (applies the migration) + apply imperative resources (`config/db_pre_request`, storage) + auth/OAuth/MCP config. **Cloud:** the OAuth 2.1 server can't be enabled via the Management API — turn it on in **Dashboard → Authentication → OAuth Server**.

## Verify

- `db migrate` again → **"No changes detected"** (schema files consistent with the migration state).
- `pnpm build` (frontend) passes.
- Security non-negotiables: a request with an `x-workspace-id` the caller isn't a member of → **403**; no header → **deny** (NULL tenant, `_auth_has_permission` false); `api.session_context()` returns `role` + `permissions[]` for a member.
- MCP: `/.well-known/oauth-protected-resource` → `200`; unauthenticated `POST` → `401` with `WWW-Authenticate`.

## Gotchas

- **Ports:** if another local stack is running, isolate this project's `config.toml` ports before `supabase start` / `db push`, or you'll apply against the wrong database.
- **The frontend merge is the manual part.** Backend + migration are mechanical (interface is stable); the frontend `types`/`navigation`/`dashboard` need a real merge because they mix framework and domain.
- **`site_url = env(APP_URL)`** resolves from `.env.local` at `supabase start`. `env()` does *not* interpolate inside `additional_redirect_urls` — keep those in sync with the port by hand.
