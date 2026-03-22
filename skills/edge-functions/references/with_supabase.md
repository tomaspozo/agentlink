# withSupabase Wrapper

The `withSupabase` wrapper is the **only** way to initialize Supabase clients in Edge Functions. It provides two clients, handles CORS preflight, and enforces authorization based on the function's `allow` config.

## Contents
- Rules
- Clients
- Allow Types (user, public, private, array)
- Selection Guide
- Function Configuration
- Anti-Patterns
- Context Reference

---

## Rules

1. **ALWAYS use `withSupabase`** — never call `createClient()` in function code, never parse JWTs manually.
2. **ALWAYS use `ctx.client` and `ctx.adminClient`** — they are provided by the wrapper. Never create your own clients.
3. **ALWAYS set `verify_jwt = false`** in `config.toml` for every function — the wrapper handles auth.

---

## Clients

Both clients are **always available** regardless of `allow` type:

| Client | Behavior | Use for |
|--------|----------|---------|
| `ctx.client` | Respects RLS | Default choice. User data operations, queries that should be scoped by policies. |
| `ctx.adminClient` | Bypasses RLS | Service-level operations that need full access. Use deliberately. |

How `ctx.client` is initialized depends on `allow`:

| Allow | `ctx.client` is... |
|-------|---------------------|
| `user` | User-scoped — carries the caller's JWT, so RLS filters by user identity |
| `public` | Public — publishable key, no JWT. RLS `anon` role policies apply |
| `private` | Public — publishable key, no JWT. RLS `anon` role policies apply |

**Default to `ctx.client`.** Reserve `ctx.adminClient` for operations where the function acts as the system, not on behalf of a user -- e.g., processing webhook payloads, cron jobs, writing to service-only tables. If RLS is blocking a user-facing operation, fix the RLS policy; do not switch to `adminClient` to work around it.

---

## Allow Types

### `user` — User-Facing Functions

For functions called from the app by a logged-in user. The wrapper validates the JWT and rejects the request if the user is not authenticated.

**Provides:** `ctx.user`, `ctx.claims`, `ctx.client` (user-scoped), `ctx.adminClient`

```typescript
Deno.serve(
  withSupabase({ allow: "user" }, async (_req, ctx) => {
    try {
      // ctx.user.id, ctx.user.email — user identity
      // ctx.client — queries scoped to this user via RLS
      const { data, error } = await ctx.client.rpc("profile_get_by_user");

      if (error) return errorResponse(error.message);
      return jsonResponse(data);
    } catch (err) {
      console.error("Unhandled error:", err);
      return errorResponse("Internal server error", 500);
    }
  }),
);
```

### `public` — Webhooks, Public Endpoints, External Services

For functions that receive no Supabase JWT. Use this for:

- **External service webhooks** (Stripe, GitHub, etc.) — the handler validates the external signature itself
- **Supabase Auth Hooks** — called by Supabase Auth, not by a user session
- **Public endpoints** — health checks, open APIs
- Any call where the caller handles its own authentication outside of Supabase

No auth enforcement — the request passes through to the handler.

**Provides:** `ctx.client` (public), `ctx.adminClient`

```typescript
// Stripe webhook — validates its own signature, uses adminClient for DB writes
Deno.serve(
  withSupabase({ allow: "public" }, async (req, ctx) => {
    try {
      const signature = req.headers.get("stripe-signature");
      if (!signature) return errorResponse("Missing signature", 401);

      const body = await req.json();
      // Webhook-specific validation here...

      const { error } = await ctx.adminClient.rpc("payment_process_webhook", {
        p_event: body,
      });

      if (error) return errorResponse(error.message);
      return jsonResponse({ received: true });
    } catch (err) {
      console.error("Unhandled error:", err);
      return errorResponse("Internal server error", 500);
    }
  }),
);
```

### `private` — Internal / Service-to-Service

For functions called with the secret key. The wrapper validates that the `apikey` header contains the correct secret key and rejects the request otherwise.

Use this for:
- Cron jobs / scheduled functions
- Database-triggered calls via `_internal_admin_call_edge_function`
- Internal service-to-service calls

**Provides:** `ctx.client` (public), `ctx.adminClient`

```typescript
// Cron job — only callable with the secret key
Deno.serve(
  withSupabase({ allow: "private" }, async (_req, ctx) => {
    try {
      const { data, error } = await ctx.adminClient.rpc(
        "cleanup_expired_sessions",
      );

      if (error) return errorResponse(error.message);
      return jsonResponse({ deleted: data });
    } catch (err) {
      console.error("Unhandled error:", err);
      return errorResponse("Internal server error", 500);
    }
  }),
);
```

### Array — Dual-Auth Functions

Some functions are called from multiple contexts — e.g., by a logged-in user from the app AND by another edge function using the secret key. Pass an array to accept multiple types:

```typescript
// Called by users (JWT) and by admin-regenerate (secret key)
Deno.serve(
  withSupabase({ allow: ["user", "private"] }, async (req, ctx) => {
    try {
      // ctx.user exists → called by a logged-in user (JWT auth succeeded)
      // ctx.user is undefined → called with secret key (internal/service)
      const userId = ctx.user?.id ?? (await req.json()).user_id;

      const { data, error } = await ctx.adminClient.rpc("birth_chart_generate", {
        p_user_id: userId,
      });

      if (error) return errorResponse(error.message);
      return jsonResponse(data);
    } catch (err) {
      console.error("Unhandled error:", err);
      return errorResponse("Internal server error", 500);
    }
  }),
);
```

**How it works:**
- The wrapper tries each type in order — first successful auth wins
- If `user` succeeds: `ctx.user`, `ctx.claims`, and user-scoped `ctx.client` are set
- If `private` succeeds: `ctx.user` is `undefined`, `ctx.client` is the public client
- If none succeed: returns 401
- If the array includes `public`: no auth is required (short-circuits)

**Use `ctx.user` to detect the auth method** in the handler — this is the idiomatic way to branch logic based on how the function was called.

---

## Selection Guide

| Scenario | Allow | Why |
|----------|-------|-----|
| User clicks a button in the app | `user` | Need user identity + RLS-scoped queries |
| External webhook (Stripe, GitHub) | `public` | No Supabase JWT; validate webhook signature yourself |
| Supabase Auth Hook | `public` | Called by Supabase Auth, not a user session |
| Public API / health check | `public` | Open access, no auth needed |
| Cron job / scheduled function | `private` | No user context; needs secret key validation |
| Called from another edge function | `private` | Internal service-to-service; uses secret key |
| Called from DB via `_internal_admin_call_edge_function` | `private` | DB calls with secret key |
| Called by users AND by other edge functions | `["user", "private"]` | Dual-auth — accepts either credential |

**When in doubt:** if there's a logged-in user, use `user`. If it's an external service, use `public`. If it's internal infrastructure, use `private`. If it's called from multiple contexts, use an array.

---

## Function Configuration

Every function using `withSupabase` must disable built-in JWT verification since the wrapper handles auth itself:

###### `config.toml`

```toml
[functions.my-function]
verify_jwt = false
```

This is **required** for `public` and `private` (they don't send a Supabase JWT), and **required** for `user` because the wrapper validates tokens using the newer `getClaims` pattern.

---

## Anti-Patterns

### Creating clients manually

```typescript
// ❌ WRONG — manual client creation inside the handler
Deno.serve(
  withSupabase({ allow: "user" }, async (req, ctx) => {
    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SB_PUBLISHABLE_KEY")!,
    );
    const { data } = await supabase.rpc("some_function");
    // ...
  }),
);

// ✅ CORRECT — use ctx.client
Deno.serve(
  withSupabase({ allow: "user" }, async (_req, ctx) => {
    const { data } = await ctx.client.rpc("some_function");
    // ...
  }),
);
```

### Using `adminClient` when `client` would suffice

```typescript
// ❌ WRONG — bypasses RLS unnecessarily
Deno.serve(
  withSupabase({ allow: "user" }, async (_req, ctx) => {
    const { data } = await ctx.adminClient.rpc("profile_get_by_user");
    // ...
  }),
);

// ✅ CORRECT — let RLS scope the query to the user
Deno.serve(
  withSupabase({ allow: "user" }, async (_req, ctx) => {
    const { data } = await ctx.client.rpc("profile_get_by_user");
    // ...
  }),
);
```

### Using `user` for a webhook

```typescript
// ❌ WRONG — Stripe doesn't send a Supabase JWT, this will always 401
Deno.serve(
  withSupabase({ allow: "user" }, async (req, ctx) => {
    const signature = req.headers.get("stripe-signature");
    // ...
  }),
);

// ✅ CORRECT — use public, validate the webhook signature yourself
Deno.serve(
  withSupabase({ allow: "public" }, async (req, ctx) => {
    const signature = req.headers.get("stripe-signature");
    if (!signature) return errorResponse("Missing signature", 401);
    // ...
  }),
);
```

---

## Context Reference

```typescript
interface SupabaseContext {
  req: Request;

  // Always available
  client: SupabaseClient;       // Respects RLS
  adminClient: SupabaseClient;  // Bypasses RLS

  // Available when allow includes 'user' and auth succeeds
  user?: Record<string, unknown>;   // { id, email, role, ...claims }
  claims?: Record<string, unknown>; // Raw JWT claims from getClaims()
}
```

### Implementation

Do not rewrite this from scratch. The `_shared/` utilities are installed by the CLI. If missing, run `npx @agentlink.sh/cli@latest`.

The wrapper handles:
- CORS preflight (`OPTIONS` requests) automatically — uses `corsHeaders` from `@supabase/supabase-js/cors`
- Resolution of `SB_PUBLISHABLE_KEY` and `SB_SECRET_KEY` from environment
- Clear error messages if secrets are missing
- JWT validation via `getClaims` for `allow: "user"`
- Secret key validation via `apikey` header for `allow: "private"`
- User-scoped client creation with the caller's JWT for `allow: "user"` (created per-request)
- Reusable public and admin clients for `allow: "public"` and `allow: "private"` (created once, shared across requests)
- Array allow for dual-auth — tries each type in order, first match wins
