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
npx create-agentlink@latest <name> --skip-env
# or for an existing directory:
npx create-agentlink@latest . --skip-env
```

This lays down the full project — templates, schemas, config, frontend, plugin, companion skills — and installs deps. No Supabase touching. Then hand off:

> "Scaffold done. Open a terminal in `<path>` and run `agentlink env add dev` to create the Supabase project. I can't do that step — it needs a browser for OAuth."

The scaffolded `CLAUDE.md` already surfaces this as a prominent "▶ Next step" callout, so the next session of Claude Code (or a different agent) will see it immediately.

**Commands — user running directly (cloud default)**

If the user is doing it themselves in a terminal:

```bash
npx create-agentlink@latest <name>
```

The wizard prompts for Supabase login (browser OAuth), org selection, region.

**Commands — user has credentials from Supabase connector MCP**

```bash
npx create-agentlink@latest <name> --link \
  --project-ref <ref> --db-url "<url>" --api-url "<api>" \
  --publishable-key "<anon>" --secret-key "<secret>"
```

**Commands — local Docker dev (no cloud)**

```bash
npx create-agentlink@latest <name> --local
```

Requires Docker running + `psql` installed. Prompts at `agentlink.sh/start` if missing.

**Watch-outs**

- `--skip-env`, `--link`, `--local` are mutually exclusive; pass only one.
- If `claude` or `supabase` isn't on PATH, point the user at `https://agentlink.sh/start` and tell them to open a new terminal after install.
- Do NOT run any `db apply` / `db sql` / `db migrate` / `deploy` commands on a `--skip-env`-scaffolded project before the user completes `env add dev` — the env doesn't exist yet.

---

## 2. Add a production environment

**Trigger:** user says "I want to deploy to prod," "add a production env," "set up prod," "ship this live."

**Questions to ask**

- **Does the prod cloud project already exist, or should we create a new one?** The CLI asks this in the wizard, but confirming up front lets you warn about data risk for existing.
- **Same Supabase org as dev, or different?** The picker shows cached orgs + an "Authorize a different organization" option. Different-org is common when dev is in a personal org and prod is in a company org.

**Commands**

```bash
npx create-agentlink@latest env add prod
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
npx create-agentlink@latest env use              # Interactive picker (✓ marks the current env)
npx create-agentlink@latest env use local        # Local Docker
npx create-agentlink@latest env use dev          # Cloud dev
npx create-agentlink@latest env use prod         # Cloud prod — requires y/N confirm
npx create-agentlink@latest env list             # See what's configured
```

`env use` rewrites the managed block of `.env.local` so `db apply` / `supabase functions serve` / `db sql` hit the right env, and persists `manifest.cloud.default` so subsequent commands resolve consistently. User-added env vars outside the block are preserved.

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
npx create-agentlink@latest env deploy

# Explicit target
npx create-agentlink@latest env deploy dev
npx create-agentlink@latest env deploy prod       # y/N confirm required

# Preview before shipping
npx create-agentlink@latest env deploy prod --dry-run

# CI-friendly
npx create-agentlink@latest env deploy prod --yes --non-interactive
```

What `env deploy` does:

1. Apply local schemas (`db apply`) to the target env's DB (explicit pooler URL — works correctly even when `.env.local` points elsewhere).
2. Deploy edge functions (`supabase functions deploy --project-ref <ref>`).

What it does NOT do — belongs elsewhere:

- **Vault secrets / PostgREST config / auth config.** If `supabase/config.toml` or auth providers changed, use `agentlink env add <name>` → "Re-apply full setup", or `agentlink config apply` for a targeted push.
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
npx create-agentlink@latest env add dev --retry
npx create-agentlink@latest env add prod --retry

# Recovery B: just need to re-apply schemas + functions (lighter)
npx create-agentlink@latest env deploy dev
npx create-agentlink@latest env deploy prod

# Recovery C: relink to a different project (or the project was deleted)
npx create-agentlink@latest env add dev          # interactive — pick "Relink"
npx create-agentlink@latest env add dev --project-ref <new-ref> --non-interactive

# Recovery D: stale DB URL
npx create-agentlink@latest db url               # See current vs expected
npx create-agentlink@latest db url --fix         # Rewrite .env.local with the right pooler URL

# Recovery E: just need to push config changes (no schema or function drift)
npx create-agentlink@latest config apply --auth  # Only auth config
npx create-agentlink@latest config apply --rest  # Only PostgREST config
npx create-agentlink@latest config apply         # Both

# Recovery F: broken migration state (duplicates, timestamp conflicts)
npx create-agentlink@latest db rebuild
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
npx create-agentlink@latest env add dev --project-ref <ref>

# Not scaffolded yet, but have all credentials
npx create-agentlink@latest <name> --link \
  --project-ref <ref> --db-url "..." --api-url "..." \
  --publishable-key "..." --secret-key "..."
```

**Watch-outs**

- If the user has a fresh scaffold from `--skip-env` and is ready to complete setup, this is exactly the `env add dev` step — no `--project-ref` needed if they want to create a new project (the wizard offers both).

---

## 7. Rotate a database password

**Trigger:** user says "I reset the DB password in the dashboard," "password changed," "`db apply` is failing with auth error."

**Questions to ask**

- None — the command does what's needed.

**Commands**

```bash
# Interactive — shows the dashboard reset link, then prompts for the new password
npx create-agentlink@latest db password

# Non-interactive
npx create-agentlink@latest db password "new-password-here"
```

**Watch-outs**

- Stores the password in `~/.config/agentlink/credentials.json` (per project ref, file mode 0600) — never in `.env.local`.
- If `.env.local`'s `SUPABASE_DB_URL` embeds the old password, run `env use <env>` (for the active env) or `env add <env> --retry` (non-interactive re-bootstrap) afterward to rewrite it.

---

## 8. Deploy from CI

**Trigger:** user asks for CI/CD setup, generates a GitHub Actions workflow, or wants to automate deploys.

**Questions to ask**

- **Which env(s)?** Usually prod on every main-branch push, sometimes dev on PRs.
- **Are `SUPABASE_ACCESS_TOKEN` and `SUPABASE_DB_PASSWORD` set as repo secrets?**

**Commands**

```bash
# Generate a GitHub Actions workflow for this env
npx create-agentlink@latest env add prod --setup-ci
npx create-agentlink@latest env add dev --setup-ci
```

The generator writes `.github/workflows/deploy-<env>.yml` using `env deploy <name> --yes --non-interactive`. Invoke exactly this form in custom CI workflows too:

```yaml
- name: Deploy to prod
  run: npx create-agentlink@latest env deploy prod --yes --non-interactive
  env:
    SUPABASE_ACCESS_TOKEN: ${{ secrets.SUPABASE_ACCESS_TOKEN }}
    SUPABASE_DB_PASSWORD: ${{ secrets.SUPABASE_DB_PASSWORD }}
```

**Watch-outs**

- `--yes` skips the prod confirmation prompt; `--non-interactive` fails fast on missing input instead of waiting for stdin. Both are mandatory in CI.
- `SUPABASE_ACCESS_TOKEN` must be a PAT (`sbp_...`) with admin access to the org — OAuth tokens from the user's laptop won't work in CI because they expire.
- Old workflows using `deploy --prod` / `deploy --ci` no longer work. Regenerate via `env add <env> --setup-ci` or update manually.

---

## What the agent does NOT do

- **Does not deploy.** Always point users at `agentlink env deploy` (interactive) or `agentlink env deploy <dev|prod>` (explicit).
- **Does not install tooling.** If Claude Code / Supabase CLI / psql is missing, point at `https://agentlink.sh/start`.
- **Does not create envs beyond dev/prod.** If the user asks for `staging`, explain the fixed model and ask what they actually need (usually a separate `prod` cloud project under a different org serves the "staging" role).
