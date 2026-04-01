# Edge Functions

Project structure, shared utilities, and setup for Supabase Edge Functions.

Every Edge Function uses the `withSupabase` wrapper. **See [withSupabase Reference](./with_supabase.md) for usage rules, role selection, client patterns, and examples.**

## Contents

- Folder Structure (setting up shared utilities)
- Required Secrets
- Function Configuration (`config.toml`)
- CORS
- Error Handling (server-side + client-side)
- Response Helpers
- Feature-Specific Shared Modules

---

## Folder Structure

```
supabase/functions/
├── _shared/                    # Global shared utilities (NOT deployed)
│   └── responses.ts            # Response helpers
├── _feature-name/              # Feature-specific shared modules (NOT deployed)
│   ├── someHelper.ts           # Shared logic for this feature
│   └── types.ts                # Feature-specific types
├── my-function/                # An edge function
│   ├── index.ts
│   └── deno.json               # Per-function dependency map (REQUIRED)
├── another-function/
│   ├── index.ts
│   └── deno.json
└── deno.json                   # Global — local dev fallback only
```

Folders prefixed with `_` are shared modules and are NOT deployed as edge functions. Use `_shared/` for global utilities and `_feature-name/` for logic shared across related functions.

**Every deployed function needs its own `deno.json`** with its npm dependencies. The global `deno.json` is excluded during `--use-api` deployment. See [Dependencies & Deployment](./dependencies.md) for full details on import maps, bare specifiers, sub-path mapping, and deployment.

### Setting Up Shared Utilities

**When creating the first edge function for a project**, check if `supabase/functions/_shared/responses.ts` exists. If not, tell the user to run `npx @agentlink.sh/cli@latest` to set up the shared utilities.

The `withSupabase` wrapper comes from the `@supabase/server` npm package — it's declared in each function's `deno.json`, not as a local file.

---

## Required Secrets

Edge Functions need the new `SUPABASE_` prefixed API keys. These are **NOT** available by default in the Edge Functions environment — they must be manually configured as secrets.

**Before writing any edge function**, verify these secrets exist. If they don't, prompt the user to set them up:

```bash
# Check if secrets are set (locally)
npx supabase secrets list

# Set secrets locally (in supabase/.env or .env.local)
SUPABASE_PUBLISHABLE_KEY=sb_publishable_...
SUPABASE_SECRET_KEY=sb_secret_...

# Set secrets in production
npx supabase secrets set SUPABASE_PUBLISHABLE_KEY=sb_publishable_...
npx supabase secrets set SUPABASE_SECRET_KEY=sb_secret_...
```

> **Note:** `SUPABASE_URL` is available by default. `SUPABASE_PUBLISHABLE_KEY` and `SUPABASE_SECRET_KEY` must be set manually.
>
> **Migrating from legacy keys?** See [API Key Migration](./api_key_migration.md) for the full migration scope — env vars, edge function rewrites, config.toml, vault secrets, and deployment.

---

## Function Configuration (`config.toml`)

**Every edge function must have `verify_jwt = false` in `supabase/config.toml`.** The `withSupabase` wrapper handles auth itself — it validates JWTs for `allow: "user"` and secret keys for `allow: "secret"`. If `verify_jwt` is left as `true` (the default), Supabase's gateway will reject requests before they reach the wrapper, breaking `public` and `secret` functions entirely and conflicting with the wrapper's own validation for `user` functions.

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

## Error Handling

### Server-Side

Always wrap handler logic in a try-catch. Without it, thrown exceptions (e.g., from `req.json()`, external API calls) crash the function with a raw 500 and no structured response.

```typescript
import { withSupabase } from "@supabase/server";
import { jsonResponse, errorResponse } from "../_shared/responses.ts";

export default {
  fetch: withSupabase({ allow: "user", db: { schema: "api" } }, async (req, ctx) => {
    try {
      const body = await req.json();
      const { data, error } = await ctx.supabase.rpc("some_function", body);

      if (error) return errorResponse(error.message, 400);
      return jsonResponse(data);
    } catch (err) {
      console.error("Unhandled error:", err);
      return errorResponse("Internal server error", 500);
    }
  }),
};
```

- Use the right HTTP status code: `400` for bad input, `401` for unauthorized, `404` for not found, `500` for unexpected errors
- Always `console.error` before returning — errors appear in the Supabase Dashboard Logs tab
- Never leak internal details (stack traces, SQL errors) to the client in production

### Client-Side (invoking from the frontend)

When calling edge functions from the client via `supabase.functions.invoke()`, handle the three error types:

```typescript
import {
  FunctionsHttpError,
  FunctionsRelayError,
  FunctionsFetchError,
} from "@supabase/supabase-js";

const { data, error } = await supabase.functions.invoke("my-function", {
  body: { id: "123" },
});

if (error) {
  if (error instanceof FunctionsHttpError) {
    // Function returned an error response (4xx/5xx)
    const errorData = await error.context.json();
    console.error("Function error:", errorData);
  } else if (error instanceof FunctionsRelayError) {
    // Network issue between client and Supabase
    console.error("Relay error:", error.message);
  } else if (error instanceof FunctionsFetchError) {
    // Function unreachable (wrong name, not deployed, etc.)
    console.error("Fetch error:", error.message);
  }
}
```

| Error type | Meaning | Common causes |
|---|---|---|
| `FunctionsHttpError` | Function ran but returned an error status | Bad input, auth failure, handler returned `errorResponse()` |
| `FunctionsRelayError` | Request didn't reach the function | Network issues, Supabase infrastructure problems |
| `FunctionsFetchError` | Function couldn't be found | Wrong function name, function not deployed |

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
import { withSupabase } from "@supabase/server";
import { jsonResponse, errorResponse } from "../_shared/responses.ts";
import { buildPrompt } from "../_ai/prompts.ts";
import { callOpenAI } from "../_ai/openai.ts";

export default {
  fetch: withSupabase({ allow: "user", db: { schema: "api" } }, async (req, ctx) => {
    try {
      const { document_id } = await req.json();

      const { data: doc, error } = await ctx.supabase.rpc("document_get_by_id", {
        p_document_id: document_id,
      });

      if (error) return errorResponse(error.message);

      const summary = await callOpenAI(buildPrompt("summarize", doc.content));

      const { error: updateError } = await ctx.supabaseAdmin.rpc(
        "document_update_summary",
        { p_document_id: document_id, p_summary: summary },
      );

      if (updateError) return errorResponse(updateError.message);
      return jsonResponse({ summary });
    } catch (err) {
      console.error("Unhandled error:", err);
      return errorResponse("Internal server error", 500);
    }
  }),
};
```
