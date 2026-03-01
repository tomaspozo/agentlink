# Setup

Run once per project to ensure the required infrastructure is in place. The agent determines when to run this guide based on the project context.

## Contents
- Verify Local Stack
- Verify Supabase MCP
- Run the Setup Check
- Enable Missing Extensions
- Create Missing Internal Functions
- Store Missing Vault Secrets
- Add Vault Secrets to Seed File
- Re-run the Check
- Configure API Schemas
- Scaffold Schema Structure

---

## 0. Verify Local Stack

**Prerequisite:** `supabase init` must have already been run (the `supabase/` directory must exist). The agent handles when to run `supabase init` based on the project context — see the agent for routing details.

Run `supabase status` from the project root. This confirms:

- The Supabase CLI is installed
- The local database is running **for this project**

**If the command fails:**

1. **CLI not found** → the user must install the Supabase CLI before proceeding
2. **Stack not running** → run `supabase start` to start the local development stack

**Why this matters:** The Supabase MCP server may be connected to a different project's database. `supabase status` run from the project directory is the only way to confirm the local stack is running for the correct project.

## 1. Verify Supabase MCP

Confirm the `supabase` MCP server for local development is connected. The skill
depends on MCP for two tools:

- `supabase:apply_migration` — apply schema migrations
- `supabase:get_advisors` — run the security advisor

All SQL execution goes through `psql` using the DB URL from `supabase status`.

If the MCP server is not available, the user must configure it before proceeding.

## 2. Run the Setup Check

Load `assets/check_setup.sql` and execute it via `psql`. The result is a JSON object:

```json
{
  "extensions": { "pg_net": true, "vault": true },
  "functions":  { "_internal_get_secret": true, "_internal_call_edge_function": true, "_internal_call_edge_function_sync": true },
  "secrets":    { "SUPABASE_URL": true, "SB_PUBLISHABLE_KEY": true, "SB_SECRET_KEY": true },
  "ready": true
}
```

If `"ready": true`, skip to the normal development phases. Otherwise continue below for each `false` value.

## 3. Enable Missing Extensions

If `extensions.pg_net` or `extensions.vault` is `false`, apply a migration:

```sql
CREATE EXTENSION IF NOT EXISTS pg_net WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS supabase_vault WITH SCHEMA extensions;
```

Use `supabase:apply_migration` with a descriptive name like `enable_required_extensions`.

## 4. Create Missing Internal Functions

If any function in the `functions` object is `false`:

1. Load `assets/setup.sql` — it contains the full definitions for all three `_internal_*` functions.
2. Copy the relevant function(s) into the project's `supabase/schemas/public/_internal.sql`.
3. Apply via `supabase:apply_migration`.

The three functions and their purposes:

| Function | Purpose |
|----------|---------|
| `_internal_get_secret(text)` | Reads a secret from Vault by name |
| `_internal_call_edge_function(text, jsonb)` | Calls an Edge Function asynchronously via pg_net |
| `_internal_call_edge_function_sync(text, jsonb, integer)` | Synchronous wrapper with timeout/polling |

## 5. Store Missing Vault Secrets

If any secret in the `secrets` object is `false`, the values need to be stored in Vault. See [`assets/seed.sql`](../assets/seed.sql) for the full explanation of why these secrets are needed and important local development notes.

**Required secrets:** `SUPABASE_URL`, `SB_PUBLISHABLE_KEY`, `SB_SECRET_KEY`

Get the values from `supabase status` (local) or the Supabase Dashboard (production).

**Path A — Agent creates secrets via `psql`:**

Ask the user for the missing values, then run for each:

```sql
SELECT vault.create_secret('<value>', '<secret_name>');
```

**Path B — User runs the script manually:**

```bash
./scripts/setup_vault_secrets.sh \
  --url "<SUPABASE_URL>" \
  --publishable-key "sb_publishable_..." \
  --secret-key "sb_secret_..."
```

The script handles upserts — it will update existing secrets if they already exist.

## 6. Add Vault Secrets to Seed File

Vault secrets are wiped on every `supabase db reset` because the database is fully recreated. To persist them, append the vault secret SQL to the project's `supabase/seed.sql` (the CLI runs this file automatically after every reset).

1. Load [`assets/seed.sql`](../assets/seed.sql) — it contains the template with placeholder values
2. Replace the placeholders with the user's actual local keys (from `supabase status`)
3. Append the content to the project's `supabase/seed.sql` — the file may already exist with other seed data, so do not overwrite it

This is for local development only. Production secrets are managed through the Supabase Dashboard.

## 7. Re-run the Check

Run `assets/check_setup.sql` again via `psql` and confirm `"ready": true` before proceeding to Phase 1.

## 8. Configure API Schemas

Update `supabase/config.toml` to expose only the `api` schema via the Data API. Remove `public` — tables are never accessed directly, only through RPC functions in the `api` schema.

```toml
[api]
schemas = ["api"]
```

The default config includes `public` and `graphql_public`. Replace the entire list with `["api"]`.

## 9. Scaffold Schema Structure (if needed)

If `supabase/schemas/` doesn't exist yet, run the scaffold script:

```bash
./scripts/scaffold_schemas.sh /path/to/project
```