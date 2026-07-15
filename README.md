<div align="center">

# AgentLink

**An opinionated skill set that tells your AI agents exactly how to build on Supabase.**

Production-ready Supabase patterns, optimized so agents get it right on the first try.
Fewer errors. Fewer wasted tokens. One backend that serves every client.

[Website](https://agentlink.sh) · [CLI on npm](https://www.npmjs.com/package/agentlink-sh) · [Report an issue](https://github.com/tomaspozo/agentlink/issues)

</div>

---

AgentLink is a [Claude Code plugin](https://docs.anthropic.com/en/docs/claude-code/plugins) (and a [Cursor plugin](https://cursor.com/docs/reference/plugins), and a [Codex plugin](https://learn.chatgpt.com/docs/build-plugins)) — a builder agent plus seven composable skills — that teaches AI agents a single, opinionated architecture for full-stack apps on Supabase. Instead of letting the model improvise a different backend every time, it gives it one well-worn path: schema isolation, RPC-first data access, RLS on every table, edge functions for the outside world, and Postgres-native background jobs.

It ships with the [`agentlink-sh` CLI](https://www.npmjs.com/package/agentlink-sh) — the plugin's hands. The agent reasons about _what_ to build; the CLI does the work the agent shouldn't do itself: OAuth, project creation, applying schemas, generating migrations, switching environments, and deploying. Designed for internal tools, business software, and operational apps.

## Why AgentLink

- **DB Functions, not raw queries.** All data access goes through Postgres functions exposed as RPCs in an `api` schema. Tables stay invisible to clients — one backend serves every frontend.
- **Secure by default.** Schema isolation, row-level security on every table, no exceptions. The patterns are default-deny, so a forgotten grant fails fast instead of leaking.
- **Multi-tenancy built in.** Tenants, memberships, invitations, RBAC, and tenant-isolation RLS are wired together from day one.
- **Edge functions for externals.** Webhooks, third-party APIs, and anything outside the database run in typed Deno edge functions via `withSupabase`.
- **Cron + queues in Postgres.** Background work runs on `pg_cron` and `pgmq` — no external job runners to operate.
- **Deploy-ready from day one.** Local Docker or Supabase Cloud, `local` / `dev` / `prod` environments, diff-based migrations, and exact production parity.
- **Tuned for agents.** Every pattern is shaped so the model lands it on the first try — less back-and-forth, fewer tokens.

## Get started

### Prerequisites

AgentLink does **not** install tooling for you — have these in place first (the agent can't browse OAuth or `curl | bash` an installer):

| Tool / account | When you need it | Notes |
|---|---|---|
| **Node.js 18+** (`node` / `npx`) | **Always** — the CLI runs via `npx agentlink-sh@latest` | Without it the `npx` call fails or times out. Install from [nodejs.org](https://nodejs.org) or a version manager. |
| **Supabase CLI** | Always | The CLI validates it and points to [agentlink.sh/start](https://agentlink.sh/start) if missing. |
| **Docker** + **`psql`** | **Local development** (`--local`) | The Docker stack runs Supabase locally; `psql` applies SQL against it. Not needed for cloud-only. |
| **Supabase account** | **Cloud development & production** | For `env add dev` / `env add prod` — browser OAuth, project creation, deploys. |
| **Resend account** | **Transactional email** | For auth emails (invites, password resets) and any product email via the edge functions. Add the API key when you wire email. |

Full setup script: **[agentlink.sh/start](https://agentlink.sh/start)**.

### Scaffold a new project (recommended)

One command runs an interactive wizard — no install step. It creates the project, wires up the database, installs the companion skills, and configures your agent editor (Claude Code and/or Cursor — the wizard asks which), then hands off to the agent with your prompt:

```bash
npx agentlink-sh@latest my-app
```

The wizard asks where your first environment should live — **Supabase Cloud** (no Docker) or **local Docker** — and sets it up for you. To skip the prompt and go straight to local Docker:

```bash
npx agentlink-sh@latest my-app --local
```

Then just describe what you want to build and let the agent take it from there.

### Add the plugin to an existing setup

Already have a project? In **Claude Code**, install the plugin from the marketplace:

```bash
/plugin marketplace add tomaspozo/agentlink
/plugin install agentlink@tomaspozo
```

In **Cursor**, install it from the marketplace instead — run `/add-plugin tomaspozo/agentlink` (or find AgentLink in the Cursor marketplace). See [Use it in Cursor](#use-it-in-cursor) below.

In **Codex**, add this repo as a marketplace, then install from it:

```bash
codex plugin marketplace add tomaspozo/agentlink
codex plugin add agentlink@tomaspozo
```

For local development of the plugin itself, point Claude Code at this directory:

```bash
claude --plugin-dir ./agent
```

(For Cursor, copy the directory into `~/.cursor/plugins/local/` — see `CONTRIBUTING.md`. For Codex, `codex plugin marketplace add ./agent` takes a local path.)

### Use it in Cursor

The same plugin is Cursor-compatible — the builder agent, all seven skills, the
always-on architecture rule, and the destructive-DB guard load in Cursor too.
Install it from this repository via Cursor's plugin manager (it reads the
manifest at `agent/.cursor-plugin/plugin.json`). In Cursor the `agentlink` builder is
selectable as a custom agent (rather than a forced default), and the skills
trigger on their descriptions just like in Claude Code.

Don't have Cursor yet? Grab it at [cursor.com](https://cursor.com/referral?code=IMIH9YQ5EFRF).

### Use it in Codex

The same plugin is Codex-compatible — all seven skills and the destructive-DB
guard load there too (Codex's hook contract matches Claude Code's, so it's the
very same hook). Codex plugins have no concept of a custom agent, so the builder
spine ships as an entry-point **`builder` skill** instead: describe what you want
to build and it routes Codex into the architecture and the other skills. Because
that's description-triggered rather than a forced default, mentioning Supabase or
your app explicitly makes it fire reliably.

In a scaffolded project (1.4+), run CLI commands through the project-local binary: `pnpm exec agentlink <subcommand>` — e.g. `pnpm exec agentlink check`, `db apply`, `env deploy prod`. (Creating a brand-new project uses `npx agentlink-sh@latest <name>`, since there's no local install yet.)

## Usage

Open Cursor or Claude Code and start prompting the agent — describe what you want and it takes it from there, loading the right skills, writing the SQL and TypeScript, applying the changes, and iterating until it works.

**Build something new** — e.g. an internal tool with public form submissions:

```
Build an internal tool where the public can submit support requests through a
form, and our team triages them in a dashboard behind auth.
```

**Harden what you already have** — e.g. lock down an existing project with schema isolation:

```
Optimize my project's security: move everything behind an api schema, put RLS on
every table, and replace the direct table access with RPCs.
```

## How it works

The CLI owns setup; the agent builds.

- **New project:** `npx agentlink-sh@latest my-app` — runs the wizard, which asks whether your first (dev) environment is Supabase Cloud or local Docker, then scaffolds schemas, vault secrets, edge functions, and a React + TanStack Start (SPA) frontend. `prod` is added later with `env add prod`.
- **Skip the prompt:** pass `--local` to go straight to local Docker.
- **Validate setup:** `pnpm exec agentlink check` — verifies extensions, internal functions, vault secrets, the `api` schema, and file layout.
- **After a CLI upgrade:** `pnpm exec agentlink --force-update` — re-applies managed templates, config, and SQL.

In cloud mode the CLI authenticates via OAuth, creates the project in your chosen org/region, and runs database operations through the Supabase Management API. In local mode SQL runs via `psql` against `localhost:54322` and a Supabase MCP server is installed for migration and advisor tooling.

### Production guardrail

The agent works autonomously against `local` and `dev` — `db apply` and `env deploy` to `dev` run without prompting. **Production is gated:** any command targeting `prod` requires explicit user approval at call time, per command — never a blanket pass.

### Blocked commands

A PreToolUse hook (`hooks/block-destructive-db.sh`) stops the agent from running:

- `npx supabase db reset` — destroys and recreates the local database
- `pnpm exec agentlink db rebuild` — the same destructive reset, wrapped
- `npx supabase db push --force` / `-f` — overwrites remote schema without diffing

Run these yourself in a terminal if you really need them.

The same hook runs in Claude Code and Codex (their hook contracts match); Cursor gets an equivalent guard via `hooks/block-destructive-db.cursor.sh`.

## Companion skills

The CLI installs a curated set of companion skills automatically — the agent assumes they're present. Pass `--no-skills` to skip auto-install.

- `supabase/agent-skills@supabase-postgres-best-practices` _(required)_
- `supabase/server` _(required)_
- `anthropics/skills@frontend-design`
- `shadcn/ui`
- `vercel-labs/agent-skills@vercel-react-best-practices`
- `resend/react-email`, `resend/email-best-practices`, `resend/resend-skills`

Install or update one manually with the [`skills`](https://www.npmjs.com/package/skills) CLI:

```bash
npx skills add supabase/agent-skills@supabase-postgres-best-practices
```

## License

MIT
