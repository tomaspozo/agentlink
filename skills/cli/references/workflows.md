# Common Workflows

A flow-by-flow playbook for the scenarios users actually trigger. Each section has the same shape:

- **Trigger** — what the user says / what situation you're in
- **Questions to ask** — before running any command
- **Commands** — exact sequence to execute
- **Watch-outs** — common pitfalls

Use this as a lookup. When a user prompt matches a trigger below, follow that section end-to-end.

---

## 1. Start a new project from zero

**Trigger:** user says "I want to build a new app / SaaS / Supabase project," "start from scratch," "build me a [thing]," or is in an empty directory asking to begin.

**Questions to ask**

- **What are you building?** (A one-liner is fine — becomes the prompt passed to Claude Code.)
- **Frontend?** React + Vite (default), Next.js (`--nextjs`), or backend-only (`--no-frontend`).
- **Where?** New subdirectory (default, pass the project name) or the current directory (`.` as the name).

If the user asks to run the scaffold for them through you (agent-driven): you do NOT have browser access, so you can't complete Supabase OAuth. Use `--skip-env`.

**Commands — agent-driven (`--skip-env`)**

```bash
agentlink <name> --skip-env
# or for an existing directory:
agentlink . --skip-env
```

This lays down the full project — templates, schemas, config, frontend, plugin, companion skills — and installs deps. No Supabase touching. Then hand off:

> "Scaffold done. Open a terminal in `<path>` and run `agentlink env add dev` to create the Supabase project. I can't do that step — it needs a browser for OAuth."

The scaffolded `CLAUDE.md` already surfaces this as a prominent "▶ Next step" callout, so the next session of Claude Code (or a different agent) will see it immediately.

**Commands — user running directly (cloud default)**

If the user is doing it themselves in a terminal:

```bash
agentlink <name>
```

The wizard prompts for Supabase login (browser OAuth), org selection, region.

**Commands — user pastes existing credentials (advanced)**

User-driven only. Agents should use `--skip-env` above; never call MCP tools to fetch credentials themselves.

```bash
agentlink <name> --link \
  --project-ref <ref> --db-url "<url>" --api-url "<api>" \
  --publishable-key "<anon>" --secret-key "<secret>"
```

**Commands — local Docker dev (no cloud)**

```bash
agentlink <name> --local
```

Requires Docker running + `psql` installed. Prompts at `agentlink.sh/start` if missing.

**Watch-outs**

- `--skip-env`, `--link`, `--local` are mutually exclusive; pass only one.
- If `claude` or `supabase` isn't on PATH, point the user at `https://agentlink.sh/start` and tell them to open a new terminal after install.
- Do NOT run any `db apply` / `db sql` / `db migrate` / `deploy` commands on a `--skip-env`-scaffolded project before the user completes `env add dev` — the env doesn't exist yet.
- If the user has an existing codebase and explicitly doesn't want the AgentLink scaffold (schemas, RLS helpers, skills, etc.) — they just want env management — point them at workflow #7 (bare mode) instead of `--skip-env`. Bare mode doesn't touch the user's existing file structure beyond `agentlink.json` and `.env.local`.

---

## 2. Add a production environment

**Trigger:** user says "I want to deploy to prod," "add a production env," "set up prod," "ship this live."

**Questions to ask**

- **Does the prod cloud project already exist, or should we create a new one?** The CLI asks this in the wizard, but confirming up front lets you warn about data risk for existing.
- **Same Supabase org as dev, or different?** The picker shows cached orgs + an "Authorize a different organization" option. Different-org is common when dev is in a personal org and prod is in a company org.

**Commands**

```bash
agentlink env add prod
```

Interactive flow:

1. Clean-tree check (use `--allow-dirty` to bypass — rare).
2. Org picker: shows API-visible + cached orgs + "+ Authorize a different organization…"
3. "Connect existing" or "Create new" project — picks inside the chosen org.
4. Deploy prompt (default Yes) — runs the full bootstrap: migrations push, vault secrets, edge functions, PostgREST + auth config.

**Watch-outs**

- Only `dev` and `prod` are valid names for `env add`. `staging`, `dev2`, `production` will error immediately.
- `env add prod` never activates prod as the working env — prod is deploy-only. After it succeeds, the active dev env remains whatever it was before.
- If the target prod project already has data in `public` / `api` schemas, the CLI prompts a safety confirmation (default No). `--force` skips the prompt — use sparingly.
- For CI / non-interactive: `env add prod --project-ref <ref> --non-interactive`.

---

## 3. Switch active dev environment

**Trigger:** user says "work locally," "go offline," "switch to local Docker," "switch back to the cloud dev env," "use dev," "use prod locally for a quick check."

**Questions to ask**

- None for `local` / `dev` — but if the user wants `prod`, double-check before running. The CLI's confirmation prompt handles it, but expectations matter.
- If switching to `local`, confirm Docker is running.

**Commands**

```bash
agentlink env use              # Interactive picker (✓ marks the current env)
agentlink env use local        # Local Docker
agentlink env use dev          # Cloud dev
agentlink env use prod         # Cloud prod — requires y/N confirm
agentlink env list             # See what's configured
```

`env use` rewrites the managed block of `.env.local` so `db apply` / `supabase functions serve` / `db sql` hit the right env, and persists `manifest.cloud.default` so subsequent commands resolve consistently. User-added env vars outside the block are preserved.

**Refreshing `.env.local` for the active env**: `env use <same-env>` doubles as a refresh verb. Re-fetches API keys (after a key rotation in the Supabase dashboard), re-resolves the pooler URL, and rewrites the managed block. Output reads `Refreshed <name>` instead of `Switched to <name>`. No prod confirmation on this path — you're already on prod. Use this when `.env.local` looks stale or after the user resets the DB password / rotates a key.

**Watch-outs**

- `env use prod` is **allowed** but requires explicit confirmation — the CLI prints an amber warning (`▲ Using prod as your active dev environment is NOT recommended`) and prompts `Continue? (y/N)` with default No. If the user just wants to deploy to prod without making it their active env, suggest `agentlink env deploy prod` instead (a one-shot action that doesn't touch `.env.local` or `cloud.default`).
- Once `cloud.default === "prod"`, every subsequent `env deploy` / `db apply` / `db sql` / `db rebuild` prints an `▲ Active env: prod` banner at the top. Tell users that's expected — it's a persistent reminder that their next data-touching command hits production.
- The `env use` picker hides `local` on cloud-only projects (projects scaffolded without `--local`, where the active env isn't already local). If the user insists on jumping to local Docker anyway, explicit `agentlink env use local` still works.
- If switching to `local`, the user still needs to run `supabase start` to bring up the Docker stack.

---

## 4. Ship changes to production

**Trigger:** user says "deploy," "push to prod," "ship it," "release."

**Questions to ask**

- **Schema changes only, or does auth / PostgREST config / vault secrets also need to go?** Plain changes → `env deploy`. Config changes → `env add <name>` → "Re-apply full setup".
- **Dev or prod?** `env deploy` prompts with a picker (preselects the active env), so this is low-stakes, but knowing the intent informs the answer if there's ambiguity.

**Commands**

```bash
# Interactive picker — preselects cloud.default
agentlink env deploy

# Explicit target
agentlink env deploy dev
agentlink env deploy prod       # y/N confirm required

# Preview before shipping
agentlink env deploy prod --dry-run

# CI-friendly
agentlink env deploy prod --yes --non-interactive
```

What `env deploy` does (each step is gated on the corresponding `supabase/` directory existing):

1. **Migrations** — `supabase db push --db-url <pooler>` if `supabase/migrations/` and `supabase/config.toml` both exist. Idempotent; Supabase tracks applied entries server-side. Skipped with a loud amber warning if migrations exist but `config.toml` doesn't (bare-with-hand-created-migrations edge case — we never silently fabricate `config.toml` into a user's tree).
2. **Schemas** — `db apply` against the target env's DB (explicit pooler URL — works correctly even when `.env.local` points elsewhere).
3. **Functions** — `supabase functions deploy --project-ref <ref>` if `supabase/functions/` exists with non-underscore subdirectories.

If ALL three directories are missing (bare project with an empty `supabase/` tree), `env deploy` short-circuits with `Nothing to deploy — no supabase/schemas, supabase/migrations, or supabase/functions found.` and exits 0.

What it does NOT do — belongs elsewhere:

- **Vault secrets / PostgREST config / auth config.** If `supabase/config.toml` or auth providers changed, use `agentlink env add <name>` → "Re-apply full setup" for the full reset, or `agentlink env config [secrets|db|auth|all] [env-name]` for a targeted push of just the drifted subsystem. `env config` is cloud-only, idempotent, and works on bare projects. Positional env name matches the rest of the env group (`env config secrets prod`).
- **Generate a migration file.** Use `db migrate <name>` explicitly when you want an auditable artifact committed to `supabase/migrations/`.
- **Clean-tree gate.** `env deploy` is safe on dirty trees — no migration diff is generated. (The clean-tree gate still applies to `env add` / `env relink` / `--force-update`.)
- **Data-risk analysis.** If the user wants that, point them at `db migrate` + manual review of the generated SQL.

**Watch-outs**

- **Deploy does NOT change the active env.** `env use dev && env deploy prod` leaves the active env on dev. If the user wants to do follow-up queries against prod, they need `env use prod` explicitly.
- The top-level `agentlink deploy` command has been removed — the CLI errors with a pointer at `agentlink env deploy` if someone tries the old form. Same for `agentlink retry-deploy`.
- The agent never runs `env deploy` autonomously. Point the user at the command; don't execute it yourself.

---

## 5. Recover from a failed deploy / missing cloud project / wrong DB URL

**Trigger:** user says "my deploy died halfway," "env add failed," "connection refused," "cloud project was deleted," "wrong DB URL," "auth config isn't taking."

**Questions to ask** (decision tree)

- **Did a previous `env add` / `env deploy` fail mid-bootstrap, or did auth providers / PostgREST config change?** (manifest has the env but the cloud project is partially set up, OR config drift) → full re-apply (`env add <name>` → "Re-apply full setup", or `--retry` non-interactively).
- **Just schema / edge function drift** (config is fine, only the tables or functions need to catch up)? → `env deploy <name>` (lighter, idempotent).
- **Was the cloud project deleted, or do you want to point at a different one?** → full relink (re-run `env add <name>`, pick "Relink to a different project").
- **Is the DB URL in `.env.local` stale?** (connection errors but project exists) → `db url --fix`.
- **Credentials no longer accepted** (`Forbidden` / 403)? — the CLI handles this automatically on newer versions; if on older, upgrade.

**Commands**

```bash
# Recovery A: mid-bootstrap failure OR config drift against the SAME project
# (Re-runs schemas + functions + vault + PostgREST + auth + verify)
agentlink env add dev --retry
agentlink env add prod --retry

# Recovery B: just need to re-apply schemas + functions (lighter)
agentlink env deploy dev
agentlink env deploy prod

# Recovery C: relink to a different project (or the project was deleted)
agentlink env add dev          # interactive — pick "Relink"
agentlink env add dev --project-ref <new-ref> --non-interactive

# Recovery D: stale DB URL
agentlink db url               # See current vs expected
agentlink db url --fix         # Rewrite .env.local with the right pooler URL

# Recovery E: just need to push config changes (no schema or function drift)
# `env config` is the replacement for the removed `config apply` command.
# Three independent subsystems; pick the one that drifted or use `all`.
# Shape: env config [subcommand] [env-name] — both positional, --env flag still accepted.
agentlink env config secrets prod   # Postgres Vault (SUPABASE_URL / publishable / secret) on prod
agentlink env config auth dev       # Only auth config (hooks + signup) on dev
agentlink env config db prod        # Only PostgREST (expose api schema) on prod
agentlink env config all prod       # All three on prod (prompts for y/N)
agentlink env config prod           # Env=prod, subcommand picker runs
agentlink env config                # Both pickers (subcommand + env)

# Recovery F: broken migration state (duplicates, timestamp conflicts)
agentlink db rebuild
```

**Watch-outs**

- `--retry` (or picking "Re-apply full setup" interactively) requires the env to already exist in the manifest — it re-runs the full bootstrap against the stored `projectRef` without touching the manifest or `.env.local`.
- The "Re-apply full setup" path IS heavier than `env deploy`. For routine schema/function pushes, `env deploy` is the right call — the interactive menu hints at this above the options.
- Full relink overwrites `.env.local`'s managed block — preserved user vars outside the block survive.
- `db rebuild` deletes and regenerates migration files; safe on new projects, destructive if you've already pushed hand-edited migrations.

---

## 6. Connect an existing Supabase project without a full scaffold

**Trigger:** user already has a Supabase project (created via dashboard / via another tool) and wants AgentLink to pick it up. Or the user re-cloned the repo and needs to re-link.

**Questions to ask**

- **Is the project already scaffolded (has `agentlink.json`)?** If yes, `env add dev` is the right command. If no, use `--link` during scaffold.
- **Do you have the project ref + DB password?** `env add dev` prompts for the password interactively. `--non-interactive` expects `SUPABASE_DB_PASSWORD` in env.

**Commands**

```bash
# Already scaffolded, just need to register an env
agentlink env add dev --project-ref <ref>

# Not scaffolded yet, but have all credentials
agentlink <name> --link \
  --project-ref <ref> --db-url "..." --api-url "..." \
  --publishable-key "..." --secret-key "..."
```

**Watch-outs**

- If the user has a fresh scaffold from `--skip-env` and is ready to complete setup, this is exactly the `env add dev` step — no `--project-ref` needed if they want to create a new project (the wizard offers both).
- If the user DOESN'T want the AgentLink scaffold at all — just Supabase env plumbing in their own codebase — use bare mode (workflow #7 below) instead of `--link`. Bare mode doesn't touch the user's file structure beyond writing `agentlink.json` and `.env.local`.

---

## 7. Bare mode — Supabase env management on an existing codebase

**Trigger:** user says "I already have a Next.js/Vite app, I just want AgentLink to manage my Supabase env," "don't scaffold anything, just wire up the env," "use AgentLink's env commands on my existing project," or runs `agentlink env add` in a directory that has no `agentlink.json`.

**Questions to ask**

- **Dev or prod?** Same as regular `env add`.
- **Which Supabase organization?** Same org picker as scaffolded flow.
- **Is this the right trade-off?** Bare mode gives up: the scaffolded `api` schema isolation, RLS helpers, RPC layout, auth hooks, edge-function wrappers, companion skills, and the opinionated `supabase/schemas/` layout. If the user wants any of those, point them at the full scaffold (workflow #1) or `--force-update` to upgrade a bare project later.

**Commands**

```bash
cd my-existing-app
agentlink env add dev
```

Interactive flow when no `agentlink.json` is present:

```
▲ No agentlink.json found in this directory.

  Agent Link's full scaffold gives you:
    • RLS + multi-tenant auth helpers, wired in from day one
    • RPC-first data layer (api schema + typed client)
    • Edge-function wrappers for webhooks and external APIs
    • Opinionated schema file layout + idempotent db apply
    • Claude Code skills that teach an agent how to build on all of it

  More at https://agentlink.sh

? How would you like to continue with env add dev?
  ❯ Run the full Agent Link scaffold (recommended)
    Continue without full features
    Cancel
```

- **Full scaffold** → aborts; user runs `agentlink my-app` in a fresh dir or `agentlink .` in this one (clean-tree required).
- **Continue without full features** → writes a minimal `agentlink.json` with `bare: true`, runs the full Supabase flow (OAuth → org pick → project select/create → credentials → `.env.local`). No schemas applied, no server-side config, no `CLAUDE.md` touched.

**What works in bare mode afterward**

| Command | Behavior |
|---------|----------|
| `env add` / `env use` / `env remove` / `env list` | Normal, but `env use` / `env add` skip CLAUDE.md writes. |
| `env config [secrets\|db\|auth\|all] [env]` | Primary way to add server-side config incrementally. |
| `env deploy [env]` | No-op until the user drops files into `supabase/migrations/`, `supabase/schemas/`, or `supabase/functions/`. Each step gates on its directory. |
| `db password` / `db url` | Normal. |
| `db apply` | Prints `Skipping schema apply — supabase/schemas/ not found.` and exits 0. |

**Upgrade path**

```bash
agentlink --force-update
```

Converts a bare project to the full scaffold: re-applies template files, generates migrations, runs the setup SQL. Requires a clean git tree.

**Watch-outs**

- Bare mode does NOT run `bootstrapCloudEnv` at `env add` time — the Supabase project is created but vault secrets / PostgREST / auth config are NOT applied. If the user later wants any of those, `agentlink env config all [env]` applies them without touching schemas.
- The `bare: true` flag in `agentlink.json` is orthogonal to `mode`. `setDefaultEnvironment` flips `mode` to `"cloud"` on first `env add dev`, but `bare` persists — that's how `env use` etc. continue to respect the bare boundary across every subsequent command.
- On bare projects, `env config auth` will apply `AUTH_CONFIG` with hook references to pg-functions that don't exist (`_hook_before_user_created`, `_hook_send_email`). Supabase's API returns a clear error — at that point the user either upgrades via `--force-update` or drops in their own hook functions first.

---

## 8. Rotate a database password

**Trigger:** user says "I reset the DB password in the dashboard," "password changed," "`db apply` is failing with auth error."

**Questions to ask**

- None — the command does what's needed.

**Commands**

```bash
# Interactive — shows the dashboard reset link, then prompts for the new password
agentlink db password

# Non-interactive
agentlink db password "new-password-here"
```

**Watch-outs**

- Stores the password in `~/.config/agentlink/credentials.json` (per project ref, file mode 0600) — never in `.env.local`.
- If `.env.local`'s `SUPABASE_DB_URL` embeds the old password, run `env use <env>` (for the active env) or `env add <env> --retry` (non-interactive re-bootstrap) afterward to rewrite it.

---

## 9. Deploy from CI

**Trigger:** user asks for CI/CD setup, generates a GitHub Actions workflow, or wants to automate deploys.

**Questions to ask**

- **Which env(s)?** Usually prod on every main-branch push, sometimes dev on PRs.
- **Are `SUPABASE_ACCESS_TOKEN` and `SUPABASE_DB_PASSWORD` set as repo secrets?**

**Commands**

```bash
# Generate a GitHub Actions workflow for this env
agentlink env add prod --setup-ci
agentlink env add dev --setup-ci
```

The generator writes `.github/workflows/deploy-<env>.yml` using `env deploy <name> --yes --non-interactive`. Invoke exactly this form in custom CI workflows too:

```yaml
- name: Deploy to prod
  run: agentlink env deploy prod --yes --non-interactive
  env:
    SUPABASE_ACCESS_TOKEN: ${{ secrets.SUPABASE_ACCESS_TOKEN }}
    SUPABASE_DB_PASSWORD: ${{ secrets.SUPABASE_DB_PASSWORD }}
```

**Watch-outs**

- `--yes` skips the prod confirmation prompt; `--non-interactive` fails fast on missing input instead of waiting for stdin. Both are mandatory in CI.
- `SUPABASE_ACCESS_TOKEN` must be a PAT (`sbp_...`) with admin access to the org — OAuth tokens from the user's laptop won't work in CI because they expire.
- Old workflows using `deploy --prod` / `deploy --ci` no longer work. Regenerate via `env add <env> --setup-ci` or update manually.

---

## 10. Snapshot an env before a risky change

**Trigger:** user says "back up before I run this," "snapshot prod," "I'm about to do something destructive," or anytime they're about to apply a migration that drops/renames/truncates, change auth config in a way that could lock them out, run `db rebuild` against a non-empty cloud env, or delete a noticeable chunk of data.

**Questions to ask**

- **Which env?** Usually the one they're about to change. The active env (`cloud.default`) is the default if they don't say.
- **Local or cloud?** Doesn't really matter — `db backup` works on both. Local snapshots are mostly useful for verifying the backup command itself before pointing it at prod.

**Commands**

```bash
# Active env (cloud.default if cloud, else local)
agentlink db backup

# Explicit target — most useful before touching prod
agentlink db backup --env prod
agentlink db backup --env dev

# Override URL entirely (e.g., backing up a non-registered project)
agentlink db backup --db-url "postgresql://postgres.[ref]:[pwd]@aws-0-[region].pooler.supabase.com:5432/postgres"
```

What it does:

1. Resolves the DB URL via the standard ladder (`--db-url` flag → `cloud.environments[env]` pooler URL → `.env.local` → `supabase status`).
2. Creates `supabase/backups/<env>/<YYYY-MM-DDTHH-MM-SS>/` (UTC, dashes instead of colons for Windows compatibility).
3. On first run only, appends `supabase/backups/` to the project's root `.gitignore` under an "Agent Link — database backups" comment. Idempotent on re-runs.
4. Runs three `supabase db dump` invocations: roles, schema, data (excluding `storage.buckets_vectors` / `storage.vector_indexes`). Each in its own spinner step.
5. Prints file sizes at the end so the user can spot silent-empty failures.

**Watch-outs**

- **Snapshots may contain real production data.** They're gitignored by default; never `git add -f` them.
- **Each run creates a NEW timestamped subdirectory.** Previous backups survive. Old ones accumulate over time — users prune manually (`rm -rf supabase/backups/<env>/<old-timestamp>/`).
- **No `db restore` command exists.** Restoring is a separate problem with its own safety story (does it wipe the target? merge? fail on conflicts?). To restore manually: `psql <other-db-url> -f supabase/backups/<env>/<ts>/schema.sql` then `data.sql`. The agent should NOT run that autonomously — restoration is a developer-initiated action.
- **The exclusion list is fixed** at the two `storage.*` tables Supabase recommends excluding. If the user has other huge tables they want skipped, point them at `supabase db dump` directly with custom `-x` flags — `db backup` is opinionated by design.
- **The agent does NOT run `db backup` autonomously before destructive changes.** It's safe (read-only) but reading prod data is still a meaningful action, and the user should choose to do it. The agent's job is to point them at the command when the situation warrants it.

---

## What the agent does NOT do

- **Does not deploy.** Always point users at `agentlink env deploy` (interactive) or `agentlink env deploy <dev|prod>` (explicit).
- **Does not install tooling.** If Claude Code / Supabase CLI / psql is missing, point at `https://agentlink.sh/start`.
- **Does not create envs beyond dev/prod.** If the user asks for `staging`, explain the fixed model and ask what they actually need (usually a separate `prod` cloud project under a different org serves the "staging" role).
