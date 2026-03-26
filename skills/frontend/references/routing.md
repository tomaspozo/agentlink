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

### `src/router.tsx` -- createRouter with typed context

```typescript
import { createRouter } from "@tanstack/react-router";
import { routeTree } from "./routeTree.gen";
import { queryClient } from "./lib/query-client";

export const router = createRouter({
  routeTree,
  context: { queryClient },
  defaultPreload: "intent",
});

declare module "@tanstack/react-router" {
  interface Register {
    router: typeof router;
  }
}
```

Key points:
- `context: { queryClient }` makes the query client available to all route loaders via `routeContext`
- `defaultPreload: "intent"` prefetches routes on hover/focus for snappy navigation
- The `Register` module declaration enables type-safe `Link` components and `useNavigate` across the app

### `src/routes/__root.tsx` -- root route with context

```typescript
import { createRootRouteWithContext, Outlet } from "@tanstack/react-router";
import type { QueryClient } from "@tanstack/react-query";

export interface RouterContext {
  queryClient: QueryClient;
}

export const Route = createRootRouteWithContext<RouterContext>()({
  component: RootComponent,
});

function RootComponent() {
  return <Outlet />;
}
```

Key points:
- `createRootRouteWithContext<RouterContext>()` types the context for all child routes
- The root component renders `<Outlet />` -- child routes render inside it
- Add global error boundaries or not-found handlers here if needed

### `routeTree.gen.ts` -- auto-generated route tree

This file is generated automatically by the TanStack Router Vite plugin. Never edit it manually. It updates whenever you add, remove, or rename route files in `src/routes/`.

If it gets out of sync, restart the Vite dev server -- the plugin regenerates it on startup.

---

## File-based Routing Conventions

All routes live in `src/routes/`. The file name determines the URL path.

### Directory structure

```
src/routes/
  __root.tsx              --> root layout (wraps everything)
  login.tsx               --> /login
  invitacion.tsx          --> /invitacion
  _auth.tsx               --> layout route (no URL segment)
  _auth/
    index.tsx             --> / (dashboard, under _auth layout)
    ganado/
      index.tsx           --> /ganado
      nuevo.tsx           --> /ganado/nuevo
      $animalId.tsx       --> /ganado/:animalId
      -components/
        animal-card.tsx   --> (ignored by router)
    fertilidad/
      index.tsx           --> /fertilidad
      -components/
        fertility-form-modal.tsx
    configuracion/
      index.tsx           --> /configuracion
```

### Convention reference

| Pattern | Example | URL |
|---------|---------|-----|
| Index route | `_auth/index.tsx` | `/` (parent path) |
| Static segment | `ganado/nuevo.tsx` | `/ganado/nuevo` |
| Dynamic param | `$animalId.tsx` | `/ganado/:animalId` |
| Layout route | `_auth.tsx` | No URL segment, wraps children |
| Pathless group | `_auth/` prefix | Groups routes under a layout |
| Co-located files | `-components/` | Ignored by the router |

### Layout routes (`_` prefix)

Files prefixed with `_` create layout routes. They render an `<Outlet />` that child routes fill in. They do not add a URL segment.

```
_auth.tsx         --> layout (sidebar, header, auth guard)
_auth/index.tsx   --> renders at /
_auth/ganado/     --> renders at /ganado/*
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

```typescript
// src/routes/_auth.tsx
import { createFileRoute, Outlet, redirect } from "@tanstack/react-router";
import { supabase } from "@/lib/supabase";
import { Sidebar } from "@/components/layout/sidebar";
import { MobileNav } from "@/components/layout/mobile-nav";
import { Header } from "@/components/layout/header";
import { ErrorBoundary } from "@/components/error-boundary";

export const Route = createFileRoute("/_auth")({
  beforeLoad: async () => {
    const {
      data: { session },
    } = await supabase.auth.getSession();
    if (!session) {
      throw redirect({ to: "/login" });
    }
    return { session };
  },
  component: AuthLayout,
});

function AuthLayout() {
  return (
    <div className="flex h-dvh overflow-hidden bg-cream">
      <div className="hidden lg:block">
        <Sidebar />
      </div>
      <div className="flex flex-1 flex-col overflow-hidden">
        <Header />
        <main className="flex-1 overflow-y-auto p-4 pb-24 sm:p-6 sm:pb-24 lg:pb-6">
          <ErrorBoundary>
            <Outlet />
          </ErrorBoundary>
        </main>
      </div>
      <div className="lg:hidden">
        <MobileNav />
      </div>
    </div>
  );
}
```

Key points:
- `beforeLoad` runs before any child route loads -- if the user is not authenticated, they are redirected before any content renders
- The `session` is returned from `beforeLoad` and available to child routes via `routeContext`
- All shared chrome (sidebar, header, mobile nav) lives in this layout -- child routes only render their own content
- Routes outside `_auth/` (like `login.tsx`, `invitacion.tsx`) are public and skip the auth check

### Redirect with return URL

Pass the current path as a search param so login can redirect back:

```typescript
beforeLoad: async ({ location }) => {
  const { data: { session } } = await supabase.auth.getSession();
  if (!session) {
    throw redirect({
      to: "/login",
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
routes/_auth/ganado/index.tsx     --> 400+ lines: list, card, form, filters, empty state
```

### After (decomposed)

```
routes/_auth/ganado/
  index.tsx                        --> page shell (~100 lines)
  $animalId.tsx                    --> detail page
  nuevo.tsx                        --> create page
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
    to: "/" as const,
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

interface LoginSearch {
  redirect?: string;
}

export const Route = createFileRoute("/login")({
  validateSearch: (search: Record<string, unknown>): LoginSearch => ({
    redirect: search.redirect as string | undefined,
  }),
  component: LoginPage,
});

function LoginPage() {
  const { redirect } = Route.useSearch();
  // Use redirect after successful login
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
