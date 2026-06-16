---
name: frontend
description: Supabase client integration for frontend applications. Use when the task involves initializing the Supabase client, calling RPCs from frontend code, setting up environment variables for Supabase, managing auth sessions on the client, using TanStack Router or TanStack Query, building forms, or connecting any frontend framework to the Supabase backend.
---

# Frontend — Supabase Client Integration

Connecting frontend applications to the Supabase backend. Client initialization, RPC calls, auth state, routing, data fetching, forms, and type safety.

The CLI scaffolds a single frontend: **React + TanStack Start in SPA mode** (Vite under the hood, file-based routing via TanStack Router, TanStack Query for data). It ships as a fully client-rendered static SPA — no server. Because it's built on TanStack Start, server-side rendering is a config switch away later, with no route rewrites (see [Rendering](#rendering--spa-now-ssr-later)).

## Client Initialization

Scaffolded by the CLI in `src/lib/supabase.ts`. Uses `@supabase/supabase-js` directly — the app is client-rendered, so there's no server client to configure:

```typescript
import { createClient } from "@supabase/supabase-js";

const supabase = createClient(
  import.meta.env.VITE_SUPABASE_URL,
  import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY,
  { db: { schema: "api" } }
);
```

The data API schema is always `api` (`{ db: { schema: 'api' } }`). Env vars use Vite's `VITE_` prefix and are read via `import.meta.env` — this holds even in TanStack Start SPA mode, since the build is Vite-based.

---

## Environment Variables

The scaffold uses Vite's `VITE_` prefix, read via `import.meta.env`:

| Variable | Purpose |
|----------|---------|
| `VITE_SUPABASE_URL` | Supabase API URL (client-safe) |
| `VITE_SUPABASE_PUBLISHABLE_KEY` | Publishable key (client-safe) |

There's no client-exposed secret key — the SPA only ever uses the publishable key, and RLS + the `api` schema are the security boundary. (Server-only secrets like `SUPABASE_SECRET_KEY` belong to edge functions, never the frontend bundle.)

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
npx agentlink-sh@latest db types
```

This works in both local and cloud mode. Types are written to
`src/types/database.ts`. The scaffolded Supabase client already imports
from this path — just run `db types` (or `db apply`, which runs it for
you) to populate them.

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
regenerate manually: `npx agentlink-sh@latest db types`.

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
├── __root.tsx                # Root shell + providers — QueryClientProvider, AuthProvider, AppToaster
├── index.tsx                 # PUBLIC /  (landing page)
├── _anon.tsx                 # Pathless layout — anon-only (redirects signed-in users to /dashboard)
├── _anon/                    # Logged-out-only pages
│   ├── sign-in.tsx           # /sign-in
│   ├── sign-up.tsx           # /sign-up
│   ├── forgot-password.tsx   # /forgot-password
│   └── check-inbox.tsx       # /check-inbox
├── _auth.tsx                 # Pathless gate — beforeLoad redirects to /sign-in when no session
└── _auth/                    # Everything here is gated
    ├── dashboard.tsx         # /dashboard
    ├── animals/
    │   ├── index.tsx         # /animals
    │   ├── $animalId.tsx     # /animals/:animalId
    │   └── -components/      # Route-scoped components (ignored by router)
    │       └── AnimalCard.tsx
    └── settings/members.tsx  # /settings/members
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

- `__root.tsx` — root shell (`shellComponent`) + app providers (QueryClient, Auth, AppToaster) in `component`. TanStack Start owns the entry point; there is no `main.tsx`/`index.html`.
- `_auth.tsx` — pathless layout with `beforeLoad` `throw redirect({ to: "/sign-in" })`. In SPA mode this guard is client-only (UX, not security).
- `$param` — dynamic route segments.
- `-components/` — folders prefixed with `-` are ignored by the router.

> **Load [Routing Patterns](./references/routing.md) for full patterns including navigation, search params, route loaders, and pending UI.**

---

## Shared Components

Reusable components that provide consistent UI patterns across the app. Check `src/components/` before building new ones.

| Component | Purpose | When to use |
|-----------|---------|-------------|
| `PageShell` | Page **wrapper** — centers content, caps column width, applies page padding | Wraps every gated page; `PageHeader` is its first child |
| `PageHeader` | Page **hero** — eyebrow + title + description + right-aligned `actions` slot | Top of every page; pass page-level buttons/filters to `actions` |
| `ListSkeleton` | Loading placeholder for list views | While query data is loading in list pages |
| `EmptyState` | Icon + message + action for empty collections | When a list query returns zero items |
| `ErrorBoundary` | Catches render errors, shows recovery UI | Wrap route components or complex sections |
| `FormField` | Label + input + error message wrapper | Every form field — keeps forms visually consistent |

### Page anatomy

Every gated page follows the same shape — compose the shipped primitives, don't re-inline headers or invent a new visual dialect:

```tsx
<PageShell>
  <PageHeader title="Members" description="…" actions={<Button>Invite</Button>} />
  {isLoading ? <ListSkeleton /> : items.length === 0 ? <EmptyState … /> : <Table>…</Table>}
</PageShell>
```

- **Lists → shadcn `Table`** (`@/components/ui/table`). `routes/_auth/settings/members.tsx` is the canonical reference (Table + Select + Badge + PageHeader).
- **Pickers → shadcn `Select`** (`@/components/ui/select`) via `Controller`. **Never a native `<select>`.**
- **Loading → `ListSkeleton`**; **empty → `EmptyState`**; **headers → `PageHeader`**.

### Need a primitive that isn't shipped?

The scaffold ships a curated shadcn set (`button`, `card`, `input`, `label`, `dialog`, `alert-dialog`, `dropdown-menu`, `tooltip`, `switch`, `badge`, `table`, `skeleton`, `select`, `separator`, `tabs`, `popover`, `sheet`, `command`, `checkbox`, `radio-group`, `textarea`, `accordion`, `avatar`, `scroll-area`). For anything else, **add it on demand — `components.json` is pre-wired:**

```bash
npx shadcn@latest add <name> --yes   # writes the component + installs its deps
```

**Never hand-roll a primitive or fall back to a native element** when shadcn ships one — run the command above first.

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
      window.location.href = "/sign-in";
    }
  }
);

// Clean up on unmount
subscription.unsubscribe();
```

**Version floor: supabase-js ≥ 2.107.0.** v2.107.0 (PR #2392) removed the `navigator.locks`-based auth mutex, which was the root cause of the async-callback deadlocks and "Lock broken by another request" errors. The scaffold pins this floor; keep it. The patterns below are written for ≥ 2.107.0 — on older versions you would additionally need `setTimeout(…, 0)` deferral around every Supabase call made from a listener.

**Caveat: avoid `await`-ing inside the callback anyway.** Even post-fix, the async `onAuthStateChange` overload remains `@deprecated`, and `refreshSession()` from inside a `TOKEN_REFRESHED` handler still carries a residual re-entry risk. Keep callbacks synchronous and dispatch any Supabase work outside them:

```typescript
supabase.auth.onAuthStateChange((event, session) => {
  if (event === "TOKEN_REFRESHED") {
    // ✅ Keep the callback synchronous; run the RPC outside it.
    void supabase.rpc("some_function");
    // Avoid `await supabase.rpc(...)` directly in the callback.
  }
});
```

**Dual-path race when combining `onAuthStateChange` + `getSession()`.** This is a *logic* race, not a locking one — and it survives the ≥ 2.107.0 fix. Auth callback pages that read a URL hash fragment (e.g., `#access_token=...`) have two paths that resolve concurrently: `onAuthStateChange` fires when the fragment is consumed, and `getSession()` resolves once the session is established. If both trigger the same post-auth action (e.g., an `invitation_accept` RPC), it runs **twice**. The "Lock broken" symptom is gone, but the double execution is still a bug.

Use a guard flag so only the first path to resolve executes the action:

```typescript
let handled = false;

async function handlePostAuthAction() {
  if (handled) return;
  handled = true;
  await supabase.rpc("invitation_accept", { p_token: token });
  await supabase.auth.refreshSession();
}

supabase.auth.onAuthStateChange((event, session) => {
  if (event === "SIGNED_IN" && session) {
    void handlePostAuthAction(); // keep the callback itself synchronous
  }
});

supabase.auth.getSession().then(({ data: { session } }) => {
  if (session) void handlePostAuthAction();
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

The custom access-token hook (`_hook_custom_access_token`) populates
`tenant_id` / `tenant_role` / `permissions` on every JWT mint by reading
`session_tenants` (per-device pin) with a fallback to the user's oldest
membership. So in normal flows the very first JWT after sign-in already
carries the right tenant — single-tenant apps need zero client-side
selection logic.

The one race that remains: a *direct signup* where the JWT is minted
before the AFTER-INSERT trigger materializes the user's default
membership. The session returned from `signUp()` lacks `tenant_id` until
a refresh re-runs the hook. The scaffold handles this in two places:

1. The scaffolded `/sign-up` route calls
   `await supabase.auth.refreshSession()` immediately after `signUp()`
   succeeds. Keep this whenever you replace or extend the sign-up flow.

2. `useTenantGuard` is the safety net. When a gated page reads
   tenant-scoped data and the JWT lacks `tenant_id`, the hook calls
   `refreshSession()` once — the access-token hook re-runs against the
   now-present membership, the new JWT has the tenant baked in, and we
   set `ready = true`. No `tenant_list` / `tenant_select` calls needed
   on the client.

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

> **🛑 Critical gotcha — read tenant claims from `session.access_token`, NOT from `user.app_metadata`.**
>
> `session.user.app_metadata` reflects the `auth.users.raw_app_meta_data`
> database row. This scaffold deliberately stopped writing tenant claims
> to `raw_app_meta_data` (they live in `public.session_tenants` now and
> get injected into the access-token JWT by `_hook_custom_access_token`).
> So `user.app_metadata.tenant_id` is always empty on the client even
> when the hook is firing perfectly. **Decode the JWT directly:**
>
> ```typescript
> function decodeJwt(token: string | undefined) {
>   if (!token) return null;
>   const parts = token.split(".");
>   if (parts.length !== 3) return null;
>   const base64 = parts[1].replace(/-/g, "+").replace(/_/g, "/");
>   const padded = base64 + "=".repeat((4 - (base64.length % 4)) % 4);
>   try { return JSON.parse(decodeURIComponent(escape(atob(padded)))); }
>   catch { return null; }
> }
>
> const { session } = useAuth();
> const claims = decodeJwt(session?.access_token);
> const tenantId    = claims?.app_metadata?.tenant_id;
> const tenantRole  = claims?.app_metadata?.tenant_role;
> const permissions = claims?.app_metadata?.permissions ?? [];
> ```
>
> Every place that gates UI on tenant context — `useTenantGuard`,
> `activeTenantId` derivations, role/permission badges — must decode
> the access token, not read `user.app_metadata`. The scaffolded
> `useTenantGuard` already does this; copy its pattern.
>
> Server-side (RLS, RPCs) is unaffected — `auth.jwt()` in Postgres
> reads from the actual JWT and continues to work via
> `_auth_tenant_id()` and the `auth_verify_access(...)` guard.

### Permissions & authorization (UX gating)

> **🛑 The frontend permission check is UX only — never security.** The real
> gate is the backend `auth_verify_access()` guard inside every mutating RPC,
> which returns **403** regardless of what the UI shows. Hiding or disabling a
> control does not secure it; a user who bypasses the UI (devtools, direct
> `.rpc()`) still hits the 403. Never weaken a backend guard because the UI
> hides a button.

Permissions come from the JWT (`app_metadata.permissions`) for the **active
workspace** — the same array the gotcha above decodes. The scaffold ships a
hook for it:

```typescript
// fails safe to false while loading / tenant not ready
const canEdit = useHasPermission("membership.update");
<Button disabled={!canEdit}>Change role</Button>
```

Convention: **disable** mutating buttons (discoverable), **hide** nav entries
the user can't use (`<RequirePermission permission="...">`).

**Page guard** (route-level, also UX): block rendering a page when the active
workspace lacks a permission. Use the route's `beforeLoad`:
`beforeLoad: () => requirePermission("membership.read")` redirects to
`/forbidden`. It reuses the `use-tenant-guard` refresh-once remedy so a fresh
signup never false-denies.

See `references/auth_ui.md` (recipes) and `references/routing.md` (the route
seam). Scaffolded files: `hooks/use-has-permission.ts`,
`components/require-permission.tsx`, `lib/require-permission.ts`,
`routes/_auth/forbidden.tsx`.

### Scaffolded auth infrastructure

The scaffold ships a working auth entry point plus the hooks to extend
it. You are not starting from zero.

**What the scaffold provides:**
- **`useAuth` hook** — `@/contexts/auth-context.tsx`. `{ user, session, loading }`; manages auth state via `onAuthStateChange`.
- **`useTenantGuard` hook** — `@/hooks/use-tenant-guard.ts`. Gates tenant-scoped reads on a fresh JWT (see the previous subsection).
- **`_auth.tsx` layout route** — pathless gate. Throws `redirect({ to: "/sign-in" })` when no session; all child routes are protected.
- **`_anon/sign-in.tsx` + `_anon/sign-up.tsx` routes** — email/password pages under the anon-only `_anon` layout (signed-in users bounce to `/dashboard`). `sign-up.tsx` calls `supabase.auth.refreshSession()` right after `signUp` so `tenant_id` lands on the first JWT. Post-auth redirects to `/dashboard`.
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
    if (!session) throw redirect({ to: "/sign-in" });
    return { session };
  },
  component: AuthLayout,
});
```

### Provider nesting order

In TanStack Start, `src/routes/__root.tsx` splits into two pieces:

- **`shellComponent`** — the HTML document (`<html>/<head>/<body>`, `<HeadContent/>`, `<Scripts/>`, the dark-mode-before-paint script). It is server-rendered during the SPA shell prerender, so it must stay free of app code that touches the browser or env (no Supabase client here).
- **`component`** — the in-body app, rendered on the client only in SPA mode. This is where the providers wrap `<Outlet/>`:

```
QueryClientProvider
  -> AuthProvider
    -> Outlet
       + Toaster
```

`QueryClientProvider` is outermost so auth and route components can use queries. `AuthProvider` wraps `<Outlet/>` so route guards can access auth state. `Toaster` is a sibling of the outlet. Keeping the providers in `component` (not `shellComponent`) is what stops the Supabase client — which reads `import.meta.env` at module load — from being pulled into the prerendered shell.

> **Load [Auth UI Patterns](./references/auth_ui.md) for sign-in/sign-up forms, OAuth redirect flows, and protected route patterns.**

---

## Rendering — SPA now, SSR later

The scaffold ships as a **fully client-rendered SPA** (TanStack Start with `spa: { enabled: true }`): no server-side execution of `beforeLoad`/loaders, no SSR of route components. The build prerenders a static HTML shell and a client bundle — deploy the static output anywhere, with a catch-all rewrite of unknown paths to the shell.

Because it's TanStack Start (not plain Vite + Router), **moving to server-side rendering later is a config switch, not a rewrite**: set `spa: { enabled: false }` in `vite.config.ts`, set `defaultSsr` in `createStart`, and/or opt individual routes in with `ssr: true | 'data-only' | false`. The router, routes, loaders, and any server functions carry over unchanged. Cookie-based server auth (`@supabase/ssr`) is what you'd add at that point.

> **Load [Rendering / SSR-later Patterns](./references/ssr.md) for the exact SPA-mode config, the static-deploy shell fallback, and how to enable SSR + `@supabase/ssr` cookie handling when you need it.**

---

## Companion Skills

These community-maintained skills enhance frontend workflows when installed alongside Agent Link. They are optional — the frontend skill works without them.

- **`frontend-design`** — Invoke during project planning when UI components or pages are being designed. Provides design patterns and component architecture guidance.
- **`vercel-react-best-practices`** — Invoke during React component work. Only applicable if the project uses React.

If available, these skills are invoked automatically at the right points in the workflow.

---

## Reference Files

- **[🌐 Rendering / SSR-later Patterns](./references/ssr.md)** — TanStack Start SPA-mode config, static-deploy shell fallback, and how to switch on SSR + `@supabase/ssr` cookie handling later
- **[🔑 Auth UI Patterns](./references/auth_ui.md)** — Sign-in/sign-up forms, OAuth redirect flow, protected routes
- **[🗂 Routing Patterns](./references/routing.md)** — File-based routing, layouts, navigation, search params, route loaders
- **[📊 Data Fetching Patterns](./references/data_fetching.md)** — TanStack Query, typedRpc, query key factories, cache invalidation
- **[📝 Form Patterns](./references/forms.md)** — React Hook Form + Zod, validation, form modals, FormField component
