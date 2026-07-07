# Changelog

## [Unreleased]

### Changed

- **`frontend` skill: the invite-accept flow diagram (`references/auth_ui.md`) reflects the CLI 2.3.1 scaffold.** A new user accepting an invitation with email confirmation on now routes through the shared `/check-inbox?type=signup` step (paste the 8-digit OTP or click the link) and lands back on `/accept-invite` to auto-join — instead of the old bare "click the link" card. The diagram also drops a stale `/sign-in` bounce (the page is self-contained with an inline create-account / sign-in form) and notes the `["tenants"]` cache refresh before landing on `/dashboard`. Keeps the plugin in lockstep with the CLI's `2.3.1` scaffold (invite-accept OTP step, invite-accept sign-out-race fix, and the route-guard query-cache fix).

## [2.3.0] - 2026-07-07

### Changed

- **`database` + `cli` skills: pgmq queues are documented as an IMPERATIVE resource, not a schema file or migration.** `cli/references/migration_system.md`, `cli/SKILL.md`, `cli/references/scaffold-map.md`, `cli/references/troubleshooting.md`, `database/SKILL.md` (the `supabase/database/` tree), and `database/references/naming_conventions.md` now place the pgmq queue in `supabase/database/queue/` alongside `config/`, `cron/`, `storage/`, `rbac/`. The rule agents must learn: a queue (or any `DO`/`pgmq`/`cron` block) in `schemas/` never reaches prod — prod is migrations-only and skips declarative `db apply`, so Supabase-managed objects must live in an imperative folder. Documented `db resources --env <name>` / `--prod` as the way to push just those to a cloud env.
- **`database` skill: a permission-gated write must not be directly writable by `authenticated`.** `SKILL.md` and root `CONVENTIONS.md` gained the rule that a write guarded by `auth_verify_access(...)` must go through a `SECURITY DEFINER` helper and grant the write to `service_role` only — RLS is isolation-only and can't see the permission check, so a direct `authenticated` write grant + isolation-only RLS is a weaker gate than the RPC. Includes the "tell" (if the RPC calls `auth_verify_access`, route the write through a DEFINER helper).

## [2.2.0] - 2026-07-06

### Changed

- **`frontend` skill: forms migrate from React Hook Form to TanStack Form.** The scaffold's form stack is now `@tanstack/react-form` — the same family as the scaffold's TanStack Router + TanStack Query, and the stack shadcn's own docs currently favor — instead of `react-hook-form` + `@hookform/resolvers`. `SKILL.md`'s basic pattern and `references/forms.md`'s modal/edit-form patterns now use `useForm` with `validators: { onSubmit: schema }` and `form.Field`'s render prop, wrapped in shadcn's `Field`/`FieldLabel`/`FieldError` primitives, instead of `register`/`Controller`/`zodResolver`.
- **`frontend` skill: three more curated shadcn primitives — `alert`, `empty`, `field`.** `references/scaffold-map.md`'s `components/ui/` inventory and `references/auth_ui.md`/`references/data_fetching.md` now reference these where they replace hand-rolled markup (e.g. empty states, inline field errors), keeping with the "never hand-roll a primitive shadcn ships" rule. `skills/cli/references/scaffold-map.md` component list updated to match.
- **`frontend` skill: the scaffold's toaster is now the real vendored shadcn `Toaster` (`ui/sonner.tsx`), not a hand-rolled `AppToaster`.** `routing.md` and `data_fetching.md`'s `__root.tsx` examples now import `Toaster` from `@/components/ui/sonner`; `scaffold-map.md`'s component inventory drops `app-toaster`/`forms/form-field` (both deleted from the scaffold) and adds `sonner` to the curated `components/ui/` list.

### Fixed

- **`frontend` skill: `SKILL.md`'s own frontmatter still said "React Hook Form + Zod forms"** — missed in the earlier TanStack Form migration pass, which updated the body sections but not the YAML description used to decide when the skill activates.

## [2.1.0] - 2026-07-03

### Added

- **`notifications` skill: a new `references/resend-box.md` documents the local email sandbox's actual HTTP API** (list/filter/fetch/clear captured emails, response shape, a verification recipe) so the plugin is self-contained. `transactional-email.md`'s local-testing step previously said "see the `resend-box` companion skill" — that skill is not part of this plugin, not declared as a dependency, and not guaranteed to be installed, so on any machine without it the agent knew resend-box captures emails but had no way to actually query it. `notifications/SKILL.md` and `cli/references/resend.md` now cross-link the new reference too.
- **`auth` skill: document the scaffold's new `no_access` suspension role and `api.user_ban`/`api.user_unban` platform-wide ban.** The membership RPC contract table grows from eight to eleven RPCs (`membership_suspend`, `user_ban`, `user_unban`), the role table gains `no_access` (rank 0, non-invitable, zero permissions), and the "role changes take effect on the next request" section is rewritten — it previously said the scaffold doesn't ship a live-session hard-cut and you'd have to build one; it now does (`user_ban` bans the account, kills `auth.sessions`/`auth.refresh_tokens`, and `_auth_pre_request` rejects a banned caller immediately even on a still-valid access token).

### Fixed

- **`cli` skill: document that `db migrate` now also gates destructive migrations behind `--allow-destructive`.** The CLI closed a gap where `db migrate` could silently write a migration containing an ungated `DROP TABLE`/`COLUMN`/`SCHEMA`/`TRUNCATE` (e.g. a table rename) with no confirmation — unlike `db apply`/`db rebuild`, which already required the flag before pushing the same statement to a live DB. `SKILL.md`'s Tier 2 migrations section and `references/migration_system.md`'s `db migrate` deep dive now say so, so the agent reviews the printed diff with the user before adding `--allow-destructive` instead of being surprised by the new refusal.

## [2.0.0] - 2026-07-02

> **Agent 2.0** — the plugin is rewritten to the **identity-only auth model** + **native MCP**. The JWT proves identity only (no tenant, no permissions in the token); the active workspace is asserted per request via an `x-workspace-id` header, resolved by a `public._auth_pre_request()` db-pre-request hook into a transaction-local GUC, with role/permissions read from `api.session_context()`. The 1.x machinery is gone (`session_tenants`, `_hook_custom_access_token`, `_internal_admin_set_session_tenant`/`sync_session_tenants`, `api.tenant_select`, all `app_metadata.tenant_id/permissions` JWT claims). Skills **auth / frontend / rpc / database** were updated to the new model; **edge-functions** gained an MCP reference; **cli** gained the 1.x → 2.0 upgrade runbook. New scaffold objects: `public._auth_pre_request`, `api.session_context`, `api.tenant_update`, `api.tenant_delete`, the imperative `config/` folder (`config/db_pre_request.sql`), and the `mcp` edge function + `_shared/mcp.ts`. Version bumped to **2.0.0** (plugin + CLI in lockstep).

### Added

- **Reference: upgrading a project to 2.0 (identity-only auth + native MCP).** `skills/cli/references/upgrade-2.0-identity-auth.md` is the breaking 1.x → 2.0 migration runbook — what `--force-update` does and doesn't cover at the 2.0 boundary, the removed/added auth objects, deleting orphaned files, generating the `new_auth_model` transformation via `db migrate`, the frontend semantic merge, and the contract bump. Validated end-to-end on a real 1.2 project. Linked from `references/upgrading.md` and the cli SKILL reference index.

## [1.4.1] - 2026-06-25

### Changed

- **The release script bumps both plugin manifests, the `builder.md` stamp, and the changelog in lockstep with the CLI.** `scripts/release.sh` gained a `--lockstep` mode (skips the confirm prompt, tolerates an empty `[Unreleased]` for a CLI-only release) and now also stamps `agents/builder.md`. The normal entry point is the CLI repo's `scripts/release.sh`, which invokes this with `--lockstep` so both repos release at the same version.

## [1.4.0] - 2026-06-25

### Added

- **Migrations are forward-only — a new immutability rule.** A migration becomes immutable the moment it is *either* committed to git *or* deployed to any environment: editing a committed migration is **forbidden** (fix forward with a new `db migrate`), and an uncommitted migration may be edited/regenerated **only after confirming with the user that it has not reached production** (a prod deploy from a dirty tree can push one). Added at the decision layer in `agents/builder.md` and as an authoritative section in `skills/cli/references/migration_system.md`; the "Fix a broken migration" / "Remove a migration" troubleshooting steps and the `cli` skill's manual-fix list were reconciled to gate on uncommitted-and-not-deployed instead of telling the agent to edit migration files.
- **`AGENTLINK_VERSION` stamp in `agents/builder.md`.** Records the current version (plugin + CLI ship in lockstep, same number) and how the agent should reason about contract drift from a project's `agentlink.json` (`version` / `appliedVersion`). Kept in sync by the release script.

### Changed

- **Prefer the project-local CLI (`pnpm exec agentlink`) over `npx …@latest` for in-project work** (pairs with the CLI's 1.4 devDependency pinning). `agents/builder.md` and the `cli` skill gained a "Running the CLI" section explaining the convention and the name split — the **package** is `agentlink-sh`, the installed **binary** is `agentlink`, and bare `npx agentlink` is unsafe (it resolves a *different* npm package when no local install exists). Swept ~230 in-project command references across the skills, `README.md`, `rules/agentlink.mdc`, and the destructive-DB hooks from `npx agentlink-sh@latest <cmd>` to `pnpm exec agentlink <cmd>`; `create` and recovery commands keep `@latest` (no local CLI exists yet). The hooks now point users at `pnpm exec agentlink db rebuild` — the block matcher is invocation-prefix-agnostic, so destructive-reset blocking still fires.

## [1.3.1] - 2026-06-24

### Added

- **`database` skill: "deprecate, don't delete" rule for deployed cron/storage resources.** The imperative deploy step only applies files that are present and never reconciles deletions (unlike `rbac/`), so removing a `cron/` or `storage/` file leaves the resource live in an already-deployed DB. New rule in `skills/database/SKILL.md`: rename to `deprecated-<name>.sql`, comment out the original definition, then for cron append an idempotent `cron.unschedule(jobid) FROM cron.job WHERE jobname='<name>'` (the bare `unschedule` throws when absent and rolls back the cron folder); for storage emit no SQL and delete the bucket from the dashboard (objects cascade), since `DELETE FROM storage.buckets` orphans objects that keep counting against Storage usage.

## [1.3.0] - 2026-06-22

### Added

- **New `notifications` skill — the entry point for transactional / non-auth email.** Teaches the builder how AgentLink sends app-driven email (welcome, "export ready", receipts, alerts) through the queue: `api._admin_send_email` → PGMQ → `internal-queue-worker` → `internal-send-email` → Resend, with `public.internal_logs_email` for idempotency/observability. `SKILL.md` covers the server-only send rule, the send API, the welcome sample + its confirmation-timing nuance, and cross-links auth (auth emails), cli (per-env Resend setup), edge-functions, and database. `references/transactional-email.md` is the deep dive: add-an-email recipe, the `internal_logs_*` convention, retry/dead-letter via `read_ct`, local resend-box testing, and troubleshooting. Registered in `agents/builder.md` (now 7 preloaded skills); `auth` and `edge-functions` SKILLs cross-link it so non-auth email is routed to the right place.
- **`builder` agent: the transactional-vs-auth email split is now spelled out at the decision layer.** Two new rows in the architecture matrix (`agents/builder.md`) route app-driven email to `api._admin_send_email(...)` → `internal-send-email` (`notifications` skill) and Supabase **Auth** email to the `_hook_send_email` → `internal-send-auth-email` hook (`auth` skill, flagged a **separate function**). A new "Email: two paths, never crossed" subsection adds the originator litmus test (*does your code decide to send it?* → notifications; *does an auth event trigger it?* → auth hook), warns against routing auth email through `api._admin_send_email` or adding auth templates to the `internal-send-email` registry, and notes the scaffolded `welcome` email is deliberately a notification, not an auth hook, so it never collides with the signup confirmation.
- **`notifications` skill: migration guide for projects scaffolded before the unified email path.** New section in `skills/notifications/SKILL.md` for older projects that shipped a dedicated `internal-invite-member` edge function: recommend consolidating onto the `invite` registry entry in `internal-send-email` (confirm with the user first — it removes a function and leaves an orphaned cloud deployment to delete), with exact steps (add the `invite` template, repoint `_internal_admin_create_invitation`/`_resend_invitation` to `api._admin_send_email('invite', …)` with **no** `dedupe_key`, delete the function + its `config.toml` block, `db apply`/`db migrate`/deploy, then `supabase functions delete` on cloud). Generalizes to any bespoke per-email function; notes auth emails stay on the auth hook.

### Changed

- **Prescriptive docs migrated off the per-function invite pattern to the unified `api._admin_send_email('invite')` → `internal-send-email` path.** `agents/references/recipes.md` (Recipe 2), `skills/auth/SKILL.md` (invitation RPC row + troubleshooting), `skills/auth/references/rls_patterns.md`, `skills/edge-functions/SKILL.md` (naming table + resend link), and `skills/cli/references/resend.md` no longer teach the standalone `internal-invite-member` function as the canonical invite-email path.

## [1.2.4] - 2026-06-21

### Added

- **New `skills/cli/references/resend.md` — the single source for Resend configuration.** Covers both consumers of Resend (Auth SMTP for the built-in mailer + `_hook_send_email`, and the transactional edge functions like `internal-invite-member`), now that Resend is configured **per cloud environment**: the FROM address is the source of truth in `agentlink.json` (`cloud.environments.<env>.resend.fromEmail`, hand-editable) while the API key lives only in that env's Supabase secret store and is **sticky** (untouched unless `--api-key` is passed). Documents the `--api-key`/`--email`/`--name` flags (positionals are deprecated), the first-time all-or-nothing rule, the cross-domain `--yes` confirmation, local resend-box vs cloud SMTP, recipes (change display name, rotate key, promote dev→prod), and the "email not sending" debug flow.

### Changed

- **Skills updated for per-env Resend.** `skills/auth/SKILL.md`'s "Email Hooks with Resend" troubleshooting no longer keys off `check`'s `resend_configured` (that field was removed from the CLI — Resend is per-env now); it tells the agent to read `cloud.environments.<env>.resend` in `agentlink.json` and validate the env's secret store, and links to the new `cli/references/resend.md`. `skills/cli/SKILL.md` updates the Resend prerequisite row and reference list to point at it; `skills/edge-functions/SKILL.md` cross-links it from the reference list for email-sending functions. The embedded `RESEND_API_KEY` / `RESEND_FROM_EMAIL` component descriptions (`cli/src/components.json`, regenerated) were rewritten to the per-env / source-of-truth model.

## [1.2.3] - 2026-06-19

### Changed

- **`withSupabase`: migrate the edge-functions docs to the new `@supabase/server` auth API.** The wrapper's `allow` option is deprecated in favor of `auth` (`allow` still works but warns and will be removed in a future major), and the auth values were renamed — `'public'` → `'publishable'` and `'always'` → `'none'` (including colon variants like `'public:<name>'`), with the `ctx.authType` field now `ctx.authMode`. Updated all references across `skills/edge-functions/` (SKILL.md, references/with_supabase.md, edge_functions.md, api_key_migration.md) and `rules/agentlink.mdc` to use `auth:` and the new value names, taking care not to touch the unrelated `public` schema. The scaffold's bundled functions only ever used `auth: "secret"` / `auth: "user"`, so generated code needed no value renames.

## [1.2.2] - 2026-06-19

### Changed

- **Document prerequisites and stop the agent from hand-creating a scaffold.** Two failure modes where the agent built project files by hand instead of running the CLI. (1) **No Node/npx on the machine** — the `npx agentlink-sh@latest` call timed out and the agent treated the failure as a cue to create files manually. Added a Prerequisites section to `README.md` and `skills/cli/SKILL.md` (Node 18+ *always*; Supabase CLI; Docker + `psql` for local; a Supabase account for cloud; Resend for transactional email), with an explicit ⚠️ that a missing `node`/`npx` makes the command time out and is a stop-and-install signal, never a reason to scaffold by hand. (2) **The Scaffold Map read as a build checklist** on an unscaffolded project — added a 🛑 banner to `references/scaffold-map.md` stating it's an inventory of what the CLI *already* created (no `agentlink.json` = unscaffolded = run the CLI, never hand-create the listed tables/RPCs/routes), and stated the precondition in `cli/SKILL.md`'s reference list. Also hardened `rules/agentlink.mdc`: an unscaffolded-detection rule at the entry point (no `agentlink.json` → CLI first, never hand-create) and a directory/init-ordering rule (settle location + dev env, then let the CLI create and init the directory — don't `mkdir`/`git init`/lay out structure by hand; check `node --version` first).

## [1.2.1] - 2026-06-19

### Changed

- **Cursor: the always-on rule now engages AgentLink on the default agent, not just the selected `builder`.** In Cursor the `builder` agent is user-selectable rather than a forced default (unlike Claude Code's `settings.json` wiring), so a user who opens a normal chat and asks to "build an app" gets Cursor's generic agent — which asked raw frontend/backend questions instead of using AgentLink. Since `rules/agentlink.mdc` (`alwaysApply: true`) is the only surface guaranteed to load regardless of agent selection, it's been promoted from pure architecture guardrails to also be the **entry point/router**: a new "Engaging AgentLink" section tells any agent to treat build/scaffold/Supabase-backend requests as AgentLink tasks (load the matching skill, scaffold only via the CLI, don't improvise a stack), and a "Building a new app" section ports the essential `builder` behaviors the generic agent was missing (plan-first; the blank-project kickoff — multi-tenancy / entry point + look-and-feel / product + entities → brief in `AGENTS.md`; ask-about-product-not-architecture; DB/deploy work via the CLI, never the Supabase connector MCP).
- **Scaffold guidance: the local-vs-cloud dev-env question is now on the surfaces that actually load at scaffold time.** The "ask the user local Docker vs Supabase Cloud first" instruction previously lived only in `agents/builder.md` and `references/workflows.md` — neither reliably reaches the model in Cursor (no forced agent) or when only `cli/SKILL.md` is loaded. `cli/SKILL.md` framed `--skip-env` as the unconditional "canonical path when an AGENT is doing the scaffolding", so the agent ran `--skip-env -y` and handed off `env add dev` without ever asking. Added a 🛑 scaffold-decision callout to the top of `cli/SKILL.md`'s "Scaffold a new project" section and reframed `--skip-env` as the cloud path *after the user chose cloud* (not a blanket default); added a matching "Scaffolding a new project" section to `rules/agentlink.mdc`.

## [1.2.0] - 2026-06-19

### Added

- **Cursor-compatible plugin (same repo, dual-format).** The plugin now installs in [Cursor](https://cursor.com/docs/reference/plugins) as well as Claude Code, sharing the skills, `builder` agent, references, and assets verbatim. Added the Cursor-native files alongside the Claude Code ones: `.cursor-plugin/plugin.json` (manifest with explicit `agents`/`skills`/`rules`/`hooks` paths so Cursor doesn't auto-discover the Claude-format `hooks/hooks.json`), `.cursor-plugin/marketplace.json`, and `rules/agentlink.mdc` — an always-on rule carrying the core guardrails (schema isolation, RPC-first, function-naming security model, RLS-on-every-table, write-apply-migrate / never-reset, `withSupabase` `allow` values). The destructive-DB guard is ported to Cursor's contract in `hooks/cursor.hooks.json` + `hooks/block-destructive-db.cursor.sh`: same `db reset` / `db rebuild` / `db push --force` matching as the Claude hook, but reading the `beforeShellExecution` top-level `command` and blocking via a `{"permission":"deny"}` JSON verdict (exit 0) instead of stderr + exit 2. Nothing existing changed behavior — `claude --plugin-dir ./agent` is unaffected. In Cursor the `builder` is a user-selectable agent rather than a forced default. `scripts/release.sh` now bumps both `plugin.json` manifests together so they never drift.

### Changed

- **`database` + `auth` skills: explicit workflow for cron / storage / RBAC changes, and the GRANT-vs-RBAC-permission distinction.** A change to `cron/`, `storage/`, or `rbac/` is excluded from `db apply`'s schema diff, so the skills now spell out the loop — *edit the imperative file → apply it* with `db apply` (applies them alongside schema) or the new `db resources` (those folders only) — plus a concrete "what you're changing → which file → then" table, and a 🛑 that dropping a `cron.schedule()`/bucket/policy/RBAC row into a `schemas/` file silently never runs. Also disambiguates the two things called "permission": a SQL **GRANT** on a table/function is DDL (lives in the object's schema file, applies with `db apply`), whereas the **RBAC permission model** (`auth_verify_access` keys + role bindings) is reference data in `rbac/` (applies with `db resources`). The `auth` skill's "add a gated capability" steps now name both apply commands.
- **Skills corrected for the new default `db apply` / `db migrate` / `db rebuild` behavior, then scrubbed of all under-the-hood detail.** Two passes. First, docs describing the old create-only / Docker behavior were fixed: `db apply` now applies changes to existing objects (an `ALTER`) directly with no Docker, `db migrate` needs no Docker, `db rebuild` is genuine recovery (not needed to pick up a schema edit, and it never regenerates migration files), `npx supabase db diff` isn't used, and standalone seed DML in schema files is rejected. Second — and the bigger cleanup — **every implementation detail the app-building agent doesn't act on was removed from the agent-facing docs and re-expressed as observable behavior.** Out: engine/library names (`pg-delta`, `pg-topo`, `pglite`, "the converger", "shadow database", "declarative apply", "catalog-export", "materialize"); internal CLI function/constant names (`runSQL`, `bootstrapCloudEnv`, `getApiKeys`, `ensureAccessToken`, `pickOrg`, `setDefaultEnvironment`, `MANAGED_KEYS`, `writeMigrationTemplates`, `repairMigrations`); and CLI-maintainer content misplaced in app skills (the `migration_system.md` "Adding an Extension/Migration → edit `cli/src/…` → rebuild the CLI" sections — an app agent never edits CLI source). `migration_system.md` was rewritten from a maintainer deep-dive into a lean agent reference. In: the same rules and behaviors — "`db apply` resolves dependency order automatically", "strips surrounding quotes from identifiers" (the snake_case rule + `42601`), "a blanket grant gets applied after the per-function REVOKEs" (the dev/prod-divergence *why*), no-Docker, ALTER-aware, prod-is-migrations-only. Net: the skills describe *what the commands do and what rules to follow*, never the library that produces it — which also makes them staleness-proof against a future engine swap. Swept across `cli/{SKILL.md, references/*}`, `database/{SKILL.md, references/*}`, `rpc/references/rpc_patterns.md`, `auth/{SKILL.md, references/rls_patterns.md}`, `agents/builder.md`, and `rules/agentlink.mdc`.
- **Docs are now editor-neutral — Cursor is a co-equal agent editor, not a footnote.** The CLI gained an editor choice (Claude Code / Cursor / both) and never requires an agent editor on PATH to scaffold, so the skills + agent now say so. `skills/cli/SKILL.md`: the Prerequisites section no longer claims the CLI "validates Claude Code is present" (it never did — that abort was removed long ago); it now states the CLI needs the Supabase CLI (+ `psql` for local) and writes editor config regardless of which agent is installed. The scaffold descriptions say "configures your chosen agent editor (Claude Code and/or Cursor)". `references/troubleshooting.md`: replaced the stale "Claude Code not found on PATH → scaffold aborts" entry with a "plugin/skills don't show up after scaffold" entry covering both editors (Claude Code auto-installs from `.claude/settings.local.json` on first launch; Cursor needs a one-time `/add-plugin tomaspozo/agentlink`), and fixed the quick-reference table row. `references/workflows.md`: "prompt passed to Claude Code" → "to your agent". `agents/builder.md`: the cloud hand-off line and scaffold-completion line are editor-neutral. `README.md`: the wizard intro, the existing-project install section (now shows the Cursor `/add-plugin` path next to the Claude Code marketplace commands), and local-dev note mention both editors.
- **`builder` agent + `cli` skill: corrected the new-project scaffold guidance (wrong flag, folder nesting, no env choice).** The "New project setup" section in `agents/builder.md` and Workflow #1 in `skills/cli/references/workflows.md` now: (1) tell the agent to **ask the user local-Docker vs Supabase-Cloud** for the dev environment first, and pick the command accordingly (`--local` the agent can run end-to-end; cloud needs browser OAuth → `--skip-env` then hand off `env add dev`); (2) document the `.` vs `<name>` target rule — a `<name>` arg always resolves to a *subfolder* (`cwd/<name>`), so when already inside the target dir use `.`, and **never** `cd foo && npx … foo` (it nests into `foo/foo/`); (3) fix the malformed `npx . --skip-env` to `npx agentlink-sh@latest . --skip-env`; and (4) list the real scaffold flags and call out that **`--no-launch` does not exist** (removed) — an unknown flag errors before anything scaffolds. Also **removed the stale `--no-launch` row from the `cli` skill's flag table** (`skills/cli/SKILL.md`), which was the source the agent learned the dead flag from. Fixes the observed failure where the agent passed `--no-launch` (command errored) and then nested a project by re-running with a name from inside the target directory.
- **`database` skill: declarative schema files are now explicitly DDL-only — no seed/data DML.** Added a prominent rule (and a "Seed / default rows" row to the where-to-put-objects table) forbidding standalone `INSERT`/`UPDATE`/`DELETE`/`MERGE`/`TRUNCATE` in `supabase/database/schemas/` files. Such data is **silently dropped** by the converger (`db apply`/`db migrate` diff catalog objects, not rows), and the CLI now hard-errors on it — so the skill directs seed/reference data to its proper home: `supabase/seed.sql` (local), a migration (prod-bound reference data), or the `rbac/` reconcile (roles/permissions). Clarifies that DML *inside a function body* is fine (it's part of the function's DDL).
- **Plugin renamed `link` → `agentlink`; marketplace namespace is now `tomaspozo`.** Install is now `/plugin install agentlink@tomaspozo` (the `/plugin marketplace add tomaspozo/agentlink` GitHub path is unchanged). Swept the live references: `settings.json` (`agentlink:builder`), the `agentlink:frontend` skill cross-ref in `agents/builder.md`, and the README. The CLI that scaffolds projects (`cli/src/claude-settings.ts`) and the landing page install snippet (`www/components/start-page-plugin.tsx`) were updated to match — without the CLI change, newly scaffolded projects would register a plugin/marketplace name that no longer resolves and silently fail to load it.
- **Destructive-command hook now blocks `db rebuild` (the CLI's `db reset` was removed; `db rebuild` is the reset).** The CLI consolidated `db reset` into `db rebuild` — `db rebuild` now runs `supabase db reset` internally (replays migrations) then re-applies schema files + imperative resources, without regenerating migrations. So the hook that keeps resets user-initiated now matches `agentlink … db rebuild` (in addition to a raw `supabase db reset`) and points the user at `npx agentlink-sh@latest db rebuild`. The `cli` skill's "Database rebuild" section + the troubleshooting entries are reworded to the new reset-then-re-apply behavior (no more migration regeneration), and stale `db reset` command references across the skills are updated to `db rebuild`.
- **`frontend` + `cli` skills: documented the scaffold's page-anatomy primitives and the neutral-shadcn list/picker rules.** The scaffold now ships `PageHeader` (page hero) + a real `PageShell` (page wrapper) and a curated shadcn `ui/` set, so the skills teach the agent to compose them instead of re-inventing. `frontend/SKILL.md` corrects the Shared Components table (`PageShell` = wrapper, `PageHeader` = hero), adds a **page anatomy** section (`PageShell → PageHeader → content`; lists use shadcn `Table`, pickers use shadcn `Select`, never a native `<select>`; loading uses `ListSkeleton`, empty uses `EmptyState`), lists the curated `ui/` components, and adds the on-demand escape hatch (`npx shadcn@latest add <name> --yes`) as the first move for any missing primitive — *never hand-roll or fall back to a native element*. `references/data_fetching.md`'s three-state example now uses the shared primitives, and `cli/references/scaffold-map.md`'s frontend inventory is updated (adds `PageHeader` + the new `ui/*`, corrects `PageShell`, names Members the canonical Table+Select reference page).

## [1.1.0] - 2026-06-15

### Added

- **`builder` agent: orchestration recipes reference (`agents/references/recipes.md`).** Cross-cutting, end-to-end worked examples that combine the layers the architecture keeps separate — `api.*` RPCs, edge functions, and `pg_cron` + PGMQ wired through the prebuilt admin functions. Three recipes: a scheduled outbound-HTTP "ping engine" (with a PGMQ fan-out variant), a queued side-effect (invite-member email), and a periodic third-party sync — each ending with a "what goes where" mapping back to the principles. The `database` and `edge-functions` skills' background-work sections link to it.
- **`cli` skill: Scaffold Map reference (`skills/cli/references/scaffold-map.md`).** A deterministic, version-matched inventory of everything a fresh scaffold ships with — every table, RPC, `_auth_*`/`_internal_admin_*`/`_hook_*` function, RBAC role + permission, and frontend route/hook/component — so the agent reads it instead of doing a discovery pass on a freshly scaffolded project.

### Changed

- **`database` + `cli` skills: documented the imperative resource folders (`cron/`, `storage/`, `rbac/`).** These three top-level folders under `supabase/database/` are excluded from `declarative apply` and from migrations, and applied imperatively by the deploy step on every env (incl. prod) — the only path that reliably reaches prod for cron jobs, storage buckets/policies, and RBAC data (pg-delta's Supabase integration filters the cron + storage schemas; RBAC is reference data). Cron files moved from `schemas/api/cron/` to the top-level `cron/` folder; added `storage/` guidance with the idempotency rules (`cron.schedule` upserts by name; buckets via `INSERT … ON CONFLICT`; policies via `DROP POLICY IF EXISTS` + `CREATE POLICY`). Swept the `database` SKILL + `naming_conventions`, the `cli` SKILL + `migration_system`, the scaffold-map reference, and the builder recipes to the new paths. Added a `db reset` section + a troubleshooting entry: a raw `supabase db reset` drops custom roles/cron/storage (migrations-only replay) — use `npx agentlink-sh db reset` (resets + re-applies imperative resources) or `db apply` to restore them.
- **`builder` agent: the Architecture section is now a decision framework, not just a description of layers.** Added a decision matrix (concern → default decision → owning skill), a **Decision protocol** (decide from the principles by default; confirm when the user dictates an implementation; research the Supabase docs then decide for uncovered patterns), and named the prebuilt cron/queue building blocks the agent must reuse (`_internal_admin_call_edge_function`, `api._admin_enqueue_task`, the queue lifecycle helpers, `internal-queue-worker`, `process-stale-tasks`). Reworded the discovery-phase guidance into two explicit buckets — *product decisions* (ask) vs. *architecture & runtime mechanics* (decide) — so the agent stops surfacing settled choices like "edge function vs. in-database `pg_net`?" as user questions.
- **`edge-functions` skill: outbound HTTP is always an edge function, never in-database `pg_net`.** Added an explicit rule (with the canonical `cron → call edge fn → RPC fetch → fetch URLs → RPC write` flow) scoping `pg_net` to its only sanctioned use — waking an edge function via `_internal_admin_call_edge_function`. The `database` skill's cron-file convention now points to it.
- **`builder` agent: trimmed the always-loaded prompt ~40% (453 → 267 lines).** Reference-grade detail that duplicated the on-demand skills — the CLI command table, `check`/`--force-update`/`info`/`--debug`/upgrading prose, the managed-files/base-snapshot mechanics, the `supabase/database/` tree diagram, the schema-usage table, and the long `.from()` / `SECURITY INVOKER` code blocks — was reduced to a rule plus a "Load the X skill" pointer (verified each is covered as well or better in the owning skill). Invariants the agent must obey even with no skill loaded (RPC-first / never `.from()`, never-reset / migrations-only, the prod-deploy CAN/MUST-NOT boundary, the function-prefix table, the decision framework) stay inline. Removed a redundant end-of-file "How the CLI tracks schema files" block that duplicated the Managed-files section.

### Fixed

- **Destructive-command hook no longer lets `npx supabase db reset` through.** The block regex was anchored such that it only matched a bare `supabase db reset` at the start of the command — the common `npx supabase db reset` (and any path/prefixed form) slipped past unblocked. Rewrote it to match `db reset` in every form of both `supabase` and `agentlink` invocations (npx / path / `@latest` prefixes, inside `&&`/`;`/`|` chains), so the agent can't reset the database — directly or via the new `agentlink db reset` wrapper — without the user. The block message now points the user at `npx agentlink-sh@latest db reset` (which also restores the imperative resources a raw reset drops).

## [1.0.1] - 2026-06-13

### Changed

- **`frontend` skill: auth-listener guidance updated for the supabase-js ≥ 2.107.0 deadlock fix.** v2.107.0 (PR #2392) removed the `navigator.locks`-based auth mutex that caused `onAuthStateChange` async-callback deadlocks and "Lock broken by another request" errors, so the old advice to wrap every in-listener Supabase call in `setTimeout(…, 0)` is obsolete. `skills/frontend/SKILL.md` and `references/auth_ui.md` now state the ≥ 2.107.0 version floor, reframe the `onAuthStateChange` + `getSession()` dual-path guard as a *logic* race (the action runs twice — a plain bug that survives the lock fix) rather than lock contention, switch the listener examples to synchronous dispatch (`void doWork()` instead of `setTimeout`), and keep the narrower caveat that the async overload is still `@deprecated` and `refreshSession()` from inside `TOKEN_REFRESHED` retains a residual re-entry risk. The quirks table's `refreshSession()`-deadlock row now points at the version floor as the fix. Verified end-to-end: the e2e auth suite (sign-up, sign-in, magic-link, password-reset, invite→accept, wrong-account) passes 6/6 against a fresh scaffold on the new floor.

## [1.0.0] - 2026-06-12

### Security

- **Docs: `api` functions are granted per-object (default-deny), never via a schema-wide blanket grant.** A bulk `GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA api` re-granted every function to `authenticated`, and pg-delta's declarative apply ordered it after the per-function revokes — exposing `SECURITY DEFINER` `api._admin_*` functions to `authenticated` on `db apply` (dev) while migrations locked them on prod. The skills now teach the per-object rule: every `api` RPC carries its own `REVOKE ALL … FROM PUBLIC` + `GRANT EXECUTE … TO authenticated, service_role` (anon-callable → +anon; `_admin_*` → service_role only) — like tables. Updated the `rpc` skill (SKILL.md + references/rpc_patterns.md Grants section), `database/SKILL.md`, and `auth/SKILL.md` (removed the stale "auto-grant / `GRANT ON ALL FUNCTIONS`" guidance).

### Fixed

- **`auth` skill: `api.invitation_accept` called `_internal_admin_set_session_tenant` with the wrong arguments.** The wrapper passed four args (`v_session_id, v_user_id, …`) but the helper takes three (`p_user_id, p_tenant_id, p_role`) and reads `session_id` from the JWT itself — the example would fail at runtime with "function does not exist". `references/rls_patterns.md` now calls it `(v_user_id, (v_result->>'id')::uuid, v_result->>'role')`, matching the helper signature (and the other correct call site in the same file).
- **`rpc` skill: `api.chart_list_paged` referenced undeclared variables.** The offset-pagination template used `v_limit`/`v_offset` but only declared `v_items`/`v_total_count`, so it wouldn't compile. `references/rpc_patterns.md` now declares `v_limit int;` and `v_offset int;`.
- **`frontend` skill: reconciled the route-tree, entry-point, and types-path examples with the real TanStack Start SPA scaffold.** Three reference files disagreed on the canonical app shape. `references/data_fetching.md` now imports `@/types/database` (was `@/types/database.types`) and shows providers nesting in `__root.tsx` (removed a fictional `src/main.tsx` doing `createRoot().render(<RouterProvider/>)` — TanStack Start owns the entry). `references/routing.md` and `SKILL.md` now use the actual route tree (`_anon/sign-in.tsx` → `/sign-in`, `_auth/dashboard.tsx`, public `index.tsx`), replacing stray `/login`, `_auth/index.tsx`-as-dashboard, and placeholder route names. `references/auth_ui.md` fixed auth URLs (`/sign-in`, `/check-inbox`, `/forgot-password`) and dropped stale "two templates" language.
- **Corrected the production-deploy process in the docs (prod is migrations-only).** The `cli` skill's "Ship changes to production" workflow + `agents/builder.md` now make clear that `env deploy prod` **skips** declarative `db apply` — schema reaches prod only through a committed migration. The required loop is: build + `db apply` on dev → `db migrate <name>` (review + commit the migration) → `env deploy prod` (explicit approval) replays it. The old docs implied `db apply` runs against the deploy target, which on prod would have shipped **no** schema change.

### Changed

- **RBAC reference data moved to `supabase/database/rbac/` with a reconcile model.** Roles / permissions / role→permission bindings are reference DATA, not schema: the *tables* stay in `schemas/public/tables/`, but their *rows* now live one-entity-per-file under `supabase/database/rbac/` (`roles.sql`, `permissions.sql`, `role_permissions.sql`), each filling an `rbac_desired` staging table. A reconcile step (`db apply`, and **every `env deploy`** incl. prod, plus standalone `agentlink db rbac-sync`) converges the DB to *exactly* the declared set — **full reconcile** (insert/update/**delete**) for permissions + bindings so revokes finally reach prod, **upsert-only** for roles. Updated the "adding a permission-gated capability" checklist + example in `skills/auth/SKILL.md`, the "Adding a domain permission" example in `references/rls_patterns.md` (now `INSERT INTO rbac_desired …`), and the directory tree / "where to put" table / naming table in `skills/database/SKILL.md` + `references/naming_conventions.md`. Rationale documented: pg-delta `declarative apply` and migrations carry DDL only, and prod skips declarative apply — so the reconcile is the only path RBAC rows (and revocations) reach prod.

- **Declarative-schema overhaul: one-object-per-file under `supabase/database/`, a committed base snapshot, no more `@agentlink` annotations.** The old `-- @agentlink` SQL annotations and the function-level SQL merge engine are gone. Declarative SQL now lives under **`supabase/database/`** (matching Supabase's `db … generate` layout), **one object per file**: `cluster/extensions/<ext>.sql` (one file per extension — replaces root `_extensions.sql`), `schemas/<schema>/schema.sql` (`CREATE SCHEMA` + schema-level grants — replaces root `_schemas.sql`; `public/schema.sql` holds only public's grants since public already exists), `schemas/<schema>/tables/<table>.sql` (table + its grants/RLS/indexes/triggers), `schemas/<schema>/functions/<fn>.sql`, `schemas/api/tables/agentlink_tasks.sql` (PGMQ queue), `schemas/api/cron/<job>.sql`. pg-delta topologically sorts at apply time, so file count/order is irrelevant; `config.toml` `db.migrations.schema_paths` is `["./database/**/*.sql"]` and `db apply` runs `pgd declarative apply --path ./supabase/database/`. **Updates** run a file-level merge against a committed base snapshot at `.agentlink/template-base/`: pristine files (disk == base) fast-forward; files you edited are preserved silently (`customized`); files you and upstream both changed surface as a `conflict` (disk preserved; 3-way reconcile captured under the gitignored `.agentlink/.incoming/`); a missing base is fail-safe + `git restore`-able + reconstructable from the `appliedVersion` in `agentlink.json`. Customizing a managed object is now just "edit its per-object file, run `db apply`" — no annotation dance. `info` reads a CLI-shipped `components.json` instead of inline annotations. **Upgrade:** a project still on `supabase/schemas/` keeps that dir **untouched but no longer applied** (nothing is moved or deleted); the update warns the user to have their agent migrate any CUSTOM objects into `supabase/database/schemas/<schema>/{tables,functions}/` (a step-by-step how-to is in the database skill) and delete `supabase/schemas/` when done. Docs swept across `agents/builder.md`, `skills/database/SKILL.md` (incl. a new create/edit guidelines table) + `references/{naming_conventions.md,workflow.md}`, `skills/auth/SKILL.md` + `references/rls_patterns.md`, `skills/rpc/SKILL.md` + `references/rpc_patterns.md`, and `skills/cli/SKILL.md` + `references/{workflows.md,upgrading.md,migration_system.md,troubleshooting.md}`.

## [0.29.0] - 2026-06-08

### Added

- **Agent learns the project-upgrade workflow.** New `skills/cli/references/upgrading.md` documents the `check` → `--dry-run` → `--force-update` → `check` path, the function-level `@agentlink` merge, and a disposable files-only reference (`--skip-env --skip-install`) to diff against when the in-place update misbehaves. Linked from `agents/builder.md` and the `skills/cli/SKILL.md` reference index.

### Changed

- **Frontend skill collapsed to a single frontend — React + TanStack Start (SPA mode); Next.js guidance removed.** Pairs with the CLI making TanStack Start SPA the only scaffolded frontend. `skills/frontend/SKILL.md` rewrites the intro + client-init to one TanStack Start path (one `createClient`, `VITE_*` via `import.meta.env`), drops the dual env-var table / `types/database.ts` alt path / Next.js `layout.tsx` permission recipe, documents the `__root.tsx` `shellComponent`-vs-`component` split (keep the Supabase client out of the prerendered shell), and reframes the SSR section as "SPA now, SSR later" (the `spa.enabled` / `defaultSsr` / per-route `ssr` switch). `references/ssr.md` repurposed from Next.js/SvelteKit SSR to TanStack Start SPA-mode config + static-deploy shell fallback + how to turn SSR on (with `@supabase/ssr` cookie auth) later. `references/auth_ui.md` drops the Next.js route-layout/callback/guard sections. `agents/builder.md`, `skills/cli/SKILL.md` (+ removed the `--nextjs` flag row), `skills/cli/references/{workflows.md,upgrading.md}`, and `README.md` (removed the `next-best-practices` companion-skill note) updated to the single-frontend framing, and `skills/edge-functions/references/api_key_migration.md`'s client env-var examples switched from `NEXT_PUBLIC_*` to `VITE_*`. Bring-your-own-Next.js bare-mode detection is unaffected.

- **Skills teach explicit, default-deny table grants — every reachable table is granted in its schema file; ungranted tables stay private.** Refines the 0.28.0 grant guidance for the model that ships with the Supabase CLI / pg-delta upgrade (where `auto_expose_new_tables = false` makes local new-default, so per-table grants are real diffs that reach prod via `db migrate`). `skills/database/SKILL.md` states the rule as "GRANT every table explicitly — default-deny" with examples for full-access, read-only (`SELECT` to authenticated), and internal (no grant → private) tables; the worked `readings` example in `references/workflow.md` shows the explicit `GRANT`. `skills/auth/SKILL.md`, `skills/rpc/SKILL.md`, and `agents/builder.md` frame the table-grant prerequisite as explicit/default-deny (a forgotten grant fails fast with `42501` in dev). `skills/cli/references/troubleshooting.md`'s `42501` entry explains it's expected default-deny and to add the table's grant. `anon` is never granted (anon RPCs are `SECURITY DEFINER`). Pairs with the CLI-side explicit-grant + toolchain-bump change.

- **Skills teach function default-deny — `anon` can't execute a function unless granted.** Pairs with the CLI making functions default-deny (the built-in `PUBLIC` EXECUTE is revoked; `db migrate` auto-locks new functions). `skills/database/SKILL.md` adds a "functions are default-deny too — and mostly automatic" rule: `api.*` RPCs auto-grant `authenticated`/`service_role`, anon-callable RPCs need an explicit `GRANT … TO anon` (+ `SECURITY DEFINER`), `public` helpers are private unless granted (RLS helpers → `authenticated`; trigger functions need nothing). `skills/rpc/SKILL.md` corrects the stale "auto-grants EXECUTE to anon" claims (the api default privilege grants `authenticated`/`service_role` only; `anon`/`PUBLIC` are revoked) across the client-RPC rule, the admin-RPC rationale, and the security checklist. `skills/auth/SKILL.md`'s grant-prerequisite note now covers functions too.

## [0.28.0] - 2026-06-06

### Changed

- **Skills teach table `GRANT`s as a required layer — Supabase stopped auto-granting public-table privileges (default changed 2026).** Because `api.*` RPCs are `SECURITY INVOKER` they touch `public` tables as the caller, so each table needs `GRANT SELECT, INSERT, UPDATE, DELETE … TO authenticated, service_role` or the RPC fails with `42501 permission denied`. `skills/database/SKILL.md` adds a GRANT rule next to the RLS rule (bundle the grant with `ENABLE ROW LEVEL SECURITY`; `anon` never granted — anon RPCs are `SECURITY DEFINER`; `db apply` is the source of truth since `db migrate` may omit grants under pg-delta's `--integration supabase`), and the worked `readings` example in `references/workflow.md` now shows the grant. `skills/auth/SKILL.md` adds the table-grant prerequisite to the four-layer Security Model (grant = "can the role touch the table," RLS = "which rows"). `skills/rpc/SKILL.md` adds a security-checklist item for the underlying table grant. `agents/builder.md` adds the prerequisite-layer note to the Authorization section. `skills/cli/references/troubleshooting.md` adds a `42501 permission denied for table` entry with the fix + immediate-unblock SQL. Pairs with the CLI-side template + baseline-migration fix.

- **Migration docs corrected to match the fixed `db migrate` — it now produces real, non-empty migrations.** `skills/cli/references/migration_system.md` rewrites "How `db migrate` works" around the tiered migrations-only baseline (empty / ephemeral throwaway stack / read-only prod→dev) and **deletes the old "in cloud mode the migration will be empty… this is expected" paragraph** that was teaching the agent to accept empty output and hand-author migrations. `skills/cli/references/troubleshooting.md` adds a "`db migrate` says 'No changes detected'" entry (it's a baseline-availability issue — ensure Docker or a prod+dev env — not a cue to hand-author) plus an intervene-table row. `agents/builder.md` notes `db migrate` doesn't touch the dev DB (builds the baseline on a throwaway Supabase stack, so Docker must be running, else a read-only prod→dev diff) and reinforces "never hand-author migration files." Pairs with the CLI-side fix.

## [0.27.0] - 2026-06-05

### Added

- **Builder agent runs a blank-project kickoff — discovery pass + product brief before building.** New "Blank-project kickoff" section in `agents/builder.md`: when asked to build on a freshly scaffolded project (no domain schema, `AGENTS.md` is just the `agentlink:config` block), the agent first discovers three things — (1) the **multi-tenancy model** (what a tenant represents: SaaS customer, internal department, multi-location branch, or genuinely single-tenant — the scaffold ships tenancy by default, so the question is *what it represents*, not *whether* to use it), (2) the **entry point & look-and-feel** (public-facing → a small real landing at `/` + gated app at `/dashboard`; internal tool → `/` redirects to the dashboard; plus colors/typography via the `frontend-design` skill), and (3) the **product itself** (value prop, v1 features, main entities). It then writes a product brief into `AGENTS.md` — the `/init` equivalent for the *what* and *why* — **outside** the CLI-managed `<!-- agentlink:config:start/end -->` block (appended below the end marker, since `--force-update` and every `env` command rewrite everything between the markers). `skills/cli/references/workflows.md` workflow #1 ("Start a new project from zero") cross-links the kickoff so the post-scaffold step is discoverable from the scaffolding flow.

### Changed

- **Project instructions file renamed `CLAUDE.md` → `AGENTS.md`.** The scaffolded per-project config/instructions file (the one carrying the `agentlink:config` block) is now `AGENTS.md`, the agent-agnostic standard read by Claude Code and other agents alike. Swept every reference in `agents/builder.md`, `skills/cli/SKILL.md`, and the `skills/cli/references/` tree (including the `writeClaudeMd` → `writeAgentsMd` mention). Paired with the matching CLI rename (output filename + `src/agents-md.ts`).

## [0.26.0] - 2026-06-04

### Changed

- **Authorization skills rewritten for the four-layer model — permissions move out of RLS into an explicit RPC guard.** Replaces the "RLS on every table enforces permissions" framing with: (1) **schema isolation** is the table boundary (`public` isn't exposed), (2) **`auth_verify_access('<entity>.<action>')`** in every mutating `api.*` RPC is the primary permission gate (raises `42501` → HTTP 403; `auth_has_access` is the boolean form for branching), (3) **RLS is isolation-only** (`tenant_id`/ownership — the forgotten-`WHERE` backstop, never where permissions are checked), and (4) the **frontend** `useHasPermission` / route guards are UX only. `skills/auth/SKILL.md` gets the four-layer Security Model, the guard helpers, a canonical guarded-RPC + isolation-policy template, and an "adding a permission-gated capability" cross-layer checklist. `skills/auth/references/rls_patterns.md` rewrites the RBAC and tenant-policy examples so the permission check lives in the RPC and the policy stays isolation-only. `skills/auth/assets/common_policies.sql` simplifies the tenant-scoped pattern to isolation-only and adds "Pattern 5: RPC authorization guard". `skills/rpc/SKILL.md` adds the guard-first rule + explicit tenant scoping to the security checklist and the `42501`→403 vs default `P0001`→400 mapping. `skills/database/SKILL.md` reframes "RLS on every table" as isolation-only. `skills/frontend/SKILL.md` + `references/{auth_ui,routing}.md` document `useHasPermission`, `<RequirePermission>`, and the route-guard seam for both routers (TanStack `beforeLoad`; Next.js server `layout.tsx`), with the "frontend is UX, backend enforces" rule called out. `agents/builder.md`'s core-rule line updated to the four-layer model.

## [0.25.0] - 2026-05-19

### Changed

- **Docs and agent skills no longer assume a global `agentlink` install — every command is `npx agentlink-sh@latest <subcommand>`.** Reverts the 0.23.0 stance ("install the CLI globally, then use the bare `agentlink` command for everything"). `npx agentlink-sh@latest` always resolves to the latest published version, removes the install step from onboarding, and means new-machine setups work in one command. Swept every `.md` file under `agents/` and `skills/` — `skills/cli/SKILL.md` (the heaviest at ~140 invocations across the Quick syntax / Commands reference / Workflows sections), `skills/edge-functions/SKILL.md`, `skills/database/SKILL.md`, `skills/auth/SKILL.md`, `skills/frontend/SKILL.md`, and the entire `skills/*/references/` tree — replacing bare `agentlink <cmd>` with `npx agentlink-sh@latest <cmd>`. `@agentlink` SQL annotations are preserved (they're CLI metadata markers parsed by `templates.ts`, not commands). `agents/builder.md`'s "Tool reference" table and command examples (lines 33-155) follow the same pattern. `README.md` install block collapsed to the single `npx agentlink-sh@latest <project-name>` form; the "After global install, every CLI command is just `agentlink <subcommand>`…" paragraph removed.

## [0.24.0] - 2026-05-05

### Changed

- **Auth skill rewritten for the per-session tenant + RBAC model.** `skills/auth/SKILL.md` and `skills/auth/references/rls_patterns.md` now lead with the custom access-token hook (`_hook_custom_access_token`) as the engine: per-device pin from `public.session_tenants` (keyed on `auth.sessions.id`) with a fallback to the user's oldest membership for single-tenant zero-touch. The tables-and-policies overview lists the four multitenancy tables (`tenants`, `memberships`, `invitations`, `session_tenants`) plus the three RBAC tables (`roles`, `permissions`, `role_permissions`); the "Tenancy UX" guidance is rewritten to match — single-tenant is zero-touch (no picker, no selection state); multi-tenant is per-device (each browser/phone has its own session pin). New "Why three tables instead of enums" subsection in `rls_patterns.md` covers the design tradeoffs (Postgres enums are append-only — apps grow new permissions constantly); "Adding a domain permission" worked example walks through the two-INSERT pattern. RLS examples switch from `_auth_has_role('admin')` to `_auth_has_permission('membership.delete')` etc. New "Wrap `_auth_*` helpers in `(SELECT ...)`" subsection — the planner promotes the call to an InitPlan, matches Supabase's RLS-performance docs. Helper code blocks updated to the new `LANGUAGE sql STABLE` bodies (inlinable by the planner) including `_auth_is_tenant_member`'s `(SELECT auth.uid())` wrap.

- **Invitations always work even when the app is single-tenant style.** New "Invitations work even when the app is single-tenant style" subsection in `skills/auth/SKILL.md`: the invitation pipeline doesn't care whether the UI exposes a tenant switcher — admin invites a teammate, teammate signs up, AFTER-INSERT trigger skips default-tenant creation (`invited_at IS NOT NULL`), teammate accepts via `api.invitation_accept`, membership row is created and pinned to their current session, next refresh lands them inside the joined workspace. No code path requires a UI picker.

- **RPC skill DEFINER worked example updated.** `skills/rpc/SKILL.md` swaps the `_internal_admin_set_tenant_claims` reference example for `_internal_admin_set_session_tenant`, with the session-ownership check (`auth.sessions.id = p_session_id AND user_id = p_user_id`) and the per-session UPSERT pattern.

- **Frontend skill `useTenantGuard` description matches the simplified hook.** `skills/frontend/SKILL.md`'s "Post-signup & the useTenantGuard hook" subsection rewritten — the hook now refreshes the session once when `app_metadata.tenant_id` is missing and lets the access-token hook do the selection server-side; no more `tenant_list` → `tenant_select` round-trip from the client. The remaining edge case (a JWT minted before the AFTER-INSERT trigger materialized the membership row) is what the guard exists to handle.

## [0.23.1] - 2026-04-30

### Changed

- **Docs no longer mention the `SB_*` edge-function secret mirror.** CLI 0.27 dropped the mirror from `applyVaultSecrets` — edge functions read the platform-injected `SUPABASE_*` env vars directly. Updated the `secrets` row in the `env config` table in `skills/cli/SKILL.md`, the "Re-apply vault secrets" entry in `agents/builder.md`'s tools table, and the `env config secrets prod` example comment in `skills/cli/references/workflows.md`.

## [0.23.0] - 2026-04-30

### Changed

- **CLI npm package renamed from `create-agentlink` to `agentlink-sh`.** Install is now `npm install -g agentlink-sh@latest` (or `npx agentlink-sh@latest <name>` for a one-shot). Updated install commands in `README.md` and the CLI skill's opening line in `skills/cli/SKILL.md` to refer to "the `agentlink` CLI" instead of `create-agentlink`. The binary name (`agentlink`) is unchanged — only the package name moved.

- **Docs assume the CLI is installed globally.** `npm install -g agentlink-sh@latest` is the recommended path, after which every command is the bare `agentlink <subcommand>`. Swept all `.md` files under `agents/` and `skills/` (~120 occurrences across 13 files) replacing `npx create-agentlink@latest` with `agentlink`. CHANGELOG history left untouched.

- **README rewritten against current CLI behavior.** Audit fixes: added the `cli` skill to the skills list (was missing — the builder agent preloads 6 skills, not 5); corrected slash-command namespace from `/agentlink:*` to `/link:*` and agent reference from `@agentlink:builder` to `@link:builder` (matches `plugin.json` `name: "link"`); rewrote the Setup section around cloud-as-default with `--local` opt-in; replaced the local-only MCP framing with a "Cloud vs local mode" subsection (cloud uses the Supabase Management API + pooler, MCP is local-only); added a "Production guardrail" subsection documenting the autonomous-on-dev / approval-required-for-prod model from 0.21.0; rewrote Companion Skills around auto-install (CLI installs them by default, manual is the escape hatch) and added the previously-missing `shadcn/ui`.

- **Repository moved to `tomaspozo/agentlink`.** Updated `repository` field in `.claude-plugin/plugin.json`, the marketplace install command in `README.md`, and the release URL in `scripts/release.sh` to point at the new GitHub location.

## [0.21.0] - 2026-04-30

### Added

- **`internal-` prefix convention for system-only edge functions.** `skills/edge-functions/SKILL.md` adds a bare/internal naming table — bare names for client/external-facing (`stripe-webhook`, `chart-render`), `internal-` prefix for queue workers, auth hooks, cron-only handlers, and anything paired with `allow: "secret"`. Mirrors the SQL `_internal_admin_*` convention. Leading-underscore caveat noted (Supabase skips top-level `_*` dirs, so use the hyphenated form). Auth and database examples renamed to match: `send-email` → `internal-send-auth-email`, `invite-member` → `internal-invite-member`, `queue-worker` → `internal-queue-worker`.

### Changed

- **`api.*` functions must be `SECURITY INVOKER` — no exceptions.** `skills/rpc/SKILL.md`, `rpc_patterns.md`, and `auth/references/rls_patterns.md` reframe DEFINER-in-`api` from "rare exception" to a linter-flagged anti-pattern (Supabase lints 0028/0029). New worked example for the INVOKER-wrapper-in-`api` → DEFINER-helper-in-`public._internal_admin_*` split with defense-in-depth `auth.uid() = p_user_id` checks. New "Where DEFINER is allowed" matrix and an `api._admin_*` carve-out requiring explicit `REVOKE … FROM PUBLIC, anon, authenticated; GRANT EXECUTE … TO service_role`. `tenant_select`, `invitation_create`, and `invitation_accept` rewritten to the wrapper pattern.

- **Agent deploys to `local` / `dev` autonomously; prod requires explicit user approval.** `agents/builder.md` and `skills/cli/SKILL.md` reframe the deploy guardrail from "the agent does not deploy" — too broad, was leaving newly-written edge functions undeployed on cloud-dev. Agent can now run `db apply`, `supabase functions deploy`, `supabase secrets set`, `env deploy dev --yes`, and `db migrate` against the active dev env without asking. Hard line at prod: `env deploy prod`, `env use prod`, `db push` against a prod URL, `functions deploy` / `secrets set` while active env is prod, prod `env add` / `--retry`, and `destroy`. Signal is `manifest.cloud.default`; approval scope is one command, not a blanket pass.

## [0.20.0] - 2026-04-24

### Added

- **CLI skill documents `db backup`.** New "Snapshot the database" subsection under Database Operations in `skills/cli/SKILL.md` covering the three-file dump triplet (roles / schema / data), the timestamped per-env folder layout, the first-run gitignore append, and the read-only safety profile. New workflow #10 "Snapshot an env before a risky change" in `workflows.md` with trigger, env-resolution flow, what-it-does, and watch-outs (including a callout that no `db restore` command exists — restoration is a developer-initiated manual step). The agent never runs `db backup` autonomously before destructive changes; it's safe but reading prod data is still the user's call to make.

### Changed

- **`env use <same-env>` documented as a refresh verb, not a no-op.** CLI 0.24 removed the `Already on "<name>"` short-circuit so re-running `env use` on the active env re-fetches API keys + pooler URL and rewrites `.env.local`'s managed block. `skills/cli/SKILL.md` and `skills/cli/references/workflows.md` (workflow #3) get a paragraph each explaining the refresh behavior, when to reach for it (key rotation in the Supabase dashboard, suspected `.env.local` drift), and the closing-line wording change (`Refreshed <name>` vs `Switched to <name>`). Prod confirmation skipped on the refresh path since the user is already on prod.

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

The agent no longer sets up your project — the CLI does. This is a fundamental shift in how AgentLink works: infrastructure setup with `npx @agentlink.sh/cli@latest` and the agent spends zero tokens verifying prerequisites, copying asset files, or scaffolding directories. Every token goes toward building your app.

This aligns with the AgentLink philosophy: **tools for agents, not agents as tools.** The CLI is purpose-built tooling that gives the agent a ready environment. The agent is a builder that assumes a working environment and gets to work. Each does what it's best at.

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

- Recommended Companions section in CATALOG.md — curated community skills that enhance AgentLink workflows (supabase-postgres-best-practices, frontend-design, vercel-react-best-practices, next-best-practices, resend-skills, email-best-practices, react-email)
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
