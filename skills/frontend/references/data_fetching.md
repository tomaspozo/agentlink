# Data Fetching Patterns -- TanStack Query + Supabase RPC

Data fetching and caching with TanStack Query, using `typedRpc()` to call Supabase RPC functions. Covers query client setup, query factories, mutations, cache invalidation, type safety, and loading states.

## Contents
- QueryClient Configuration
- Query Factory Pattern
- Mutation Pattern
- Query Key Structure
- typedRpc() Helper
- Cache Invalidation Strategies
- Loading and Error States
- Provider Nesting Order

---

## QueryClient Configuration

```typescript
// src/lib/query-client.ts
import { QueryClient } from "@tanstack/react-query";

export const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      staleTime: 1000 * 60 * 2, // 2 minutes
      retry: 1,
      refetchOnWindowFocus: false,
    },
  },
});
```

Why these defaults:
- **2-minute staleTime** -- Supabase RPC data does not change between requests from the same user session frequently enough to justify constant refetching. Two minutes prevents redundant network calls during normal navigation without letting data go truly stale.
- **1 retry** -- RPC errors from Postgres (validation, RLS denials) are deterministic and will not succeed on retry. A single retry catches transient network issues without hammering a consistently failing endpoint.
- **No refetchOnWindowFocus** -- Users switching between tabs should not trigger a flood of requests. Data freshness is handled by explicit invalidation after mutations.

---

## Query Factory Pattern

Query factories centralize query definitions for each entity. Each factory is an object with methods that return `queryOptions()` -- ready to pass to `useQuery()` or `useSuspenseQuery()`.

```typescript
// src/queries/animals.ts
import { queryOptions } from "@tanstack/react-query";
import { typedRpc } from "@/lib/supabase";

export const animalQueries = {
  list: (params?: {
    status?: string | null;
    sex?: string | null;
    breed?: string | null;
    search?: string | null;
    limit?: number;
    offset?: number;
  }) =>
    queryOptions({
      queryKey: ["animals", "list", params],
      queryFn: async () => {
        const result = await typedRpc("animal_list", {
          p_status: params?.status ?? null,
          p_sex: params?.sex ?? null,
          p_breed: params?.breed ?? null,
          p_search: params?.search ?? null,
          p_limit: params?.limit ?? null,
          p_offset: params?.offset ?? null,
        });
        return { items: result.data, total: result.total };
      },
    }),

  detail: (animalId: string) =>
    queryOptions({
      queryKey: ["animals", "detail", animalId],
      queryFn: async () =>
        typedRpc("animal_get_by_id", { p_animal_id: animalId }),
      enabled: !!animalId,
    }),
};
```

### File organization

```
src/queries/
  animals.ts         --> animalQueries.list(), animalQueries.detail()
  health.ts          --> healthQueries.list(), healthQueries.listByAnimal()
  fertility.ts       --> fertilityQueries.list(), fertilityQueries.listByAnimal()
  dashboard.ts       --> dashboardQueries.summary()
  reports.ts         --> reportQueries.inventory(), reportQueries.health()
```

One file per entity. Each exports a single factory object. Name the factory `{entity}Queries`.

### Usage in components

```typescript
import { useQuery } from "@tanstack/react-query";
import { animalQueries } from "@/queries/animals";

function AnimalDetailPage({ animalId }: { animalId: string }) {
  const { data, isLoading, error } = useQuery(animalQueries.detail(animalId));
  // ...
}
```

### Queries with no parameters

For queries that take no arguments (like dashboard summaries), the factory method takes no params:

```typescript
export const dashboardQueries = {
  summary: () =>
    queryOptions({
      queryKey: ["dashboard", "summary"],
      queryFn: async () => typedRpc("dashboard_summary"),
    }),
};
```

---

## Mutation Pattern

Mutations live in `src/mutations/` with one file per entity. Each mutation is a custom hook that wraps `useMutation()`.

```typescript
// src/mutations/animals.ts
import { useMutation, useQueryClient } from "@tanstack/react-query";
import { typedRpc } from "@/lib/supabase";

export function useCreateAnimal() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: async (input: {
      tag_number: string;
      sex: string;
      name: string | null;
      breed: string | null;
      birth_date: string | null;
      weight_kg: number | null;
      notes: string | null;
    }) => {
      return typedRpc("animal_create", {
        p_tag_number: input.tag_number,
        p_sex: input.sex,
        p_name: input.name,
        p_breed: input.breed,
        p_birth_date: input.birth_date,
        p_weight_kg: input.weight_kg,
        p_notes: input.notes,
      });
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["animals"] });
    },
  });
}

export function useUpdateAnimal() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: async (input: {
      animal_id: string;
      tag_number: string | null;
      name: string | null;
      // ... other fields
    }) => {
      return typedRpc("animal_update", {
        p_animal_id: input.animal_id,
        p_tag_number: input.tag_number,
        p_name: input.name,
        // ...
      });
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["animals"] });
    },
  });
}

export function useDeleteAnimal() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: async (input: { animal_id: string }) => {
      return typedRpc("animal_delete", { p_animal_id: input.animal_id });
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["animals"] });
    },
  });
}
```

Key points:
- Each mutation is a named hook: `useCreate{Entity}`, `useUpdate{Entity}`, `useDelete{Entity}`
- `onSuccess` invalidates related queries so the UI updates automatically
- The `input` type is defined inline -- it maps form data to RPC parameter names
- Toast feedback and form reset are handled at the call site, not in the mutation hook (see Forms reference)

### Usage at the call site

```typescript
const createAnimal = useCreateAnimal();

createAnimal.mutate(formData, {
  onSuccess: () => {
    toast.success("Animal created");
    form.reset();
    onOpenChange(false);
  },
  onError: (err) => toast.error(err.message),
});
```

---

## Query Key Structure

Query keys follow the pattern: `["entity", "operation", params]`.

```typescript
["animals", "list", { status: "active", search: "Luna" }]
["animals", "detail", "uuid-123"]
["dashboard", "summary"]
["health", "list", { limit: 20, offset: 0 }]
["health", "listByAnimal", { animalId: "uuid-123" }]
```

### Why this structure matters

The hierarchical key structure enables smart invalidation:

```typescript
// Invalidate ALL animal queries (list + detail + any future operations)
queryClient.invalidateQueries({ queryKey: ["animals"] });

// Invalidate only animal lists (all filter combinations)
queryClient.invalidateQueries({ queryKey: ["animals", "list"] });

// Invalidate one specific detail query
queryClient.invalidateQueries({ queryKey: ["animals", "detail", animalId] });
```

### Rules

- First segment is always the entity name (plural): `"animals"`, `"health"`, `"fertility"`
- Second segment is the operation: `"list"`, `"detail"`, `"summary"`, `"listByAnimal"`
- Third segment (optional) is the params object or ID string
- Include filter/pagination params in the key so different filters get different cache entries
- Use `null` (not `undefined`) for empty filter values -- `undefined` values are stripped from objects and can cause key mismatches

---

## typedRpc() Helper

The Supabase client types all RPC return values as `Json` because the Postgres functions return `jsonb`. The `typedRpc()` helper restores real TypeScript types.

### The problem

```typescript
// Generated database types say:
// animal_get_by_id: { Args: { p_animal_id: string }; Returns: Json }
const { data } = await supabase.rpc("animal_get_by_id", { p_animal_id: id });
// data is typed as `Json` -- useless for type-safe access
```

### The solution

```typescript
// src/lib/supabase.ts
import { createClient } from "@supabase/supabase-js";
import type { Database } from "@/types/database.types";
import type { RpcReturnMap } from "@/types/models";

export const supabase = createClient<Database>(
  import.meta.env.VITE_SUPABASE_URL,
  import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY,
  { db: { schema: "api" } },
);

type ApiFunctions = Database["api"]["Functions"];
type TypedRpcName = keyof ApiFunctions & keyof RpcReturnMap;

type AcceptNull<T> = {
  [K in keyof T]: undefined extends T[K] ? T[K] | null : T[K];
};

export async function typedRpc<F extends TypedRpcName>(
  fn: F,
  ...args: ApiFunctions[F]["Args"] extends Record<string, never>
    ? []
    : [AcceptNull<ApiFunctions[F]["Args"]>]
): Promise<RpcReturnMap[F]> {
  const { data, error } = await supabase.rpc(fn, args[0] as any);
  if (error) throw error;
  return data as unknown as RpcReturnMap[F];
}
```

### RpcReturnMap

```typescript
// src/types/models.ts
export interface RpcReturnMap {
  animal_create: Animal;
  animal_update: Animal;
  animal_delete: { success: boolean };
  animal_get_by_id: Animal;
  animal_list: PaginatedResponse<Animal>;
  health_record_create: HealthRecord;
  health_record_list: PaginatedResponse<HealthRecord>;
  dashboard_summary: DashboardSummary;
  // ... add an entry every time you create a new RPC
}
```

### When to update RpcReturnMap

Every time you create a new RPC function in `api` schema, add a corresponding entry to `RpcReturnMap` in `src/types/models.ts`. Without it, `typedRpc()` will not accept the function name.

Steps:
1. Define the return type interface in `src/types/models.ts` (e.g., `export interface Animal { ... }`)
2. Add the RPC name and return type to `RpcReturnMap`
3. Use `typedRpc("new_function_name", { ... })` -- fully typed

### AcceptNull

Database-generated types use `?:` (optional) for nullable RPC parameters, meaning they accept `T | undefined`. But in practice, you often want to pass `null` explicitly (e.g., `p_breed: selectedBreed ?? null`). The `AcceptNull<T>` utility type adds `| null` to every optional parameter so both `null` and `undefined` work.

---

## Cache Invalidation Strategies

### After create -- invalidate the list

```typescript
onSuccess: () => {
  queryClient.invalidateQueries({ queryKey: ["animals"] });
},
```

This invalidates both list and detail queries for the entity. The list query will refetch to include the new item.

### After update -- invalidate the entity

```typescript
onSuccess: () => {
  queryClient.invalidateQueries({ queryKey: ["animals"] });
},
```

Same pattern as create. Both list and detail caches are stale after an update.

### After delete -- invalidate the entity

```typescript
onSuccess: () => {
  queryClient.invalidateQueries({ queryKey: ["animals"] });
},
```

### Cross-entity invalidation

Some mutations affect multiple entities. A birth record might need to invalidate fertility data too:

```typescript
// src/mutations/births.ts
export function useCreateBirth() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: async (input) => typedRpc("birth_create", { ... }),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["births"] });
      queryClient.invalidateQueries({ queryKey: ["fertility"] });
      queryClient.invalidateQueries({ queryKey: ["dashboard"] });
    },
  });
}
```

### Rules

- Invalidate at the entity level (`["animals"]`) unless you have a specific reason to be more granular
- Never mass-invalidate everything -- scope to the affected query keys
- If a mutation touches dashboard data, invalidate `["dashboard"]` too
- Keep invalidation in the mutation `onSuccess` -- not at the call site -- so it is consistent everywhere the mutation is used

---

## Loading and Error States

Every list page follows a three-state pattern: loading, empty, and data.

### The three-state pattern

```typescript
function AnimalsPage() {
  const { data, isLoading } = useQuery(animalQueries.list(params));
  const items = data?.items ?? [];

  if (isLoading) {
    return (
      <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
        {[...Array(6)].map((_, i) => (
          <Skeleton key={i} className="h-32" />
        ))}
      </div>
    );
  }

  if (items.length === 0) {
    return (
      <EmptyState
        icon={CowIcon}
        title="No animals registered"
        description="Start by registering your first animal."
        action={{ label: "Register animal", to: "/animals/new", icon: Plus }}
      />
    );
  }

  return (
    <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
      {items.map((animal) => (
        <AnimalCard key={animal.id} animal={animal} />
      ))}
    </div>
  );
}
```

### Skeleton loading

Use `<Skeleton>` components that match the shape of the actual content:
- For card grids: render 6 skeleton cards in the same grid layout
- For tables: render skeleton rows
- For detail pages: render skeleton blocks matching the section layout

### Empty state

Use `<EmptyState>` with:
- An icon matching the entity
- A title explaining the empty state
- A description with guidance
- An optional action button (link to create page or modal trigger)

Distinguish between "no data at all" and "no results for current filters":

```typescript
if (items.length === 0 && hasFilters) {
  return (
    <EmptyState
      icon={SearchIcon}
      title="No results"
      description="Try different search terms or clear your filters."
    />
  );
}
```

---

## Provider Nesting Order

The provider hierarchy in `src/main.tsx` follows a specific nesting order:

```typescript
// src/main.tsx
createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <QueryClientProvider client={queryClient}>
      <AuthProvider>
        <RouterProvider router={router} />
        <Toaster position="top-right" />
      </AuthProvider>
    </QueryClientProvider>
  </StrictMode>,
);
```

### Why this order

```
QueryClientProvider     <-- outermost: available to everything including auth
  AuthProvider          <-- auth state: available to router and all routes
    RouterProvider      <-- routing: renders route tree, has access to auth + queries
    Toaster             <-- toast notifications: sibling to router, always visible
```

- **QueryClientProvider** is outermost because auth logic and route loaders both need access to the query client
- **AuthProvider** wraps the router so auth state is available in `beforeLoad` hooks and all route components
- **RouterProvider** renders the actual route tree
- **Toaster** is a sibling to the router (not nested inside) so toasts are visible during route transitions
