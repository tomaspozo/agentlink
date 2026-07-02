# Account & Connections

The **personal** account surface — everything scoped to `auth.uid()`, not to a
workspace. The scaffold ships three pieces: a profile page, a connections page,
and the avatar user menu in the top bar. All three are workspace-independent:
the display name, avatar, and OAuth grants belong to the user and follow them
across every workspace they're a member of.

## Contents

- [The account surface](#the-account-surface)
- [Profile — display name + avatar](#profile--display-name--avatar)
- [Connections — MCP/OAuth grants](#connections--mcpoauth-grants)
- [The user menu (avatar trigger)](#the-user-menu-avatar-trigger)
- [`lib/account.ts` helpers](#libaccountts-helpers)
- [Scaffolded files](#scaffolded-files)

---

## The account surface

| Route | Purpose | Data |
|-------|---------|------|
| `/account/profile` | Display name + avatar upload | `profile_get` / `profile_update` RPCs; avatar in the public `avatars` bucket |
| `/account/connections` | MCP/OAuth clients the user authorized | `supabase.auth.oauth.listGrants()` + `revokeGrant({ clientId })` |

Both live under `_auth/` (gated) and are reached from the top-bar
[user menu](#the-user-menu-avatar-trigger). They use `PageShell` + `PageHeader`
like every other page — see the frontend SKILL's page anatomy.

Because these are personal, **don't gate them on `useTenantGuard`/permissions** —
`auth.uid()` alone drives their policies. A signed-in user with zero workspaces
can still edit their profile and manage connections.

---

## Profile — display name + avatar

`routes/_auth/account/profile.tsx`. Two independent writes:

- **Display name** — a React Hook Form + Zod form that calls
  `typedRpc("profile_update", { p_display_name })` on submit, then invalidates
  the `["profile"]` query.
- **Avatar** — uploads **immediately on file pick** (not on form submit), then
  records the resulting public URL via `profile_update`.

### Avatar upload → the public `avatars` bucket

The avatar lives in a **public** Storage bucket, so its URL is stable and needs
no signing. Upload under the user's own folder (`<uid>/…`) — the bucket's RLS
policy (see `supabase/database/storage/avatars.sql`) only lets a user write
inside their own prefix.

```typescript
const ext = (file.name.split(".").pop() || "png").toLowerCase();
// Unique filename per upload → the public URL changes, so no CDN cache staleness.
const path = `${user.id}/${crypto.randomUUID()}.${ext}`;

const { error } = await supabase.storage
  .from("avatars")
  .upload(path, file, { contentType: file.type, upsert: true });
if (error) throw error;

// Public bucket → getPublicUrl (no signing). Persist the URL on the profile.
const { data } = supabase.storage.from("avatars").getPublicUrl(path);
await typedRpc("profile_update", { p_avatar_url: data.publicUrl });
```

Notes worth keeping:

- **Validate client-side** before upload — image mimetype + a size cap (the
  scaffold uses 3 MB). It's UX; the bucket/RLS is the real boundary.
- **Remove = empty string, not null.** `profile_update` COALESCEs `null` (leave
  unchanged), so clear the avatar with `p_avatar_url: ""`.
- A **public** bucket is the right call for avatars (they're shown to other
  members). Private user files would use a private bucket + signed URLs instead.

---

## Connections — MCP/OAuth grants

`routes/_auth/account/connections.tsx`. Lists the third-party apps (MCP clients
like Claude Code or Cursor) the user authorized against this project's OAuth
server, with a per-row **Disconnect**. Mirrors the Members roster visually: a
shadcn `Table`, an `EmptyState` when there's nothing, and a primary "Connect"
action opening the `ConnectMcpDialog` how-to.

Grants and revocation go through the GoTrue OAuth API, surfaced by the
`lib/account.ts` hooks:

```typescript
// Read — supabase.auth.oauth.listGrants()
const grantsQuery = useOAuthGrants();          // OAuthGrant[]

// Revoke one — supabase.auth.oauth.revokeGrant({ clientId })
const revoke = useRevokeGrant();
revoke.mutate(grant.client.id);                // invalidates ["oauth-grants"]
```

An `OAuthGrant` is `{ client: { id, name? }, scopes: string[], granted_at }`.
Wrap Disconnect in an `AlertDialog` — revoking immediately kills that client's
access. These grants are what the user's connected agents ride on: a
connected client acts **as the user**, using their permissions in their active
workspace (that's the confused-deputy-safe MCP model).

---

## The user menu (avatar trigger)

`components/user-menu.tsx`, mounted in `components/topbar.tsx`. The trigger is
an `Avatar` (image when `avatar_url` is set, otherwise `initialsFrom(name, email)`
in the fallback). The dropdown surfaces:

- **Signed in as** — display name + email
- **My profile** → `/account/profile`
- **My connections** → `/account/connections`
- **Theme** — Light / Dark / System submenu, calling `useDarkMode().setMode`
  immediately (a preference, not a form)
- **Sign out** — clears the active workspace, `supabase.auth.signOut()`,
  `queryClient.clear()`, navigate to `/sign-in`

The TopBar feeds it `email`, `displayName`, and `avatarUrl` from `useProfile()`,
and passes the navigation + sign-out callbacks. When the user has **no**
connected clients yet, the TopBar also shows a "Connect MCP" shortcut
(`hasNoConnections` from `useOAuthGrants()`).

---

## `lib/account.ts` helpers

One module backs the whole surface:

| Export | What it does |
|--------|--------------|
| `useProfile()` | `["profile"]` query → `typedRpc("profile_get")` (`{ display_name, avatar_url, email }`) |
| `useOAuthGrants()` | `["oauth-grants"]` query → `supabase.auth.oauth.listGrants()`; shared so the TopBar shortcut and the Connections page stay in sync |
| `useRevokeGrant()` | mutation → `supabase.auth.oauth.revokeGrant({ clientId })`, invalidates `["oauth-grants"]` |
| `initialsFrom(name, email)` | Two-letter avatar-fallback initials |
| `mcpServerUrl()` | This project's MCP endpoint (`<SUPABASE_URL>/functions/v1/mcp`) — what users paste into a client |
| `claudeConnectUrl()` | Deep link that opens Claude's "Add custom connector" modal pre-filled with the server name + URL |

---

## Scaffolded files

- `routes/_auth/account/profile.tsx` — profile page (name form + avatar upload)
- `routes/_auth/account/connections.tsx` — connections roster + disconnect
- `components/user-menu.tsx` — avatar-trigger dropdown
- `components/connect-mcp-dialog.tsx` — "Connect an MCP client" how-to
- `lib/account.ts` — profile + grants hooks and MCP URL helpers
- `supabase/database/storage/avatars.sql` — the public `avatars` bucket + its owner-scoped RLS
- RPCs: `api.profile_get`, `api.profile_update`
