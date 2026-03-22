---
name: frontend
description: Supabase client integration for frontend applications. Use when the task involves initializing the Supabase client, calling RPCs from frontend code, setting up environment variables for Supabase, managing auth sessions on the client, using `@supabase/ssr`, or connecting any frontend framework to the Supabase backend.
license: MIT
metadata:
  author: agentlink
  version: "0.1"
---

# Frontend — Supabase Client Integration

Connecting frontend applications to the Supabase backend. Client initialization, RPC calls, auth state, environment variables, and type safety.

The CLI scaffolds React + Vite + React Router v7 by default. Next.js is available with `--nextjs`. Both use `{ db: { schema: 'api' } }` — the difference is client initialization and auth handling.

## Client Initialization

### Vite / SPA (default)

Scaffolded by the CLI. Uses `@supabase/supabase-js` directly. For client-side only apps (React SPA, Vue, etc.) without server-side rendering:

```typescript
import { createClient } from "@supabase/supabase-js";

const supabase = createClient(
  import.meta.env.VITE_SUPABASE_URL,
  import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY,
  { db: { schema: "api" } }
);
```

### Next.js / SSR (`--nextjs`)

For projects created with `npx @agentlink.sh/cli@latest <name> --nextjs`. Uses `@supabase/ssr` for cookie-based session management:

```typescript
import { createBrowserClient } from "@supabase/ssr";

// Client-side — use in components, hooks, client modules
const supabase = createBrowserClient(
  process.env.NEXT_PUBLIC_SUPABASE_URL!,
  process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY!,
  { db: { schema: "api" } }
);
```

```typescript
import { createServerClient } from "@supabase/ssr";

// Server-side — use in server components, API routes, middleware
const supabase = createServerClient(
  process.env.NEXT_PUBLIC_SUPABASE_URL!,
  process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY!,
  { db: { schema: "api" }, cookies: { /* cookie handlers — see SSR reference */ } }
);
```

> **Load [SSR Patterns](./references/ssr.md) for full `@supabase/ssr` setup with Next.js App Router or SvelteKit.**

---

## Environment Variables

### Variable names by framework

| Framework | URL | Publishable key | Secret key (server-only) |
|-----------|-----|-----------------|--------------------------|
| Vite (React, Vue) | `VITE_SUPABASE_URL` | `VITE_SUPABASE_PUBLISHABLE_KEY` | N/A (no server) |
| Next.js | `NEXT_PUBLIC_SUPABASE_URL` | `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` | `SUPABASE_SECRET_KEY` |
| SvelteKit | `PUBLIC_SUPABASE_URL` | `PUBLIC_SUPABASE_PUBLISHABLE_KEY` | `SUPABASE_SECRET_KEY` |
| Astro | `PUBLIC_SUPABASE_URL` | `PUBLIC_SUPABASE_PUBLISHABLE_KEY` | `SUPABASE_SECRET_KEY` |

### What's safe to expose

- **Client-safe:** Supabase URL and publishable key. These are embedded in the browser bundle. They only grant access through RLS policies — the `api` schema + RLS is the security boundary, not the key.
- **Server-only:** Secret key (service role key). Bypasses RLS entirely. Never expose to the client. Use only in server-side code, edge functions, or API routes.

### Finding connection values

**Local:** Run `supabase status` — prints the local API URL, publishable key, and secret key. Use these in your `.env.local` for development.

**Cloud:** Read from `.env.local` — values are pre-configured by the CLI scaffold. Do not use `supabase status`.

---

## Calling RPCs

All data access goes through `supabase.rpc()`. Tables are not exposed via the Data API.

### Basic pattern

The SQL function name maps directly to the RPC call. Parameters use the same names without the `p_` prefix:

```sql
-- SQL: api.chart_create(p_name text, p_description text)
```

```typescript
// Client call
const { data, error } = await supabase.rpc("chart_create", {
  p_name: "My Chart",
  p_description: "A description",
});
```

### Error handling

```typescript
const { data, error } = await supabase.rpc("chart_get_by_id", {
  p_chart_id: chartId,
});

if (error) {
  // error.message contains the RAISE EXCEPTION message from SQL
  // error.code is the Postgres error code (e.g., "P0001")
  console.error("RPC failed:", error.message);
  return;
}

// data is the jsonb return value from the function
```

### Calling RPCs that return arrays

```typescript
const { data, error } = await supabase.rpc("chart_list");

// data is already parsed — it's the jsonb array from the function
// { items: [...], total_count: 42, has_more: true }
```

---

## Type Safety

Generate TypeScript types from your database schema:

```bash
# Local
supabase gen types typescript --local > src/types/database.ts

# Cloud (project ref from agentlink.json or CLAUDE.md)
supabase gen types typescript --project-id <ref> > src/types/database.ts
```

Use the generated types with the Supabase client:

```typescript
import { createClient } from "@supabase/supabase-js";
import type { Database } from "./types/database";

const supabase = createClient<Database>(
  import.meta.env.VITE_SUPABASE_URL,
  import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY,
  { db: { schema: "api" } }
);

// RPC calls are now typed — parameters and return types are inferred
const { data } = await supabase.rpc("chart_get_by_id", { p_chart_id: id });
```

Re-run `supabase gen types` after schema changes to keep types in sync.

---

## Auth on the Client

### Listening for auth state changes

```typescript
const { data: { subscription } } = supabase.auth.onAuthStateChange(
  (event, session) => {
    if (event === "SIGNED_OUT") {
      // Redirect to login
      window.location.href = "/login";
    }
  }
);

// Clean up on unmount
subscription.unsubscribe();
```

**Critical: async callbacks can deadlock.** `onAuthStateChange` callbacks run synchronously during auth state processing. If your callback `await`s another Supabase method, it can deadlock because the auth state lock is still held.

Use the `setTimeout` dispatch pattern to safely call Supabase functions after the callback completes:

```typescript
supabase.auth.onAuthStateChange((event, session) => {
  if (event === "TOKEN_REFRESHED") {
    // ❌ WRONG — can deadlock
    // await supabase.rpc("some_function");

    // ✅ CORRECT — dispatch async work outside the callback
    setTimeout(async () => {
      await supabase.rpc("some_function");
    }, 0);
  }
});
```

### Refresh session after claim changes

When JWT claims change (e.g., after `api.tenant_select()`), the client must refresh to get the new token:

```typescript
await supabase.auth.refreshSession();
```

Without this, RLS policies use stale claims until the token naturally expires.

### Scaffolded auth (Vite projects)

The Vite scaffold provides pre-built auth components and patterns:

- **`useAuth` hook** — Manages auth state, provides `user`, `session`, `signIn`, `signUp`, `signOut`
- **`AuthGuard` component** — Wraps protected routes, redirects unauthenticated users to login
- **Pre-built pages** — Login, signup, and auth callback pages in `src/pages/`
- **React Router v7 routing** — Route protection via layout components

Check `src/components/` and `src/pages/` before building auth UI from scratch.

### Protected route pattern

```typescript
// Check if user is authenticated before rendering protected content
const { data: { user } } = await supabase.auth.getUser();

if (!user) {
  // Redirect to login
  redirect("/login");
}
```

> **Load [Auth UI Patterns](./references/auth_ui.md) for sign-in/sign-up forms, OAuth redirect flows, and protected route patterns.**

---

## SSR

For server-side rendered apps, `@supabase/ssr` handles cookie-based session management so the server can make authenticated Supabase calls on behalf of the user.

Key concepts:
- **`createBrowserClient`** — client-side, reads cookies automatically
- **`createServerClient`** — server-side, requires explicit cookie handlers
- **Middleware** — refreshes tokens on every server request to keep the session alive

> **Load [SSR Patterns](./references/ssr.md) for full setup with Next.js App Router and SvelteKit, including middleware and cookie handling.**

---

## Companion Skills

These community-maintained skills enhance frontend workflows when installed alongside Agent Link:

- **`frontend-design`** — Invoke during project planning when UI components or pages are being designed. Provides design patterns and component architecture guidance.
- **`vercel-react-best-practices`** — Invoke during React component work. Only applicable if the project uses React.
- **`next-best-practices`** — Invoke during Next.js-specific work (routing, server components, data fetching). Only applicable to `--nextjs` projects.

If available, these skills are invoked automatically at the right points in the workflow. They are not required — the frontend skill works without them.

---

## Reference Files

- **[🌐 SSR Patterns](./references/ssr.md)** — `@supabase/ssr` setup, middleware, cookie handling for Next.js and SvelteKit
- **[🔑 Auth UI Patterns](./references/auth_ui.md)** — Sign-in/sign-up forms, OAuth redirect flow, protected routes
