# CLI Troubleshooting

## Contents

- **Common Errors** — `42501 permission denied`, `db migrate` "No changes detected",
  `schema "api" does not exist`, `function already exists`, duplicate
  `schema_migrations_pkey`, `pg_net already exists`, `trigger does not exist`,
  migration ordering, `db rebuild` fails, custom roles/cron/buckets gone after `db reset`.
- **Supabase & DB Connection Issues** — DB URL wrong / connection refused, Vault
  secret duplicate key, duplicate migration files, `db push` "Remote migration
  versions not found", pointing at a different project, project transferred to a new
  org, `env add` "bare mode", `env deploy` "Nothing to deploy", `env config` "No
  agentlink.json found", re-login prompt, `Forbidden`/revoked access, plugin/skills
  don't show up, `psql` not found in cloud mode, OAuth login timeout.
- **Manual Migration Operations** — create a migration file manually, apply SQL
  directly via psql, fix a broken migration, remove a migration.
- **When to Intervene vs When to Use the CLI** — decision guidance.

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

**Cause:** `db migrate` diffs your **committed migrations** against the schema files. By default this runs **without Docker and without the live DB** — so "No changes" means the committed migrations already capture everything in your schema files. (An older CLI diffed the live DB against itself and emitted an empty migration whose body was the literal text "No changes detected." — that bug is fixed.)

**This is NOT automatically a signal to hand-author the migration.** Check, in order:

- **Is the change actually in a schema file?** A change applied only via `psql` (not written to `supabase/database/`) won't appear. Write it to the file.
- **Genuinely already migrated?** If you previously generated a migration for this change, the baseline already has it — nothing to do.
- **Diff couldn't build the schema?** If `db migrate` *errors* (rather than "No changes") pointing at `--legacy`, it couldn't faithfully build the schema in-process (an exotic extension/type). Re-run with `--legacy`, which builds the baseline on a short-lived throwaway Supabase stack (needs Docker) or via a read-only `prod`→`dev` cloud diff (needs both envs registered). Only when `--legacy` prints `▲ Could not build a clean migration baseline` (no Docker AND no prod+dev) should you author the migration by hand — see "Manual Migration Operations" below.

---

### `schema "api" does not exist` during `db apply` / `db migrate`

**Cause:** `database/schemas/api/schema.sql` doesn't exist on disk, so when `db apply` builds the schema files the `api` schema is never created and objects referencing `api.*` fail.

**Fix:** Verify `supabase/database/schemas/api/schema.sql` exists on disk (`db apply` resolves dependency order, so the `api` schema is created before objects that reference it). Run `pnpm exec agentlink --force-update` to regenerate it.

---

### `function already exists with same argument types` during migration

**Cause:** Running `npx supabase migration up` or `npx supabase db reset` on a database where objects already exist. Schema files use `CREATE OR REPLACE` (idempotent), but generated migrations may use plain `CREATE`.

**Fix:** Don't use `migration up` / a raw reset to re-apply on a running local DB. Apply your schema changes with `pnpm exec agentlink db apply` — it reconciles existing objects (handling changes to existing tables). Migrations are for production deployments on clean databases; replaying them onto a populated DB is what triggers this. (Avoid hand-running `psql -f <schema-file>` — it bypasses `db apply` and leaves the CLI's tracking state stale.)

---

### `duplicate key value violates unique constraint "schema_migrations_pkey"`

**Cause:** Two migration files have the same timestamp. This can happen when template migrations and a `db migrate` run generate files within the same second.

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
2. `agentlink_setup` is next (tables, functions, policies — generated by `db migrate`)
3. `agentlink_auth_triggers` comes after setup

(The pgmq queue is no longer a migration — it's an imperative resource in
`supabase/database/queue/`, applied on every deploy, so it never participates in
migration ordering.)

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
pnpm exec agentlink --force-update
```

---

### After `supabase db reset`, custom roles / cron jobs / storage buckets are gone

**Symptom:** A raw `supabase db reset` leaves the database missing your custom roles or permissions (membership role dropdowns empty, `auth_verify_access` failing), the queue cron job, or storage buckets/policies.

**Cause:** `supabase db reset` replays **migrations only**. The imperative resources in `supabase/database/{rbac,cron,storage}/` are deliberately **excluded from migrations** (RBAC is reference data; the cron and storage schemas are filtered out of migration plans by design). The migration replay restores the *baseline* defaults but not anything you added after scaffold.

**Fix:** Use `db rebuild` instead of a raw reset — it replays migrations **and** re-applies the schema files + imperative resources in one step:
```bash
pnpm exec agentlink db rebuild
```
If you already ran a raw `supabase db reset`, just run `pnpm exec agentlink db apply` — it detects the reset and reapplies the **full** schema plus the imperative resources. Local-only; the agent is blocked from running `db rebuild` or a raw reset directly — resets are user-initiated.

---

## Supabase & DB Connection Issues

### DB URL is wrong / connection refused

**Symptom:** `db apply` or `db sql` fails with connection errors, timeouts, or "Invalid URL".

**Fix:**
```bash
pnpm exec agentlink db url --fix
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

**Fix:** Delete the duplicate migration files, then regenerate a clean one:
```bash
# remove the redundant *_agentlink_setup.sql copies, keep one (or none), then:
pnpm exec agentlink db migrate setup
```
(`db rebuild` only resets + re-applies — it does **not** touch migration files anymore; regenerating migrations is a separate `db migrate` step.)

---

### `npx supabase db push` fails with "Remote migration versions not found"

**Symptom:** `Remote migration versions not found in local migrations directory` — the cloud database has migration versions that don't exist locally.

**Cause:** Migration files were recreated with new timestamps (from repeated scaffold runs), so the remote versions no longer match local files.

**Fix:** Reconcile the remote migration history with `supabase migration repair` (mark the orphaned remote versions reverted, then re-push). `db rebuild` does **not** help here — it's local/dev only (hard-blocks prod) and no longer touches migration files.
```bash
npx supabase migration repair --status reverted <version1> <version2> ...
# then re-push the correct local migrations:
npx supabase db push
```

---

### Cloud project was deleted / need to point at a different project

**Symptom:** CLI commands fail because the Supabase project no longer exists, or you need to switch to a different project.

**Fix:**
```bash
# Full relink (run env add, pick "Relink to a different Supabase project", or pass --project-ref)
pnpm exec agentlink env add dev

# If a PREVIOUS env add died mid-bootstrap against the SAME project, use --retry instead:
pnpm exec agentlink env add dev --retry
```

- **Relink** rewrites the env to point at a different cloud project and re-runs the full bootstrap. Use when the project was deleted, the DB URL is wrong, or you need to switch to a different project.
- **`--retry`** (or the interactive "Re-apply full setup" option) re-runs the bootstrap against the stored `projectRef` without touching the manifest or `.env.local`. Use when a previous `env add` failed partway through — link, db push, vault upserts, functions deploy, or auth config died — and you want to resume without rewiring anything. Also applicable when auth providers / PostgREST config / vault secrets changed and need to be pushed.

If you just need to re-apply schemas and functions (no config changes), `pnpm exec agentlink env deploy <name>` is the lighter, idempotent option — it skips vault / PostgREST / auth. If you just need to re-push server-side config (no schemas / functions), `pnpm exec agentlink env config [secrets|db|auth|all] [env]` is lighter still — skips schemas, migrations, functions, and verify.

Both preserve existing migrations.

---

### Project transferred to a new organization

**Symptom:** After moving a Supabase project to a different organization, `env deploy` (or `env config`) keeps asking you to re-authenticate, or fails with 403s, because the `orgId` stored in `agentlink.json` no longer matches the project's current org.

**Fix:** Newer CLIs self-heal. `env deploy`, `env config`, and `env add --retry` detect that the project's current org differs from the stored `orgId`, auto-update `agentlink.json` with a notice (`▲ Project <ref> moved to organization <org> — updated agentlink.json`), and re-pin the correct token. If no locally-stored token can see the project under its new org, the CLI prompts you to authorize the new org (interactive) or errors with a "re-run `env add`" hint (non-interactive).

For CI, re-link the same project without re-entering the DB password:

```bash
pnpm exec agentlink env add <name> --project-ref <ref> --keep-password --non-interactive
```

`--keep-password` reuses the stored DB password instead of prompting. Without it, a non-interactive same-project relink updates the password from `SUPABASE_DB_PASSWORD`, or errors telling you to pass `--keep-password` or set `SUPABASE_DB_PASSWORD`.

---

### `env add` asked me about "bare mode" — what is that?

**Symptom:** Running `pnpm exec agentlink env add dev` in a directory that has no `agentlink.json` surfaces a "No agentlink.json found" menu with three options: *Run the full AgentLink scaffold*, *Continue without full features*, *Cancel*.

**Cause:** The CLI detected the directory isn't scaffolded and offered bare mode — Supabase env plumbing without the full AgentLink scaffold. This is intentional: users who just want env management on an existing codebase shouldn't be forced to scaffold over their own file structure.

**What to pick:**

- **Full scaffold** if the project is empty-ish and the user wants AgentLink's schemas / RLS / RPC layout / skills. The CLI will exit and tell them to run `npx agentlink-sh@latest <name>` (or `npx agentlink-sh@latest .` in the current dir — clean-tree required).
- **Continue without full features** if the user wants Supabase env wiring only (OAuth, project, `.env.local`). Writes `agentlink.json` with `bare: true`. No schemas, no server-side config, no AGENTS.md touched. Full details: workflow #7 in `workflows.md`.
- **Cancel** if the menu appeared by accident (e.g., ran `env add` from the wrong directory).

Bare projects can upgrade later via `pnpm exec agentlink --force-update`.

---

### `env deploy` says "Nothing to deploy"

**Symptom:** Running `pnpm exec agentlink env deploy <name>` prints `Nothing to deploy — no supabase/database, supabase/migrations, or supabase/functions found.` and exits 0 without touching the cloud.

**Cause:** The project has no `supabase/` subsystem directories — usually because it's a bare-mode project (workflow #7) where the user hasn't added any SQL or edge functions yet, or someone deleted those directories.

**Fix:** Add at least one of:

- `supabase/database/**/*.sql` for schema changes (then `env deploy` runs `db apply`).
- `supabase/migrations/*.sql` + `supabase/config.toml` for migrations (then `env deploy` runs `supabase db push`).
- `supabase/functions/<name>/index.ts` for edge functions (then `env deploy` runs `supabase functions deploy`).

Or upgrade to the full AgentLink scaffold: `pnpm exec agentlink --force-update`.

---

### `env config` says "No agentlink.json found"

**Symptom:** Running `pnpm exec agentlink env config secrets` prints `No agentlink.json found. Run: pnpm exec agentlink env add <name>` and exits.

**Cause:** `env config` operates on a registered cloud env, so it presupposes `env add` has already run. Unlike `env add` (which offers bare-mode onboarding when no manifest exists), `env config` doesn't auto-scaffold — the command assumes you have a target.

**Fix:**

```bash
pnpm exec agentlink env add dev      # Register the env first (offers bare mode if no manifest)
pnpm exec agentlink env config secrets prod
```

---

### Re-login prompt despite valid stored tokens

**Symptom:** `env add` shows "How would you like to authenticate?" even though you successfully logged in recently.

**Cause:** Pre-v0.21 CLIs had a credential-resolution gap that re-prompted for login even when valid per-org tokens were stored.

**Fix:** Upgrade to v0.21+ — it reuses a valid stored credential without re-prompting, and resolves the target org early so the right one is used.

---

### `Forbidden` / revoked access on `env add` or project creation

**Symptom:** Org picker completes without prompting you to log in, but then `supabase projects create` (or another Management API call) fails with `{"message":"Forbidden"}` or HTTP 403.

**Cause:** The refresh token still works on paper, but the server no longer accepts that token for the target org — usually because org membership was revoked, admin access was removed, or the integration org changed its authorized-apps policy. Pre-v0.21 CLIs didn't handle the 403, so the error bubbled up with no context.

**Fix:** Upgrade to v0.21+. After you pick an org, the CLI validates the stored credential; if it's no longer accepted it surfaces `▲ Stored credentials for <org> are no longer accepted. Re-authenticating…` and kicks off a fresh org-scoped OAuth login before continuing.

---

### Plugin / skills don't show up after scaffold

**Symptom:** The scaffold finished, but the `agentlink` builder agent or the companion skills aren't available when you open the project.

**Cause:** The scaffold never requires an agent editor to be installed — it writes the project and the editor config regardless, so the actual plugin install happens the first time you open the project. How that lands differs per editor:

- **Claude Code** — installs the plugin automatically on first launch. The scaffold writes `enabledPlugins` + `extraKnownMarketplaces` into `.claude/settings.local.json`, so opening the project in Claude Code picks it up with no command. If it doesn't, confirm that file exists and that you opened Claude Code *in the project directory*.
- **Cursor** — Cursor has no committed-config auto-install, so the plugin is a one-time manual step: run `/add-plugin tomaspozo/agentlink` (or install AgentLink from the Cursor marketplace). The companion skills and the Supabase MCP (`.cursor/mcp.json`) are written by the scaffold; only the plugin install is manual.

In both cases the companion skills are installed during scaffold (Claude Code → `.claude/skills/`, Cursor → `.agents/skills/`). Re-run `npx agentlink-sh@latest install` if they're missing.

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

> **🛑 Migrations are forward-only.** Editing a migration that is **committed** or **deployed to any environment** is forbidden — it rewrites the shared deployment record and diverges from what deployed envs already ran. The steps below apply **only to an uncommitted migration that has not been deployed to production** — confirm that with the user first. If it's committed or deployed, leave it untouched: fix the schema files and run `db migrate <name>` to generate a **new** migration that corrects it forward. See [migration_system.md](./migration_system.md) → *Migrations are forward-only*.

For an uncommitted, not-yet-deployed migration:

1. Edit the migration file in `supabase/migrations/`
2. If the migration was already applied **to the local/dev DB**, revert and re-apply:
```bash
npx supabase migration repair <version> --status reverted --local
# Fix the SQL in the file
# Re-apply by running the SQL via psql
psql "$DB_URL" -f supabase/migrations/<version>_name.sql
npx supabase migration repair <version> --status applied --local
# Cloud: use --linked instead of --local
```

### Remove a migration

> Same forward-only rule: only remove a migration that is **uncommitted AND not deployed to production** (confirm with the user). Deleting a committed or deployed migration rewrites the deployment record — don't. Fix forward with a new migration instead.

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
| Missing component reported by `check` | `pnpm exec agentlink --force-update` |
| `db migrate` prints "No changes detected" | The committed migrations already capture your schema files (no Docker needed to check). Confirm the change is written to a schema file; don't hand-author |
| `db migrate` output looks wrong | Review/edit the generated migration SQL before committing |
| Need a migration for auth schema changes | Write migration file + repair |
| Timestamp collision | Rename file + repair |
| CLI version is outdated | `pnpm exec agentlink --force-update` |
| Migration references non-existent object | Fix ordering or merge migrations |
| Need to undo a migration | `repair --status reverted` + delete file |
| DB URL is wrong / connection fails | `pnpm exec agentlink db url --fix` |
| Duplicate migration files | Delete the redundant files, then `pnpm exec agentlink db migrate <name>` to regenerate one (`db rebuild` does not touch migration files) |
| `db push` says remote versions not found | `npx supabase migration repair --status reverted <versions>` + re-push |
| Cloud project deleted / need new project | `pnpm exec agentlink env add dev` (prompts to relink) |
| `env add` died partway OR config drifted | `pnpm exec agentlink env add <name> --retry` (re-apply full setup) |
| Need to push schema / function changes (no config drift) | `pnpm exec agentlink env deploy <name>` |
| Need to push config only (no schemas / functions) | `pnpm exec agentlink env config [secrets\|db\|auth\|all] [env]` |
| Existing codebase, want Supabase env plumbing only | `pnpm exec agentlink env add dev` → choose "Continue without full features" (bare mode) |
| `env deploy` prints "Nothing to deploy" | Add files to `supabase/database/` / `supabase/migrations/` / `supabase/functions/`, or run `--force-update` for the full scaffold |
| Broken migration state on new project | `pnpm exec agentlink db rebuild` |
| DB password was reset in dashboard | `pnpm exec agentlink db password "newpass"` |
| Plugin/skills missing after scaffold | Claude Code installs on first launch; in Cursor run `/add-plugin tomaspozo/agentlink`. Re-run `npx agentlink-sh@latest install` for skills |
| Supabase CLI / `psql` not found | Install via `https://agentlink.sh/start`, open a new terminal |
| `Forbidden` (403) on env add | Upgrade CLI; re-auth is automatic on v0.21+ |
| `npx agentlink-sh@latest deploy` errors "no longer a top-level command" | Use `pnpm exec agentlink env deploy` (same functionality, under the env group) |
