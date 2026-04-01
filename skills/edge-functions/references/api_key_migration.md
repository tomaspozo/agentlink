# API Key Migration

Migrate from legacy JWT-based keys (`anon`/`service_role`) to the new Supabase API keys (`publishable`/`secret`).

## Contents
- What Changed
- Migration Scope
- Client-Side
- Edge Functions
- Database
- Deployment
- Verification

---

## What Changed

Supabase replaced the legacy JWT-based `anon` and `service_role` keys with new `publishable` and `secret` API keys. The old keys are deprecated (late 2026 removal). See the [Supabase API keys docs](https://supabase.com/docs/guides/api/api-keys) for details.

Key differences:
- **Publishable key** (`SUPABASE_PUBLISHABLE_KEY`) replaces `SUPABASE_ANON_KEY` — safe for client-side use
- **Secret key** (`SUPABASE_SECRET_KEY`) replaces `SUPABASE_SERVICE_ROLE_KEY` — server-side only, bypasses RLS

---

## Migration Scope

This is **not** just an env var rename. The migration touches client code, edge functions, database secrets, config, and deployment:

| Area | Old Pattern | New Pattern |
|------|-------------|-------------|
| Client env vars | `NEXT_PUBLIC_SUPABASE_ANON_KEY` | `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` |
| Server env vars | `SUPABASE_SERVICE_ROLE_KEY` | `SUPABASE_SECRET_KEY` |
| Edge function auth | Manual `createClient()` + gateway JWT check | `withSupabase` wrapper handles auth |
| Edge function config | `verify_jwt = true` (default) | `verify_jwt = false` (required) |
| Edge function secrets | `SUPABASE_ANON_KEY` env | `SUPABASE_PUBLISHABLE_KEY` + `SUPABASE_SECRET_KEY` env |
| Edge function shared code | Custom `supabase.ts`, `supabase-admin.ts` | `@supabase/server` (npm) + `responses.ts` — CORS from SDK |
| Vault secrets | None or old names | `SUPABASE_PUBLISHABLE_KEY`, `SUPABASE_SECRET_KEY`, `SUPABASE_URL` |
| Seed file | No vault secrets | Vault secrets for persistence across `db reset` |

---

## Client-Side

Find-and-replace env vars across `.env`, `.env.example`, `.env.local`, and all source files:

| Old | New |
|-----|-----|
| `NEXT_PUBLIC_SUPABASE_ANON_KEY` | `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` |
| `SUPABASE_ANON_KEY` | `SUPABASE_PUBLISHABLE_KEY` (or framework-prefixed equivalent) |
| `SUPABASE_SERVICE_ROLE_KEY` | `SUPABASE_SECRET_KEY` |

Update all `createClient()` calls that reference these env vars:

```typescript
// Before
const supabase = createClient(
  process.env.NEXT_PUBLIC_SUPABASE_URL!,
  process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!
);

// After
const supabase = createClient(
  process.env.NEXT_PUBLIC_SUPABASE_URL!,
  process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY!
);
```

Search the entire codebase for references to old names — any file that reads `ANON_KEY` or `SERVICE_ROLE_KEY` from the environment needs updating.

---

## Edge Functions

This is the largest part of the migration. Each step below must be completed.

### 1. Set up shared utilities

Check if `supabase/functions/_shared/responses.ts` exists. If not, tell the user to run `npx @agentlink.sh/cli@latest` to install the shared utilities (`responses.ts`). The `withSupabase` wrapper comes from the `@supabase/server` npm package, declared in each function's `deno.json`.

### 2. Set `verify_jwt = false` in `config.toml`

**Every** edge function must have `verify_jwt = false`. The `withSupabase` wrapper handles auth — if `verify_jwt` is left as `true` (the default), Supabase's gateway will reject requests before they reach the wrapper.

```toml
# supabase/config.toml — add an entry for EVERY function
[functions.my-function]
verify_jwt = false

[functions.another-function]
verify_jwt = false
```

### 3. Set edge function secrets

```bash
# Local development — add to supabase/.env or .env.local
SUPABASE_PUBLISHABLE_KEY=sb_publishable_...
SUPABASE_SECRET_KEY=sb_secret_...

# Production
npx supabase secrets set SUPABASE_PUBLISHABLE_KEY=sb_publishable_...
npx supabase secrets set SUPABASE_SECRET_KEY=sb_secret_...
```

### 4. Rewrite each function to use `withSupabase`

Migrate every edge function from manual client creation to the `withSupabase` wrapper.

**Before** — manual `createClient`, relies on gateway JWT verification:

```typescript
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

Deno.serve(async (req) => {
  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_ANON_KEY")!,
    {
      global: { headers: { Authorization: req.headers.get("Authorization")! } },
    }
  );

  const { data, error } = await supabase.rpc("profile_get_by_user");

  return new Response(JSON.stringify({ data, error }), {
    headers: { "Content-Type": "application/json" },
  });
});
```

**After** — `withSupabase` handles auth, clients, and CORS:

```typescript
import { withSupabase } from "@supabase/server";
import { jsonResponse, errorResponse } from "../_shared/responses.ts";

export default {
  fetch: withSupabase({ allow: "user", db: { schema: "api" } }, async (_req, ctx) => {
    const { data, error } = await ctx.supabase.rpc("profile_get_by_user");

    if (error) return errorResponse(error.message);
    return jsonResponse(data);
  }),
};
```

For each function, choose the correct `allow` type. See [withSupabase Reference](./with_supabase.md) for the selection guide.

### 5. Remove old shared client files

Delete legacy shared utilities that are replaced by the new pattern:

- `supabase/functions/_shared/supabase.ts` (or `supabaseClient.ts`)
- `supabase/functions/_shared/supabase-admin.ts` (or `supabaseAdmin.ts`)
- Any other custom client initialization files

Grep for imports of these files and update them to use `withSupabase` and the response helpers.

---

## Database

### Vault secrets

The `_internal_admin_call_edge_function` database function relies on vault secrets to call edge functions. Store the new keys in Vault:

```sql
SELECT vault.create_secret('http://127.0.0.1:54321', 'SUPABASE_URL');
SELECT vault.create_secret('sb_publishable_...', 'SUPABASE_PUBLISHABLE_KEY');
SELECT vault.create_secret('sb_secret_...', 'SUPABASE_SECRET_KEY');
```

If old vault secrets exist with the legacy names, remove them:

```sql
DELETE FROM vault.secrets WHERE name IN ('SUPABASE_ANON_KEY', 'SUPABASE_SERVICE_ROLE_KEY');
```

Store vault secrets via `psql` using `vault.create_secret()`.

### Seed file

Vault secrets are wiped on every `npx supabase db reset`. Add the secrets to `supabase/seed.sql` so they persist:

```sql
-- Vault secrets for local development (re-created on every db reset)
SELECT vault.create_secret('http://127.0.0.1:54321', 'SUPABASE_URL');
SELECT vault.create_secret('sb_publishable_...', 'SUPABASE_PUBLISHABLE_KEY');
SELECT vault.create_secret('sb_secret_...', 'SUPABASE_SECRET_KEY');
```

Replace placeholders with actual local keys from `npx supabase status`. If the seed file already has legacy vault secrets, replace them — don't duplicate.

---

## Deployment

### Hosting platform (Vercel, Netlify, etc.)

Update environment variables in your hosting platform's dashboard:

| Old | New |
|-----|-----|
| `NEXT_PUBLIC_SUPABASE_ANON_KEY` | `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` |
| `SUPABASE_SERVICE_ROLE_KEY` | `SUPABASE_SECRET_KEY` |

### Supabase dashboard

1. Set edge function secrets in production: `npx supabase secrets set SUPABASE_PUBLISHABLE_KEY=... SUPABASE_SECRET_KEY=...`
2. Store vault secrets in production via the SQL Editor
3. Once everything is confirmed working, disable legacy keys in the Supabase Dashboard under Project Settings > API

---

## Verification

After completing all steps, run through this checklist:

- [ ] No references to `SUPABASE_ANON_KEY` or `SUPABASE_SERVICE_ROLE_KEY` in codebase
- [ ] No references to `NEXT_PUBLIC_SUPABASE_ANON_KEY` in codebase
- [ ] `verify_jwt = false` set for all functions in `config.toml`
- [ ] Edge function secrets configured (`npx supabase secrets list`)
- [ ] Vault secrets present (`npx @agentlink.sh/cli@latest check` passes)
- [ ] Seed file updated with new vault secret names
- [ ] All edge functions use `withSupabase` wrapper (no manual `createClient`)
- [ ] Old shared client files removed
- [ ] All edge functions tested locally
- [ ] Hosting platform env vars updated
- [ ] Legacy keys disabled in Supabase dashboard
