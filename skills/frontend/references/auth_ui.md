# Auth UI Patterns

Client-side authentication UI: sign-in, sign-up, password reset, email confirmation, magic links, and workspace-invitation acceptance. The scaffold ships a complete canonical flow in the React + TanStack Start (SPA) template — this doc explains how the pieces fit together so you can customize without breaking it.

## Contents

- [Canonical flow](#canonical-flow)
- [Page-by-page reference](#page-by-page-reference)
- [Hooks layer](#hooks-layer)
- [Customizing without breaking the flow](#customizing-without-breaking-the-flow)
- [Cross-device PKCE: why OTP-paste is always visible](#cross-device-pkce)
- [OAuth callback (extension point)](#oauth-callback-extension-point)
- [Post-auth actions (e.g. invitation acceptance)](#post-auth-actions)

---

## Canonical flow

One diagram, both templates.

```
                         ┌─── /auth/sign-in ───► /dashboard (session created)
                         │       │
                         │       └── magic link ─► sends email
                         │                          │
                         ▼                          ▼
            /auth/sign-up ─signup─► /auth/check-inbox?type=signup|magiclink|recovery
                         │                          │
                         │                  ┌───────┴────────┐
                         │              click link        paste OTP
                         │                  │                │
                         │                  ▼                ▼
                         │           /auth/confirm   verifyOtp({type, token, email})
                         │                  │                │
                         │                  └────────┬───────┘
                         │                           │
                         │              type=signup|magiclink → refreshSession → /dashboard
                         │              type=recovery        → /update-password
                         │              type=email_change    → success page
                         │
            /auth/forgot-password ─► /auth/check-inbox?type=recovery
                         │
                         ▼
                  /update-password ─► /dashboard

            /accept-invite?token=&[code=]
                         │
                         ├─ ?code present (new user)   → exchangeCodeForSession → invitation_accept → refreshSession → /dashboard
                         └─ no ?code (existing user)   → if no session: /auth/sign-in?next=/accept-invite?token=...
                                                       → else: invitation_accept → refreshSession → /dashboard

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

2. **One `/auth/check-inbox` page** replaces the old `sign-up-success`. It's parameterized by `?type=signup|magiclink|recovery` and renders the same shell with type-specific copy. Resend + OTP-paste are baked in.

---

## Page-by-page reference

| Path | Purpose | Hook used | Navigation targets |
|------|---------|-----------|--------------------|
| `/auth/sign-in` | Email+password sign-in with magic-link toggle | `useSignInFlow`, `useMagicLinkFlow` | password ok → `next \|\| /dashboard`; magic-link ok → `/auth/check-inbox?type=magiclink&email=…` |
| `/auth/sign-up` | New account creation | `useSignUpFlow` | session returned → `/dashboard`; pending → `/auth/check-inbox?type=signup&email=…` |
| `/auth/check-inbox` | Pending email state — Resend + OTP entry | `useResendEmail`, `useVerifyOtpFlow` | recovery → `/update-password`; signup/magiclink → `/dashboard` |
| `/auth/forgot-password` | Request a recovery email | `useResetPasswordFlow` | success → `/auth/check-inbox?type=recovery&email=…` |
| `/update-password` | Set a new password (recovery destination + in-app change) | `useUpdatePasswordFlow` | success → `/dashboard` |
| `/auth/confirm` | Single PKCE callback for link clicks | `useEffect` `exchangeCodeForSession` | branches on `?type=` |
| `/accept-invite` | Workspace invitation acceptance | `useAcceptInvite` | accepted → `/dashboard`; logged out → `/auth/sign-in?next=…` |
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

`src/lib/auth/` ships a set of hooks. Each wraps one Supabase call with the canonical post-call logic — friendly errors via `formatAuthError`, post-signup `refreshSession()` so the JWT carries the `tenant_id` claim, etc. Hooks do not navigate; they return discriminated state and the page picks the destination.

| Hook | Wraps | Returns |
|------|-------|---------|
| `useSignUpFlow` | `auth.signUp` | `{ submit, loading, error }` — `submit` returns `{ kind: "pending", email } \| { kind: "authenticated" } \| null` |
| `useSignInFlow` | `auth.signInWithPassword` | `{ submit, loading, error }` — `submit` returns `boolean` |
| `useMagicLinkFlow` | `auth.signInWithOtp` | `{ submit, loading, error, sentTo }` |
| `useResetPasswordFlow` | `auth.resetPasswordForEmail` | `{ submit, loading, error, sentTo }` |
| `useUpdatePasswordFlow` | `auth.updateUser({ password })` | `{ submit, loading, error }` |
| `useVerifyOtpFlow(kind)` | `auth.verifyOtp` | `{ submit, loading, error }` — `submit` returns a `VerifyResult` discriminator |
| `useResendEmail({ type, email })` | type-aware: `auth.resend`, `signInWithOtp`, `resetPasswordForEmail` | `{ resend, loading, error, cooldownLeft }` |
| `useAcceptInvite` | `exchangeCodeForSession` + `invitation_accept` RPC | `{ loading, error }` (auto-runs on mount with auth-lock guard) |

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
  // Email confirmation required → router to /auth/check-inbox?type=signup&email=…
} else if (result?.kind === "authenticated") {
  // Confirmation disabled (scaffold dev default) → /dashboard
}
```

When a session IS returned, the hook calls `refreshSession()` internally so the JWT picks up the `tenant_id` claim that `_internal_admin_handle_new_user` populates AFTER the initial mint.

### `useVerifyOtpFlow` — type mapping

When verifying email-confirmation OTPs, supabase-js wants `type: 'email'` (the canonical value), not `'signup'`. The hook collapses user-facing kinds to SDK values:

- `signup`, `magiclink`, `invite` → SDK `type: 'email'`
- `recovery` → SDK `type: 'recovery'`

---

## Customizing without breaking the flow

What you can change freely:
- Copy, headings, descriptions
- Layout, spacing, colors (the visual system in `index.css` / `globals.css`)
- Form field order, validation messages
- Add OAuth providers (see [extension point](#oauth-callback-extension-point))
- Move pages around — but keep the URL paths stable, because `internal-send-auth-email` builds verify URLs from `REDIRECT_PATHS`

What's load-bearing — change carefully:
- **`useSignUpFlow`'s `!data.session` branch.** Skipping it produces the silent-failure bug (sign-up succeeds, no UI feedback, user stuck on the form).
- **`refreshSession()` after signup.** The trigger writes `tenant_id` AFTER the initial JWT is minted; without refresh, every tenant-scoped RPC fails until the user reloads.
- **`useAcceptInvite`'s auth-lock guard.** Two paths can race for the auth lock during invite acceptance — see [Post-auth actions](#post-auth-actions). The hook already implements the guard; don't reorder its operations.
- **PKCE flow type.** `auth.confirm` and `useAcceptInvite` rely on `exchangeCodeForSession`, which requires `flowType: 'pkce'`. The scaffold sets it explicitly in `src/lib/supabase.ts`.
- **`/update-password` is NOT under `_anon`.** Recovery sessions have a session, so `_anon` would bounce them away. Keep it top-level.

What's load-bearing — never change:
- The `REDIRECT_PATHS` shape in `internal-send-auth-email/index.ts`. The keys are GoTrue's `email_action_type` vocabulary; the values must be valid paths in your app. Adding a new key only works if Supabase Auth emits that action type.
- The `additional_redirect_urls` allowlist in `config.toml`. PKCE callbacks fail if the URL isn't in the allowlist. The default ships wildcards for local development; production needs your real domain there.

---

## Cross-device PKCE

PKCE stores a `code_verifier` in `localStorage` on the device that *initiated* the auth flow. If the user signs up on a laptop and opens the email on their phone, the verifier isn't there → `exchangeCodeForSession` fails with "invalid request: both auth code and code verifier should be non-empty".

This is the single biggest reason the OTP-paste input on `/auth/check-inbox` is **always visible**, not hidden behind a toggle. Pasting the 8-digit code carries no verifier requirement and works regardless of device.

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

When the auth callback must perform an action after sign-in (e.g., accept an invitation, claim a referral), two concurrent paths race for the auth lock:

1. `onAuthStateChange` fires `SIGNED_IN` when the URL hash fragment is consumed
2. `getSession()` resolves once the session is established

If both trigger the same async work, the SDK's serializer competes with itself and produces **"Lock broken by another request"** errors.

The `useAcceptInvite` hook already implements the canonical guard pattern. If you build a similar flow, mirror it:

- **Guard flag**: `let handled = false` — only the first path executes
- **Non-async `onAuthStateChange` callback** — do not `await` inside (holds the lock)
- **Defer `refreshSession()`** — call it in a `setTimeout(0)` after the RPC succeeds

```typescript
useEffect(() => {
  let handled = false;

  async function doWork() {
    if (handled) return;
    handled = true;
    const { error } = await supabase.rpc("invitation_accept", { p_token: token });
    if (error) { /* ... */ return; }
    setTimeout(() => supabase.auth.refreshSession().then(() => navigate("/dashboard")), 0);
  }

  const { data: { subscription } } = supabase.auth.onAuthStateChange((event) => {
    if (event === "SIGNED_IN") doWork(); // NOT async, no await here
  });

  supabase.auth.getSession().then(({ data: { session } }) => {
    if (session) doWork();
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
| `refreshSession()` deadlock | Called inside `onAuthStateChange` callback | Refresh after explicit user actions (signup, invite accept), not inside listeners |
| Invite link "Invalid or expired" on second click | `invitation_accept` checks `accepted_at IS NULL` | The scaffold's `_internal_admin_complete_invitation` is idempotent — it returns success when the user already has a membership in the invited tenant |

The `formatAuthError` helper in `lib/auth-errors.ts` maps these to friendly copy. Use it everywhere instead of surfacing raw Supabase strings.

---

## Permission gating (authorization UX)

> **UX only — never security.** The backend `auth_verify_access()` guard inside
> every mutating RPC is the real gate (returns HTTP 403). The frontend just
> avoids showing controls/pages the user can't use. Bypassing the UI still
> hits the 403. Permissions come from the JWT `app_metadata.permissions` for
> the **active workspace**.

`useHasPermission(permission, mode?)` (both templates) returns a boolean,
failing safe to `false` while loading. Disable mutating buttons; hide nav.

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

`requirePermission` reads the session, refreshes once if the tenant claim
isn't present yet (fresh-signup race), then redirects to `/forbidden` (a route
under `_auth`, so the TopBar/workspace switcher stays mounted). Client controls
inside the page gate with the same `useHasPermission(...)`.
