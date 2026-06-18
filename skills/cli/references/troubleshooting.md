# CLI Troubleshooting

## Common Errors

### `42501 permission denied for table public.<name>` (RPC fails / "GRANT … TO authenticated")

**Cause:** Supabase stopped auto-granting table privileges to `anon`/`authenticated`/`service_role` on `public` (default changed 2026; new cloud projects, and existing projects' future tables from Oct 30 2026). The `api.*` RPCs are `SECURITY INVOKER`, so they touch `public` tables **as the caller** — which now has no privilege. Grants are a layer separate from RLS: the grant decides whether the role can touch the table at all; RLS decides which rows.

**This is expected default-deny behavior** — AgentLink does **not** auto-grant tables. The table is missing its explicit grant.

**Fix:** add the grant to the table's schema file (bundled with `ENABLE ROW LEVEL SECURITY`), then `db apply`:
```sql
GRANT SELECT, INSERT, UPDATE, DELETE ON public.<table> TO authenticated, service_role;
-- read-only reference table → GRANT SELECT to authenticated, full to service_role.
-- internal table only touched by DEFINER/service code → grant NOTHING (stays private).
```
`db apply` applies it on dev; `db migrate` carries it into the migration so it reaches prod (`db push`). Never grant `anon` (anon-facing RPCs are `SECURITY DEFINER`).

To unblock an existing table immediately without editing files:
```sql
grant select, insert, update, delete on public.<table> to authenticated, service_role;
```

See the `database` skill's table-privileges rule and the `auth` skill's Security Model.

---

### `db migrate` says "No changes detected" (or wrote a migration containing that text)

**Cause:** `db migrate` diffs a **migrations-only baseline** against the schema files. The baseline must come from replaying `supabase/migrations/` — **not** the live dev DB, which `db apply` has already converged to the schema files. If a clean baseline can't be built, no diff is found. (An older CLI diffed the live DB against itself and emitted an empty migration whose body was the literal text "No changes detected." — that bug is fixed.)

**This is NOT a signal to hand-author the migration.** First make sure a baseline source is available:

- **Local / cloud-dev with Docker:** ensure Docker is running. `db migrate` spins a short-lived throwaway Supabase stack from your migration files to build the baseline. Confirm the change is actually in a schema file and was applied (`db apply`) so the desired state reflects it.
- **No Docker, cloud:** `db migrate` falls back to a read-only `prod` (baseline) → `dev` (desired) catalog diff. This needs **both** a `prod` and a `dev` env registered. Verify prod is current with all committed migrations (`supabase migration list --linked`), or its catalog will be stale and the diff may re-include already-migrated objects.

**Genuinely empty?** If the baseline built cleanly and the diff is still empty, the migrations already capture your schema — nothing to do. Only when `db migrate` prints `▲ Could not build a clean migration baseline` (no Docker AND no prod+dev) should you author the migration by hand — see "Manual Migration Operations" below.

---

### `schema "api" does not exist` during `db diff`

**Cause:** `schema_paths` in `config.toml` doesn't cover the schema files, or `database/schemas/api/schema.sql` doesn't exist on disk. The shadow database can't build because schema files reference `api.*` objects but the schema was never created.

**Fix:**
```toml
# config.toml should use the recursive glob over supabase/database/:
[db.migrations]
schema_paths = ["./database/**/*.sql"]
```
Also verify `supabase/database/schemas/api/schema.sql` exists on disk (pg-delta topo-sorts statements, so the `api` schema gets created before objects that reference it). Run `npx agentlink-sh@latest --force-update` to regenerate it.

---

### `function already exists with same argument types` during migration

**Cause:** Running `npx supabase migration up` or `npx supabase db reset` on a database where objects already exist. Schema files use `CREATE OR REPLACE` (idempotent), but generated migrations may use plain `CREATE`.

**Fix:** Don't use `migration up` to apply SQL on a running local DB where objects exist. Use `psql` to apply schema files directly:
```bash
psql <db_url> -f supabase/database/schemas/public/tables/my_entity.sql
```
Or use `runSQL` via the CLI. Migrations are for production deployments on clean databases.

---

### `duplicate key value violates unique constraint "schema_migrations_pkey"`

**Cause:** Two migration files have the same timestamp. This can happen when template migrations and `db diff` generate files within the same second.

**Fix:** Rename one of the conflicting files to use a different timestamp:
```bash
# Find the duplicates
ls supabase/migrations/ | sort
# Rename one — change the timestamp (increment by 1 second)
mv supabase/migrations/20240101120000_foo.sql supabase/migrations/20240101120001_foo.sql
# Repair if needed
npx supabase migration repair 20240101120001 --status applied --local
# Cloud: use --linked instead of --local
```

---

### `extension "pg_net" already exists, skipping`

**Harmless NOTICE.** Supabase pre-installs `pg_net`. The `CREATE EXTENSION IF NOT EXISTS` in the infrastructure migration correctly skips it. No action needed.

---

### `trigger does not exist, skipping`

**Harmless NOTICE.** Comes from `DROP TRIGGER IF EXISTS` statements in auth trigger migrations. These clean up legacy trigger names before creating the current ones. No action needed.

---

### Migration ordering issues

**Symptom:** `npx supabase db reset` or `npx supabase start` fails because a migration references an object that doesn't exist yet.

**Common causes:**
- Post-setup migrations have timestamps *before* the `agentlink_setup` migration (they must come after)
- A function is referenced by a trigger migration but the function's migration hasn't run yet

**Fix:** Check migration file timestamps with `ls supabase/migrations/ | sort`. Ensure:
1. `agentlink_infrastructure` is first (extensions, schemas)
2. `agentlink_setup` is next (tables, functions, policies — generated by `db diff`)
3. `agentlink_queues` and `agentlink_auth_triggers` come after setup

If ordering is wrong, rename files to fix timestamps and repair:
```bash
npx supabase migration repair <old_version> --status reverted --local
npx supabase migration repair <new_version> --status applied --local
# Cloud: use --linked instead of --local
```

---

### `db rebuild` fails (migration replay)

**Cause:** `db rebuild` runs `supabase db reset` first; usually a migration ordering problem or a migration referencing a non-existent object.

**Diagnosis:**
1. Read the error — it tells you which migration failed and why
2. `ls supabase/migrations/ | sort` — check ordering
3. Look for references to functions/tables that are defined in later migrations

**Fix:** Fix the ordering (see above) or merge the problematic migrations. As a last resort, delete all migrations and regenerate:
```bash
rm supabase/migrations/*.sql
npx agentlink-sh@latest --force-update
```

---

### After `supabase db reset`, custom roles / cron jobs / storage buckets are gone

**Symptom:** A raw `supabase db reset` leaves the database missing your custom roles or permissions (membership role dropdowns empty, `auth_verify_access` failing), the queue cron job, or storage buckets/policies.

**Cause:** `supabase db reset` replays **migrations only**. The imperative resources in `supabase/database/{rbac,cron,storage}/` are deliberately **excluded from migrations** (RBAC is reference data; pg-delta filters the cron + storage schemas out of plans). The migration replay restores the *baseline* defaults but not anything you added after scaffold.

**Fix:** Use `db rebuild` instead of a raw reset — it replays migrations **and** re-applies the schema files + imperative resources in one step:
```bash
npx agentlink-sh@latest db rebuild
```
If you already ran a raw `supabase db reset`, just run `npx agentlink-sh@latest db apply` to restore them (it runs the same imperative step). Local-only; the agent is blocked from running `db rebuild` or a raw reset directly — resets are user-initiated.

---

## Supabase & DB Connection Issues

### DB URL is wrong / connection refused

**Symptom:** `db apply` or `db sql` fails with connection errors, timeouts, or "Invalid URL".

**Fix:**
```bash
npx agentlink-sh@latest db url --fix
```
Fetches the correct pooler URL from the Supabase Management API and updates `.env.local`. Run `db url` (without `--fix`) first to see the current vs expected URL.

---

### Vault secret duplicate key error

**Symptom:** `duplicate key value violates unique constraint "secrets_name_idx"` during scaffold setup.

**Cause:** Scaffold ran multiple times on the same cloud project. The CLI now uses `vault.update_secret()` for existing secrets (fixed in v0.11.1+). If you're on an older version, update the CLI.

**Fix:** Update to the latest CLI version and re-run. The vault upsert handles this automatically.

---

### Duplicate migration files from repeated scaffold runs

**Symptom:** Multiple `agentlink_setup.sql` files in `supabase/migrations/` with different timestamps. `npx supabase db push` may fail.

**Cause:** Each scaffold run created a new setup migration instead of detecting the existing one. Fixed in v0.11.1+, but if you already have duplicates:

**Fix:**
```bash
npx agentlink-sh@latest db rebuild
```
Deletes all migration files, re-applies schemas, and regenerates a single clean migration.

---

### `npx supabase db push` fails with "Remote migration versions not found"

**Symptom:** `Remote migration versions not found in local migrations directory` — the cloud database has migration versions that don't exist locally.

**Cause:** Migration files were recreated with new timestamps (from repeated scaffold runs), so the remote versions no longer match local files.

**Fix:**
```bash
# Option 1: Full rebuild (easiest for new projects)
npx agentlink-sh@latest db rebuild

# Option 2: Manual repair (if you need to keep specific migrations)
npx supabase migration repair --status reverted <version1> <version2> ...
```

---

### Cloud project was deleted / need to point at a different project

**Symptom:** CLI commands fail because the Supabase project no longer exists, or you need to switch to a different project.

**Fix:**
```bash
# Full relink (pick "Relink" in the interactive prompt, or pass --project-ref)
npx agentlink-sh@latest env add dev

# If a PREVIOUS env add died mid-bootstrap against the SAME project, use --retry instead:
npx agentlink-sh@latest env add dev --retry
```

- **Relink** rewrites the env to point at a different cloud project and re-runs the full bootstrap. Use when the project was deleted, the DB URL is wrong, or you need to switch to a different project.
- **`--retry`** (or the interactive "Re-apply full setup" option) re-runs the bootstrap against the stored `projectRef` without touching the manifest or `.env.local`. Use when a previous `env add` / `env relink` failed partway through — link, db push, vault upserts, functions deploy, or auth config died — and you want to resume without rewiring anything. Also applicable when auth providers / PostgREST config / vault secrets changed and need to be pushed.

If you just need to re-apply schemas and functions (no config changes), `npx agentlink-sh@latest env deploy <name>` is the lighter, idempotent option — it skips vault / PostgREST / auth. If you just need to re-push server-side config (no schemas / functions), `npx agentlink-sh@latest env config [secrets|db|auth|all] [env]` is lighter still — skips schemas, migrations, functions, and verify.

Both preserve existing migrations.

---

### `env add` asked me about "bare mode" — what is that?

**Symptom:** Running `npx agentlink-sh@latest env add dev` in a directory that has no `agentlink.json` surfaces a "No agentlink.json found" menu with three options: *Run the full Agent Link scaffold*, *Continue without full features*, *Cancel*.

**Cause:** The CLI detected the directory isn't scaffolded and offered bare mode — Supabase env plumbing without the full AgentLink scaffold. This is intentional: users who just want env management on an existing codebase shouldn't be forced to scaffold over their own file structure.

**What to pick:**

- **Full scaffold** if the project is empty-ish and the user wants AgentLink's schemas / RLS / RPC layout / skills. The CLI will exit and tell them to run `npx agentlink-sh@latest <name>` (or `npx agentlink-sh@latest .` in the current dir — clean-tree required).
- **Continue without full features** if the user wants Supabase env wiring only (OAuth, project, `.env.local`). Writes `agentlink.json` with `bare: true`. No schemas, no server-side config, no AGENTS.md touched. Full details: workflow #7 in `workflows.md`.
- **Cancel** if the menu appeared by accident (e.g., ran `env add` from the wrong directory).

Bare projects can upgrade later via `npx agentlink-sh@latest --force-update`.

---

### `env deploy` says "Nothing to deploy"

**Symptom:** Running `npx agentlink-sh@latest env deploy <name>` prints `Nothing to deploy — no supabase/database, supabase/migrations, or supabase/functions found.` and exits 0 without touching the cloud.

**Cause:** The project has no `supabase/` subsystem directories — usually because it's a bare-mode project (workflow #7) where the user hasn't added any SQL or edge functions yet, or someone deleted those directories.

**Fix:** Add at least one of:

- `supabase/database/**/*.sql` for schema changes (then `env deploy` runs `db apply`).
- `supabase/migrations/*.sql` + `supabase/config.toml` for migrations (then `env deploy` runs `supabase db push`).
- `supabase/functions/<name>/index.ts` for edge functions (then `env deploy` runs `supabase functions deploy`).

Or upgrade to the full AgentLink scaffold: `npx agentlink-sh@latest --force-update`.

---

### `env config` says "No agentlink.json found"

**Symptom:** Running `npx agentlink-sh@latest env config secrets` prints `No agentlink.json found. Run: npx agentlink-sh@latest env add <name>` and exits.

**Cause:** `env config` operates on a registered cloud env, so it presupposes `env add` has already run. Unlike `env add` (which offers bare-mode onboarding when no manifest exists), `env config` doesn't auto-scaffold — the command assumes you have a target.

**Fix:**

```bash
npx agentlink-sh@latest env add dev      # Register the env first (offers bare mode if no manifest)
npx agentlink-sh@latest env config secrets prod
```

---

### Re-login prompt despite valid stored tokens

**Symptom:** `env add` / `env relink` shows "How would you like to authenticate?" even though you successfully logged in recently.

**Cause:** Pre-v0.21 CLIs had a resolution-ladder gap — after the legacy-oauth → per-org credential migration wiped the single `oauth` slot, calling `ensureAccessToken` without an `orgId` (which happens at the top of `env add` before the user has picked) fell through all the per-org entries and hit the interactive prompt.

**Fix:** Upgrade to v0.21+. Two changes resolve it: (1) `ensureAccessToken` now walks `oauth_by_org` when no `orgId` hint is given and picks any valid entry; (2) `env add` / `env relink` resolve the target org BEFORE the existing-vs-new choice so the correct per-org credential can be pinned early.

---

### `Forbidden` / revoked access on `env add` or project creation

**Symptom:** Org picker completes without prompting you to log in, but then `supabase projects create` (or another Management API call) fails with `{"message":"Forbidden"}` or HTTP 403.

**Cause:** The refresh token still works on paper (refresh endpoint returns a new access token), but the server no longer accepts that token for the target org — usually because org membership was revoked, admin access was removed, or the integration org changed its authorized-apps policy. Pre-v0.21 CLIs' 401-only retry path doesn't match 403 so the error bubbles up with no context.

**Fix:** Upgrade to v0.21+. `pickOrg` now probes `GET /v1/projects` with the resolved token right after the user picks an org; on 401/403 it surfaces `▲ Stored credentials for <org> are no longer accepted. Re-authenticating…`, clears the stale `oauth_by_org[orgId]` entry, and kicks off a fresh org-scoped OAuth login before the rest of `env add` / `env relink` runs.

---

### Claude Code not found on PATH

**Symptom:** Scaffold aborts with `Claude Code not found on PATH. Install Claude Code with our setup script: https://agentlink.sh/start`.

**Cause:** The CLI no longer auto-installs Claude Code (removed in v0.20.1) — it validates and points users at the setup script instead.

**Fix:**
```bash
# macOS / Linux
curl -sSf https://agentlink.sh/start | sh

# Windows (PowerShell)
iwr https://agentlink.sh/start | iex
```

Then open a **new terminal** (so PATH reloads) and retry the scaffold.

---

### `psql` not found in cloud mode

**Symptom:** `psql is required but not installed` error during scaffold.

**Cause:** Old CLI version checked for psql even in cloud mode. Fixed in v0.10.2+.

**Fix:** Update to the latest CLI version. Cloud mode uses the Supabase Management API — psql is not needed.

---

### OAuth login timeout / expired auth link

**Symptom:** Browser opens for Supabase login but the CLI doesn't receive the callback, or the auth link expired.

**Fix:** The CLI checks in after 30 seconds with options to:
- **Keep waiting** — if you're still completing signup
- **Retry** — opens a fresh browser session with new credentials
- **Cancel** — exit and try again later

If the browser didn't open, copy the URL from the terminal manually.

---

## Manual Migration Operations

### Create a migration file manually

```bash
# Generate timestamp
TIMESTAMP=$(date -u +"%Y%m%d%H%M%S")

# Write the migration
cat > supabase/migrations/${TIMESTAMP}_my_fix.sql << 'EOF'
-- Your SQL here
EOF

# Mark as applied (if the SQL was already run on the local DB)
npx supabase migration repair ${TIMESTAMP} --status applied --local
# Cloud: use --linked instead of --local
```

### Apply SQL directly via psql

```bash
# Local — get the DB URL from supabase status
DB_URL=$(npx supabase status -o json | jq -r '.DB_URL // .db_url')

# Cloud — use the pooler URL from .env.local (IPv4-compatible)
# DB_URL="postgresql://postgres.[project_id]:[password]@aws-0-[region].pooler.supabase.com:5432/postgres"

# Run inline SQL
psql "$DB_URL" -c "ALTER TABLE public.charts ADD COLUMN description text;"

# Run a schema file
psql "$DB_URL" -f supabase/database/schemas/public/tables/charts.sql
```

### Fix a broken migration

1. Edit the migration file in `supabase/migrations/`
2. If the migration was already applied, you need to revert and re-apply:
```bash
npx supabase migration repair <version> --status reverted --local
# Fix the SQL in the file
# Re-apply by running the SQL via psql
psql "$DB_URL" -f supabase/migrations/<version>_name.sql
npx supabase migration repair <version> --status applied --local
# Cloud: use --linked instead of --local
```

### Remove a migration

```bash
# Mark as reverted
npx supabase migration repair <version> --status reverted --local
# Delete the file
rm supabase/migrations/<version>_name.sql
```

---

## When to Intervene vs When to Use the CLI

| Situation | Action |
|-----------|--------|
| Missing component reported by `check` | `npx agentlink-sh@latest --force-update` |
| `db migrate` prints "No changes detected" | Ensure Docker is running (ephemeral baseline) or a `prod`+`dev` cloud env exists (read-only baseline); don't hand-author unless it prints `▲ Could not build a clean migration baseline` |
| `db diff` produces wrong output | Edit the generated migration file manually |
| Need a migration for auth schema changes | Write migration file + repair |
| Timestamp collision | Rename file + repair |
| CLI version is outdated | `npx agentlink-sh@latest --force-update` |
| Migration references non-existent object | Fix ordering or merge migrations |
| Need to undo a migration | `repair --status reverted` + delete file |
| DB URL is wrong / connection fails | `npx agentlink-sh@latest db url --fix` |
| Duplicate migration files | `npx agentlink-sh@latest db rebuild` |
| `db push` says remote versions not found | `npx agentlink-sh@latest db rebuild` |
| Cloud project deleted / need new project | `npx agentlink-sh@latest env add dev` (prompts to relink) |
| `env add` died partway OR config drifted | `npx agentlink-sh@latest env add <name> --retry` (re-apply full setup) |
| Need to push schema / function changes (no config drift) | `npx agentlink-sh@latest env deploy <name>` |
| Need to push config only (no schemas / functions) | `npx agentlink-sh@latest env config [secrets\|db\|auth\|all] [env]` |
| Existing codebase, want Supabase env plumbing only | `npx agentlink-sh@latest env add dev` → choose "Continue without full features" (bare mode) |
| `env deploy` prints "Nothing to deploy" | Add files to `supabase/database/` / `supabase/migrations/` / `supabase/functions/`, or run `--force-update` for the full scaffold |
| Broken migration state on new project | `npx agentlink-sh@latest db rebuild` |
| DB password was reset in dashboard | `npx agentlink-sh@latest db password "newpass"` |
| Claude Code not found on PATH | Install via `https://agentlink.sh/start`, open a new terminal |
| `Forbidden` (403) on env add | Upgrade CLI; re-auth is automatic on v0.21+ |
| `npx agentlink-sh@latest deploy` errors "no longer a top-level command" | Use `npx agentlink-sh@latest env deploy` (same functionality, under the env group) |
