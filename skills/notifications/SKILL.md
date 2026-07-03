---
name: notifications
description: Transactional and notification emails (welcome, "your export is ready", "payment failed", receipts, alerts) on Supabase — everything that is NOT a Supabase Auth email. Use when the task involves sending an app-driven email, adding a new email template, firing email from a database event or trigger, or debugging delivery of a non-auth email. Activate whenever the task touches api._admin_send_email, internal-send-email, public.internal_logs_email, or "send an email when X happens." For Supabase AUTH emails (signup confirm, magic link, password reset, email change) use the auth skill instead; for per-environment Resend setup (API key, FROM address) use the cli skill.
---

# Notifications (Transactional Email)

App-driven emails — welcome, "your export is ready", "payment failed", receipts,
digests, alerts. Anything fired by **your** code or a **DB event**, as opposed to
Supabase Auth's own emails (those go through the `auth` skill's email hook).

The infrastructure already exists in every scaffolded project. You do **not** build
a queue, a worker, a cron, or a retry loop — you **register a template** and **call
one RPC**.

## The one rule: send from the server, never the client

Transactional email is **service-role only**. The entry point —
`api._admin_send_email(...)` — is `SECURITY DEFINER`, granted to `service_role`,
and revoked from `anon`/`authenticated`. Fire it from a DB trigger, another
`SECURITY DEFINER` function, or a `secret`-auth edge function. **Never** expose an
RPC that lets a client send arbitrary email (recipient + content) — that is a spam
and spoofing vector. The events that need email (signup, export done, payment
failed) originate server-side anyway.

## How it flows

```
server-side event ─→ api._admin_send_email('<email_id>', recipient, params, dedupe_key)
   │   inserts public.internal_logs_email (status 'queued', unique dedupe_key)
   │   enqueues api._admin_enqueue_task('internal-send-email', { log_id })
   ▼
internal-queue-worker  (existing, generic) ──invoke──▶ internal-send-email
   │   loads the log row (api._admin_email_log_get)
   │   if status='sent' → skip (idempotent);  else: TEMPLATES[email_id] → render → Resend.send
   ▼
api._admin_email_log_mark(log_id, 'sent'|'failed', resend_id, error)
```

This reuses the **same** queue + worker that powers auth emails and workspace
invites. PGMQ's visibility-timeout + `read_ct` already give you retry-with-backoff
and a dead-letter (archive) after `QUEUE_MAX_RETRIES` — see the
[edge-functions](../edge-functions/SKILL.md) and [database](../database/SKILL.md)
skills for the queue/worker model. The 1-minute cron is only a safety net;
`api._admin_send_email` fires the worker immediately via `pg_net`, so latency is
seconds, not a minute.

## Send an email

```sql
-- From any SECURITY DEFINER function or trigger (service_role context):
PERFORM api._admin_send_email(
  'export_ready',                                   -- email_id (template key)
  v_user_email,                                     -- recipient
  jsonb_build_object('download_url', v_url),        -- params → template props
  'export_ready:' || v_export_id::text              -- dedupe_key (optional, recommended)
);
```

- **`dedupe_key`** is your idempotency guarantee. A partial unique index on
  `internal_logs_email.dedupe_key` means one row — and therefore one email — per
  key, even if the trigger fires twice. Use a stable id (`<event>:<entity-id>`).
  Omit it only for genuinely fire-and-forget sends.
- **Params are untrusted jsonb.** The template's `render()` narrows them — never
  assume a shape. Keep params small and serializable.

## Add a new transactional email

Three steps, all mirroring the shipped `welcome` example:

1. **Template** — create `supabase/functions/internal-send-email/_templates/<name>.tsx`,
   a React Email component that composes the shared chrome from
   `supabase/functions/_shared/email-components/` (`EmailLayout`, `EmailButton`,
   `typography`). Match the existing templates' structure.
2. **Register** — add an entry to the `TEMPLATES` registry in
   `supabase/functions/internal-send-email/index.ts`, keyed by your `email_id`,
   with a `subject(params, appName)` and a `render(params, appName)` that validates
   params and returns the React element.
3. **Fire** — call `api._admin_send_email('<email_id>', recipient, params, dedupe_key)`
   from the server-side event that should trigger it (a trigger, an `_internal_admin_*`
   function, or a `secret`-auth edge function).

Then `pnpm exec agentlink db apply` (for any new SQL) and deploy the function.

## The sample: welcome email

The scaffold ships one working example so the path is live on day one:
`public._internal_welcome_on_profile()` is fired by an **AFTER INSERT trigger on
`public.profiles`** and enqueues the `welcome` template. It is intentionally routed
through this queue (NOT the auth email hook), so it never collides with the signup
confirmation email. Customize the copy in `_templates/welcome.tsx`, or remove the
`trg_profiles_welcome_email` trigger if you don't want it.

> **Timing nuance:** a profile is created at signup, *before* email confirmation —
> so the welcome arrives alongside the confirmation email. To send it only after the
> user confirms, move the trigger to `AFTER UPDATE OF email_confirmed_at ON auth.users`.
> See [transactional-email.md](references/transactional-email.md) for the full recipe.

## Migrating projects scaffolded before the unified path (`internal-invite-member`)

Older AgentLink projects shipped a **dedicated `internal-invite-member` edge function** for workspace invites (enqueued directly from `_internal_admin_create_invitation` / `_internal_admin_resend_invitation`). New scaffolds fold that into this path — the **`invite`** entry in `internal-send-email`'s registry — so all app email goes through one function.

If you're in an older project and the user wants the consolidated setup, **recommend migrating, but confirm with the user first** — it removes an edge function and (on cloud) leaves an orphaned deployment to delete. Steps:

1. Add an `invite` entry to `internal-send-email`'s `TEMPLATES` registry (subject + render building the `/accept-invite?token=…` URL from `{ token, tenant_name }`); move `internal-invite-member/_templates/team-invite.tsx` to `internal-send-email/_templates/`.
2. Repoint `public._internal_admin_create_invitation` and `_internal_admin_resend_invitation` to `api._admin_send_email('invite', email, jsonb_build_object('token', …, 'tenant_name', …))`. **Pass no `dedupe_key`** — resending an invitation must deliver a fresh email.
3. Delete `supabase/functions/internal-invite-member/` and remove its `[functions.internal-invite-member]` block from `supabase/config.toml`.
4. `pnpm exec agentlink db apply`, then `db migrate <name>` and deploy.
5. **Cloud only:** delete the now-orphaned deployed function — `supabase functions delete internal-invite-member`.

The same shape applies to any other bespoke per-email function (e.g. an app's `internal-approval-decision`): move its template into the registry, repoint its enqueue to `api._admin_send_email`, delete the function. Auth emails are the exception — they stay on the auth hook.

## Deeper reference

- **[references/transactional-email.md](references/transactional-email.md)** — full
  add-an-email recipe, the `internal_logs_*` log convention, idempotency/retry
  semantics, local testing with resend-box, and troubleshooting.
- **[references/resend-box.md](references/resend-box.md)** — the local email
  sandbox's HTTP API (list/filter/fetch/clear captured emails) and a
  verification recipe for confirming a template actually rendered right, not
  just that `internal_logs_email` says `sent`.
- **Auth emails** (signup, magic link, recovery, email change): [auth skill](../auth/SKILL.md).
- **Per-environment Resend setup** (API key, FROM address, local vs cloud):
  [cli/references/resend.md](../cli/references/resend.md).
- **Queue + worker + cron model**: [edge-functions](../edge-functions/SKILL.md),
  [database](../database/SKILL.md), and worked examples in
  [recipes.md](../../agents/references/recipes.md).
