# Agent Link

> **Beta** — Agent Link is under active development. Skills, agent behavior, and APIs may change between versions.

An opinionated way to build on Supabase with AI agents.

Agent Link is a [Claude Code plugin](https://docs.anthropic.com/en/docs/claude-code/plugins) with composable skills and an app development agent. Each skill covers a specific domain — CLI, schema development, RPCs, edge functions, auth, frontend — and Claude loads whichever skills are relevant to the current task automatically. The agent bundles all skills together with architecture enforcement.

It ships alongside the [`agentlink-sh` CLI](https://www.npmjs.com/package/agentlink-sh) — the plugin's hands. The CLI scaffolds new Supabase projects (cloud or local Docker), manages multiple environments (`local` / `dev` / `prod`), applies schemas, generates migrations, and deploys schemas + edge functions to any cloud env. The agent reasons about _what_ to build; the CLI does the work the agent shouldn't do itself — OAuth, project creation, environment switching, deploys.

---

## Install

```bash
# Run via npx — always pulls the latest version, no install step
npx agentlink-sh@latest <project-name>

# From the Claude Code plugin marketplace
/plugin marketplace add tomaspozo/agentlink
/plugin install link@agentlink

# Local directory (development)
claude --plugin-dir ./path/to/agentlink
```

Every CLI command runs through `npx agentlink-sh@latest <subcommand>` — `npx agentlink-sh@latest check`, `npx agentlink-sh@latest db apply`, `npx agentlink-sh@latest env deploy prod`, etc.

---

## Usage

Describe what you want to build. The agent handles the rest — prerequisites, architecture, and the right skills for the job.

```
Build me an uptime monitor that checks endpoints every 5 minutes.
```

```
Review my db schema and suggest improvements.
```

```
Add a multi-tenant invitation flow to my app..
```

You can also call it directly with `@link:builder`.

### Use skills directly

Skills also activate automatically when Claude detects a relevant task. You can invoke them explicitly with slash commands:

- `/link:cli` — `npx agentlink-sh@latest` commands, env management, deploys
- `/link:database` — schema files, migrations, type generation
- `/link:rpc` — RPC-first data access, CRUD templates, pagination
- `/link:edge-functions` — `withSupabase` wrapper, webhooks, secrets
- `/link:auth` — RLS policies, RBAC, multi-tenancy, invitation flows
- `/link:frontend` — Supabase client setup, RPC calls, auth state, SSR

---

## Agent Configuration

The app development agent ships with opinionated defaults:

### Setup

The CLI handles all project setup. The agent builds — it does not scaffold.

- **New project (cloud, default):** `npx agentlink-sh@latest my-app` — creates a Supabase Cloud project, scaffolds schemas, vault secrets, edge functions, and a frontend
- **Local Docker mode:** `npx agentlink-sh@latest my-app --local` — runs Supabase locally instead of cloud
- **Validate setup:** `npx agentlink-sh@latest check` — verifies extensions, internal functions, vault secrets, api schema, file layout
- **Re-apply managed resources:** `npx agentlink-sh@latest --force-update` — patches templates, config, and SQL after a CLI upgrade

### Cloud vs local mode

Cloud is the default. The CLI authenticates with Supabase via OAuth, creates a project in the user's chosen org/region, and stores credentials in `~/.config/agentlink/credentials.json`. Database operations go through the Supabase Management API; SQL runs against the connection pooler.

Local mode (`--local`) runs Supabase in Docker via `supabase start`. SQL executes via `psql` against `localhost:54322`, and a Supabase MCP server is installed at `http://localhost:54321/mcp` for migration and advisor tooling. The MCP server is **not** installed in cloud mode.

### Production guardrail

The agent deploys autonomously to `local` and `dev` environments — `db apply` and `env deploy` against your `dev` environment run without prompting.

**Production is gated.** Any command targeting `prod` requires explicit user approval at call time. Approval is per-command, not a blanket pass.

### Blocked commands

A PreToolUse hook (`hooks/block-destructive-db.sh`) blocks the agent from running:

- `npx supabase db reset` — destroys and recreates the local database
- `npx supabase db push --force` / `-f` — overwrites remote schema without diffing

If you need these, run them manually on your terminal outside Claude Code.

---

## Companion Skills

The CLI installs a curated set of companion skills automatically — the agent assumes they are present. To skip auto-install, pass `--no-skills` to `npx agentlink-sh@latest`.

**Auto-installed for every project:**

- `supabase/agent-skills@supabase-postgres-best-practices` (required)
- `supabase/server` (required)
- `anthropics/skills@frontend-design`
- `shadcn/ui`
- `vercel-labs/agent-skills@vercel-react-best-practices`
- `resend/react-email`, `resend/email-best-practices`, `resend/resend-skills`

**Auto-installed for Next.js projects (`--nextjs`):**

- `vercel-labs/next-skills --skill next-best-practices`

To install or update a companion skill manually use the `skills` cli:

```bash
npx skills add supabase/agent-skills@supabase-postgres-best-practices
```

---

## License

MIT
