# Changelog

## [Unreleased]

### Changed

- **`env use <same-env>` documented as a refresh verb, not a no-op.** CLI 0.24 removed the `Already on "<name>"` short-circuit so re-running `env use` on the active env re-fetches API keys + pooler URL and rewrites `.env.local`'s managed block. `skills/cli/SKILL.md` and `skills/cli/references/workflows.md` (workflow #3) get a paragraph each explaining the refresh behavior, when to reach for it (key rotation in the Supabase dashboard, suspected `.env.local` drift), and the closing-line wording change (`Refreshed <name>` vs `Switched to <name>`). Prod confirmation skipped on the refresh path since the user is already on prod.

### Added

- **CLI skill documents `db backup`.** New "Snapshot the database" subsection under Database Operations in `skills/cli/SKILL.md` covering the three-file dump triplet (roles / schema / data), the timestamped per-env folder layout, the first-run gitignore append, and the read-only safety profile. New workflow #10 "Snapshot an env before a risky change" in `workflows.md` with trigger, env-resolution flow, what-it-does, and watch-outs (including a callout that no `db restore` command exists — restoration is a developer-initiated manual step). The agent never runs `db backup` autonomously before destructive changes; it's safe but reading prod data is still the user's call to make.

## [0.19.0] - 2026-04-24

### Added

- **CLI skill documents bare mode.** New section in `skills/cli/SKILL.md` explains the `env add` path on a non-scaffolded directory: interactive "what you're opting out of" menu, minimal `agentlink.json` with `bare: true`, what works / what's a no-op until content appears, upgrade path via `--force-update`. New dedicated workflow #7 "Bare mode — Supabase env management on an existing codebase" in `workflows.md` with trigger, questions to ask, command flow, what-works table, and watch-outs. Cross-refs from workflow #1 (start from zero) and workflow #6 (connect existing) point users at bare mode when it's the better fit. Troubleshooting gains three entries: what the bare-mode menu is, "env deploy says Nothing to deploy," and "env config says No agentlink.json."

### Changed

- **`env deploy` documented as a three-step operation.** `skills/cli/SKILL.md` updated from "thin two-step" (schemas + functions) to three-step (migrations → schemas → functions). Each step gates on the corresponding `supabase/` directory existing; all-missing short-circuits with a friendly "Nothing to deploy" message. The `env deploy` workflow in `workflows.md` got the same treatment. Reflects CLI 0.23 which brings `supabase db push` into the standalone deploy path (previously migrations only ran during the initial bootstrap).

- **New `### Server-side config (env config)` subsection in `skills/cli/SKILL.md`.** Full documentation of the command: subcommand table (secrets / db / auth / all), positional env-name form (`env config secrets prod`), rotation shortcut (`env config prod` treats the first positional as env when it's not a valid subcommand), relationship to `env add --retry` (env config is lighter) and `env deploy` (orthogonal — config vs schemas/functions/migrations). `workflows.md` Recovery E examples updated to the positional form across the board.

- **Multi-org credentials section now documents per-project credentials.** `skills/cli/SKILL.md` added a breakdown of `project_credentials[projectRef]` in `~/.config/agentlink/credentials.json`: `db_password` (entered at env add; not re-fetchable) and `secret_key` (cached service-role key; auto-refreshed at every `getApiKeys` callsite). Also documents what's in the `.env.local` managed block for cloud envs, including the newly-added `SUPABASE_SECRET_KEY` (server-only, no prefix). Troubleshooting final table gains rows for "need config only" (→ `env config`), "existing codebase wants env plumbing only" (→ bare mode), and "env deploy prints Nothing to deploy" (→ add files or `--force-update`).

- **Docs swept for the `config apply` → `env config` rename.** CLI 0.23 removes the top-level `agentlink config apply` command and replaces it with `agentlink env config [secrets|db|auth|all]` — a superset that adds vault secrets (+ edge-function `SB_*` mirror) alongside the existing auth and PostgREST sections. Touches:
  - `agents/builder.md` — truth-table rows for "Re-apply config" updated; added a dedicated row for "Re-apply vault + SB_* secrets."
  - `skills/cli/SKILL.md` — `env deploy` section's "what it doesn't do" note now points at `env config` for targeted re-applies and `env add --retry` for the full reset.
  - `skills/cli/references/workflows.md` — Recovery E (config drift) rewritten around the three new subcommands; top-of-deploy guidance updated to mention `env config` as the lighter alternative to `env add --retry` when only config drifted.

- **Builder agent's "New project setup" no longer has an MCP branch.** The section in `agents/builder.md` had a dual path — "MCP available" (use `supabase_create_project` MCP tool + CLI with `--link`) vs "MCP not available" (tell user to run bare `create-agentlink`). The MCP path was creating a Supabase cloud project; the fallback instruction told the user to run `npx create-agentlink@latest <name>` which, without `--link`, triggered the CLI's interactive wizard and created a **second** Supabase project — leaving the first one orphaned. Replaced with a single agent-driven path: `npx create-agentlink@latest <name> --skip-env`, which scaffolds all files + deps + Claude Code config without touching Supabase. Agent hands off to the user for `agentlink env add dev` (browser OAuth). Aligns with `skills/cli/references/workflows.md` Workflow #1 and with `cli` 0.21.0's `--skip-env` "primary use case: AI agent running without browser access."
- **`skills/cli/references/workflows.md` — "user has credentials from Supabase connector MCP" subsection reframed.** Renamed to "user pastes existing credentials (advanced)" with a one-liner guardrail: "User-driven only. Agents should use `--skip-env` above; never call MCP tools to fetch credentials themselves." Preserves the documentation of the escape hatch without inviting agents to take it.

## [0.18.0] - 2026-04-23

### Changed

- **Skills sweep for the CLI restructure (top-level `deploy` → `env deploy`, `env use prod` now allowed).** Touches every skill that references CLI verbs:
  - `skills/cli/SKILL.md` — rewrote the Deployment section around `env deploy`. `env deploy` does only `db apply` + `functions deploy` (not a migration-based diff/push). Added a Picker Visibility Rules subsection documenting how `env use` / `env add` / `env deploy` behave when no name is passed. `env use prod` is documented as **allowed** with warning + confirmation (previously "blocked"). Migration-system text no longer claims `deploy` generates migrations.
  - `skills/cli/references/workflows.md` — rewrote "Switch active dev environment" (adds the prod confirmation + sticky `▲ Active env: prod` banner), "Ship changes to production" (now centered on `env deploy` with explicit callouts for what it does NOT do — vault/PostgREST/auth, migration file, clean-tree gate), "Recover from a failed deploy" (decision tree disambiguates `env deploy` vs `env add --retry`). New "Deploy from CI" playbook covering `--setup-ci` and the manual form.
  - `skills/cli/references/troubleshooting.md` — recovery rows separate the "schema/function drift" path (`env deploy`) from the "config drift / mid-bootstrap failure" path (`env add --retry`). Added "`agentlink deploy` errors" row to the intervention matrix pointing at the new verb.
  - `skills/edge-functions/SKILL.md` — step 6 of the "Add a new function" flow points at `agentlink env deploy` as the primary deploy path; direct `supabase functions deploy --use-api` kept as the functions-only escape hatch.
  - `agents/builder.md` — Tools Reference table rebuilt: "Deploy to production" row now shows `env deploy <dev|prod>`, added a "Re-apply full setup" row for `env add --retry`, corrected the "Push migration" row (no more `deploy` suggestion). Deployment section rewritten — it enumerates `env deploy`, `env deploy --dry-run`, `env add --retry`, `env use` — and ends with a callout that the top-level `agentlink deploy` was removed.

- **Builder agent's "New project setup" no longer asks the user to pick a mode.** The section in `agents/builder.md` now tells the agent to always scaffold a new Supabase cloud project via the CLI and auto-route between `--link` (Supabase connector MCP available) and interactive `create-agentlink` (no MCP). Local Docker and reusing an existing cloud project are no longer presented as default options — only used if the user explicitly asks. Fixes a regression where the agent presented a "Modo Supabase" picker (Cloud+MCP / Cloud existing / Local Docker) on greenfield projects.

### Added

- **"Handling Supabase Auth Responses" section in frontend `auth_ui.md`.** Documents the reliable `data.session === null` branch for email-confirmation-pending state (not `email_confirmed_at` — that field can be written asynchronously), the `refreshSession()`-after-signup rationale for the `_internal_admin_handle_new_user` JWT race, where confirmation is configured (local `config.toml` vs. cloud `mailer_autoconfirm`), the `formatAuthError` pattern shipped in the scaffold's `lib/auth-errors.ts`, and known Supabase quirks (`User already registered` on unconfirmed emails, `refreshSession()` deadlock inside `onAuthStateChange`).
- **Pointer from auth `SKILL.md` to the new section.** The post-signup JWT race note now points at `frontend/references/auth_ui.md` → Handling Supabase Auth Responses for the client-side flow.

## [0.17.2] - 2026-04-20

### Added

- **Snake_case policy-naming rule surfaced in auth `SKILL.md`.** Mirrors the rule added to `database/references/naming_conventions.md` in 0.17.1 so agents hit the guardrail whether they consult the auth or database skill first.

## [0.17.1] - 2026-04-17

### Added

- **RLS policy naming rule** — database skill's `naming_conventions.md` now codifies that RLS policies must be snake_case bare identifiers (`{role}_{action}_{scope}`), never quoted names with spaces. Includes a ❌ / ✅ example and explains why: `agentlink db apply` runs SQL through `pg-delta` / `pg-topo`, whose libpg_query deparser canonicalizes identifiers and silently drops surrounding quotes — so `DROP POLICY IF EXISTS "Members can read own tenant" …` reaches Postgres unquoted and fails with `42601: syntax error at or near "can"`.

## [0.17.0] - 2026-04-16

### Added

- **Auth grants guidance** — auth SKILL.md now explains that `USAGE` on the `api` schema is open to `anon + authenticated + service_role` so pages can resolve the schema, while `EXECUTE` is the real security boundary (default: `authenticated + service_role`; `anon` is explicit per-function opt-in).
- **Post-signup JWT race documentation** — `_internal_admin_handle_new_user` writes `tenant_id` into `raw_app_meta_data` *after* Supabase issues the first JWT; documented two-part fix using `refreshSession()` after `signUp` plus `useTenantGuard` as a safety net.
- **Tenancy UX rule** — backend is always multi-tenant; the UX decision is counting tenants. `tenants.length === 1` → no picker, default to `tenants[0]`.
- **Per-section route gating convention** — frontend SKILL.md now makes the file-based gating convention explicit: `src/routes/*` public, `src/routes/_auth/*` gated. Drop a file in, done. Anti-patterns called out (`AuthGate` wrapper, `useState`/`useEffect` gating, globally gating a partially-gated app).
- **`useTenantGuard` as shipped infrastructure** — scaffolded auth block rewritten to list `/login` route, public `index.tsx`, and `useTenantGuard` as already provided; agent **extends** rather than **builds from scratch**.
- **Post-signup + `useTenantGuard` gate-on-ready pattern** — new subsection in frontend SKILL.md.
- **`.from()` anti-pattern** — added at the end of Calling RPCs in frontend SKILL.md.

### Fixed

- **Frontend import paths and API accuracy** — `typedRpc` is imported from `@/lib/supabase` (not `@/lib/typed-rpc`); `RpcReturnMap` lives in `@/types/models`; `Database` type is imported from `@/types/database` (following the scaffold rename `database.types.ts` → `database.ts`); `Button` uses `disabled` (not `loading`) for pending state; navigation example points Dashboard at `/dashboard` (not `/`).

## [0.16.1] - 2026-04-16

### Fixed

- **`withSupabase` config shape** — `db: { schema: "api" }` was at the top level of the config object; the correct shape nests it under `supabaseOptions`. Updated all edge-functions skill docs (SKILL.md, edge_functions.md, with_supabase.md, api_key_migration.md) to use `{ allow: "...", supabaseOptions: { db: { schema: "api" } } }`.

## [0.16.0] - 2026-04-14

### Changed

- **CLI npm package renamed from `@agentlink.sh/cli` to `create-agentlink`** — all command references across the builder agent, CLI skill, database/auth/edge-functions/frontend skills, and their references have been updated from `npx @agentlink.sh/cli@latest` to `npx create-agentlink@latest`. The bin name (`agentlink`) is unchanged, so all subcommands work exactly as before.
- **CLI skill docs updated for new command tree** — the CLI in v0.16.0 reorganized Supabase-scoped commands under a new `sb` group and merged `env relink` into `env add`. All user-facing references in the CLI skill, builder agent tool table, and troubleshooting recipes now point to the new commands: `agentlink sb login`, `agentlink sb token show|set`, `agentlink frontend <name>`, and `agentlink env add <name>` (which now prompts to relink if the environment already exists).

## [0.15.0] - 2026-04-01

### Changed

- **`@supabase/server` API naming** — updated all edge-functions skill docs, builder agent, RPC skill, and auth skill to match the official `@supabase/server` package API: `ctx.client` → `ctx.supabase`, `ctx.adminClient` → `ctx.supabaseAdmin`, `allow: "private"` → `allow: "secret"`, `Deno.serve(withSupabase(...))` → `export default { fetch: withSupabase(...) }` with `db: { schema: "api" }` config.
- **Vault secret names** — `SB_PUBLISHABLE_KEY` → `SUPABASE_PUBLISHABLE_KEY`, `SB_SECRET_KEY` → `SUPABASE_SECRET_KEY` across edge-functions secrets docs and api_key_migration reference.
- **Shared utilities** — removed `_shared/types.ts` from project structure listings; types now come from the `@supabase/server` package.

### Fixed

- **`npx supabase` prefix across all skills** — replaced bare `supabase` CLI command invocations with `npx supabase` in builder agent, skills, references, README, and hook messages. The CLI installs `supabase` as a local devDependency, so `npx` is required to resolve it.

## [0.14.0] - 2026-03-27

### Added

- **Auth lock race condition guidance** — documented the dual-path race between `onAuthStateChange` and `getSession()` that causes "Lock broken by another request" errors in post-auth action flows (e.g., invitation acceptance)
  - `frontend/SKILL.md` — new warning after the existing deadlock section with guard flag pattern
  - `frontend/references/auth_ui.md` — new "Post-auth action" section with ❌ wrong / ✅ correct examples showing guard flag, non-async callback, and deferred `refreshSession()`
- **`config apply` command** — added to builder agent tools reference table
- **Function-level `@agentlink` override system** — documented how `--force-update` merges at the individual function level; agent can remove the `@agentlink` annotation block and modify a function body while the CLI preserves that override and still updates other annotated functions in the same file
  - `builder.md` — rewritten "managed resources" section with step-by-step override instructions, concrete example, and merge mechanics
  - `database/SKILL.md` — added override guidance to annotations section
  - `auth/SKILL.md` — added note on customizing `_internal_admin_handle_new_user`

## [0.13.1] - 2026-03-26

### Fixed

- **Plugin hooks loading** — restored `"hooks"` wrapper in `hooks.json`; Claude Code's plugin schema requires event definitions nested inside a top-level `"hooks"` key

## [0.13.0] - 2026-03-26

### Changed

- **RPC-first rule is now universal** — reframed from "client-side: never direct table access" to "never use `.from()` — all data goes through `.rpc()`" across builder agent, RPC skill, edge-functions skill, and frontend skill. Applies to all code (frontend, edge functions, webhooks, cron jobs), not just client-side.
- **`.from()` anti-pattern added to edge-functions** — new first bullet in IMPORTANT rules and new anti-pattern in `with_supabase.md` showing why `.from()` fails even with service role keys
- **"client-facing" language removed** — replaced with "data access" throughout RPC skill and rpc_patterns reference to prevent the agent from reasoning that server-side code is exempt

## [0.12.0] - 2026-03-25

### Added

- **Routing reference** — new `references/routing.md` covering TanStack Router file-based routing, router setup, conventions, auth-protected layout routes, route decomposition, navigation config, and search params
- **Data fetching reference** — new `references/data_fetching.md` covering TanStack Query setup, query factory pattern, mutation hooks, query key structure, `typedRpc()` helper with `RpcReturnMap`, cache invalidation strategies, loading/error states, and provider nesting order
- **Form patterns reference** — new `references/forms.md` covering React Hook Form + Zod, schema definition, `register()` vs `Controller`, `FormField` component, form modal pattern, grid layouts, and centralized label maps
- **`typedRpc()` helper** section in frontend SKILL.md — wraps `supabase.rpc()` with `RpcReturnMap` for real return types instead of `Json`
- **Data fetching** section in frontend SKILL.md — TanStack Query overview with query options factories and mutation hooks
- **Forms** section in frontend SKILL.md — React Hook Form + Zod overview with basic pattern
- **Route architecture** section in frontend SKILL.md — TanStack Router file-based routing conventions, directory structure, and `-components/` co-location
- **Shared components** table in frontend SKILL.md — `PageShell`, `ListSkeleton`, `EmptyState`, `ErrorBoundary`, `FormField`
- **Config patterns** section in frontend SKILL.md — navigation config and centralized label maps
- **Provider nesting order** — documented `QueryClientProvider → AuthProvider → RouterProvider + Toaster` hierarchy
- **Auth strategy planning** — checklist for clarifying auth flow during planning (self-registration, auth method, password recovery, redirect)
- **Dependencies & Deployment reference** — new `references/dependencies.md` covering per-function `deno.json` import maps, bare specifiers, sub-path mapping, version pinning, `--use-api` deployment isolation, and anti-patterns
- **`@supabase/server` as npm package** — `withSupabase` now imports from `@supabase/server` via bare specifier instead of local `_shared/withSupabase.ts`
- **Per-function `deno.json` requirement** — added to IMPORTANT rules, project structure, and new function checklist in SKILL.md
- **Version pinning enforcement** — pinned versions required in all `deno.json` entries; unversioned specifiers listed as anti-pattern

### Changed

- **Frontend stack** — default scaffold changed from React Router v7 to TanStack Router (file-based routing) with TanStack Query for data fetching
- **Frontend SKILL.md** — expanded from client initialization + RPC calling to full frontend patterns covering routing, data fetching, forms, shared components, and config
- **Auth UI reference** — rewritten for TanStack Router: `_auth.tsx` layout route with `beforeLoad` guard replaces `AuthGuard` wrapper component; auth callback uses `createFileRoute`; sign-out now clears query cache
- **Protected route pattern** — updated from `AuthGuard` component + React Router `<Navigate>` to TanStack Router `beforeLoad` redirect
- **Scaffolded auth description** — clarified that scaffold provides auth infrastructure (`AuthProvider`, `_auth.tsx` guard) but not auth pages; agent builds pages based on auth strategy
- **RPC parameter naming** — fixed documentation to show parameters keep the `p_` prefix in RPC calls (was incorrectly saying "without the `p_` prefix")
- **Companion skills** — removed `next-best-practices` from the list; marked companion skills as optional
- **Edge functions SKILL.md** — updated project structure to show `deno.json` per function, expanded new function checklist with `deno.json` and `config.toml` steps, added Dependencies & Deployment reference link
- **edge_functions.md** — updated folder structure, shared utilities setup, and code examples to use `@supabase/server` import
- **with_supabase.md** — implementation section now references `@supabase/server` npm package and `deno.json` setup
- **api_key_migration.md** — updated migration table, shared utilities reference, and code examples to reflect `@supabase/server` package

## [0.11.0] - 2026-03-23

### Added

- **Desktop/Cowork support** — builder agent now detects Supabase connector MCP and uses `--link` flag for non-interactive project setup from Claude Desktop and Cowork apps
- **`--local` flag** documented in CLI skill flags table (cloud is default, `--local` opts into Docker mode)
- **`db sql` command** added to builder agent tools table for single SQL statements (works in both local and cloud mode)
- **Database operations section** in CLI skill — `db apply`, `db sql`, `db types`, `db migrate` with full flag examples (`--env`, `--db-url`, `--json`, `--output`)
- **Database recovery section** in CLI skill — `db rebuild` for broken migration state, `db url --fix` for connection issues
- **`db password` command** in CLI skill — show/set cloud DB password when reset in dashboard
- **New CLI flags** — `--prompt`, `--resume`, `--non-interactive` documented in flags table
- **`env relink` command** — reconnect environment to a new Supabase project while keeping migrations
- **Non-interactive env commands** — `env add --project-ref --non-interactive`, `env relink --non-interactive`, `env remove -y`
- **Deploy flags** — `--allow-warnings` for CI, `--setup-ci` for GitHub Actions scaffold
- **Troubleshooting entries** — DB URL issues, vault duplicate key errors, duplicate migration files, cloud project deletion recovery, psql-not-found in cloud mode, OAuth login timeout
- **Builder tools table** — added rows for `env add`, `env remove`, `env relink`, `db password`, `db url --fix`, `db rebuild`

### Changed

- **Tools table updated** — `db types` CLI command replaces raw `supabase gen types` references (works in both modes); `db sql` replaces `psql` for single statements in cloud
- **`db apply` auto-generates types** — database skill development loop updated; no separate type generation step needed
- **Type generation references** updated across frontend skill and database workflow reference to use `db types`
- **CLI skill scaffold flow** updated with interactive and `--link` variants; update flow now references pgdelta/CLI commands instead of psql/db-diff
- **Environment setup** — builder agent restructured with "New project setup" (Option A: Supabase connector MCP, Option B: terminal) and "Ongoing development" sections
- **Check command** now shows `--env` flag for checking specific environments
- **Deploy section** expanded with `--allow-warnings` and `--setup-ci` flags
- **Environment management** reorganized into interactive and non-interactive sections with `env relink` docs

## [0.10.0] - 2026-03-23

### Fixed

- **Plugin schema compatibility** — removed extra `"hooks"` wrapper in `hooks.json` so event names are at the top level as expected by Claude Code
- **Skill frontmatter** — stripped unrecognized fields (`license`, `compatibility`, `metadata`) from all skill files; only `name` and `description` remain
- **Agent frontmatter** — removed duplicate inline `hooks:` block from builder agent; `hooks/hooks.json` is the canonical source

## [0.9.0] - 2026-03-22

### Changed

- Rename package references from `@agentlinksh/cli` to `@agentlink.sh/cli`

### Added

- **Language matching** — builder agent now responds in the user's language (chat, planning, explanations) while keeping all code in English
- **Deployment commands** in builder agent — tools reference table now includes `deploy`, `env use`, and `env list`; new Deployment section explains that deployment is developer-initiated and lists available commands
- **Deployment section** in CLI skill — `deploy` command workflow (diff, validate, push), `--dry-run` / `--ci` / `--env` flags, and environment management commands (`env add`, `env use`, `env list`, `env remove`)

## [0.8.1] - 2026-03-16

### Changed

- **Development loop simplified** — agent only uses `db apply` during development. Migrations removed from the build loop and repositioned as a deployment concern, generated only when the user explicitly asks.
- Cloud DB URL format updated to use Supabase connection pooler (`pooler.supabase.com`) — IPv4-compatible, works in all environments. Direct connection (`db.<ref>.supabase.co`) requires IPv6.
- Builder agent tools reference: migration commands moved to bottom with "(deployment)" label
- Database skill: migration steps removed from development loop, added note about deployment-only migrations
- Database workflow reference: migration section removed from development docs
- CLI skill: migration system section rewritten with development vs deployment separation
- CLI migration system reference: `db apply` marked as the development command, `db migrate` marked as deployment-only, added cloud DB URL format docs, added note about empty migrations when developing directly on cloud

## [0.8.0] - 2026-03-15

Replace `supabase db diff` with `pgdelta` for migration generation. The CLI now bundles `pgdelta` and exposes two subcommands — `db apply` and `db migrate` — that resolve cross-file FK ordering issues and unify the local/cloud workflow.

### Added

- `npx @agentlink.sh/cli@latest db apply` — applies all schema files with `pgdelta declarative apply`, resolving statement ordering automatically
- `npx @agentlink.sh/cli@latest db migrate name` — generates migrations by comparing catalog snapshots (no shadow DB needed)
- `pgdelta` documentation in CLI migration system reference: how it works, why it replaces `db diff`, limitations (cron/storage schema filtering)
- Idempotent policy pattern: `DROP POLICY IF EXISTS` + `CREATE POLICY` (policies don't support `CREATE OR REPLACE`)
- Guidance to use `record` type in `DECLARE` blocks instead of `%rowtype` to avoid `pgdelta` ordering issues

### Changed

- **Development loop unified** — same `db apply` / `db migrate` commands for both local and cloud (DB URL auto-resolved from `.env.local`)
- Builder agent tools reference table updated with new CLI subcommands
- Database skill development loop simplified: removed separate cloud mode section, single workflow for both modes
- Database workflow reference rewritten around `pgdelta` — batch apply (recommended) vs single-statement `psql`
- All worked examples updated to use `db apply` instead of raw `psql`
- CLI skill Tier 2 migration section rewritten for `pgdelta`
- `supabase db diff --use-pg-delta` moved to "Legacy" section in migration system reference

## [0.7.0] - 2026-03-15

Cloud mode support — the plugin now works with both local Docker development and cloud-hosted Supabase projects. Every skill, the builder agent, and the CLI skill have been updated with mode-aware commands and workflows.

### Added

- **Cloud mode** across all skills — local vs cloud command tables, `--linked` flag for migrations, `db push` for deploying, remote connection strings
- Project mode detection: agent reads `CLAUDE.md` or `agentlink.json` to determine local vs cloud mode
- Cloud-specific environment section in builder agent with mode-separated tool reference table
- Expanded `_internal_admin_handle_new_user` trigger: now creates default tenant, owner membership, and sets JWT claims on signup
- `@agentlink` annotation guidance — agent should never add CLI metadata annotations to SQL files
- Cloud mode migration workflow (diff with `--linked`, deploy with `db push`)
- Cloud mode troubleshooting scenarios in CLI skill

### Changed

- Builder agent planning: CLI scaffolds React + Vite by default (Next.js via `--nextjs`), work with existing frontend instead of asking
- Architecture diagram updated to distinguish scaffolded resources (profiles, tenants, memberships, auth helpers) from agent-built entities
- Auth skill: profiles, tenants, memberships, invitations, and their RPCs now documented as "scaffolded by CLI" with reference-only SQL
- Multi-tenancy section rewritten around scaffolded foundation — agent builds on top, not from scratch
- RLS patterns reference updated: scaffolded resources marked, new "adding tenant-scoped tables" guidance
- Schema file tree shows scaffolded vs agent-built files
- `_auth.sql` renamed to `_auth_chart.sql` in examples (one file per entity pattern)
- Database workflow reference updated for cloud mode
- Naming conventions reference updated
- Frontend and SSR references updated for cloud mode and React + Vite default

### Removed

- `skills/auth/assets/profile_trigger.sql` — now CLI-owned
- `skills/auth/assets/tenant_tables.sql` — now CLI-owned
- Per-tool "Via" column in tools reference (replaced by local/cloud comparison)

## [0.6.1] - 2026-03-02

### Added

- "Always Schema-Qualify" section in database skill with NOT THIS / THIS examples for tables, function definitions, function calls, and grants
- Detailed CLI command sections in builder agent: `check`, `--force-update`, `info`, `--debug`
- Guidance for handling managed `@agentlink` resources (update, override, or project-scope)

### Changed

- Enforce `public.` schema prefix on all `_auth_*` and `_internal_*` function references — definitions, calls, triggers, grants, and RLS policies across all skills
- Update naming convention tables to include schema prefixes (`public._auth_*`, `public._internal_*`)
- Expand RPC checklist to cover schema-qualified function calls, not just table names

## [0.6.0] - 2026-03-01

The agent no longer sets up your project — the CLI does. This is a fundamental shift in how Agent Link works: infrastructure setup with `npx @agentlink.sh/cli@latest` and the agent spends zero tokens verifying prerequisites, copying asset files, or scaffolding directories. Every token goes toward building your app.

This aligns with the Agent Link philosophy: **tools for agents, not agents as tools.** The CLI is purpose-built tooling that gives the agent a ready environment. The agent is a builder that assumes a working environment and gets to work. Each does what it's best at.

### Added

- `npx @agentlink.sh/cli@latest check` — CLI validation command for setup issues (extensions, internal functions, vault secrets, api schema)
- CORS headers now imported from `@supabase/supabase-js/cors` (SDK v2.95.0+) — no more local `cors.ts` file

### Changed

- **Agent no longer runs Phase 0 prerequisites** — CLI handles all project setup and validation. The agent builds, it does not scaffold.
- Replace `execute_sql` MCP tool with `psql` across all skills — direct SQL execution via DB URL from `supabase status`
- Tools reference table added to builder agent for quick lookup
- Update `withSupabase` references to match latest implementation — trailing commas, `Record<string, unknown>` context types, client reuse pattern documented
- Simplify README agent configuration section

### Removed

- **Database assets** — `setup.sql`, `check_setup.sql`, `seed.sql` (now CLI-owned)
- **Edge function assets** — `withSupabase.ts`, `cors.ts`, `responses.ts`, `types.ts` (now CLI-owned)
- **`cors.ts` as a shared utility** — replaced by SDK import `@supabase/supabase-js/cors`
- Phase 0 prerequisite system from builder agent (setup.md, scaffold_schemas.sh, setup_vault_secrets.sh)
- `auth.md` reference file (to be rewritten)
- `frontend` skill from builder agent preloads
- `docs/` directory (ABOUT.md, CATALOG.md)
- Agent memory configuration (`memory: project`)
- First migration rule (CLI creates api schema)

## [0.5.0] - 2026-02-28

### Changed

- Update README Install section with real installation methods — CLI (`npx @agentlink.sh/cli@latest`), marketplace, and local directory

## [0.4.1] - 2026-02-28

### Changed

- Rename `app-developer` agent to `builder`
- Refine Path C detection — bare `supabase init` (no schema files) now routes to Path B instead of skipping to Step 2
- Path B expanded to cover both "existing project adding Supabase" and "Supabase initialized but bare" cases

## [0.4.0] - 2026-02-28

### Added

- Schema-qualify rule — all SQL must use fully-qualified names (`public.charts`, not `charts`)
- Database workflow rules in agent core — schema files as source of truth, first migration must create `api` schema, migration naming via `db diff`
- Plan-first instruction — agent plans before building greenfield projects and major features
- Marketplace manifest (`marketplace.json`)

### Changed

- Agent activates by default via `settings.json` — no need to `@mention` it
- Granular Phase 0 prerequisite tracking — each item saved to memory individually (`cli_installed`, `stack_running`, `mcp_connected`, `setup_check`)
- Grant `service_role` USAGE on `api` schema and set `db: { schema: "api" }` on all Supabase clients in `withSupabase.ts`
- Standardize skill references to "Load the `X` skill for..." pattern

### Removed

- ENTITIES.md — entity registry file and all references (scaffold script, workflow examples)
- Companion skills section from agent — was not picked up reliably, wasted context
- `companions_offered` prerequisite step

## [0.3.0] - 2026-02-27

### Added

- Recommended Companions section in CATALOG.md — curated community skills that enhance Agent Link workflows (supabase-postgres-best-practices, frontend-design, vercel-react-best-practices, next-best-practices, resend-skills, email-best-practices, react-email)
- CHANGELOG.md

## [0.2.0] - 2026-02-27

### Changed

- Rename `development.md` to `workflow.md` — clearer name for the write-apply-migrate workflow
- Rename `app-development` agent to `app-developer` — agent names should be roles, not activities
- Bump plugin version to 0.2.0
- Remove redundant `hooks` field from plugin manifest (auto-loaded by convention)

### Fixed

- Fix RPC "not found" errors: add schema grants and client schema option
- Make MCP setup editor-agnostic (Claude Code, Cursor, Windsurf)
- Fix extension schema references
- Inline SQL apply in examples, block db reset via hook

### Added

- Natural language usage examples in README
- Block `supabase db reset` via PreToolUse hook (was only in skill text before)

### Removed

- Remove `bypassPermissions` from agent config

## [0.1.0] - 2026-02-26

Initial release as a Claude Code plugin.

### Added

- **Plugin structure** — `.claude-plugin/plugin.json` manifest, hooks, skills, agents
- **App developer agent** — Phase 0 prerequisites, architecture enforcement, preloads all domain skills
- **Database skill** — Schema file organization, write-apply-migrate workflow, migration generation, type generation, naming conventions
- **RPC skill** — RPC-first data access, CRUD templates, pagination, search, input validation, error handling
- **Edge functions skill** — `withSupabase` wrapper, CORS utilities, secrets management, `config.toml` setup
- **Auth skill** — RLS policies, `_auth_*` functions, multi-tenancy, RBAC, invitation flows
- **Frontend skill** — Supabase client initialization, `supabase.rpc()` usage, auth state, SSR
- **Schema isolation** — `public` schema not exposed via Data API; all client access through `api` schema RPCs
- **PreToolUse hook** — Blocks `supabase db reset` and `supabase db push --force`
- **Progressive disclosure** — SKILL.md core workflows, references on demand, assets copied into projects
- **Documentation** — ABOUT.md (philosophy), CATALOG.md (full skill catalog and roadmap), README
