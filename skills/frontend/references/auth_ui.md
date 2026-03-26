# Auth UI Patterns

Client-side authentication UI — sign-in/sign-up forms, OAuth redirect flows, and protected routes.

> **Vite projects:** The scaffold provides auth infrastructure (`AuthProvider`, `_auth.tsx` guard) but not auth pages. Build login/sign-up pages based on the project's auth strategy.

## Contents
- Vite Auth Infrastructure
- Sign-In / Sign-Up Forms
- OAuth Redirect Flow
- Protected Routes

---

## Vite Auth Infrastructure

### Auth context

The scaffold provides `AuthProvider` and `useAuth()` in `src/contexts/auth-context.tsx`:

```typescript
import { useAuth } from "@/contexts/auth-context";

function MyComponent() {
  const { user, session, loading } = useAuth();
  // user: User | null, session: Session | null, loading: boolean
}
```

The `AuthProvider` wraps the app in `main.tsx` and manages a single Supabase auth subscription. All components share the same auth state — no duplicate subscriptions.

### Protected routes (TanStack Router layout)

The scaffold uses a `_auth.tsx` layout route that guards all child routes via `beforeLoad`:

```typescript
// src/routes/_auth.tsx
import { createFileRoute, Outlet, redirect } from "@tanstack/react-router";
import { supabase } from "@/lib/supabase";
import { ErrorBoundary } from "@/components/error-boundary";

export const Route = createFileRoute("/_auth")({
  beforeLoad: async () => {
    const { data: { session } } = await supabase.auth.getSession();
    if (!session) throw redirect({ to: "/login" });
    return { session };
  },
  component: AuthLayout,
});

function AuthLayout() {
  return (
    <main className="min-h-dvh bg-background">
      <ErrorBoundary>
        <Outlet />
      </ErrorBoundary>
    </main>
  );
}
```

All routes under `src/routes/_auth/` are automatically protected. No wrapper component needed — the router handles it before the page even renders.

### Auth callback (PKCE flow)

For OAuth redirects, magic links, and email confirmations, `onAuthStateChange` handles the token exchange automatically. Create a dedicated route if you need custom post-auth logic:

```typescript
// src/routes/auth-callback.tsx
import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { useEffect } from "react";
import { supabase } from "@/lib/supabase";

export const Route = createFileRoute("/auth-callback")({
  component: AuthCallbackPage,
});

function AuthCallbackPage() {
  const navigate = useNavigate();

  useEffect(() => {
    const { data: { subscription } } = supabase.auth.onAuthStateChange(
      (event) => {
        if (event === "SIGNED_IN") {
          navigate({ to: "/", replace: true });
        }
      }
    );
    return () => subscription.unsubscribe();
  }, [navigate]);

  return <div>Completing sign in...</div>;
}
```

---

## Sign-In / Sign-Up Forms

### Email + password form

```typescript
"use client";
import { createClient } from "@/lib/supabase/client";
import { useState } from "react";

export function SignInForm() {
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const supabase = createClient();

  async function handleSignIn(e: React.FormEvent) {
    e.preventDefault();
    setLoading(true);
    setError(null);

    const { error } = await supabase.auth.signInWithPassword({
      email,
      password,
    });

    if (error) {
      setError(error.message);
      setLoading(false);
      return;
    }

    // Redirect — middleware or onAuthStateChange handles navigation
    window.location.href = "/dashboard";
  }

  return (
    <form onSubmit={handleSignIn}>
      <input
        type="email"
        value={email}
        onChange={(e) => setEmail(e.target.value)}
        placeholder="Email"
        required
      />
      <input
        type="password"
        value={password}
        onChange={(e) => setPassword(e.target.value)}
        placeholder="Password"
        required
      />
      {error && <p>{error}</p>}
      <button type="submit" disabled={loading}>
        {loading ? "Signing in..." : "Sign in"}
      </button>
    </form>
  );
}
```

### Sign-up form

Same pattern as sign-in, but use `supabase.auth.signUp()`:

```typescript
const { data, error } = await supabase.auth.signUp({
  email,
  password,
});

if (error) {
  setError(error.message);
  return;
}

// If email confirmation is enabled, tell the user to check their inbox
if (data.user && !data.user.email_confirmed_at) {
  setMessage("Check your email for a confirmation link.");
}
```

### Magic link (passwordless)

```typescript
const { error } = await supabase.auth.signInWithOtp({
  email,
  options: {
    emailRedirectTo: `${window.location.origin}/auth/callback`,
  },
});

if (error) {
  setError(error.message);
  return;
}

setMessage("Check your email for a login link.");
```

---

## OAuth Redirect Flow

### Trigger sign-in

```typescript
async function handleOAuthSignIn(provider: "google" | "github") {
  const { error } = await supabase.auth.signInWithOAuth({
    provider,
    options: {
      redirectTo: `${window.location.origin}/auth/callback`,
    },
  });

  if (error) {
    setError(error.message);
  }
  // Browser redirects to the OAuth provider — no need to handle success here
}
```

### Callback page

After the OAuth provider redirects back, exchange the code for a session:

```typescript
// Next.js: src/app/auth/callback/route.ts
import { createClient } from "@/lib/supabase/server";
import { NextResponse } from "next/server";

export async function GET(request: Request) {
  const { searchParams, origin } = new URL(request.url);
  const code = searchParams.get("code");
  const next = searchParams.get("next") ?? "/dashboard";

  if (code) {
    const supabase = await createClient();
    const { error } = await supabase.auth.exchangeCodeForSession(code);
    if (!error) {
      return NextResponse.redirect(`${origin}${next}`);
    }
  }

  // Auth failed — redirect to error page
  return NextResponse.redirect(`${origin}/auth/error`);
}
```

```typescript
// SvelteKit: src/routes/auth/callback/+server.ts
import { redirect } from "@sveltejs/kit";
import type { RequestHandler } from "./$types";
import { createClient } from "$lib/supabase/server";

export const GET: RequestHandler = async ({ url, cookies }) => {
  const code = url.searchParams.get("code");
  const next = url.searchParams.get("next") ?? "/dashboard";

  if (code) {
    const supabase = createClient(cookies);
    const { error } = await supabase.auth.exchangeCodeForSession(code);
    if (!error) {
      redirect(303, next);
    }
  }

  redirect(303, "/auth/error");
};
```

---

## Protected Routes

### Server-side (recommended)

Check auth in server components or load functions. This prevents flash of unauthenticated content.

```typescript
// Next.js: src/app/dashboard/layout.tsx
import { createClient } from "@/lib/supabase/server";
import { redirect } from "next/navigation";

export default async function DashboardLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();

  if (!user) redirect("/login");

  return <>{children}</>;
}
```

```typescript
// SvelteKit: src/routes/dashboard/+layout.server.ts
import { redirect } from "@sveltejs/kit";
import type { LayoutServerLoad } from "./$types";

export const load: LayoutServerLoad = async ({ locals }) => {
  if (!locals.user) redirect(303, "/login");
  return { user: locals.user };
};
```

### Client-side guard (Vite SPA)

For Vite projects, the `_auth.tsx` layout route handles this automatically via `beforeLoad`. No separate guard component is needed — see the "Vite Auth Patterns" section above.

For Next.js projects without SSR, guard in client components:

```typescript
"use client";
import { createClient } from "@/lib/supabase/client";
import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";

export function ProtectedRoute({ children }: { children: React.ReactNode }) {
  const [loading, setLoading] = useState(true);
  const router = useRouter();
  const supabase = createClient();

  useEffect(() => {
    supabase.auth.getUser().then(({ data: { user } }) => {
      if (!user) {
        router.push("/login");
      } else {
        setLoading(false);
      }
    });
  }, []);

  if (loading) return null; // or a spinner

  return <>{children}</>;
}
```

### Sign-out

Call `supabase.auth.signOut()` directly — no wrapper needed:

```typescript
import { supabase } from "@/lib/supabase";
import { useQueryClient } from "@tanstack/react-query";
import { useNavigate } from "@tanstack/react-router";

function SignOutButton() {
  const navigate = useNavigate();
  const queryClient = useQueryClient();

  const handleSignOut = async () => {
    await supabase.auth.signOut();
    queryClient.clear(); // clear cached data
    navigate({ to: "/login" });
  };

  return <button onClick={handleSignOut}>Sign out</button>;
}
```
