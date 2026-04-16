---
name: frontend
description: Supabase client integration for frontend applications. Use when the task involves initializing the Supabase client, calling RPCs from frontend code, setting up environment variables for Supabase, managing auth sessions on the client, using TanStack Router or TanStack Query, building forms, or connecting any frontend framework to the Supabase backend.
---

# Frontend — Supabase Client Integration

Connecting frontend applications to the Supabase backend. Client initialization, RPC calls, auth state, routing, data fetching, forms, and type safety.

The CLI scaffolds React + Vite + TanStack Router (file-based routing) by default. Next.js is available with `--nextjs`. Both use `{ db: { schema: 'api' } }` — the difference is client initialization and auth handling.

## Client Initialization

### Vite / SPA (default)

Scaffolded by the CLI in `src/lib/supabase.ts`. Uses `@supabase/supabase-js` directly. For client-side only apps (React SPA, Vue, etc.) without server-side rendering:

```typescript
import { createClient } from "@supabase/supabase-js";

const supabase = createClient(
  import.meta.env.VITE_SUPABASE_URL,
  import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY,
  { db: { schema: "api" } }
);
```

### Next.js / SSR (`--nextjs`)

For projects created with `npx create-agentlink@latest <name> --nextjs`. Uses `@supabase/ssr` for cookie-based session management:

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

**Local:** Run `npx supabase status` — prints the local API URL, publishable key, and secret key. Use these in your `.env.local` for development.

**Cloud:** Read from `.env.local` — values are pre-configured by the CLI scaffold. Do not use `npx supabase status`.

---

## Calling RPCs

All data access goes through `.rpc()` — never `.from()`. The `public` schema is not exposed via the Data API, so `.from()` cannot reach tables. This is a universal rule across all code (frontend, edge functions, webhooks, etc.), not just the client. For type-safe calls with real return types (instead of `Json`), use `typedRpc()` — see the next section.

### Basic pattern

The SQL function name maps directly to the RPC call. Parameters use the same names with the `p_` prefix:

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

### Don't use `.from()` — ever

`public` is not exposed via the Data API; `api` has no tables, only
functions. `supabase.from("charts").select()` fails with "permission
denied" or returns nothing regardless of which key you use —
publishable or secret. The rule is universal (frontend, edge
functions, webhooks, cron handlers, Node scripts): every data access
goes through `.rpc()`. If you're tempted to `.from()` for "quick
reads", add the RPC instead — it's a six-line SQL function with RLS
already carrying the weight.

---

## Type Safety

Generate TypeScript types from your database schema:

```bash
npx create-agentlink@latest db types
```

This works in both local and cloud mode. Types are written to
`src/types/database.ts` (Vite) or `types/database.ts` (Next.js). The
scaffolded Supabase client already imports from these paths — just
run `db types` (or `db apply`, which runs it for you) to populate them.

```typescript
import { createClient } from "@supabase/supabase-js";
import type { Database } from "@/types/database";

const supabase = createClient<Database>(
  import.meta.env.VITE_SUPABASE_URL,
  import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY,
  { db: { schema: "api" } }
);

// RPC calls are now typed — parameters and return types are inferred
const { data } = await supabase.rpc("chart_get_by_id", { p_chart_id: id });
```

`db apply` regenerates types automatically (non-fatal on failure). To
regenerate manually: `npx create-agentlink@latest db types`.

---

## typedRpc() Helper

Database-generated types return `Json` for every `jsonb` column, which
loses the shape of RPC return values. The scaffold ships a `typedRpc()`
helper that casts each RPC's return type using an `RpcReturnMap`
interface you maintain by hand.

### Where things live (scaffolded)

- **`typedRpc` function** → `src/lib/supabase.ts` (alongside the client).
- **`RpcReturnMap` interface** → `src/types/models.ts`.

So you always `import { typedRpc } from "@/lib/supabase"`, and extend
the map by editing `src/types/models.ts`.

### Extending the map

`src/types/models.ts` already imports the generated `Database` type
and exports helper types. Add each RPC's real return shape to
`RpcReturnMap`:

```typescript
// src/types/models.ts
import type { Database } from "./database";

export interface RpcReturnMap {
  chart_get_by_id: { id: string; name: string; created_at: string };
  chart_list: {
    items: Array<{ id: string; name: string }>;
    total_count: number;
    has_more: boolean;
  };
  chart_create: { id: string; name: string; created_at: string };
}
```

### Usage

```typescript
import { typedRpc } from "@/lib/supabase";

// Fully typed — return type is { id: string; name: string; created_at: string }
const chart = await typedRpc("chart_get_by_id", { p_chart_id: id });
```

`typedRpc` derives argument types from `Database["api"]["Functions"]`,
so the *parameters* are typed automatically once `db types` has run.
Only the *return* shapes need to live in `RpcReturnMap`.

> **Load [Data Fetching Patterns](./references/data_fetching.md) for the full `typedRpc()` implementation, `RpcReturnMap` conventions, and error handling patterns.**

---

## Data Fetching with TanStack Query

TanStack Query handles caching, background refetching, and loading/error states. All data fetching goes through query and mutation functions that call `typedRpc()` under the hood.

### Query options factory

Define query options in `src/queries/` — one file per entity:

```typescript
// src/queries/chart.ts
import { queryOptions } from "@tanstack/react-query";
import { typedRpc } from "@/lib/supabase";

export const chartQueries = {
  all: () => queryOptions({
    queryKey: ["charts"],
    queryFn: () => typedRpc("chart_list"),
  }),
  detail: (id: string) => queryOptions({
    queryKey: ["charts", id],
    queryFn: () => typedRpc("chart_get_by_id", { p_chart_id: id }),
  }),
};
```

### Mutations with cache invalidation

Define mutations in `src/mutations/` — one file per entity:

```typescript
// src/mutations/chart.ts
import { useMutation, useQueryClient } from "@tanstack/react-query";
import { typedRpc } from "@/lib/supabase";

export function useChartCreate() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (params: { p_name: string }) => typedRpc("chart_create", params),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ["charts"] }),
  });
}
```

### Directory structure

```
src/
├── queries/          # queryOptions factories (read operations)
│   ├── chart.ts
│   └── tenant.ts
├── mutations/        # useMutation hooks (write operations)
│   ├── chart.ts
│   └── tenant.ts
```

> **Load [Data Fetching Patterns](./references/data_fetching.md) for full query key factories, cache invalidation strategies, optimistic updates, and prefetching in route loaders.**

---

## Forms with React Hook Form + Zod

Forms use React Hook Form for state management and Zod for validation. The pattern is: define a Zod schema, derive the form type, use `useForm` with `zodResolver`.

### Basic pattern

```typescript
import { useForm } from "react-hook-form";
import { zodResolver } from "@hookform/resolvers/zod";
import { z } from "zod";

const chartSchema = z.object({
  name: z.string().min(1, "Name is required"),
  description: z.string().optional(),
});

type ChartForm = z.infer<typeof chartSchema>;

function ChartCreateForm() {
  const { register, handleSubmit, formState: { errors } } = useForm<ChartForm>({
    resolver: zodResolver(chartSchema),
  });
  const chartCreate = useChartCreate();

  const onSubmit = (values: ChartForm) => {
    chartCreate.mutate({ p_name: values.name, p_description: values.description });
  };

  return (
    <form onSubmit={handleSubmit(onSubmit)}>
      <FormField label="Name" error={errors.name?.message}>
        <Input {...register("name")} />
      </FormField>
      <Button type="submit" disabled={chartCreate.isPending}>Create</Button>
    </form>
  );
}
```

The `FormField` component wraps a label, input, and error message into a consistent layout. Use it for all form fields to keep forms visually consistent.

> **Load [Form Patterns](./references/forms.md) for full patterns including form modals, Controller usage for non-native inputs, and async validation.**

---

## Route Architecture

TanStack Router with file-based routing. Route files in `src/routes/` map directly to URL paths. The router is type-safe — route params, search params, and loader data are all typed.

### Key conventions

```
src/routes/
├── __root.tsx                # Root layout — QueryClientProvider, AuthProvider, Toaster
├── index.tsx                 # PUBLIC /  (auth-aware landing page)
├── login.tsx                 # Public /login (sign-in + sign-up)
├── _auth.tsx                 # Pathless gate — beforeLoad redirects to /login when no session
└── _auth/                    # Everything here is gated
    ├── dashboard.tsx         # /dashboard
    ├── animals/
    │   ├── index.tsx         # /animals
    │   ├── $animalId.tsx     # /animals/:animalId
    │   └── -components/      # Route-scoped components (ignored by router)
    │       └── AnimalCard.tsx
    └── settings.tsx          # /settings
```

**Per-section gating is the whole API.** A file in `src/routes/*` is
public; a file in `src/routes/_auth/*` is gated. Drop a file in the
right folder and you're done — no wrappers, no hooks, no state
machines. Specifically, do not:

- build a `<RequireAuth>` / `<AuthGate>` wrapper — the pathless
  `_auth` layout already gates at the route level before the tree
  mounts;
- hand-gate with `useState` / `useEffect` inside individual pages —
  you'll introduce flicker and a client-only race;
- put the app's only page under `_auth/` unless the app is genuinely
  fully gated end to end (no public landing, no public marketing,
  no public anything). Customer portals, SaaS apps, and most
  products want a public `/` and gated `/dashboard`.

- `__root.tsx` — root providers (QueryClient, Auth, Toaster). No auth logic.
- `_auth.tsx` — pathless layout with `beforeLoad` `throw redirect({ to: "/login" })`.
- `$param` — dynamic route segments.
- `-components/` — folders prefixed with `-` are ignored by the router.

> **Load [Routing Patterns](./references/routing.md) for full patterns including navigation, search params, route loaders, and pending UI.**

---

## Shared Components

Reusable components that provide consistent UI patterns across the app. Check `src/components/` before building new ones.

| Component | Purpose | When to use |
|-----------|---------|-------------|
| `PageShell` | Page wrapper with title, description, and optional action button | Every page — provides consistent header layout |
| `ListSkeleton` | Loading placeholder for list views | While query data is loading in list pages |
| `EmptyState` | Illustration + message + action for empty collections | When a list query returns zero items |
| `ErrorBoundary` | Catches render errors, shows recovery UI | Wrap route components or complex sections |
| `FormField` | Label + input + error message wrapper | Every form field — keeps forms visually consistent |

---

## Config Patterns

Centralized configuration keeps display logic out of components and makes updates easy.

### Navigation

`src/config/navigation.ts` defines sidebar and header navigation items:

```typescript
// Rendered inside the gated chrome (authed sidebar / header).
// `/` is the public landing page, so it does not belong here.
export const navigationItems = [
  { label: "Dashboard", to: "/dashboard", icon: LayoutDashboard },
  { label: "Animals", to: "/animals", icon: Beef },
  { label: "Settings", to: "/settings", icon: Settings },
];
```

### Labels and display text

`src/config/labels.ts` maps enum values and status codes to display text:

```typescript
export const animalStatusLabels: Record<AnimalStatus, string> = {
  active: "Active",
  sold: "Sold",
  deceased: "Deceased",
};
```

**When to centralize vs inline:** Centralize when a value appears in more than one place (sidebar items, status badges, select options) or when values may change (labels, feature flags). Inline when it is truly local to one component.

---

## Auth on the Client

### Listening for auth state changes

```typescript
const { data: { subscription } } = supabase.auth.onAuthStateChange(
  (event, session) => {
    if (event === "SIGNED_OUT") {
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

**Critical: dual-path race when combining `onAuthStateChange` + `getSession()`.** Auth callback pages that read a URL hash fragment (e.g., `#access_token=...`) have two paths that resolve concurrently: `onAuthStateChange` fires when the fragment is consumed, and `getSession()` resolves once the session is established. If both paths trigger the same post-auth action (e.g., `invitation_accept` RPC + `refreshSession()`), three operations compete for the auth lock and produce "Lock broken by another request" errors.

Use a guard flag so only the first path to resolve executes the action:

```typescript
let handled = false;

async function handlePostAuthAction() {
  if (handled) return;
  handled = true;
  await supabase.rpc("invitation_accept", { p_token: token });
  // Defer refreshSession — do NOT call it in the same tick as the initial auth flow
  setTimeout(() => supabase.auth.refreshSession(), 0);
}

supabase.auth.onAuthStateChange((event, session) => {
  if (event === "SIGNED_IN" && session) {
    handlePostAuthAction(); // non-async — do not hold the auth lock
  }
});

supabase.auth.getSession().then(({ data: { session } }) => {
  if (session) handlePostAuthAction();
});
```

> **Load [Auth UI Patterns](./references/auth_ui.md) for the full post-auth action pattern (invitation acceptance example).**

### Refresh session after claim changes

When JWT claims change (e.g., after `api.tenant_select()`), the client must refresh to get the new token:

```typescript
await supabase.auth.refreshSession();
```

Without this, RLS policies use stale claims until the token naturally expires.

### Post-signup & the `useTenantGuard` hook

Direct signup has a JWT-timing race: the
`_internal_admin_handle_new_user` trigger writes `tenant_id` into
`raw_app_meta_data` AFTER Supabase issues the first JWT. The session
returned from `signUp()` is stale — every tenant-scoped RPC returns
NULL until the token refreshes. The scaffold handles this in two
places:

1. The scaffolded `/login` route calls
   `await supabase.auth.refreshSession()` immediately after `signUp()`
   succeeds. Keep this whenever you replace or extend the login flow.

2. `useTenantGuard` is the safety net. When a gated page reads
   tenant-scoped data and the JWT lacks `tenant_id`, the hook calls
   `tenant_list` → `tenant_select` → `refreshSession()`:

   ```typescript
   import { useTenantGuard } from "@/hooks/use-tenant-guard";

   function Dashboard() {
     const { user } = useAuth();
     const { ready, error } = useTenantGuard();

     const { data } = useQuery({
       ...myQueries.list(),
       enabled: ready && !!user, // gate tenant-scoped queries on ready
     });

     if (!ready) return <ListSkeleton />;
     if (error) return <EmptyState title="No workspace" description={error} />;
     return <List items={data} />;
   }
   ```

   Use it on every gated page that depends on `_auth_tenant_id()`.
   Skip it on purely personal pages (profile, account settings) where
   `auth.uid()` alone drives the policy.

`useTenantGuard` defaults to `tenants[0]` on mount. If the user only
belongs to one tenant (the common case — see the auth skill's
"Tenancy UX" block), that's the whole story: no picker, no selection
state.

### Scaffolded auth infrastructure (Vite projects)

The scaffold ships a working auth entry point plus the hooks to extend
it. You are not starting from zero.

**What the scaffold provides:**
- **`useAuth` hook** — `@/contexts/auth-context.tsx`. `{ user, session, loading }`; manages auth state via `onAuthStateChange`.
- **`useTenantGuard` hook** — `@/hooks/use-tenant-guard.ts`. Gates tenant-scoped reads on a fresh JWT (see the previous subsection).
- **`_auth.tsx` layout route** — pathless gate. Throws `redirect({ to: "/login" })` when no session; all child routes are protected.
- **`login.tsx` route** — minimal email/password page with sign-in ⇄ sign-up toggle. Calls `supabase.auth.refreshSession()` right after `signUp` so `tenant_id` lands on the first JWT. Post-auth redirects to `/dashboard`.
- **Public `index.tsx`** — auth-aware landing with a CTA that flips between "Sign in" and "Go to dashboard" based on `useAuth().user`.
- **`ErrorBoundary`** — wraps the auth layout's `<Outlet />` to catch render errors.

**What the agent extends:** richer auth surface (OAuth buttons, magic
links, forgot-password, sign-out button placement, post-auth
onboarding). The building blocks are in place — add routes and pages,
don't rewrite the gate.

### Auth strategy — clarify during planning

Different projects need different auth flows. Clarify this before building auth pages:

| Question | Options |
|---|---|
| Can users self-register? | Yes (sign-up page) / No (invitation-only) |
| Auth method? | Email+password, OAuth (Google, GitHub), Magic link/OTP, or a combination |
| Password recovery? | Forgot-password flow needed? |
| Post-auth redirect? | Where does the user land after login? |

Build only what's needed. An invitation-only app with OAuth doesn't need a sign-up page or password recovery.

### Protected route pattern

```typescript
// _auth.tsx layout route — protects all child routes
export const Route = createFileRoute("/_auth")({
  beforeLoad: async () => {
    const { data: { session } } = await supabase.auth.getSession();
    if (!session) throw redirect({ to: "/login" });
    return { session };
  },
  component: AuthLayout,
});
```

### Provider nesting order

Providers are nested in `__root.tsx`. The order matters:

```
QueryClientProvider
  -> AuthProvider
    -> RouterProvider
      + Toaster
```

`QueryClientProvider` is outermost so auth and route components can use queries. `AuthProvider` wraps the router so route guards can access auth state. `Toaster` is a sibling of the router, not a wrapper.

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

These community-maintained skills enhance frontend workflows when installed alongside Agent Link. They are optional — the frontend skill works without them.

- **`frontend-design`** — Invoke during project planning when UI components or pages are being designed. Provides design patterns and component architecture guidance.
- **`vercel-react-best-practices`** — Invoke during React component work. Only applicable if the project uses React.

If available, these skills are invoked automatically at the right points in the workflow.

---

## Reference Files

- **[🌐 SSR Patterns](./references/ssr.md)** — `@supabase/ssr` setup, middleware, cookie handling for Next.js and SvelteKit
- **[🔑 Auth UI Patterns](./references/auth_ui.md)** — Sign-in/sign-up forms, OAuth redirect flow, protected routes
- **[🗂 Routing Patterns](./references/routing.md)** — File-based routing, layouts, navigation, search params, route loaders
- **[📊 Data Fetching Patterns](./references/data_fetching.md)** — TanStack Query, typedRpc, query key factories, cache invalidation
- **[📝 Form Patterns](./references/forms.md)** — React Hook Form + Zod, validation, form modals, FormField component
