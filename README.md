# Agent Link

> **Beta** — Agent Link is under active development. Skills, agent behavior, and APIs may change between versions.

An opinionated way to build on Supabase with AI agents.

Agent Link is a [Claude Code plugin](https://docs.anthropic.com/en/docs/claude-code/plugins) with composable skills and an app development agent. Each skill covers a specific domain — CLI, schema development, RPCs, edge functions, auth, frontend — and Claude loads whichever skills are relevant to the current task automatically. The agent bundles all skills together with architecture enforcement.

It ships alongside the [`agentlink` CLI](https://www.npmjs.com/package/agentlink-sh) — the plugin's hands. The CLI scaffolds new Supabase projects (cloud or local Docker), manages multiple environments (`local` / `dev` / `prod`), applies schemas, generates migrations, and deploys schemas + edge functions to any cloud env. The agent reasons about *what* to build; the CLI does the work the agent shouldn't do itself — OAuth, project creation, environment switching, deploys.

---

## Install

```bash
# Recommended — install the CLI globally so you can use the bare `agentlink` command
npm install -g agentlink-sh@latest
agentlink <project-name>

# Or run once via npx (fine for trying it out)
npx agentlink-sh@latest <project-name>

# From the Claude Code plugin marketplace
/plugin marketplace add tomaspozo/agentlink
/plugin install link@agentlink

# Local directory (development)
claude --plugin-dir ./path/to/agentlink
```

After global install, every CLI command is just `agentlink <subcommand>` — `agentlink check`, `agentlink db apply`, `agentlink env deploy prod`, etc.

---

## Usage

Describe what you want to build and tell Claude to use Agent Link. The agent handles the rest — prerequisites, architecture, and the right skills for the job.

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

- `/link:cli` — `agentlink` commands, env management, deploys
- `/link:database` — schema files, migrations, type generation
- `/link:rpc` — RPC-first data access, CRUD templates, pagination
- `/link:edge-functions` — `withSupabase` wrapper, webhooks, secrets
- `/link:auth` — RLS policies, RBAC, multi-tenancy, invitation flows
- `/link:frontend` — Supabase client setup, RPC calls, auth state, SSR

---

## How It Works

Skills use progressive disclosure to keep context lean:

1. **Metadata** (~100 tokens per skill) — name + description, always in context
2. **SKILL.md** — loads when a skill triggers, contains the core workflow
3. **References** — loaded on demand from SKILL.md for detailed patterns
4. **Assets** — ready-to-copy SQL and TypeScript files dropped into projects

The `@link:builder` agent preloads all six domain skills and enforces architecture patterns. Individual skills can also be used standalone — Claude loads multiple skills simultaneously when a task spans domains.

---

## Agent Configuration

The app development agent ships with opinionated defaults:

### Setup

The CLI handles all project setup. The agent builds — it does not scaffold.

- **New project (cloud, default):** `agentlink my-app` — creates a Supabase Cloud project, scaffolds schemas, vault secrets, edge functions, and a frontend
- **Local Docker mode:** `agentlink my-app --local` — runs Supabase locally instead of cloud
- **Validate setup:** `agentlink check` — verifies extensions, internal functions, vault secrets, api schema, file layout
- **Re-apply managed resources:** `agentlink --force-update` — patches templates, config, and SQL after a CLI upgrade

### Cloud vs local mode

Cloud is the default. The CLI authenticates with Supabase via OAuth, creates a project in the user's chosen org/region, and stores credentials in `~/.config/agentlink/credentials.json`. Database operations go through the Supabase Management API; SQL runs against the connection pooler.

Local mode (`--local`) runs Supabase in Docker via `supabase start`. SQL executes via `psql` against `localhost:54322`, and a Supabase MCP server is installed at `http://localhost:54321/mcp` for migration and advisor tooling. The MCP server is **not** installed in cloud mode.

### Production guardrail

The agent deploys autonomously to `local` and `dev` environments — `agentlink db apply`, `env deploy dev`, `db migrate`, and `supabase functions deploy` all run without prompting. **Production is gated.** Any command targeting prod (`env deploy prod`, `env use prod`, `env add prod`, `db push` against a prod URL, `destroy`) requires explicit user approval at call time. Approval is per-command, not a blanket pass.

### Blocked commands

A PreToolUse hook (`hooks/block-destructive-db.sh`) blocks the agent from running:

- `npx supabase db reset` — destroys and recreates the local database
- `npx supabase db push --force` / `-f` — overwrites remote schema without diffing

If you need these, run them manually.

---

## Companion Skills

The CLI installs a curated set of companion skills automatically — the agent assumes they are present. To skip auto-install, pass `--no-skills` to `agentlink`.

**Auto-installed for every project:**

- `supabase/agent-skills@supabase-postgres-best-practices` (required)
- `anthropics/skills@frontend-design`
- `shadcn/ui`
- `vercel-labs/agent-skills@vercel-react-best-practices`
- `resend/react-email`, `resend/email-best-practices`, `resend/resend-skills`

**Auto-installed for Next.js projects (`--nextjs`):**

- `vercel-labs/next-skills --skill next-best-practices`

To install or update a companion skill manually:

```bash
npx skills add supabase/agent-skills@supabase-postgres-best-practices
```

---

## Contributing

Agent Link is open source. If you've found a pattern that works, a mistake agents keep making, or a gap — we want to hear about it.

## License

MIT
