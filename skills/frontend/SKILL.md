---
name: frontend
description: Frontend integration for the scaffolded React + TanStack Start (SPA) app on Supabase — client setup, RPC calls, TanStack Query and TanStack Router, React Hook Form + Zod forms, shadcn/ui primitives, the PageShell/PageHeader page anatomy, route guards and permission gating, workspace switching, the account section, SSR-later config, and client-side auth. Activate whenever the task touches the frontend, the client, or any workspace/account UI: initializing or calling the Supabase client, building pages/forms/tables, adding shadcn/ui components, wiring TanStack routes or queries, guarding routes by auth or permission, switching the active workspace, or turning on SSR.
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

The real scaffolded `lib/supabase.ts` adds two things the snippet above omits, and you should not strip them: a lazy `Proxy` so importing the module has no side effects (the SPA prerenders the route graph on the server), and a **global `fetch` wrapper that injects the `x-workspace-id` header** on every request from the active-workspace store. That header is the whole 2.0 workspace model — see [Auth on the Client](#auth-on-the-client). It also sets `auth: { flowType: "pkce", detectSessionInUrl: true }` for the email-confirm callbacks.

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
pnpm exec agentlink db types
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
regenerate manually: `pnpm exec agentlink db types`.

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

## Forms with TanStack Form + Zod

Forms use TanStack Form (`@tanstack/react-form`) for state management and Zod for validation — the same family as this scaffold's TanStack Router + TanStack Query, and shadcn's own currently-documented forms stack. The pattern is: define a Zod schema, call `useForm` with `validators: { onSubmit: schema }`, and author each field with `form.Field`'s render prop wrapped in shadcn's `Field`/`FieldLabel`/`FieldError`.

### Basic pattern

```typescript
import { useForm } from "@tanstack/react-form";
import { z } from "zod";
import { Field, FieldError, FieldGroup, FieldLabel } from "@/components/ui/field";

const chartSchema = z.object({
  name: z.string().min(1, "Name is required"),
  description: z.string().optional(),
});

type ChartForm = z.infer<typeof chartSchema>;

function ChartCreateForm() {
  const chartCreate = useChartCreate();

  const form = useForm({
    defaultValues: { name: "", description: "" } as ChartForm,
    validators: { onSubmit: chartSchema },
    onSubmit: async ({ value }) =>
      chartCreate.mutate({ p_name: value.name, p_description: value.description }),
  });

  return (
    <form
      onSubmit={(e) => {
        e.preventDefault();
        e.stopPropagation();
        void form.handleSubmit();
      }}
    >
      <FieldGroup>
        <form.Field
          name="name"
          children={(field) => {
            const isInvalid = field.state.meta.isTouched && !field.state.meta.isValid;
            return (
              <Field data-invalid={isInvalid}>
                <FieldLabel htmlFor={field.name}>Name</FieldLabel>
                <Input
                  id={field.name}
                  value={field.state.value}
                  onBlur={field.handleBlur}
                  onChange={(e) => field.handleChange(e.target.value)}
                  aria-invalid={isInvalid}
                />
                {isInvalid && <FieldError errors={field.state.meta.errors} />}
              </Field>
            );
          }}
        />
        <Button type="submit" disabled={chartCreate.isPending}>Create</Button>
      </FieldGroup>
    </form>
  );
}
```

`Field`/`FieldGroup`/`FieldLabel`/`FieldError` (shadcn's `Field` component) wrap every field for consistent label, spacing, and error layout — never a raw `div` with `space-y-*`.

> **Load [Form Patterns](./references/forms.md) for full patterns including form modals, Select/Checkbox wiring, conditional validation, and cross-field `.refine()` checks.**

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
| `Field`/`FieldGroup` (shadcn) | Label + input + error message wrapper | Every form field — keeps forms visually consistent |

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

The scaffold ships a curated shadcn set (`button`, `card`, `input`, `label`, `dialog`, `alert-dialog`, `dropdown-menu`, `tooltip`, `switch`, `badge`, `table`, `skeleton`, `select`, `separator`, `tabs`, `popover`, `sheet`, `command`, `checkbox`, `radio-group`, `textarea`, `accordion`, `avatar`, `scroll-area`, `alert`, `empty`, `field`) on the **Base UI** primitive library (shadcn's current default — `components.json`'s `style: "base-nova"`). For anything else, **add it on demand — `components.json` is pre-wired:**

```bash
npx shadcn@latest add <name> --yes   # writes the component + installs its deps
```

**Never hand-roll a primitive or fall back to a native element** when shadcn ships one — run the command above first.

Base UI's API differs from Radix in a few places (`asChild` → `render`, `Select` needs an `items` array, `Accordion` uses `multiple` + array `defaultValue` instead of `type`). The `shadcn/ui` companion skill's `rules/base-vs-radix.md` documents every difference — check it before wiring a new interactive component. This scaffold's `ui/*` files and the account/settings routes already show the correct patterns to copy from.

### Theming & customization

The scaffold ships **pure, unmodified shadcn output** — `src/styles.css` is byte-for-byte what `npx shadcn@latest init -t start` generates (base-nova preset, neutral base color, Geist Variable font), and `components.json` matches a fresh shadcn scaffold exactly. There is no template-specific fork of the design system to work around.

**Re-theme the app by editing `src/styles.css` — nothing else should need to change** to reskin the entire app (colors, corner radius, typography):

```css
/* src/styles.css */
:root {
  --primary: oklch(0.205 0 0);   /* → change this, every primary-colored element updates */
  --radius: 0.625rem;            /* → change this, every rounded corner updates */
}
```

Or swap the whole theme at once with the real shadcn CLI:

```bash
npx shadcn@latest init --preset <code> --force --no-reinstall   # rewrites styles.css wholesale
```

**Rules that keep this working:**
- **No custom CSS declarations, no custom classes, no custom tokens.** Don't add anything to `styles.css` beyond what shadcn itself would generate — it gets silently wiped the next time someone runs `shadcn init --force`/`apply --preset <code>` (both rewrite the file wholesale), and it breaks the "one file reskins everything" guarantee.
- Need a repeated visual pattern (an eyebrow label, a section divider)? Inline the Tailwind utilities directly at each call site (e.g. `text-xs font-medium uppercase tracking-wide text-muted-foreground`) rather than inventing a named class in the stylesheet.
- Need a semantic color shadcn doesn't ship (success/warning)? Use Tailwind's stock palette directly (`text-green-600 dark:text-green-500`, `text-amber-600 dark:text-amber-500`) rather than adding a custom CSS variable — `destructive` already covers the error case.
- Never add one-off inline styles or ad-hoc hex colors in component files — that's what breaks the "change one file, reskin everything" story.

**Never hardcode a pixel/rem radius (`rounded-[2px]`, `rounded-[10px]`, `style={{ borderRadius: ... }}`) on any custom component** — bespoke cards, buttons, badges, banners, anything you build by hand instead of via `shadcn add`. Hardcoded radii don't track `--radius` in `styles.css`, so the element silently stops matching the theme the moment someone re-themes the app (this has bitten this exact scaffold before). Always use the theme-relative scale instead: `rounded-sm` / `rounded-md` / `rounded-lg` / `rounded-xl` / `rounded-2xl` / `rounded-3xl` / `rounded-4xl` / `rounded-full` (all mapped through `--radius` in `styles.css`'s `@theme inline` block). Pick whichever step visually matches what you're building — a small badge might want `rounded-md`, a card `rounded-xl`.

If you genuinely believe a fixed, non-theme-relative radius is required (e.g. matching a third-party embed's exact pixel dimensions), **stop and ask the user to confirm before writing it** — don't silently opt out of the theme system.

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

The scaffold ships a **complete, working auth flow** — sign-in, sign-up, magic
link, password recovery, email confirmation, and workspace-invitation
acceptance. You extend it (OAuth buttons, copy, post-auth onboarding); you do
not rebuild the gate. The deep patterns — the page/hook layer, `onAuthStateChange`
listener safety, and post-auth actions — live in
[Auth UI Patterns](./references/auth_ui.md).

### Identity-only model (2.0) — read this before touching auth

The JWT proves **identity only** — who the user is. It carries **no workspace
and no permissions**. Two consequences define the entire client model:

- **The active workspace is asserted per request**, via an `x-workspace-id`
  header. `lib/supabase.ts` injects it into every Data-API request through a
  global `fetch` wrapper reading the active-workspace store — set once, no
  client rebuild on switch. Switching workspace is just sending a different
  header (`setActive(id)`).
- **Role and permissions come from `api.session_context()`**, fetched for the
  active workspace — never from `session.access_token` / `user.app_metadata`.

> **Do not** decode the JWT for a `tenant_id`/`permissions` claim, call
> `api.tenant_select()`, or `supabase.auth.refreshSession()` to "pick up" a
> workspace. None of that exists in 2.0 — the workspace was never in the token.
> See [Workspaces, Roles & Permissions](#workspaces-roles--permissions).

### What the scaffold provides

- **`useAuth`** — `@/contexts/auth-context.tsx`. `{ user, session, loading }`; tracks auth state via `onAuthStateChange`.
- **`_auth.tsx`** — pathless gate; `beforeLoad` throws `redirect({ to: "/sign-in" })` when there's no session. All child routes are gated.
- **`_anon/` pages** — `sign-in`, `sign-up`, `forgot-password`, `check-inbox` under the anon-only `_anon` layout (signed-in users bounce to `/dashboard`). Sign-up needs **no** `refreshSession` — on success the default workspace materializes and `WorkspaceProvider` selects it on the next render.
- **Public `index.tsx`** — auth-aware landing; the CTA flips on `useAuth().user`.
- **`ErrorBoundary`** — wraps the auth layout's `<Outlet />` to catch render errors.

**What you extend:** richer auth surface — OAuth buttons, magic links,
post-auth onboarding. The building blocks are in place; add routes and pages,
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

Protection is by folder, not by wrapper: the `_auth.tsx` layout route's
`beforeLoad` does `getSession()` and `throw redirect({ to: "/sign-in" })` when
there's none — see [Route Architecture](#route-architecture) and
[Routing Patterns](./references/routing.md).

### Provider nesting order

In TanStack Start, `src/routes/__root.tsx` splits into two pieces:

- **`shellComponent`** — the HTML document (`<html>/<head>/<body>`, `<HeadContent/>`, `<Scripts/>`, the dark-mode-before-paint script). It is server-rendered during the SPA shell prerender, so it must stay free of app code that touches the browser or env (no Supabase client here).
- **`component`** — the in-body app, rendered on the client only in SPA mode. This is where the providers wrap `<Outlet/>`:

```
QueryClientProvider
  -> AuthProvider
    -> WorkspaceProvider
      -> Outlet
         + Toaster
```

`QueryClientProvider` is outermost so auth and route components can use queries. `AuthProvider` wraps `<Outlet/>` so route guards can access auth state; `WorkspaceProvider` sits inside it (it needs `useAuth`) and supplies the active workspace + permissions to the tree. `Toaster` is a sibling of the outlet. Keeping the providers in `component` (not `shellComponent`) is what stops the Supabase client — which reads `import.meta.env` at first use — from being pulled into the prerendered shell.

> **Load [Auth UI Patterns](./references/auth_ui.md) for sign-in/sign-up forms, the OAuth redirect flow, `onAuthStateChange` listener safety, and post-auth actions (invitation acceptance).**

---

## Workspaces, Roles & Permissions

Every gated request runs in exactly one workspace, chosen **on the client** and
asserted with the `x-workspace-id` header (injected by `lib/supabase.ts`). The
server validates membership and pins the workspace for that request; the client
reads role/permissions for it from `api.session_context()`. There is no tenant
claim in the token and no re-mint on switch.

### Switching workspace — `useWorkspace()`

`useWorkspace()` (from `@/contexts/workspace-context`) returns
`{ tenants, activeId, activeTenant, setActive, ready }` (plus `permissions`,
`role`, `hasNoWorkspace`, `error`). **Switch = `setActive(id)`** — it updates
the active-workspace store and invalidates scoped queries so they refetch under
the new header. No `refreshSession`, no `tenant_select`, no JWT decode.

```tsx
const { tenants, activeTenant, setActive } = useWorkspace();
// ...
setActive(tenant.id); // instant; scoped queries refetch under the new workspace
```

Create-then-switch: `typedRpc("tenant_create", …)` → refetch the `["tenants"]`
query so the new workspace is in the membership list → `setActive(created.id)`.
(The reconcile only honours a workspace the user actually belongs to.)

### Gating workspace-scoped queries — `useTenantGuard()`

Workspace-scoped reads must wait until an active workspace has resolved.
`useTenantGuard()` reads `WorkspaceProvider` and returns `{ ready, error }` — no
`refreshSession` dance anymore, just the provider's readiness:

```tsx
const { user } = useAuth();
const { ready, error } = useTenantGuard();

const { data } = useQuery({
  ...myQueries.list(),
  enabled: ready && !!user, // gate tenant-scoped queries on ready
});

if (!ready) return <ListSkeleton />;
if (error) return <EmptyState title="No workspace" description={error} />;
```

Skip it on purely personal pages (profile, account) where `auth.uid()` alone
drives the policy.

### Permissions — `useHasPermission()` (UX only)

> **🛑 The frontend permission check is UX only — never security.** The real
> gate is the backend `auth_verify_access()` guard inside every mutating RPC,
> which returns **403** regardless of what the UI shows. A user who bypasses the
> UI (devtools, direct `.rpc()`) still hits the 403. Never weaken a backend
> guard because the UI hides a button.

Permissions come from `api.session_context()` for the active workspace (via
`WorkspaceProvider`), not the token. Same signature as before, still fails safe
to `false` until the workspace is ready:

```tsx
const canEdit = useHasPermission("membership.update");
<Button disabled={!canEdit}>Change role</Button>
```

Convention: **disable** mutating buttons (discoverable), **hide** nav entries
the user can't use (`<RequirePermission permission="…">`). **Page guard**
(route-level, also UX): `beforeLoad: () => requirePermission("membership.read")`
resolves the active workspace and redirects to `/forbidden` (or `/no-workspace`
when the account has none). See `references/auth_ui.md` (recipes) and
`references/routing.md` (the route seam).

### The account section

`/account/profile` (display name + avatar), `/account/connections` (MCP/OAuth
grants), and the avatar user menu in the top bar are **personal** —
workspace-independent, driven by `auth.uid()`. See
[Account & Connections](./references/account.md).

**Scaffolded files:** `contexts/workspace-context.tsx` (`useWorkspace`),
`lib/active-workspace.ts`, `lib/supabase.ts` (header injection),
`lib/session-context.ts`, `hooks/use-has-permission.ts`,
`hooks/use-tenant-guard.ts`, `lib/require-permission.ts`,
`components/require-permission.tsx`, `routes/_auth/forbidden.tsx`,
`routes/no-workspace.tsx`.

---

## Rendering — SPA now, SSR later

The scaffold ships as a **fully client-rendered SPA** (TanStack Start with `spa: { enabled: true }`): no server-side execution of `beforeLoad`/loaders, no SSR of route components. The build prerenders a static HTML shell and a client bundle — deploy the static output anywhere, with a catch-all rewrite of unknown paths to the shell.

Because it's TanStack Start (not plain Vite + Router), **moving to server-side rendering later is a config switch, not a rewrite**: set `spa: { enabled: false }` in `vite.config.ts`, set `defaultSsr` in `createStart`, and/or opt individual routes in with `ssr: true | 'data-only' | false`. The router, routes, loaders, and any server functions carry over unchanged. Cookie-based server auth (`@supabase/ssr`) is what you'd add at that point.

> **Load [Rendering / SSR-later Patterns](./references/ssr.md) for the exact SPA-mode config, the static-deploy shell fallback, and how to enable SSR + `@supabase/ssr` cookie handling when you need it.**

---

## Companion Skills

These community-maintained skills enhance frontend workflows when installed alongside AgentLink. They are optional — the frontend skill works without them.

- **`frontend-design`** — Invoke during project planning when UI components or pages are being designed. Provides design patterns and component architecture guidance.
- **`vercel-react-best-practices`** — Invoke during React component work. Only applicable if the project uses React.

If available, these skills are invoked automatically at the right points in the workflow.

---

## Reference Files

- **[🌐 Rendering / SSR-later Patterns](./references/ssr.md)** — TanStack Start SPA-mode config, static-deploy shell fallback, and how to switch on SSR + `@supabase/ssr` cookie handling later
- **[🔑 Auth UI Patterns](./references/auth_ui.md)** — Sign-in/sign-up forms, OAuth redirect flow, protected routes, `onAuthStateChange` listener safety, post-auth actions, permission gating
- **[👤 Account & Connections](./references/account.md)** — Profile (display name + avatar upload), MCP/OAuth connections, the avatar user menu
- **[🗂 Routing Patterns](./references/routing.md)** — File-based routing, layouts, navigation, search params, route loaders
- **[📊 Data Fetching Patterns](./references/data_fetching.md)** — TanStack Query, typedRpc, query key factories, cache invalidation
- **[📝 Form Patterns](./references/forms.md)** — TanStack Form + Zod, validation, form modals, Field component
