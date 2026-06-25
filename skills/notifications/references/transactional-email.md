# Transactional Email — Reference

The full model behind the `notifications` skill: the moving parts the scaffold
ships, how to add an email, the log/idempotency design, retry semantics, local
testing, and troubleshooting.

This is the path for **app-driven** email. Supabase **auth** emails (signup
confirm, magic link, recovery, email change) take a parallel path through the
auth email hook — see the [auth skill](../../auth/SKILL.md).

## Contents
- Components shipped by the scaffold
- The send API
- The delivery log (`internal_logs_email`)
- Idempotency
- Retry, failure, and dead-letter
- Recipe: add a new transactional email
- Recipe: fire email from a database event
- The welcome sample (and its timing nuance)
- Local testing with resend-box
- Troubleshooting

---

## Components shipped by the scaffold

| Piece | Path | Role |
|-------|------|------|
| `api._admin_send_email` | `database/schemas/api/functions/_admin_send_email.sql` | Entry point. Logs intent + enqueues. service_role only. |
| `public.internal_logs_email` | `database/schemas/public/tables/internal_logs_email.sql` | Delivery log + idempotency anchor. |
| `api._admin_email_log_get` / `_mark` | `database/schemas/api/functions/` | Worker reads the row / records the outcome. |
| `internal-send-email` | `functions/internal-send-email/index.ts` | Generic worker: registry → render → Resend → mark. |
| `_templates/welcome.tsx` | `functions/internal-send-email/_templates/` | Sample template. |
| `_internal_welcome_on_profile` | `database/schemas/public/functions/` | Trigger fn that fires the welcome sample. |

Reused (not new): `api._admin_enqueue_task`, `internal-queue-worker`,
`public._internal_admin_call_edge_function`, and the shared email components in
`functions/_shared/email-components/`.

---

## The send API

```sql
api._admin_send_email(
  email_id   text,                 -- template key registered in internal-send-email
  recipient  text,                 -- "to" address
  params     jsonb DEFAULT '{}',   -- template props (untrusted; render() narrows them)
  dedupe_key text DEFAULT NULL     -- optional idempotency key
) RETURNS uuid                     -- the internal_logs_email row id
```

- `SECURITY DEFINER`, granted to `service_role`, revoked from `anon`/`authenticated`.
- Call it from a trigger, another `SECURITY DEFINER` function, or a `secret`-auth
  edge function. **Never** wrap it in a client-callable RPC.
- It inserts the log row and enqueues `internal-send-email` with `{ log_id }`,
  then returns the row id.

---

## The delivery log (`internal_logs_email`)

AgentLink's first `internal_logs_*` table — the naming convention for
**system/internal** log tables (distinct from user/domain tables). It lives in the
`public` schema so it is **not** exposed via the Data API, and only `service_role`
has DML. RLS is enabled (per the "RLS on every table" rule) with no policies, since
nothing client-side reads it.

Columns: `id`, `email_id`, `recipient`, `params`, `status` (`queued` | `sent` |
`failed`), `dedupe_key`, `resend_id`, `error`, `created_at`, `sent_at`,
`updated_at`. It doubles as your observability surface — query it to see what was
sent, when, and why a send failed:

```sql
select email_id, recipient, status, error, created_at, sent_at
from public.internal_logs_email
order by created_at desc
limit 50;
```

Future internal logs (webhooks, jobs, …) should follow the same `internal_logs_*`
prefix in `public`.

---

## Idempotency

Two layers:

1. **Enqueue-time dedupe** — pass a stable `dedupe_key`. A partial unique index
   (`uq_internal_logs_email_dedupe ... WHERE dedupe_key IS NOT NULL`) means a second
   `api._admin_send_email` with the same key is a no-op (`ON CONFLICT DO NOTHING`),
   so no second row and no second email.
2. **Send-time gate** — the worker skips when the log row is already `status='sent'`.
   PGMQ can re-deliver a message (visibility-timeout retry); this guarantees a
   re-delivery never re-sends.

Resend-send and the `_mark('sent')` write are not a single transaction, so in the
worst case (crash between send and mark) a message could be retried; the
`status='sent'` gate is what makes that safe once the mark lands. Use `dedupe_key`
for anything where a duplicate would matter (billing, receipts).

---

## Retry, failure, and dead-letter

You do **not** implement retries — PGMQ + `internal-queue-worker` already do:

- On failure the worker **throws**, leaving the message in the queue; PGMQ makes it
  visible again after the visibility timeout (`vt`) for another attempt.
- `read_ct` counts deliveries; after `QUEUE_MAX_RETRIES` (default 5, env-overridable)
  the worker **archives** the message instead of retrying forever.
- `internal-send-email` also writes `status='failed'` + `error` to the log on each
  failed attempt, so a poison message is visible in `internal_logs_email` rather
  than silently looping.

Do not add a "max 3 retries" counter in the template/worker — tune
`QUEUE_MAX_RETRIES` instead.

---

## Recipe: add a new transactional email

Example: an "export ready" email.

**1. Template** — `functions/internal-send-email/_templates/export-ready.tsx`:

```tsx
// @ts-nocheck
import * as React from 'npm:react@18.3.1'
import { Heading, Text } from 'npm:@react-email/components@0.0.22'
import { EmailLayout } from '../../_shared/email-components/layout.tsx'
import { EmailButton } from '../../_shared/email-components/button.tsx'
import { typography } from '../../_shared/email-components/styles.ts'

export interface ExportReadyEmailProps { downloadUrl: string; appName: string }

export function ExportReadyEmail({ downloadUrl, appName }: ExportReadyEmailProps) {
  return (
    <EmailLayout preview="Your export is ready" label="Export ready">
      <Heading as="h1" style={typography.title}>Your export is ready</Heading>
      <Text style={typography.text}>Download it below — the link expires in 24 hours.</Text>
      <EmailButton href={downloadUrl}>Download export →</EmailButton>
    </EmailLayout>
  )
}
export default ExportReadyEmail
```

**2. Register** — in `functions/internal-send-email/index.ts`, import it and add a
`TEMPLATES` entry. `render()` is where you validate/narrow the untrusted params:

```ts
import { ExportReadyEmail } from "./_templates/export-ready.tsx";

const TEMPLATES = {
  welcome: { /* … existing … */ },
  export_ready: {
    subject: (_p, appName) => `Your export from ${appName} is ready`,
    render: (params, appName) => {
      const downloadUrl = typeof params.download_url === "string" ? params.download_url : "";
      if (!downloadUrl) throw new Error("export_ready requires download_url");
      return React.createElement(ExportReadyEmail, { downloadUrl, appName });
    },
  },
};
```

**3. Fire** — from the server-side event:

```sql
PERFORM api._admin_send_email(
  'export_ready', v_user_email,
  jsonb_build_object('download_url', v_url),
  'export_ready:' || v_export_id::text
);
```

Then `pnpm exec agentlink db apply` (for new SQL) and deploy functions.

---

## Recipe: fire email from a database event

Use an `AFTER INSERT`/`AFTER UPDATE` trigger calling a `SECURITY DEFINER` function
that invokes `api._admin_send_email` — exactly like the welcome sample. The trigger
function must be `SECURITY DEFINER` (it calls the service-role-only send fn) and use
`SET search_path = ''` with fully-qualified names, matching every other internal
function. Guard against NULL recipients.

---

## The welcome sample (and its timing nuance)

`public._internal_welcome_on_profile()` + `trg_profiles_welcome_email` (an
`AFTER INSERT` trigger on `public.profiles`) send the `welcome` template once per
user (`dedupe_key = 'welcome:<user-id>'`).

A profile row is created at signup, **before** email confirmation, so the welcome
arrives alongside the confirmation email. That's fine for a demo. To send it only
after the user confirms, drop `trg_profiles_welcome_email` and instead trigger on
the confirmation transition:

```sql
CREATE OR REPLACE TRIGGER trg_welcome_after_confirm
  AFTER UPDATE OF email_confirmed_at ON auth.users
  FOR EACH ROW
  WHEN (OLD.email_confirmed_at IS NULL AND NEW.email_confirmed_at IS NOT NULL)
  EXECUTE FUNCTION public._internal_welcome_on_confirm();  -- a fn that reads the profile + sends
```

---

## Local testing with resend-box

Scaffolded projects point `RESEND_BASE_URL` at the local **resend-box** sandbox, so
emails are captured locally instead of really sent. To exercise the full path:

1. `supabase start`, then run the app and the functions/queue locally
   (`pnpm dev:all`).
2. Sign up a user → `public.profiles` insert fires `trg_profiles_welcome_email` →
   `internal_logs_email` row goes `queued` → `sent`.
3. Inspect the captured email in resend-box (see the `resend-box` companion skill).
4. Confirm the auth confirmation email still arrives separately — the two paths are
   independent.

---

## Troubleshooting

- **No email sent, no log row** — the caller isn't `service_role` / the
  `SECURITY DEFINER` function isn't owned correctly, or `api._admin_send_email`
  threw. Check the calling function's privileges.
- **Row stuck at `queued`** — the worker isn't draining. Confirm `internal-send-email`
  and `internal-queue-worker` are deployed, `RESEND_API_KEY` is set in the env's
  secrets, and the `process-stale-tasks` cron exists. Check edge function logs.
- **Row `failed` with "Unknown email_id"** — you fired an `email_id` that isn't in
  the `TEMPLATES` registry. Add the entry (and redeploy the function).
- **Row `failed` with a Resend error** — usually `RESEND_API_KEY` missing/invalid or
  an unverified FROM domain. See [cli/references/resend.md](../../cli/references/resend.md)
  for per-environment Resend setup.
- **Duplicate emails** — you didn't pass a `dedupe_key`, or used a non-stable one.
  Use `<event>:<entity-id>`.
