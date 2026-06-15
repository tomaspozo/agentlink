# Recipes — building features across the stack

Worked, end-to-end examples that combine the layers the `## Architecture` decision matrix
keeps separate: `api.*` RPCs (data + business logic), edge functions (anything that talks to
the outside world), and `pg_cron` + PGMQ (background/scheduled work) wired through the prebuilt
admin functions. The per-skill references teach each layer in isolation; these show them working
together so you can pattern-match instead of re-deriving the wiring (or asking the user how to
wire it).

Every prebuilt function below is real and scaffolded — see `cli/references/scaffold-map.md` for
the full inventory. Don't reinvent them.

## Contents

- [The orchestration primitives](#the-orchestration-primitives)
- [Recipe 1 — Scheduled outbound HTTP (the "ping engine")](#recipe-1--scheduled-outbound-http-the-ping-engine)
- [Recipe 2 — Queued side-effect (invite-member email)](#recipe-2--queued-side-effect-invite-member-email)
- [Recipe 3 — Periodic third-party sync](#recipe-3--periodic-third-party-sync)

---

## The orchestration primitives

| Primitive | Signature / form | Role |
|---|---|---|
| `public._internal_admin_call_edge_function` | `(function_name text, payload jsonb DEFAULT '{}') RETURNS bigint` | Fires **one** `pg_net` call to wake an edge function. `pg_net`'s only sanctioned use. |
| `api._admin_enqueue_task` | `(function_name text, payload jsonb DEFAULT '{}', delay_seconds int DEFAULT 0) RETURNS bigint` | Enqueue a job into the `agentlink_tasks` PGMQ queue; auto-wakes the worker. |
| `api._admin_queue_read` | `(qty int DEFAULT 5, vt int DEFAULT 30) RETURNS TABLE(msg_id bigint, read_ct int, enqueued_at timestamptz, vt timestamptz, message jsonb)` | Read a batch off the queue (used by the worker). |
| `api._admin_queue_archive` / `api._admin_queue_delete` | `(id bigint) RETURNS boolean` | Retire a processed message (archive keeps history). |
| `internal-queue-worker` | edge function, `allow: "secret"` | Drains the queue and `functions.invoke`s each task's target function. |
| `process-stale-tasks` | scaffolded `pg_cron` job (`* * * * *`) | Wakes the worker every minute so stuck tasks retry. |

**Two ways to run background work:**

- **Cron-driven sweep** — `pg_cron` fires `_internal_admin_call_edge_function('internal-<worker>')`
  on a schedule; the worker does an RPC to find the due set and processes it. Best for
  "every N minutes, do the work that's now due" (Recipes 1 and 3).
- **Queue-driven jobs** — a request (an RPC, an auth hook) calls `api._admin_enqueue_task(...)`;
  `internal-queue-worker` drains and dispatches. Best for per-item side-effects that shouldn't
  block the request that triggered them (Recipe 2). Use this for fan-out when a sweep would be
  too much work for one edge-function invocation.

> Edge functions are **never** called from in-database `pg_net` directly except via
> `_internal_admin_call_edge_function`, and `pg_net` **never** makes outbound HTTP for business
> logic. Both rules are in the `edge-functions` skill.

---

## Recipe 1 — Scheduled outbound HTTP (the "ping engine")

**Goal:** every minute, fetch each monitored URL and record whether it's up. Outbound HTTP at
a schedule — the textbook case for cron + an edge worker.

**Wrong instinct:** "loop over monitors in SQL and `net.http_post` each URL." That puts N
fire-and-forget calls inside a transaction with no timeouts, retries, or error capture, and ties
up the database. Outbound HTTP is *always* the edge function's job.

### 1. Cron wakes the worker — `supabase/database/cron/ping-due-monitors.sql`

```sql
SELECT cron.schedule(
  'ping-due-monitors',
  '* * * * *',
  $$SELECT public._internal_admin_call_edge_function('internal-monitor-pinger')$$
);
```

### 2. Admin RPCs the worker calls — `supabase/database/schemas/api/functions/`

```sql
-- _admin_monitor_due.sql — service-only: which monitors are due for a check?
CREATE OR REPLACE FUNCTION api._admin_monitor_due()
RETURNS TABLE (id uuid, url text)
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT m.id, m.url
  FROM public.monitors m
  WHERE m.next_check_at <= now();
$$;

REVOKE ALL ON FUNCTION api._admin_monitor_due() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION api._admin_monitor_due() TO service_role;
```

```sql
-- _admin_monitor_record_result.sql — service-only: write one check result back
CREATE OR REPLACE FUNCTION api._admin_monitor_record_result(
  p_monitor_id uuid,
  p_status text,
  p_status_code integer,
  p_latency_ms integer
)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $$
  INSERT INTO public.monitor_checks (monitor_id, status, status_code, latency_ms, checked_at)
  VALUES (p_monitor_id, p_status, p_status_code, p_latency_ms, now());

  UPDATE public.monitors
  SET last_status = p_status, next_check_at = now() + interval '1 minute'
  WHERE id = p_monitor_id;
$$;

REVOKE ALL ON FUNCTION api._admin_monitor_record_result(uuid, text, integer, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION api._admin_monitor_record_result(uuid, text, integer, integer) TO service_role;
```

### 3. The worker — `supabase/functions/internal-monitor-pinger/index.ts`

```typescript
import { withSupabase } from "@supabase/server";
import { jsonResponse, errorResponse } from "../_shared/responses.ts";

export default {
  fetch: withSupabase(
    { allow: "secret", supabaseOptions: { db: { schema: "api" } } },
    async (_req, { supabaseAdmin }) => {
      const { data: monitors, error } = await supabaseAdmin.rpc("_admin_monitor_due");
      if (error) return errorResponse(error.message, 500);
      if (!monitors?.length) return jsonResponse({ checked: 0 });

      for (const m of monitors) {
        const controller = new AbortController();
        const timeout = setTimeout(() => controller.abort(), 10_000);
        const started = performance.now();
        let status = "down", statusCode: number | null = null, latency: number | null = null;
        try {
          const res = await fetch(m.url, { redirect: "follow", signal: controller.signal });
          latency = Math.round(performance.now() - started);
          statusCode = res.status;
          status = res.ok ? "up" : "down";
        } catch {
          status = "down"; // timeout / DNS / connection refused
        } finally {
          clearTimeout(timeout);
        }
        await supabaseAdmin.rpc("_admin_monitor_record_result", {
          p_monitor_id: m.id, p_status: status, p_status_code: statusCode, p_latency_ms: latency,
        });
      }
      return jsonResponse({ checked: monitors.length });
    },
  ),
};
```

Register it in `supabase/config.toml`:

```toml
[functions.internal-monitor-pinger]
enabled = true
verify_jwt = false
```

### Fan-out variant (high volume)

If one invocation can't ping everything inside the function timeout, **enqueue one task per
monitor** and let `internal-queue-worker` spread the load — the pinger then handles a single
monitor from its payload instead of looping:

```sql
-- inside an admin RPC or the cron body
PERFORM api._admin_enqueue_task('internal-monitor-pinger', jsonb_build_object('monitor_id', id))
FROM public.monitors
WHERE next_check_at <= now();
```

### What goes where

| Step | Layer | Why |
|---|---|---|
| Schedule | `pg_cron` + `_internal_admin_call_edge_function` | Postgres-native scheduling; `pg_net` only wakes the worker |
| Fetch due rows / write results | `api._admin_*` RPC (`SECURITY DEFINER`, service_role) | All data access is an RPC, even from a worker |
| The outbound `fetch` | edge function (`allow: "secret"`) | Timeouts, redirects, error capture — never `pg_net` |

---

## Recipe 2 — Queued side-effect (invite-member email)

**Goal:** when a user invites a teammate, send a branded email — *without* blocking or failing the
invite RPC if the email provider is slow or down. This is the scaffolded flow; reuse it as the
template for any "do a side-effect after a mutation" feature.

**Flow:** `api.invitation_create` (client RPC) → `_internal_admin_create_invitation` enqueues an
`internal-invite-member` task → `internal-queue-worker` drains it → `internal-invite-member`
(edge function) sends the email via Resend.

### 1. The mutation enqueues instead of emailing inline

The client RPC `api.invitation_create` (`SECURITY INVOKER`, guarded by
`auth_verify_access('invitation.create')`) delegates the privileged write to
`public._internal_admin_create_invitation`, which ends with:

```sql
PERFORM api._admin_enqueue_task(
  'internal-invite-member',
  jsonb_build_object('email', v_email, 'token', v_token, 'tenant_name', v_tenant_name)
);
```

The RPC returns immediately; the email happens out-of-band. `_admin_enqueue_task` also wakes
`internal-queue-worker`, so there's no wait for the next cron tick.

### 2. The worker drains and dispatches (scaffolded — don't rewrite it)

`internal-queue-worker` reads a batch, invokes each task's target function, and archives on
success (failures stay in the queue and retry after the visibility timeout, bounded by
`QUEUE_MAX_RETRIES`):

```typescript
const { data: messages } = await supabaseAdmin.rpc("_admin_queue_read", { qty: 5, vt: 30 });
for (const msg of messages) {
  const { function_name, payload } = msg.message;
  const { error } = await supabaseAdmin.functions.invoke(function_name, { body: payload });
  if (!error) await supabaseAdmin.rpc("_admin_queue_archive", { id: msg.msg_id });
  // else: leave in queue → becomes visible again after vt for retry
}
```

### 3. The target function does the external work

`internal-invite-member` (`allow: "secret"`, since only the worker/service_role invokes it) reads
the payload and calls Resend. To add a *new* queued side-effect, write a new `internal-<thing>`
edge function with `allow: "secret"`, register it in `config.toml`, and enqueue it by name — the
worker dispatches it generically.

### What goes where

| Step | Layer | Why |
|---|---|---|
| Validate + authorize + write the invite | `api.invitation_create` (INVOKER) + `_internal_admin_create_invitation` (DEFINER) | Business logic + authz live in RPCs |
| Hand off the email | `api._admin_enqueue_task` → PGMQ | Side-effect is decoupled so the mutation never blocks on it |
| Send the email | `internal-invite-member` edge function (`allow: "secret"`) | Third-party API (Resend) = edge function |

---

## Recipe 3 — Periodic third-party sync

**Goal:** every hour, pull data from an external API and persist it. Same cron + edge shape as
Recipe 1, but the external call is a *read* and the result is upserted through an admin RPC.

### 1. Cron — `supabase/database/cron/sync-exchange-rates.sql`

```sql
SELECT cron.schedule(
  'sync-exchange-rates',
  '0 * * * *',                                  -- top of every hour
  $$SELECT public._internal_admin_call_edge_function('internal-rates-sync')$$
);
```

### 2. Upsert RPC — `api._admin_rates_upsert(p_rates jsonb)`

```sql
CREATE OR REPLACE FUNCTION api._admin_rates_upsert(p_rates jsonb)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $$
  INSERT INTO public.exchange_rates (code, rate, fetched_at)
  SELECT (r->>'code')::text, (r->>'rate')::numeric, now()
  FROM jsonb_array_elements(p_rates) AS r
  ON CONFLICT (code) DO UPDATE SET rate = excluded.rate, fetched_at = excluded.fetched_at;
$$;

REVOKE ALL ON FUNCTION api._admin_rates_upsert(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION api._admin_rates_upsert(jsonb) TO service_role;
```

### 3. The sync worker — `supabase/functions/internal-rates-sync/index.ts`

```typescript
import { withSupabase } from "@supabase/server";
import { jsonResponse, errorResponse } from "../_shared/responses.ts";

export default {
  fetch: withSupabase(
    { allow: "secret", supabaseOptions: { db: { schema: "api" } } },
    async (_req, { supabaseAdmin }) => {
      const res = await fetch("https://api.example.com/rates", {
        headers: { Authorization: `Bearer ${Deno.env.get("RATES_API_KEY")}` },
      });
      if (!res.ok) return errorResponse(`upstream ${res.status}`, 502);
      const { rates } = await res.json(); // [{ code, rate }, ...]

      const { error } = await supabaseAdmin.rpc("_admin_rates_upsert", { p_rates: rates });
      if (error) return errorResponse(error.message, 500);
      return jsonResponse({ synced: rates.length });
    },
  ),
};
```

### What goes where

| Step | Layer | Why |
|---|---|---|
| Schedule | `pg_cron` + `_internal_admin_call_edge_function` | Postgres-native scheduling |
| Read the external API | `internal-rates-sync` edge function (`allow: "secret"`) | Outbound HTTP = edge function; secrets live in the function env |
| Persist | `api._admin_rates_upsert` RPC | Persistence is always an RPC, never `.from()` |
