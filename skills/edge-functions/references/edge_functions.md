# Edge Functions

Project structure, shared utilities, and setup for Supabase Edge Functions.

Every Edge Function uses the `withSupabase` wrapper. **See [withSupabase Reference](./with_supabase.md) for usage rules, role selection, client patterns, and examples.**

## Contents

- Folder Structure (setting up shared utilities)
- Required Secrets
- Function Configuration (`config.toml`)
- CORS
- Response Helpers
- Feature-Specific Shared Modules

---

## Folder Structure

```
supabase/functions/
├── _shared/                    # Global shared utilities
│   ├── withSupabase.ts         # Context wrapper (core utility)
│   ├── responses.ts            # Response helpers
│   └── types.ts                # Shared TypeScript types
├── _feature-name/              # Feature-specific shared modules
│   ├── someHelper.ts           # Shared logic for this feature
│   └── types.ts                # Feature-specific types
├── my-function/                # An edge function
│   └── index.ts
└── another-function/
    └── index.ts
```

Folders prefixed with `_` are shared modules and are NOT deployed as edge functions. Use `_shared/` for global utilities and `_feature-name/` for logic shared across related functions.

### Setting Up Shared Utilities

**When creating the first edge function for a project**, check if `supabase/functions/_shared/withSupabase.ts` exists. If not, tell the user to run `npx create-agentlink@latest` to set up the shared utilities.

---

## Required Secrets

Edge Functions need the new `SB_` prefixed API keys. These are **NOT** available by default in the Edge Functions environment — they must be manually configured as secrets.

**Before writing any edge function**, verify these secrets exist. If they don't, prompt the user to set them up:

```bash
# Check if secrets are set (locally)
supabase secrets list

# Set secrets locally (in supabase/.env or .env.local)
SB_PUBLISHABLE_KEY=sb_publishable_...
SB_SECRET_KEY=sb_secret_...

# Set secrets in production
supabase secrets set SB_PUBLISHABLE_KEY=sb_publishable_...
supabase secrets set SB_SECRET_KEY=sb_secret_...
```

> **Note:** `SUPABASE_URL` is available by default. `SB_PUBLISHABLE_KEY` and `SB_SECRET_KEY` must be set manually.
>
> **Migrating from legacy keys?** See [API Key Migration](./api_key_migration.md) for the full migration scope — env vars, edge function rewrites, config.toml, vault secrets, and deployment.

---

## Function Configuration (`config.toml`)

**Every edge function must have `verify_jwt = false` in `supabase/config.toml`.** The `withSupabase` wrapper handles auth itself — it validates JWTs for `allow: "user"` and secret keys for `allow: "private"`. If `verify_jwt` is left as `true` (the default), Supabase's gateway will reject requests before they reach the wrapper, breaking `public` and `private` functions entirely and conflicting with the wrapper's own validation for `user` functions.

When creating a new function, add its entry to `config.toml`:

```toml
[functions.my-function]
verify_jwt = false
```

---

## CORS

For @supabase/supabase-js v2.95.0 and later: Import CORS headers directly from the SDK to ensure they stay synchronized with any new headers added to the client libraries. [Documentation](https://supabase.com/docs/guides/functions/cors)

Always include `corsHeaders` in your responses:

```typescript
import { corsHeaders } from "@supabase/supabase-js/cors";

return Response.json(data, {
  headers: { ...corsHeaders, "Content-Type": "application/json" },
});
```

IMPORTANT: The `withSupabase` wrapper already handles `OPTIONS` preflight requests automatically.

---

## Response Helpers

`supabase/functions/_shared/responses.ts` provides response helpers. Installed by CLI. Utilities:

```typescript
import { jsonResponse, errorResponse, notFound } from "../_shared/responses.ts";

// Success
return jsonResponse({ id: "123", name: "test" });

// Error with status
return errorResponse("Invalid input", 400);

// 404
return notFound("User not found");
```

These helpers automatically include CORS headers in every response.

---

## Feature-Specific Shared Modules

For logic shared across related functions, use a `_feature-name/` directory:

```typescript
// supabase/functions/generate-summary/index.ts
import { withSupabase } from "../_shared/withSupabase.ts";
import { jsonResponse, errorResponse } from "../_shared/responses.ts";
import { buildPrompt } from "../_ai/prompts.ts";
import { callOpenAI } from "../_ai/openai.ts";

Deno.serve(
  withSupabase({ allow: "user" }, async (req, ctx) => {
    const { document_id } = await req.json();

    const { data: doc, error } = await ctx.client.rpc("document_get_by_id", {
      p_document_id: document_id,
    });

    if (error) return errorResponse(error.message);

    const summary = await callOpenAI(buildPrompt("summarize", doc.content));

    const { error: updateError } = await ctx.adminClient.rpc(
      "document_update_summary",
      { p_document_id: document_id, p_summary: summary },
    );

    if (updateError) return errorResponse(updateError.message);
    return jsonResponse({ summary });
  }),
);
```
