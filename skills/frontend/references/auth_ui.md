# Auth UI Patterns

Client-side authentication UI: sign-in, sign-up, password reset, email confirmation, magic links, and workspace-invitation acceptance. The CLI scaffolds a complete canonical flow in the React + TanStack Start (SPA) frontend — this doc explains how the pieces fit together so you can customize without breaking it.

## Contents

- [Identity-only model (2.0)](#identity-only-model-20)
- [Canonical flow](#canonical-flow)
- [Page-by-page reference](#page-by-page-reference)
- [Hooks layer](#hooks-layer)
- [Auth state changes & listener safety](#auth-state-changes--listener-safety)
- [Customizing without breaking the flow](#customizing-without-breaking-the-flow)
- [Cross-device PKCE: why OTP-paste is always visible](#cross-device-pkce)
- [OAuth callback (extension point)](#oauth-callback-extension-point)
- [Post-auth actions (e.g. invitation acceptance)](#post-auth-actions)
- [Permission gating (authorization UX)](#permission-gating-authorization-ux)

---

## Identity-only model (2.0)

The JWT proves **identity only** — it carries no workspace and no permissions.
The active workspace is a **per-request** choice, asserted with an
`x-workspace-id` header that `lib/supabase.ts` injects on every Data-API
request. Role and permissions are read from `api.session_context()` for that
workspace, not from the token.

This is why the flows below **never** call `supabase.auth.refreshSession()` to
"pick up" a workspace, never decode the JWT for a tenant claim, and never call
`api.tenant_select()`. Sign-in and invite-accept just establish identity; the
`WorkspaceProvider` then resolves the active workspace and its context. See the
[frontend SKILL](../SKILL.md#workspaces-roles--permissions) for the workspace
context itself.

---

## Canonical flow

```
                         ┌─── /sign-in ────────► /dashboard (session created)
                         │       │
                         │       └── magic link ─► sends email
                         │                          │
                         ▼                          ▼
            /sign-up ─────signup─► /check-inbox?type=signup|magiclink|recovery
                         │                          │
                         │                  ┌───────┴────────┐
                         │              click link        paste OTP
                         │                  │                │
                         │                  ▼                ▼
                         │           /auth/confirm   verifyOtp({type, token, email})
                         │                  │                │
                         │                  └────────┬───────┘
                         │                           │
                         │              type=signup|magiclink → /dashboard
                         │              type=recovery        → /update-password
                         │              type=email_change    → success page
                         │
            /forgot-password ────► /check-inbox?type=recovery
                         │
                         ▼
                  /update-password ─► /dashboard

            /accept-invite?token=&[code=]     (self-contained: inline create-account / sign-in)
                         │
                         ├─ signed out, new user      → inline create-account form
                         │      └─ email confirmation on → /check-inbox?type=signup&next=/accept-invite?token=…
                         │            (paste OTP or click link) → back to /accept-invite → auto-join
                         ├─ ?code present (return)     → exchangeCodeForSession → session → auto-join
                         └─ session, email matches     → invitation_accept → setActive(joined) → invalidate ["tenants"] → /dashboard

            /settings/members  (in-app, gated)
                         ├─ membership_list    — show members + roles
                         ├─ invitation_list    — show pending invites
                         ├─ invitation_create  — invite (queue-driven)
                         ├─ invitation_resend  — re-enqueue email for existing invitation
                         ├─ invitation_revoke  — cancel pending invite
                         ├─ membership_update_role
                         └─ membership_remove
```

Two consolidations to keep in mind:

1. **One `/auth/confirm` route** handles signup / magiclink / recovery / email_change link-clicks. It reads `?type=…` and branches. Invites are NOT routed through here — they have `/accept-invite` because the URL also carries `?token=` for the `invitation_accept` RPC.

2. **One `/check-inbox` page** replaces the old `sign-up-success`. It's parameterized by `?type=signup|magiclink|recovery` and renders the same shell with type-specific copy. Resend + OTP-paste are baked in.

---

## Page-by-page reference

| Path | Purpose | Hook used | Navigation targets |
|------|---------|-----------|--------------------|
| `/sign-in` | Email+password sign-in with magic-link toggle | `useSignInFlow`, `useMagicLinkFlow` | password ok → `next \|\| /dashboard`; magic-link ok → `/check-inbox?type=magiclink&email=…` |
| `/sign-up` | New account creation | `useSignUpFlow` | session returned → `/dashboard`; pending → `/check-inbox?type=signup&email=…` |
| `/check-inbox` | Pending email state — Resend + OTP entry | `useResendEmail`, `useVerifyOtpFlow` | recovery → `/update-password`; signup/magiclink → `/dashboard` |
| `/forgot-password` | Request a recovery email | `useResetPasswordFlow` | success → `/check-inbox?type=recovery&email=…` |
| `/update-password` | Set a new password (recovery destination + in-app change) | `useUpdatePasswordFlow` | success → `/dashboard` |
| `/auth/confirm` | Single PKCE callback for link clicks | `useEffect` `exchangeCodeForSession` | branches on `?type=` |
| `/accept-invite` | Workspace invitation acceptance | `useAcceptInvitation` (+ inline PKCE exchange) | accepted → `setActive(joined)` → `/dashboard`; logged out → `/sign-in?next=…` |
| `/settings/members` | Admin: list, invite, revoke, resend, update role, remove | RPC calls (no hooks layer needed) | mutations refresh the table |

### Route layout

```
src/routes/
  __root.tsx                       — document shell + providers (see frontend SKILL)
  index.tsx                       — public landing
  _anon.tsx                       — anon-only layout (redirects signed-in users to /dashboard)
  _anon/
    sign-in.tsx
    sign-up.tsx
    check-inbox.tsx
    forgot-password.tsx
  update-password.tsx              — TOP-LEVEL, not under _anon (recovery sessions
                                     have a session, so _anon would bounce them)
  auth.confirm.tsx                  — TOP-LEVEL PKCE callback
  accept-invite.tsx                 — TOP-LEVEL (workspace invitation)
  _auth.tsx                         — gated layout (redirects to /sign-in)
  _auth/
    dashboard.tsx
    settings/
      members.tsx
```

Gating is by folder: `_anon/*` is anon-only, `_auth/*` is gated (each via the layout route's `beforeLoad`), and top-level files are public.

---

## Hooks layer

`src/lib/auth/` ships a set of hooks. Each wraps one Supabase call with the canonical post-call logic — friendly errors via `formatAuthError`, discriminated result state, etc. Hooks do not navigate; they return state and the page picks the destination. (Identity-only model: no hook calls `refreshSession()` to bake in a workspace — there is no tenant claim to refresh.)

| Hook | Wraps | Returns |
|------|-------|---------|
| `useSignUpFlow` | `auth.signUp` | `{ submit, loading, error }` — `submit` returns `{ kind: "pending", email } \| { kind: "authenticated" } \| null` |
| `useSignInFlow` | `auth.signInWithPassword` | `{ submit, loading, error }` — `submit` returns `boolean` |
| `useMagicLinkFlow` | `auth.signInWithOtp` | `{ submit, loading, error, sentTo }` |
| `useResetPasswordFlow` | `auth.resetPasswordForEmail` | `{ submit, loading, error, sentTo }` |
| `useUpdatePasswordFlow` | `auth.updateUser({ password })` | `{ submit, loading, error }` |
| `useVerifyOtpFlow(kind)` | `auth.verifyOtp` | `{ submit, loading, error }` — `submit` returns a `VerifyResult` discriminator |
| `useResendEmail({ type, email })` | type-aware: `auth.resend`, `signInWithOtp`, `resetPasswordForEmail` | `{ resend, loading, error, cooldownLeft }` |
| `useAcceptInvitation` | `invitation_accept` RPC + `setActiveWorkspaceId(joined)` | `{ accept, loading, error, setError }` — the `/accept-invite` state machine does the PKCE `exchangeCodeForSession` inline and calls `accept()` on click |

### `useResendEmail` is type-aware

`supabase.auth.resend({ type })` only accepts `'signup'` and `'email_change'`. The hook handles other types by re-calling the original send API:

- `signup` → `auth.resend({ type: 'signup' })`
- `magiclink` → `signInWithOtp({ email })` again (new token, old still valid until use)
- `recovery` → `resetPasswordForEmail(email)` again
- `invite` → **NOT supported** here; workspace invitations resend via `api.invitation_resend` from `/settings/members`

### `useSignUpFlow` — branching on `data.session`

The hook checks `data.session`, not `data.user.email_confirmed_at`. The latter can be written asynchronously and is unsafe to race on.

```typescript
const result = await signUp.submit({ email, password, displayName, organizationName });
if (result?.kind === "pending") {
  // Email confirmation required → router to /check-inbox?type=signup&email=…
} else if (result?.kind === "authenticated") {
  // Confirmation disabled (scaffold dev default) → /dashboard
}
```

When a session IS returned, the user is signed in immediately — **no
`refreshSession()`**. The AFTER-INSERT trigger materializes the user's default
workspace; `WorkspaceProvider` then loads `api.tenant_list()` and selects it on
the next render. There's no tenant claim to bake into the token, so there's
nothing to refresh.

### `useVerifyOtpFlow` — type mapping

When verifying email-confirmation OTPs, supabase-js wants `type: 'email'` (the canonical value), not `'signup'`. The hook collapses user-facing kinds to SDK values:

- `signup`, `magiclink`, `invite` → SDK `type: 'email'`
- `recovery` → SDK `type: 'recovery'`

---

## Auth state changes & listener safety

`supabase.auth.onAuthStateChange` is how you react to sign-in / sign-out /
token refresh. The scaffold's `AuthProvider` already subscribes for `{ user,
session }`; you only touch this when building a callback page or a custom
post-auth action.

```typescript
const { data: { subscription } } = supabase.auth.onAuthStateChange(
  (event, session) => {
    if (event === "SIGNED_OUT") window.location.href = "/sign-in";
  },
);
subscription.unsubscribe(); // clean up on unmount
```

**Version floor: supabase-js ≥ 2.107.0.** v2.107.0 (PR #2392) removed the
`navigator.locks`-based auth mutex — the root cause of async-callback deadlocks
and "Lock broken by another request" errors. The scaffold pins this floor; keep
it. On older versions you'd need `setTimeout(…, 0)` deferral around every
Supabase call made from a listener.

**Keep callbacks synchronous.** Even post-fix, the async `onAuthStateChange`
overload is `@deprecated`, and awaiting inside a `TOKEN_REFRESHED` handler
carries a residual re-entry risk. Dispatch Supabase work outside the callback:

```typescript
supabase.auth.onAuthStateChange((event) => {
  if (event === "TOKEN_REFRESHED") {
    void supabase.rpc("some_function"); // ✅ dispatch — don't await in the callback
  }
});
```

**Dual-path race — `onAuthStateChange` + `getSession()`.** A *logic* race that
survives the ≥ 2.107.0 fix. A callback page reading a URL fragment has two
paths resolve concurrently: `onAuthStateChange` fires when the fragment is
consumed, and `getSession()` resolves once the session exists. If both trigger
the same post-auth action it runs **twice**. Guard it — see
[Post-auth actions](#post-auth-actions).

---

## Customizing without breaking the flow

What you can change freely:
- Copy, headings, descriptions
- Layout, spacing, colors (the visual system's tokens live in `src/styles.css` — see [Theming & customization](../SKILL.md#theming--customization))
- Form field order, validation messages
- Add OAuth providers (see [extension point](#oauth-callback-extension-point))
- Move pages around — but keep the URL paths stable, because `internal-send-auth-email` builds verify URLs from `REDIRECT_PATHS`

What's load-bearing — change carefully:
- **`useSignUpFlow`'s `!data.session` branch.** Skipping it produces the silent-failure bug (sign-up succeeds, no UI feedback, user stuck on the form).
- **The `/accept-invite` guard.** Two paths can race during invite acceptance — see [Post-auth actions](#post-auth-actions). The page/`useAcceptInvitation` flow already guards it; don't reorder its operations.
- **PKCE flow type.** `auth.confirm` and `/accept-invite` rely on `exchangeCodeForSession`, which requires `flowType: 'pkce'`. The scaffold sets it explicitly in `src/lib/supabase.ts`.

What you no longer need (identity-only model):
- **No `refreshSession()` after signup or invite-accept.** There's no tenant claim in the JWT to refresh — the active workspace is a header, resolved by `WorkspaceProvider`. Don't reintroduce a post-auth refresh to "load the workspace."
- **`/update-password` is NOT under `_anon`.** Recovery sessions have a session, so `_anon` would bounce them away. Keep it top-level.

What's load-bearing — never change:
- The `REDIRECT_PATHS` shape in `internal-send-auth-email/index.ts`. The keys are GoTrue's `email_action_type` vocabulary; the values must be valid paths in your app. Adding a new key only works if Supabase Auth emits that action type.
- The `additional_redirect_urls` allowlist in `config.toml`. PKCE callbacks fail if the URL isn't in the allowlist. The default ships wildcards for local development; production needs your real domain there.

---

## Cross-device PKCE

PKCE stores a `code_verifier` in `localStorage` on the device that *initiated* the auth flow. If the user signs up on a laptop and opens the email on their phone, the verifier isn't there → `exchangeCodeForSession` fails with "invalid request: both auth code and code verifier should be non-empty".

This is the single biggest reason the OTP-paste input on `/check-inbox` is **always visible**, not hidden behind a toggle. Pasting the 8-digit code carries no verifier requirement and works regardless of device.

Don't change this UX. Hiding the OTP input is a footgun.

If you need to support a workflow where the email is always opened on a different device, consider switching to implicit flow (`flowType: 'implicit'`) — but the OTP becomes redundant, and you'd give up the PKCE guarantees the scaffold relies on.

---

## OAuth callback (extension point)

The scaffold doesn't ship OAuth providers (Google, GitHub, etc.) by default — wire them up by adding a callback route alongside `/auth/confirm`.

### Trigger sign-in (client)

```typescript
async function handleOAuthSignIn(provider: "google" | "github") {
  const { error } = await supabase.auth.signInWithOAuth({
    provider,
    options: {
      redirectTo: `${window.location.origin}/auth/callback?next=/dashboard`,
    },
  });
  if (error) setError(formatAuthError(error));
  // Browser redirects to the OAuth provider — no need to handle success here
}
```

### Callback route

```typescript
// src/routes/auth.callback.tsx
import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { useEffect } from "react";
import { supabase } from "@/lib/supabase";

export const Route = createFileRoute("/auth/callback")({
  component: AuthCallbackPage,
});

function AuthCallbackPage() {
  const navigate = useNavigate();

  useEffect(() => {
    const { data: { subscription } } = supabase.auth.onAuthStateChange(
      (event) => {
        if (event === "SIGNED_IN") navigate({ to: "/dashboard", replace: true });
      },
    );
    return () => subscription.unsubscribe();
  }, [navigate]);

  return <p>Completing sign in…</p>;
}
```

For the OAuth-via-magic-link case where `auth.callback` does the same thing as `auth.confirm`, you can route them to a single handler — but keep the URLs distinct so the email-link flow doesn't accidentally inherit OAuth-specific behavior later.

---

## Post-auth actions

When the auth callback must perform an action after sign-in (e.g., accept an invitation, claim a referral), two concurrent paths resolve and can both fire:

1. `onAuthStateChange` fires `SIGNED_IN` when the URL hash fragment is consumed
2. `getSession()` resolves once the session is established

If both trigger the same work, the action runs **twice** (e.g., a double `invitation_accept`). On supabase-js < 2.107.0 this also surfaced as **"Lock broken by another request"** errors from the `navigator.locks`-based auth mutex; that mutex was removed in v2.107.0 (PR #2392), so the lock error is gone — but the double-execution is a plain logic bug that remains. The guard flag below fixes it regardless of SDK version.

The `/accept-invite` flow already implements the canonical guard pattern. If you build a similar flow, mirror it:

- **Guard flag**: `let handled = false` — only the first path executes
- **Keep the `onAuthStateChange` callback synchronous** — dispatch the async work (`void doWork()`) rather than `await`-ing inside the listener (the async overload is still `@deprecated`)

```typescript
import { setActiveWorkspaceId } from "@/lib/active-workspace";

useEffect(() => {
  let handled = false;

  async function doWork() {
    if (handled) return;
    handled = true;
    const { data, error } = await supabase.rpc("invitation_accept", { p_token: token });
    if (error) { /* ... */ return; }
    // Identity-only: land the user in the workspace they just joined by
    // selecting it — its id rides as the x-workspace-id header. No refreshSession.
    if (data?.id) setActiveWorkspaceId(data.id);
    navigate("/dashboard");
  }

  const { data: { subscription } } = supabase.auth.onAuthStateChange((event) => {
    if (event === "SIGNED_IN") void doWork(); // dispatch — keep the listener synchronous
  });

  supabase.auth.getSession().then(({ data: { session } }) => {
    if (session) void doWork();
  });

  return () => subscription.unsubscribe();
}, [token, navigate]);
```

---

## Known auth response quirks

| Symptom | Cause | Fix |
|---------|-------|-----|
| Sign-up returns "User already registered" but the user never finished confirmation | Auth keeps the unconfirmed user. Looks like a duplicate. | Send them to resend (`useResendEmail({ type: 'signup' })`) |
| Sign-in returns "Email not confirmed" | Session not issued yet | Render the "resend confirmation" CTA — don't ask for a different password |
| "Email rate limit exceeded" | ~4 signups from the same IP within an hour | Show the rate-limit copy, not a generic error. The 30s cooldown on `useResendEmail` reduces the chance of hitting this. |
| Auth deadlock / "Lock broken by another request" | supabase-js < 2.107.0 `navigator.locks` mutex + `await` inside `onAuthStateChange` | Pin supabase-js ≥ 2.107.0 (PR #2392 removed the mutex). Still keep listeners synchronous — dispatch Supabase work outside them, never `await` inside a `TOKEN_REFRESHED` handler |
| Invite link "Invalid or expired" on second click | `invitation_accept` checks `accepted_at IS NULL` | The scaffold's `_internal_admin_complete_invitation` is idempotent — it returns success when the user already has a membership in the invited tenant |

The `formatAuthError` helper in `lib/auth-errors.ts` maps these to friendly copy. Use it everywhere instead of surfacing raw Supabase strings.

---

## Permission gating (authorization UX)

> **UX only — never security.** The backend `auth_verify_access()` guard inside
> every mutating RPC is the real gate (returns HTTP 403). The frontend just
> avoids showing controls/pages the user can't use. Bypassing the UI still
> hits the 403. Permissions come from `api.session_context()` for the **active
> workspace** (via `WorkspaceProvider`) — never from the JWT.

`useHasPermission(permission, mode?)` returns a boolean,
failing safe to `false` until the active workspace's context has resolved.
Disable mutating buttons; hide nav.

```tsx
const canManage = useHasPermission("membership.update");
<Button disabled={!canManage}>Change role</Button>

// hide a nav entry entirely:
<RequirePermission permission="membership.read">
  <NavLink to="/settings/members">Members</NavLink>
</RequirePermission>
```

### Recipe — guard a page (TanStack Router `beforeLoad`)

```tsx
// routes/_auth/settings/members.tsx
import { requirePermission } from "@/lib/require-permission";

export const Route = createFileRoute("/_auth/settings/members")({
  beforeLoad: () => requirePermission("membership.read"), // → redirect /forbidden
  component: MembersPage,
});
```

`requirePermission` runs outside React: it reads the session, resolves (and
defaults, if needed) the active workspace via `ensureWorkspaceContext()`, reads
that workspace's permissions from `api.session_context()`, then redirects —
`/sign-in` when signed out, `/no-workspace` when the account has none, or
`/forbidden` when the permission is missing (a route under `_auth`, so the
TopBar/workspace switcher stays mounted). No refresh race — permissions are
derived fresh server-side, not from a token claim. Client controls inside the
page gate with the same `useHasPermission(...)`.
