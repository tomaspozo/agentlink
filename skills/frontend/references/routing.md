# Routing Patterns -- TanStack Router

File-based routing with TanStack Router for Vite + React projects. Covers router setup, conventions, auth guards, route decomposition, navigation config, and search params.

## Contents
- Router Setup
- File-based Routing Conventions
- Auth-Protected Routes
- Route Decomposition Pattern
- Navigation Config Pattern
- Search Params

---

## Router Setup

Three files form the routing foundation. The CLI scaffolds all three.

This is **TanStack Start in SPA mode** (`tanstackStart({ spa: { enabled: true } })` in `vite.config.ts`). Start owns the entry point -- there is **no hand-written `src/main.tsx` and no `index.html`**. You never call `createRoot(...).render(...)` or mount a `<RouterProvider>` yourself.

### `src/router.tsx` -- getRouter factory with typed context

```typescript
import { createRouter as createTanStackRouter } from "@tanstack/react-router";
import { routeTree } from "./routeTree.gen";
import { queryClient } from "./lib/query-client";

export interface RouterContext {
  queryClient: typeof queryClient;
}

// TanStack Start calls this factory to create the router. Keep it a function
// (not a module-level singleton) so Start can construct the router for the
// generated client entry; in SPA mode it runs once on the client.
export function getRouter() {
  return createTanStackRouter({
    routeTree,
    context: { queryClient },
    defaultPreload: "intent",
    scrollRestoration: true,
  });
}

declare module "@tanstack/react-router" {
  interface Register {
    router: ReturnType<typeof getRouter>;
  }
}
```

Key points:
- TanStack Start calls `getRouter()` -- export the factory, not a singleton, and do not render the router yourself
- `context: { queryClient }` makes the query client available to all route loaders via `routeContext`
- `defaultPreload: "intent"` prefetches routes on hover/focus for snappy navigation
- The `Register` module declaration enables type-safe `Link` components and `useNavigate` across the app

### `src/routes/__root.tsx` -- root shell + app providers

The root route has two parts: a `shellComponent` (the server-prerendered `<html>`/`<head>`/`<body>` document, kept free of any browser/Supabase code) and a `component` that holds the client-only app providers. This is where `QueryClientProvider`, `AuthProvider`, and the toaster nest -- there is no separate `main.tsx`.

```typescript
import {
  createRootRouteWithContext,
  HeadContent,
  Outlet,
  Scripts,
} from "@tanstack/react-router";
import { QueryClientProvider } from "@tanstack/react-query";
import type { QueryClient } from "@tanstack/react-query";
import { Toaster } from "@/components/ui/sonner";
import { AuthProvider } from "@/contexts/auth-context";
import { queryClient } from "@/lib/query-client";

interface RouterContext {
  queryClient: QueryClient;
}

export const Route = createRootRouteWithContext<RouterContext>()({
  shellComponent: RootDocument, // prerendered <html> shell, no app code
  component: RootComponent, // client-only app providers (SPA)
});

function RootDocument({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <head>
        <HeadContent />
      </head>
      <body>
        {children}
        <Scripts />
      </body>
    </html>
  );
}

function RootComponent() {
  return (
    <QueryClientProvider client={queryClient}>
      <AuthProvider>
        <Outlet />
        <Toaster />
      </AuthProvider>
    </QueryClientProvider>
  );
}
```

Key points:
- `createRootRouteWithContext<RouterContext>()` types the context for all child routes
- `shellComponent` is server-prerendered -- keep it free of code that touches the browser or the Supabase client; app providers belong in `component`, which SPA mode renders on the client only
- The `component` renders `<Outlet />` (the matched route tree) and nests the app providers around it
- Add global error boundaries or not-found handlers here if needed

### `routeTree.gen.ts` -- auto-generated route tree

This file is generated automatically by the TanStack Router Vite plugin. Never edit it manually. It updates whenever you add, remove, or rename route files in `src/routes/`.

If it gets out of sync, restart the Vite dev server -- the plugin regenerates it on startup.

---

## File-based Routing Conventions

All routes live in `src/routes/`. The file name determines the URL path.

### Directory structure

This is the route tree the CLI scaffolds:

```
src/routes/
  __root.tsx              --> root shell + providers
  index.tsx               --> PUBLIC landing page (at "/")
  _anon.tsx               --> layout for logged-out-only pages
  _anon/
    sign-in.tsx           --> /sign-in
    sign-up.tsx           --> /sign-up
    forgot-password.tsx   --> /forgot-password
    check-inbox.tsx       --> /check-inbox
  _auth.tsx               --> layout that gates authenticated pages
  _auth/
    dashboard.tsx         --> /dashboard
    forbidden.tsx         --> /forbidden
    settings/
      members.tsx         --> /settings/members
  accept-invite.tsx       --> /accept-invite
  auth.confirm.tsx        --> /auth/confirm
  update-password.tsx     --> /update-password
```

Routes are flat-file based: `_anon/sign-in.tsx` renders at `/sign-in`, NOT `/_anon/sign-in`. The landing page is the public `index.tsx` at `/`. The gated app lives under `_auth/` (e.g. `/dashboard`). The sign-in page is at `/sign-in`. When you add feature pages, nest them under `_auth/` (e.g. `_auth/animals.tsx` → `/animals`).

### Convention reference

| Pattern | Example | URL |
|---------|---------|-----|
| Index route | `index.tsx` | `/` (parent path) |
| Static segment | `_auth/dashboard.tsx` | `/dashboard` |
| Nested segment | `_auth/settings/members.tsx` | `/settings/members` |
| Dotted segment | `auth.confirm.tsx` | `/auth/confirm` |
| Dynamic param | `$animalId.tsx` | `/:animalId` |
| Layout route | `_auth.tsx` | No URL segment, wraps children |
| Pathless group | `_auth/` prefix | Groups routes under a layout |
| Co-located files | `-components/` | Ignored by the router |

### Layout routes (`_` prefix)

Files prefixed with `_` create layout routes. They render an `<Outlet />` that child routes fill in. They do not add a URL segment.

```
_auth.tsx           --> layout (TopBar + auth guard)
_auth/dashboard.tsx --> renders at /dashboard
_anon.tsx           --> layout for logged-out-only pages (sign-in, sign-up, ...)
```

Layout routes are the right place for:
- Auth guards (`beforeLoad`)
- Shared chrome (sidebar, header, mobile nav)
- Error boundaries

### Co-located components (`-components/`)

Directories prefixed with `-` are ignored by the TanStack Router plugin. Use them for components that belong to a specific route but should not become routes themselves:

```
_auth/sanidad/
  index.tsx                          --> the page
  -components/
    health-card.tsx                  --> used by the page
    health-form-modal.tsx            --> form modal
    vaccination-form-modal.tsx       --> another form modal
    vaccination-card.tsx             --> card component
```

---

## Auth-Protected Routes

The `_auth.tsx` layout route guards all its children. Any route under `_auth/` requires authentication.

> **SPA caveat:** In SPA mode the `beforeLoad` guard runs **client-side only** -- there is no server-side gating. It controls navigation/UX, not data access. The real access gate is the backend `auth_verify_access()` check inside every RPC. Never rely on a client guard to protect data.

```typescript
// src/routes/_auth.tsx
import { createFileRoute, Outlet, redirect } from "@tanstack/react-router";
import { supabase } from "@/lib/supabase";
import { ErrorBoundary } from "@/components/error-boundary";
import { TopBar } from "@/components/topbar";

export const Route = createFileRoute("/_auth")({
  beforeLoad: async () => {
    const {
      data: { session },
    } = await supabase.auth.getSession();
    if (!session) {
      throw redirect({ to: "/sign-in" });
    }
    return { session };
  },
  component: AuthLayout,
});

function AuthLayout() {
  return (
    <main className="min-h-dvh bg-background">
      <TopBar />
      <ErrorBoundary>
        <Outlet />
      </ErrorBoundary>
    </main>
  );
}
```

Key points:
- `beforeLoad` runs before any child route loads -- if the user is not authenticated, they are redirected (to `/sign-in`) before any content renders
- The `session` is returned from `beforeLoad` and available to child routes via `routeContext`
- Shared chrome (the `TopBar` with workspace switcher + user menu) lives in this layout -- child routes only render their own content
- The mirror layout `_anon.tsx` guards logged-out-only pages: if a session exists, it redirects to `/dashboard`
- The public landing `index.tsx` and routes like `accept-invite.tsx` live outside `_auth/` and skip the auth check

### Permission route guard (per page)

`_auth.tsx` only checks *authentication*. To require a *permission* for a
specific page, add `requirePermission(...)` (scaffolded at
`lib/require-permission.ts`) to that route's `beforeLoad`:

```typescript
import { requirePermission } from "@/lib/require-permission";

export const Route = createFileRoute("/_auth/settings/members")({
  beforeLoad: () => requirePermission("membership.read"), // → redirect /forbidden
  component: MembersPage,
});
```

It reads the active workspace's JWT permissions, refreshes once if the tenant
claim isn't ready yet (fresh-signup race), and redirects to `/forbidden`
otherwise. **UX only** — the backend `auth_verify_access()` guard in each RPC
is the real gate. Combine with `useHasPermission(...)` to gate controls inside
the page.

### Redirect with return URL

Pass the current path as a search param so login can redirect back:

```typescript
beforeLoad: async ({ location }) => {
  const { data: { session } } = await supabase.auth.getSession();
  if (!session) {
    throw redirect({
      to: "/sign-in",
      search: { redirect: location.href },
    });
  }
  return { session };
},
```

---

## Route Decomposition Pattern

When a route file grows beyond ~150 lines, extract components into a `-components/` folder. Keep the page shell (data fetching, layout, state) in `index.tsx` and put form modals, cards, and other UI components in separate files.

### Before (everything in one file)

```
routes/_auth/animals/index.tsx    --> 400+ lines: list, card, form, filters, empty state
```

### After (decomposed)

```
routes/_auth/animals/
  index.tsx                        --> page shell (~100 lines)
  $animalId.tsx                    --> detail page
  new.tsx                          --> create page
  -components/
    animal-card.tsx                --> extracted card component
    animal-form.tsx                --> form modal (if using modal pattern)
```

### What stays in `index.tsx`

- Route definition (`createFileRoute`, `validateSearch`)
- Page-level state (search, filters, pagination)
- Data fetching (`useQuery`)
- Page layout (header, search bar, grid, pagination controls)

### What goes in `-components/`

- Form modals (`*-form-modal.tsx`)
- Card components (`*-card.tsx`)
- Complex sub-sections that are self-contained
- Anything reused across the detail and list pages of the same route

---

## Navigation Config Pattern

Centralize navigation items in `src/config/navigation.ts` so the sidebar, mobile nav, and header all share the same source of truth.

```typescript
// src/config/navigation.ts
import {
  LayoutDashboard,
  Heart,
  Baby,
  Stethoscope,
  Milk,
  GitBranch,
  Bell,
  BarChart3,
  Settings,
} from "lucide-react";

export const navItems = [
  {
    to: "/dashboard" as const,
    label: "Dashboard",
    title: "Dashboard",
    icon: LayoutDashboard,
    showInMobile: true,
  },
  {
    to: "/animals" as const,
    label: "Animals",
    title: "Animals",
    icon: Heart,
    showInMobile: true,
  },
  {
    to: "/health" as const,
    label: "Health",
    title: "Health",
    icon: Stethoscope,
    showInMobile: true,
  },
  {
    to: "/reports" as const,
    label: "Reports",
    title: "Reports",
    icon: BarChart3,
    showInMobile: true,
  },
  {
    to: "/alerts" as const,
    label: "Alerts",
    title: "Alerts",
    icon: Bell,
    showInMobile: false,
  },
] as const;

export const settingsNav = {
  to: "/settings" as const,
  label: "Settings",
  title: "Settings",
  icon: Settings,
} as const;

export function getPageTitle(pathname: string): string {
  const allItems = [...navItems, settingsNav];
  const match = allItems
    .filter(({ to }) => pathname === to || (to !== "/" && pathname.startsWith(to)))
    .sort((a, b) => b.to.length - a.to.length)[0];
  return match?.title ?? "My App";
}
```

Key points:
- `as const` on `to` values gives type-safe route paths -- `Link` components will autocomplete
- `showInMobile` controls which items appear in the bottom mobile nav (screen space is limited)
- `getPageTitle()` finds the most specific match for the current pathname -- used by the header component
- Settings is separated from the main nav array because it renders differently (e.g., at the bottom of the sidebar)
- The sidebar, mobile nav, and header all import from this single file

### Usage in components

```typescript
// Sidebar
import { navItems, settingsNav } from "@/config/navigation";

function Sidebar() {
  return (
    <nav>
      {navItems.map((item) => (
        <Link key={item.to} to={item.to}>
          <item.icon />
          {item.label}
        </Link>
      ))}
      <Link to={settingsNav.to}>
        <settingsNav.icon />
        {settingsNav.label}
      </Link>
    </nav>
  );
}

// Mobile nav -- only show items flagged for mobile
function MobileNav() {
  return (
    <nav>
      {navItems
        .filter((item) => item.showInMobile)
        .map((item) => (
          <Link key={item.to} to={item.to}>
            <item.icon />
            {item.label}
          </Link>
        ))}
    </nav>
  );
}

// Header -- dynamic title
import { getPageTitle } from "@/config/navigation";
import { useLocation } from "@tanstack/react-router";

function Header() {
  const { pathname } = useLocation();
  return <h1>{getPageTitle(pathname)}</h1>;
}
```

---

## Search Params

TanStack Router supports typed search params via `validateSearch`. Use this for filters, pagination, and any state that should be reflected in the URL.

### Basic usage

```typescript
import { createFileRoute } from "@tanstack/react-router";

interface SignInSearch {
  redirect?: string;
}

export const Route = createFileRoute("/_anon/sign-in")({
  validateSearch: (search: Record<string, unknown>): SignInSearch => ({
    redirect: search.redirect as string | undefined,
  }),
  component: SignInPage,
});

function SignInPage() {
  const { redirect } = Route.useSearch();
  // Use redirect after successful sign-in
}
```

### Filters and pagination

```typescript
interface AnimalListSearch {
  page: number;
  status: string | null;
  search: string | null;
}

export const Route = createFileRoute("/_auth/animals/")({
  validateSearch: (search: Record<string, unknown>): AnimalListSearch => ({
    page: Number(search.page) || 0,
    status: (search.status as string) || null,
    search: (search.search as string) || null,
  }),
  component: AnimalsPage,
});

function AnimalsPage() {
  const { page, status, search } = Route.useSearch();
  const navigate = useNavigate();

  // Update search params without full navigation
  const setPage = (p: number) =>
    navigate({ search: (prev) => ({ ...prev, page: p }) });
}
```

### When to use search params vs component state

| Use case | Approach |
|----------|----------|
| Filters that should survive refresh | Search params (`validateSearch`) |
| Pagination that should be bookmarkable | Search params |
| Temporary UI state (modal open, dropdown) | Component state (`useState`) |
| Debounced search input | Component state, sync to search params on commit |
| Quick prototype / iteration | Component state (migrate to search params later) |

For list pages, using component state for filters and pagination is simpler to start with. Migrate to search params later if URL persistence is needed.
