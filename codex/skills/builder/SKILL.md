---
name: builder
description: Entry point for building or scaffolding an app on Supabase with AgentLink, and the architecture spine for any Supabase backend work — database, schema, RPCs, auth, RLS, edge functions, background jobs, migrations, deploys. Use whenever the user asks to build, scaffold, or add a feature to an app on this stack, or when a task touches supabase/, agentlink.json, or the agentlink CLI. Load this before improvising a stack or asking "what backend should we use" — the stack is already settled. Points at the domain skills (cli, database, rpc, auth, edge-functions, frontend, notifications) that carry the how.
---

# AgentLink — Building on Supabase

These are app development guidelines, not the project itself. The user's project
is whatever they ask you to build; Supabase is the backend. Follow these patterns
when building it.

> **Where this fits.** This skill is **Codex-only** — it lives in `codex/skills/`
> and is loaded solely by `.codex-plugin/plugin.json`. Codex plugins have no
> `agents` or `rules` field, so on Claude Code the `builder` agent
> (`agents/builder.md`) carries this spine and on Cursor the AgentLink rules
> (`rules/agentlink.mdc`) do; here, this skill *is* the spine — the only thing
> standing between a generic agent and an improvised stack. It is the peer of
> those two files: **change one, consider the other two.** The seven domain
> skills in `skills/` are shared by all three hosts and remain the source of
> truth for the *how*.

## Engaging AgentLink (entry point)

Whenever the user wants to **build or scaffold an app**, or do **any Supabase
backend work** (database, auth, RPC, edge functions, deploys):

- Treat it as an AgentLink task. **Do not improvise a generic frontend/backend
  setup, and do not ask raw "what stack?" questions.** The stack is settled:
  Supabase + the architecture below + a React/TanStack Start frontend.
- **Load the matching skill** for the work at hand: `cli` (scaffolding, env,
  migrations, deploys), `database`, `rpc`, `auth`, `edge-functions`, `frontend`,
  `notifications`.
- **Scaffold only via the CLI** (`npx agentlink-sh@latest …`) — never hand-roll
  the project structure.
- **Is this project already scaffolded?** If there's no `agentlink.json` in the
  project root, it is **not scaffolded** — the CLI must create it first. **Never
  hand-create** the schema files, tables, RPCs, auth/RLS helpers, routes, or
  config. The `scaffold-map` reference (in the `cli` skill) lists what the CLI
  produces; it is a map for *reading* an existing scaffold, never a checklist for
  *building* one by hand. Seeing those files described is not permission to
  recreate them.

**Match the user's language.** Chat, planning, and explanations use the same
language as the user. All code — SQL, TypeScript/JSX, names, comments — is always
in English regardless.

## Building a new app

- **Plan first.** Don't write SQL or UI until the scope is confirmed. For
  greenfield work, present the architecture for approval before coding.
- **Blank-project kickoff (once, on a freshly scaffolded project).** Run a short
  discovery pass, then write a product brief into `AGENTS.md`. Discover:
  - **Multi-tenancy model** — what a tenant represents here (a SaaS customer, an
    internal team, a location, or genuinely single-tenant). The scaffold ships
    multi-tenancy by default; keep the tables regardless.
  - **Entry point & look-and-feel** — what lives at `/` (a real landing page for
    public-facing products; a redirect to `/dashboard` for internal tools), plus
    colors, typography, mood. Load the `frontend-design` skill if available.
  - **The product itself** — one-line value prop, v1 features, and the main
    entities (which become your first tables and RPCs).
- **🛑 Write the brief OUTSIDE the managed config block.** `AGENTS.md` has a
  CLI-owned section fenced by `<!-- agentlink:config:start -->` …
  `<!-- agentlink:config:end -->`. The CLI rewrites everything between those
  markers — anything you put there is lost. Append the brief *below* the
  `agentlink:config:end` marker. Never edit inside the markers.
- **Ask about the product, not the architecture.** Product forks (what a tenant
  is, what lives at `/`, what the app does and for whom) are the user's. Runtime
  mechanics (RPC vs. direct query, edge function vs. in-database `pg_net`, RLS)
  are settled by the stack — decide them yourself, never ask.
- **DB / schema / deploy work goes through the AgentLink CLI**, never the Supabase
  connector MCP (no `apply_migration` / `execute_sql` / `create_project` for
  project setup, schema, or deploys).

Before scaffolding, **ask where the dev environment should live** — local Docker
or Supabase Cloud. Don't default silently. Cloud needs browser OAuth you don't
have (`--skip-env`, then hand off `pnpm exec agentlink env add dev`); local runs
end-to-end with `--local`. Load the `cli` skill (workflow #1) for the full flow.

## Architecture decision matrix

100% Supabase — one platform, no extra infrastructure. **These are decisions you
make, not questions you ask.** Each concern has one right home.

| Concern | Default decision | Owning skill |
|---|---|---|
| Data access / business logic | `api.*` RPC (`SECURITY INVOKER`, never `.from()`) | `rpc` |
| Outbound HTTP / third-party APIs / webhooks | Edge function (`withSupabase`) | `edge-functions` |
| Background / scheduled / async work | `pg_cron` + PGMQ via the prebuilt admin functions | `database` |
| Authorization | `auth_verify_access('<entity>.<action>')` guard in the RPC + RLS isolation | `auth` |
| Multi-tenancy | scaffolded `tenants` / `memberships` / `invitations` | `auth` |
| App-driven / transactional email | `api._admin_send_email(...)` → `internal-send-email` | `notifications` |
| Supabase **Auth** email (signup confirm, magic link, recovery) | Send Email hook (`_hook_send_email` → `internal-send-auth-email`) — **separate function** | `auth` |
| Frontend | TanStack Start + `typedRpc` | `frontend` |

### Decision protocol

1. **Default — decide, don't ask.** Make architecture and runtime choices
   yourself from the matrix. Never turn them into user-facing questions.
2. **User dictates an implementation → confirm.** If their instruction conflicts
   with a principle (e.g. "just query the table with `.from()`"), name the
   conflict and propose the principled alternative — then follow their call.
3. **Uncovered use case → research, then decide.** Consult the official Supabase
   docs, choose what best aligns with these principles, and record non-obvious
   calls under "Decisions to track" in `AGENTS.md`.

## Core rules

**Schema isolation.** The `api` schema is the **only** schema exposed via the
Supabase Data API, and it holds functions only — never tables. `public` holds
tables and internal functions and is never exposed. `extensions` holds every
extension. **Always schema-qualify** every identifier (`public.charts`,
`api.chart_create`) — no bare names, anywhere.

**RPC-first — never `.from()`, always `.rpc()`.** `.from()` targets the exposed
schema (`api`), which has no tables, so it always fails or returns nothing —
regardless of key. This applies to **all** code: frontend, edge functions,
webhooks, cron handlers, server routes.

**RLS on every table, no exceptions**, default-deny. RLS is *isolation only*
(`tenant_id` / ownership); permission checks live in RPC guards, not policies.
Tables also need explicit `GRANT`s — AgentLink is default-deny. See `auth`.

**Function prefixes encode the security model:**

| Type           | Pattern                          | Security |
| -------------- | -------------------------------- | -------- |
| Client RPCs    | `api.{entity}_{action}`          | INVOKER  |
| Admin RPCs     | `api._admin_{name}`              | DEFINER  |
| Auth (RLS)     | `public._auth_{entity}_{check}`  | DEFINER  |
| Internal admin | `public._internal_admin_{name}`  | DEFINER  |
| Auth hooks     | `public._hook_{hook_name}`       | DEFINER  |

**Write-Apply-Migrate.** Write SQL as one object per file under
`supabase/database/` → apply with `pnpm exec agentlink db apply` → **fix errors
with more SQL, never reset the database** → generate a migration with
`db migrate <name>` only when deploying. Schema files are the source of truth;
the live DB is the working copy. **Never hand-author migration files**, and
**never rewrite migration history** — a migration is immutable once committed or
deployed; fix forward with a new one.

**Edge functions** all use the `withSupabase` wrapper from `@supabase/server`.
Load the `edge-functions` skill for the wrapper's auth options and the current
key contract — don't guess them from memory.

## Production guardrail

The boundary is **production**, not deployment in general. Against `local` or
`dev`, deploy freely and autonomously (`db apply`, `supabase functions deploy`,
`secrets set`, `env deploy dev --yes`) — verifying your work end-to-end needs it.

**Without explicit, in-message user approval, never:** `env deploy prod`,
`env use prod`, `supabase db push` / `functions deploy` / `secrets set` against
prod, or `env add prod`. The signal is the active env in `agentlink.json`
(`manifest.cloud.default`) — `local`/`dev` means go, `prod` means stop and ask.
An approval covers that one deploy, not future ones.
