# Native MCP Server

Your app ships a **native MCP server** at `supabase/functions/mcp/` — a per-user, OAuth 2.1 protected resource server that lets Claude, Cursor, or any MCP client call your app's RPCs on the user's behalf. It mirrors `withSupabase`: the whole function file is `export default { fetch: withMCP(info, registerTools) }`, and all the plumbing lives in `_shared/mcp.ts`.

The thing you'll do most is **add a domain tool** — one `ctx.workspaceTool(...)` call per `api.*` RPC you want to expose. The DB stays the enforcement boundary: the tool runs as the user, and `auth_verify_access` + RLS decide what they can see and do.

## Contents

- [What it is](#what-it-is)
- [Add a domain tool (the main thing)](#add-a-domain-tool-the-main-thing)
- [The `ctx` toolkit](#the-ctx-toolkit)
- [`registerAdminTools` — the free admin surface](#registeradmintools--the-free-admin-surface)
- [config.toml (and the cloud caveat)](#configtoml-and-the-cloud-caveat)
- [Rules](#rules)

---

## What it is

`withMCP(info, registerTools)` returns a fetch handler — wired exactly like the other functions (`export default { fetch: withMCP(...) }`, no `Deno.serve`). The handler in `_shared/mcp.ts` owns the request flow so your function file only registers tools. It:

- **Serves OAuth 2.1 resource-server discovery** — RFC 9728 metadata at `/.well-known/oauth-protected-resource` (reachable unauthenticated) plus a spec `401` with a `WWW-Authenticate: Bearer resource_metadata="…"` header. That's how an MCP client discovers Supabase Auth and logs the user in itself — you write no login code.
- **Binds each request to the caller's own JWT** via `createSupabaseContext(req, { auth: "user" })` (the primitive `withSupabase` is built on). A present-but-invalid token is rejected, never downgraded to anon.
- **Applies the identity-only workspace model.** The JWT proves identity only; the active workspace is asserted **per request** by the `x-workspace-id` header and validated server-side by the `public._auth_pre_request` db-pre-request hook. `workspaceTool` attaches that header for you.

On each request the wrapper resolves the caller, discovers their workspaces (`tenant_list`, membership-scoped by `auth.uid()`), builds an `McpServer`, and runs your `registerTools(ctx)` callback.

---

## Add a domain tool (the main thing)

Expose an `api.*` RPC as a workspace-scoped tool with `ctx.workspaceTool`. You provide the name, the tool config, and a handler that just calls the RPC:

```ts
import { withMCP, registerAdminTools, z } from "../_shared/mcp.ts";

export default {
  fetch: withMCP({ title: Deno.env.get("APP_NAME"), icon: ICON }, (ctx) => {
    registerAdminTools(ctx); // optional — see below

    ctx.workspaceTool(
      "list_notes",
      {
        title: "List notes",
        description: "List notes in a workspace, newest first. Optionally filter by status.",
        inputSchema: { status: z.string().optional() },
      },
      ({ supabase, status }) => supabase.rpc("note_list", { p_status: status ?? null }),
    );

    ctx.workspaceTool(
      "create_note",
      {
        title: "Create note",
        description: "Create a note in a workspace. Requires note.create there.",
        inputSchema: { title: z.string().min(1), body: z.string().optional() },
      },
      ({ supabase, title, body }) =>
        supabase.rpc("note_create", { p_title: title, p_body: body ?? null }),
    );
  }),
};
```

What `workspaceTool` does for you, so the handler stays a one-liner:

1. **Adds a `workspace` arg** to your `inputSchema` (id or slug; optional — defaults to the caller's only workspace, or asks them to pick if they have several).
2. **Resolves it** against the caller's workspaces.
3. **Binds a workspace-scoped client** — a user-bound client that attaches `x-workspace-id: <resolved id>`, so the db-pre-request hook pins the right tenant.
4. **Calls your handler** with `{ supabase, workspaceId, ...args }`.
5. **Wraps the RPC `{ data, error }`** into an MCP tool result (`error` → `isError`).

So your handler is only `({ supabase, ...args }) => supabase.rpc("your_rpc", { ... })`. You do **not** check permissions, resolve tenants, or format results in the tool — the DB does the authz (`auth_verify_access('<perm>')` raises `42501` → surfaced as a tool error; RLS on `tenant_id` isolates rows), and the wrapper does the formatting. Descriptions are the tool's contract with the agent — say what it does and which permission it needs.

For a workspace-less call (create a workspace, list all workspaces), use `ctx.supabase` (the base user client, no header) directly with `ctx.tool` — see `create_workspace` / `list_workspaces` in `registerAdminTools`.

---

## The `ctx` toolkit

`registerTools(ctx)` receives the full `@supabase/server` caller context plus the MCP helpers:

| Member | What it is |
|---|---|
| `ctx.supabase` | Base **user** client (caller's JWT, **no** workspace header). Use for workspace-less RPCs (`tenant_list`, `tenant_create`). |
| `ctx.userClaims` | The validated user claims. |
| `ctx.jwtClaims` | Raw JWT claims. |
| `ctx.authMode` | How the caller authenticated. |
| `ctx.workspaceTool(name, config, handler)` | Register a workspace-scoped tool (the main one — see above). |
| `ctx.tool(name, config, handler)` | Register a raw tool — full control over args and the returned MCP result. |
| `ctx.clientFor(workspaceId)` | Get a user client bound to a specific workspace (what `workspaceTool` uses internally). |
| `ctx.resolveSingle(arg?)` | Resolve a `workspace` arg (id or slug) to one tenant id, or an error message. |
| `z` | The **same** zod instance the SDK validates against — always `import { z } from "../_shared/mcp.ts"`, never a separate zod. |
| `ctx.rpcResult`, `ctx.toolError`, `ctx.WORKSPACE_ARG` | Result/error wrappers and the shared workspace arg, for hand-rolled tools. |

**`supabaseAdmin` is deliberately absent.** There is no service-role client on `ctx` — and you must never construct one in a tool. See rule 7 below.

---

## `registerAdminTools` — the free admin surface

`registerAdminTools(ctx)` is **opt-in**: call it to expose 10 generic multitenancy tools every AgentLink app gets for free —

- **Discovery:** `list_workspaces`
- **Members:** `list_members`, `update_member_role`, `remove_member`
- **Invitations:** `list_invitations`, `invite_member`, `revoke_invitation`
- **Workspaces:** `create_workspace`, `update_workspace`, `delete_workspace`

It's a normal registration call, so you can omit it entirely, keep it and add your own tools alongside, or call it and then override individual tools by re-registering the same name. Each is a thin `workspaceTool` (or `tool`) over an `api.*` RPC — copy any of them as a template for your own.

---

## config.toml (and the cloud caveat)

Two blocks make the server work. The scaffold sets these; keep them:

```toml
[functions.mcp]
verify_jwt = false   # so unauthenticated OAuth discovery reaches the handler;
                     # withMCP does its own JWT check via auth:'user'

[auth.oauth_server]
enabled = true
authorization_url_path = "/oauth/consent"
allow_dynamic_registration = true
```

- `verify_jwt = false` is required (same reason as every `withSupabase` function): the gateway must let the public discovery request and the wrapper's own auth flow through.
- `[auth.oauth_server]` turns Supabase Auth into the OAuth 2.1 authorization server MCP clients log into, with dynamic client registration so clients enroll themselves.

**Cloud caveat:** `[auth.oauth_server]` **cannot be enabled via the Management API** — `config.toml` only takes effect locally. In a cloud project you must enable it by hand in **Dashboard → Authentication → OAuth Server**. If MCP clients can't complete login against a deployed project, this is the first thing to check.

---

## Rules

1. **Never use a service-role client in a tool.** `ctx` has no `supabaseAdmin` on purpose — a tool that acts with elevated privilege on behalf of a user is a confused-deputy hole. Tools run as the user; the DB enforces access. If RLS or `auth_verify_access` blocks something a user should be able to do, fix the RPC/policy — don't reach around it.
2. **Handlers just call the `api.*` RPC.** No permission checks, tenant resolution, or result formatting in the tool — `workspaceTool` and the DB own those.
3. **Import `z` from `../_shared/mcp.ts`**, not a fresh zod — schemas must be built with the exact module the SDK validates against.
4. **Keep `verify_jwt = false`** for the `mcp` function, and remember the cloud OAuth-server toggle lives in the Dashboard.
5. **Write descriptions for the agent.** The `title`/`description` are how an MCP client decides when and how to call your tool — state what it does and which permission it needs.
