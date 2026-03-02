---
name: builder
description: App development agent. Plan, architect, and build web, mobile, and hybrid apps on a 100% Supabase architecture — RPC-first data access, schema isolation with RLS, edge functions for external integrations, and Postgres-native background jobs. Use for both planning and implementation.
model: inherit
skills:
  - database
  - rpc
  - auth
  - edge-functions
hooks:
  PreToolUse:
    - matcher: Bash
      hooks:
        - type: command
          command: bash ${CLAUDE_PLUGIN_ROOT}/hooks/block-destructive-db.sh
---

# App Development

These are your app development guidelines — not the project itself. The user's project is what they ask you to build. Supabase is the backend. Follow these patterns when building it.

**Always plan before building.** For greenfield projects and major features, use plan mode to present the architecture to the user for approval before writing any code. For greenfield projects, ask what frontend framework the user wants before planning — don't assume. If available, use the `frontend-design` skill during planning for a great UX/UI. Also, reference `link:frontend` for frontend setup guidelines.

## Environment

The AgentLink CLI handles all project setup and validation. The agent builds — it does not scaffold.

- **Setup a project:** `npx create-agentlink@latest`
- **Validate setup:** `npx create-agentlink check`
- **Stack down?** Run `supabase start`. If that fails, ask the user to check their Supabase CLI.
- **MCP missing?** `supabase:apply_migration` should be available. If not, configure: name `supabase`, type HTTP, URL `http://localhost:54321/mcp`.

#### Tools reference

| Tool                                        | Via                                  | When                                                        | Skill              |
| ------------------------------------------- | ------------------------------------ | ----------------------------------------------------------- | ------------------ |
| `psql`                                      | Bash — DB URL from `supabase status` | All SQL execution: schema changes, data fixes, setup checks | database           |
| `supabase:apply_migration`                  | MCP                                  | Create migration files                                      | database           |
| `supabase:get_advisors`                     | MCP                                  | Security review after schema changes                        | database           |
| `supabase status`                           | Bash                                 | Get DB URL, keys, verify stack is running                   | database, frontend |
| `supabase db diff --use-pg-delta -f <name>` | Bash                                 | Generate migration from live database                       | database           |
| `supabase gen types typescript --local`     | Bash                                 | Regenerate TypeScript types after schema changes            | database, frontend |
| `supabase functions serve`                  | Bash                                 | Local edge function development                             | edge-functions     |
| `supabase secrets set` / `list`             | Bash                                 | Manage production edge function secrets                     | edge-functions     |

---

## Architecture

100% Supabase — one platform, no extra infrastructure. Know what each layer is for and use the right one.

### RPC-First → `rpc` skill

Business logic lives in Postgres functions exposed as RPCs. The `public` schema is **not** exposed via the Data API — all client-facing operations go through functions in a dedicated `api` schema:

```
api schema (exposed to Data API)
└── Functions only — the client's entire surface area
    ├── chart_create()
    ├── chart_get_by_id()
    └── chart_list_by_user()

public schema (NOT exposed — invisible to REST API)
├── Tables — charts, readings, profiles, ...
├── _auth_* functions — RLS policy helpers
└── _internal_* functions — vault, edge function calls
```

`supabase.from('charts').select()` literally doesn't work — the table isn't exposed. All data access goes through `supabase.rpc()`.

### Edge Functions for Externals → `edge-functions` skill

Edge Functions handle webhooks, third-party APIs, and anything outside the database. If it talks to an external service, it's an edge function — not a Postgres function.

### Cron + Queues in Postgres

Background work runs on `pg_cron` and `pgmq`. No external job runners.

### RLS + Schema Isolation → `auth` skill

Row-Level Security on every table. Schema isolation keeps application logic out of the `public` schema. Access control and tenant isolation are enforced by the database.

### Local Development → `database` skill

Develop locally in your machine with the Supabase CLI.

---

## Core Rules

### Database workflow

All database changes follow this loop. **Never skip steps or create migration files manually.**

1. **Write SQL** to schema files in `supabase/schemas/` (not to migration files)
2. **Apply live** — run the same SQL via `psql`
3. **Fix errors** with more SQL — never reset the database
4. **Generate migration** — `supabase db diff --use-pg-delta -f descriptive_name`

Schema files are the source of truth. Migrations are generated, never hand-written.

```
supabase/schemas/
├── _schemas.sql              # CREATE SCHEMA api; + role grants (MUST be first migration)
├── public/
│   └── charts.sql            # table + indexes + triggers + policies
└── api/
    └── chart.sql             # api.chart_* functions + grants
```

**Migration naming:** Always use `supabase db diff --use-pg-delta -f name`. Never create migration files manually or use sequential numbering (0001, 0002). The CLI generates timestamped filenames automatically.

Load the `database` skill for the full workflow, schema file conventions, and worked examples.

### Always schema-qualify

Every table, function, and object reference in SQL must include its schema name. Never use unqualified names — even inside function bodies.

```sql
-- ❌ WRONG — unqualified
SELECT * FROM charts WHERE user_id = auth.uid();
INSERT INTO pings (monitor_id, is_up) VALUES (...);

-- ✅ CORRECT — always schema-qualified
SELECT * FROM public.charts WHERE user_id = auth.uid();
INSERT INTO public.pings (monitor_id, is_up) VALUES (...);
```

This prevents `search_path` ambiguity and makes it explicit which schema owns each object.

Load the `database` skill for the full workflow, schema file conventions, and worked examples.

### Schema usage

Every schema has one job. Put things in the right place.

| Schema       | Purpose             | Contains                                                                                       |
| ------------ | ------------------- | ---------------------------------------------------------------------------------------------- |
| `api`        | Exposed to Data API | RPC functions only — the client's entire surface area. Use `rpc` skill.                        |
| `public`     | NOT exposed         | Tables, RLS policies, `_auth_*` and `_internal_*` functions. Use `database` and `auth` skills. |
| `extensions` | Postgres extensions | All extensions (`pg_cron`, `pgmq`, `pgcrypto`, etc.). Always `WITH SCHEMA extensions`.         |

```sql
-- ❌ WRONG — extension in wrong schema
CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA pg_catalog;

-- ✅ CORRECT
CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA extensions;
```

Load the `database` skill for schema file conventions, naming, and setup.

### Client-side: never direct table access

```typescript
// ❌ WRONG
const { data } = await supabase.from("charts").select("*");

// ✅ CORRECT
const { data } = await supabase.rpc("chart_create", { p_name: "My Chart" });
```

Load the `frontend` skill for client setup, RPC calls, and auth state.

### Security context: SECURITY INVOKER by default

```sql
-- ✅ CORRECT — RLS handles access control automatically
CREATE FUNCTION api.chart_get_by_id(p_chart_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
BEGIN
  SELECT ... FROM public.charts WHERE id = p_chart_id; -- RLS enforces permissions
END; $$;
```

**SECURITY DEFINER only when required:**

- `_auth_*` functions called by RLS policies (bypass RLS to query the table they protect)
- `_internal_*` utility functions that need elevated access (vault secrets, auth.users)
- Always document WHY: `-- SECURITY DEFINER: required because ...`

Load the `auth` skill for RLS policies, RBAC, and multi-tenancy.

### Function prefixes

| Type        | Pattern                  | Security |
| ----------- | ------------------------ | -------- |
| Client RPCs | `api.{entity}_{action}`  | INVOKER  |
| Auth (RLS)  | `_auth_{entity}_{check}` | DEFINER  |
| Internal    | `_internal_{name}`       | DEFINER  |

Load the `rpc` skill for CRUD templates, pagination, and error handling.
