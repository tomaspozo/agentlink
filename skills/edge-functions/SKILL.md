---
name: edge-functions
description: Supabase Edge Functions. Use when the task involves creating, modifying, or debugging edge functions, webhooks, external API integrations, service-to-service calls, or anything that runs in the Deno edge runtime. Also use for configuring edge function secrets, config.toml, or migrating from legacy Supabase API keys (anon/service_role to publishable/secret). Activate whenever the task touches supabase/functions/ or mentions edge functions.
---

# Edge Functions

Edge Functions handle everything that needs to talk to the outside world — webhooks, third-party APIs, scheduled triggers, service-to-service calls. They are **not** for CRUD or business logic (that belongs in database functions via RPCs).

## IMPORTANT!

- **All database access uses `.rpc()` — never `.from()`.** The `public` schema is not exposed via the Data API, so `.from()` cannot reach tables. Use `ctx.supabase.rpc()` or `ctx.supabaseAdmin.rpc()` to call functions in the `api` schema.
- Every edge function uses the `withSupabase` wrapper. No exceptions.
- Every edge function needs its own `deno.json` with pinned dependency versions — the global one is excluded during deployment.
- Every edge function must have `verify_jwt = false` in `supabase/config.toml`:

```toml
[functions.my-function]
verify_jwt = false
```

This is required because the `withSupabase` wrapper handles auth itself. If `verify_jwt` is left as `true` (the default), Supabase's gateway rejects requests before they reach the wrapper.

## Quick Start

### First edge function in a project?

The `_shared/` utilities (`responses.ts`) should already exist in `supabase/functions/_shared/` — the CLI sets these up. If missing, run `npx create-agentlink@latest`.

The `withSupabase` wrapper comes from the `@supabase/server` npm package, resolved via per-function `deno.json` import maps.

### Creating a new function

1. **Create the function directory** — `supabase/functions/my-function/`
2. **Add `deno.json`** with pinned dependency versions:
   ```jsonc
   // supabase/functions/my-function/deno.json
   {
     "imports": {
       "@supabase/server": "npm:@supabase/server@0.1.0-alpha.1",
       "@supabase/supabase-js": "npm:@supabase/supabase-js@2"
     }
   }
   ```
   Always pin versions — exact for pre-release (`@0.1.0-alpha.1`), major for stable (`@2`). Never use unversioned specifiers.
3. **Choose the `allow` type** — who can call this function? (see Selection Guide below)
4. **Write `index.ts`** using `withSupabase`:

```typescript
import { withSupabase } from "@supabase/server";
import { jsonResponse, errorResponse } from "../_shared/responses.ts";

export default {
  fetch: withSupabase({ allow: "user", supabaseOptions: { db: { schema: "api" } } }, async (_req, ctx) => {
    try {
      const { data, error } = await ctx.supabase.rpc("my_rpc_function");

      if (error) return errorResponse(error.message);
      return jsonResponse(data);
    } catch (err) {
      console.error("Unhandled error:", err);
      return errorResponse("Internal server error", 500);
    }
  }),
};
```

5. **Add to `config.toml`**:
   ```toml
   [functions.my-function]
   enabled = true
   verify_jwt = false
   ```
6. **Test** — Local: `npx supabase functions serve` / Deploy: `npx supabase functions deploy --use-api`

---

## Selection Guide

| Scenario                                          | Allow                 | Why                                                   |
| ------------------------------------------------- | --------------------- | ----------------------------------------------------- |
| User clicks a button in the app                   | `"user"`              | Need user identity + RLS-scoped queries               |
| External webhook (Stripe, GitHub)                 | `"public"`            | No Supabase JWT — validate webhook signature yourself |
| Supabase Auth Hook                                | `"public"`            | Called by Supabase Auth, not a user session           |
| Public API / health check                         | `"public"`            | Open access, no auth needed                           |
| Cron job / scheduled function                     | `"secret"`            | No user context — needs secret key validation         |
| Called from DB via `_internal_admin_call_edge_function` | `"secret"`            | DB calls use the secret key                           |
| Called by users AND by other services             | `["user", "secret"]`  | Dual-auth — accepts either credential                 |

**When in doubt:** logged-in user → `"user"`. External service → `"public"`. Internal infrastructure → `"secret"`.

> **For the full wrapper API, dual-auth patterns, anti-patterns, and context reference, load [withSupabase Reference](./references/with_supabase.md).**

---

## Secrets

Edge functions need `SUPABASE_PUBLISHABLE_KEY` and `SUPABASE_SECRET_KEY` configured as secrets — they are **not** available by default.

```bash
# Local development — add to supabase/.env or .env.local
SUPABASE_PUBLISHABLE_KEY=sb_publishable_...
SUPABASE_SECRET_KEY=sb_secret_...

# Cloud / Production — set via CLI (already configured by scaffold)
npx supabase secrets set SUPABASE_PUBLISHABLE_KEY=sb_publishable_...
npx supabase secrets set SUPABASE_SECRET_KEY=sb_secret_...
```

`SUPABASE_URL` is available by default and does not need to be set.

---

## Project Structure

```
supabase/functions/
├── _shared/                    # Shared utilities (NOT deployed)
│   └── responses.ts            # Response helpers
├── _feature-name/              # Feature-specific shared modules (NOT deployed)
│   └── helpers.ts
├── my-function/
│   ├── index.ts
│   └── deno.json               # Per-function dependency map (REQUIRED)
├── another-function/
│   ├── index.ts
│   └── deno.json
└── deno.json                   # Global — local dev fallback only
```

Folders prefixed with `_` are shared modules — they are not deployed as edge functions. Every deployed function needs its own `deno.json` with its dependencies mapped — the global `deno.json` is excluded during deployment.

---

## Reference Files

Load these as needed:

- **[🔧 withSupabase Wrapper](./references/with_supabase.md)** — Full wrapper API: allow types, dual-auth, clients, anti-patterns, context reference
- **[📦 Dependencies & Deployment](./references/dependencies.md)** — Per-function `deno.json`, import maps, bare specifiers, sub-path mapping, version pinning, `--use-api` deployment
- **[📁 Edge Function Patterns](./references/edge_functions.md)** — Folder structure details, response helpers, feature-specific modules
- **[🔑 API Key Migration](./references/api_key_migration.md)** — Migrate from legacy anon/service_role keys to new publishable/secret keys
