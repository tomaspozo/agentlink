# Rendering — SPA now, SSR later

> The scaffold ships a **TanStack Start app in SPA mode** (fully client-rendered, no server). This reference covers (1) the SPA-mode config and static deploy, and (2) how to switch on server-side rendering later — a config change, not a rewrite — including the `@supabase/ssr` cookie auth you'd add at that point.

## Contents
- SPA mode (the default)
- Static deployment
- Switching on SSR
- Server auth with @supabase/ssr (only once SSR is on)
- Cookie handling

---

## SPA mode (the default)

`vite.config.ts` enables SPA mode on the TanStack Start plugin:

```ts
import { tanstackStart } from "@tanstack/react-start/plugin/vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import { defineConfig } from "vite";

export default defineConfig({
  resolve: { alias: { "@": "/src" } },
  plugins: [
    tailwindcss(),
    tanstackStart({ spa: { enabled: true } }),
    react(),
  ],
});
```

In SPA mode TanStack Start:
- **does not** run `beforeLoad`/loaders on the server,
- **does not** server-render route components,
- prerenders a static HTML **shell** (`_shell.html`) — your `__root.tsx` `shellComponent` — and ships a client bundle that hydrates and takes over routing.

`src/routes/__root.tsx` is split: `shellComponent` is the server-prerendered document (`<html>/<head>/<body>`, `<HeadContent/>`, `<Scripts/>`, the dark-mode-before-paint script), and `component` holds the in-body app (providers + `<Outlet/>`) which renders on the client only. Keep anything that reads the browser or `import.meta.env` — notably the Supabase client — inside `component`, never the shell, or the prerender will try to construct it at build time with no env.

---

## Static deployment

`vite build` produces static assets plus the prerendered shell. Serve the assets and **rewrite unknown paths to the shell** so client-side routes resolve on hard navigation / refresh:

- **Netlify** — `public/_redirects`: `/* /_shell.html 200`
- **Vercel / Cloudflare Pages / S3+CloudFront** — a catch-all rewrite of 404s to `/_shell.html`.

No Node server is required — host it anywhere static.

---

## Switching on SSR

Moving off SPA mode does **not** require rewriting routes, loaders, or components. Three knobs:

1. **Turn SPA mode off** in `vite.config.ts`:
   ```ts
   tanstackStart({ spa: { enabled: false } })   // or drop the spa option
   ```
2. **Set the default** in `createStart` (server entry) with `defaultSsr: true | false`.
3. **Opt routes in/out** individually:
   ```ts
   export const Route = createFileRoute("/dashboard")({
     ssr: true,          // server-render this route's component + run loaders on the server
     // ssr: 'data-only' // run beforeLoad/loader on the server, render the component on the client
     // ssr: false       // keep this route client-only
   });
   ```

The same router, routes, loaders, and any `createServerFn` server functions carry over. You then deploy to a Node/edge host instead of static hosting.

---

## Server auth with @supabase/ssr (only once SSR is on)

A browser client stores the session in `localStorage`, which server code can't read. When you enable SSR and want authenticated Supabase calls in server loaders / server functions, switch the server-side client to cookie-based sessions with `@supabase/ssr`:

```bash
npm install @supabase/ssr
```

```typescript
// Server-side client — bound to the request's cookies.
import { createServerClient } from "@supabase/ssr";

export function createServerSupabase(getCookies: () => { name: string; value: string }[],
                                     setCookies: (c: { name: string; value: string; options: any }[]) => void) {
  return createServerClient(
    import.meta.env.VITE_SUPABASE_URL,
    import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY,
    {
      db: { schema: "api" },
      cookies: {
        getAll() { return getCookies(); },
        setAll(cookiesToSet) { setCookies(cookiesToSet); },
      },
    },
  );
}
```

Wire `getCookies`/`setCookies` to TanStack Start's request/response context (read the request cookie header on the way in, set `Set-Cookie` on the way out) so the session refreshes on every server request. The browser-side client stays on `@supabase/supabase-js` as today.

---

## Cookie handling

- `@supabase/ssr` stores auth tokens in cookies so both browser and server can read them; refresh on every server request keeps the session alive.
- Cookies default to `HttpOnly`, `Secure`, `SameSite=Lax`.
- The session is split across multiple cookies to stay within size limits.
- Never manually read or write Supabase auth cookies — let the library handle it.
