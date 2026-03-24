# Changelog

## [Unreleased]

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
