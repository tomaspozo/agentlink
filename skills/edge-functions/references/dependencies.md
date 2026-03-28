# Dependencies & Deployment

How dependencies work in Supabase Edge Functions — import maps, per-function isolation, and deployment.

## Contents

- How Dependencies Work
- Per-Function `deno.json` (Required)
- Bare Specifiers
- Sub-Path Imports
- Version Pinning
- Global `deno.json`
- Deployment
- Anti-Patterns
- New Function Checklist
- `@supabase/server` Reference

---

## How Dependencies Work

Supabase Edge Functions run on Deno. Dependencies are declared in `deno.json` import maps, which map bare specifiers (like `@supabase/server`) to versioned `npm:` URLs.

**Each function must have its own `deno.json`** in its directory. This is the only way to guarantee dependencies resolve correctly during deployment.

```
supabase/functions/
├── my-function/
│   ├── index.ts          # imports from "@supabase/server"
│   └── deno.json          # maps "@supabase/server" → npm:@supabase/server@x.x.x
├── my-hono-function/
│   ├── index.ts           # imports from "hono", "@supabase/server/adapters/hono"
│   └── deno.json          # maps both hono and @supabase/server
└── deno.json              # global — only used for local dev fallback
```

---

## Per-Function `deno.json` (Required)

The global `supabase/functions/deno.json` works during local development (`npx supabase functions serve`), but **is not included** when deploying with `--use-api`. The deploy process bundles each function in isolation — only files inside the function's directory are available.

Every function directory needs its own `deno.json` with the dependencies that function actually uses. Keep it minimal — a function that only uses `@supabase/server` doesn't need `hono` entries.

**Standard function:**

```jsonc
// supabase/functions/my-function/deno.json
{
  "imports": {
    "@supabase/server": "npm:@supabase/server@0.1.0-alpha.1",
    "@supabase/supabase-js": "npm:@supabase/supabase-js@2"
  }
}
```

**Hono function:**

```jsonc
// supabase/functions/my-hono-function/deno.json
{
  "imports": {
    "@supabase/server/adapters/hono": "npm:@supabase/server@0.1.0-alpha.1/adapters/hono",
    "@supabase/supabase-js": "npm:@supabase/supabase-js@2",
    "hono": "npm:hono@4",
    "hono/cors": "npm:hono@4/cors",
    "hono/http-exception": "npm:hono@4/http-exception"
  }
}
```

---

## Bare Specifiers

Source files import from clean package names. The per-function `deno.json` handles resolution to the actual `npm:` URL.

```typescript
// ✅ CORRECT — bare specifiers, versions managed by deno.json
import { withSupabase } from "@supabase/server"
import { Hono } from "hono"
import { cors } from "hono/cors"
```

```typescript
// ❌ WRONG — inline npm: specifiers scatter versions across files
import { withSupabase } from "npm:@supabase/server@0.1.0-alpha.1"
```

Inline `npm:` specifiers technically work but they scatter version numbers across every file, make upgrades painful, trigger Deno lint warnings (`no-import-prefix`), and bypass the import map.

**Relative imports** for local shared code (`../_shared/responses.ts`, `../_ai/helpers.ts`) don't need `deno.json` entries — they resolve naturally.

---

## Sub-Path Imports

Deno import maps don't resolve sub-paths automatically. A mapping for `"hono"` does **not** cover `"hono/cors"` — each sub-path needs its own explicit entry.

```jsonc
// ❌ This does NOT automatically resolve "hono/cors" or "hono/http-exception"
{
  "imports": {
    "hono": "npm:hono@4"
  }
}
```

```jsonc
// ✅ Every sub-path import gets its own mapping
{
  "imports": {
    "hono": "npm:hono@4",
    "hono/cors": "npm:hono@4/cors",
    "hono/http-exception": "npm:hono@4/http-exception"
  }
}
```

Same for `@supabase/server` sub-paths:

```jsonc
{
  "imports": {
    "@supabase/server": "npm:@supabase/server@0.1.0-alpha.1",
    "@supabase/server/adapters/hono": "npm:@supabase/server@0.1.0-alpha.1/adapters/hono"
  }
}
```

---

## Version Pinning

Always pin versions in `deno.json`. Unversioned specifiers can pull in breaking changes without warning — especially dangerous for pre-release packages like `@supabase/server`.

```jsonc
// ✅ Pinned to exact version (recommended for pre-release packages)
"@supabase/server": "npm:@supabase/server@0.1.0-alpha.1"

// ✅ Pinned to major version (fine for stable packages)
"@supabase/supabase-js": "npm:@supabase/supabase-js@2"
"hono": "npm:hono@4"

// ❌ WRONG — no version, pulls latest and can break at any time
"@supabase/server": "npm:@supabase/server"
"hono": "npm:hono"
```

---

## Global `deno.json`

Keep the global `supabase/functions/deno.json` as a local development convenience. During `npx supabase functions serve`, Deno falls back to it if a per-function `deno.json` doesn't exist. But don't depend on it for deployment — only per-function `deno.json` files are included in the deploy bundle.

Keep the global file in sync with per-function files, but always ensure each function has its own copy.

---

## Deployment

Local dev and deployment resolve dependencies differently:

| Environment | Dependency source |
|-------------|-------------------|
| `npx supabase functions serve` | Per-function `deno.json` first, then global fallback |
| `npx supabase functions deploy --use-api` | Per-function `deno.json` only — global is excluded |

Always test both paths:

```bash
# Local development
npx supabase functions serve --env-file ./.env.local

# Deploy (identical to production bundling)
npx supabase functions deploy --use-api
```

The `--use-api` deploy bundles each function in isolation. Only files inside the function's directory are available. If the per-function `deno.json` is missing, deployment fails:

```
Failed to bundle the function (reason: Relative import path
"@supabase/server" not prefixed with / or ./ or ../)
```

---

## Anti-Patterns

### Relying on the global `deno.json` for deployment

```
supabase/functions/
├── deno.json              # Has all the mappings
├── my-function/
│   └── index.ts           # Imports "@supabase/server"
│                           # ❌ No deno.json here — BREAKS on deploy
```

### Using inline `npm:` specifiers in source files

```typescript
// ❌ Scatters versions, triggers lint warnings, bypasses import map
import { withSupabase } from "npm:@supabase/server@0.1.0-alpha.1"
```

### Assuming sub-path resolution from a parent mapping

```typescript
// deno.json has "hono": "npm:hono@4" but NOT "hono/cors"
import { cors } from "hono/cors"  // ❌ Fails — needs explicit mapping
```

### Using unversioned specifiers

```jsonc
// ❌ No version — can silently pull breaking changes
{
  "imports": {
    "@supabase/server": "npm:@supabase/server",
    "hono": "npm:hono"
  }
}
```

Always pin: exact for pre-release (`@0.1.0-alpha.1`), major for stable (`@2`, `@4`).

### Putting relative imports in `deno.json`

The import map is only for external packages. Relative imports (`../_shared/responses.ts`) resolve naturally and don't need entries.

---

## New Function Checklist

1. Create the function directory: `supabase/functions/my-function/`
2. Add `index.ts` with bare specifier imports
3. Add `deno.json` with the function's specific dependencies
4. Add the function config to `supabase/config.toml`:
   ```toml
   [functions.my-function]
   enabled = true
   verify_jwt = false
   ```
5. Test locally: `npx supabase functions serve`
6. Deploy: `npx supabase functions deploy --use-api`

---

## `@supabase/server` Reference

- **Package:** [@supabase/server](https://www.npmjs.com/package/@supabase/server)
- **Current version:** `0.1.0-alpha.1`
- **Export paths:**
  - `@supabase/server` — core `withSupabase` wrapper
  - `@supabase/server/core` — lower-level primitives
  - `@supabase/server/adapters/hono` — Hono framework adapter
  - `@supabase/server/wrappers` — additional wrapper utilities

Standard `deno.json` entry:

```jsonc
"@supabase/server": "npm:@supabase/server@0.1.0-alpha.1"
```

With Hono adapter:

```jsonc
"@supabase/server/adapters/hono": "npm:@supabase/server@0.1.0-alpha.1/adapters/hono"
```
