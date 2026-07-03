# resend-box — Local Email Sandbox Reference

How to actually **look at** an email the scaffold sent during local dev,
instead of just confirming `internal_logs_email.status = 'sent'`. The status
column proves the send was attempted and accepted; it says nothing about
whether the subject line is right, the template rendered correctly, or the
link inside points where it should. resend-box is what closes that gap.

## What it is

resend-box is a local, in-memory email sandbox that ships as a devDependency
on every scaffolded project. It:

1. **Mocks the Resend API** — a drop-in replacement for `https://api.resend.com`.
2. **Runs an SMTP server** on port `1025` (catches anything sent via SMTP too,
   not just the Resend SDK — relevant if Supabase Auth's own SMTP-based mailer
   is ever pointed at it).
3. **Serves a web UI + HTTP API** on `http://127.0.0.1:4657`.
4. **Stores everything in memory** — captured emails vanish on restart. There
   is no persistence to worry about between dev sessions.

The scaffold wires it in already — you don't configure anything to get this:

- `package.json`'s `dev:all`/`dev:backend` scripts start it alongside Supabase
  and the edge functions (`npx resend-box start` under `concurrently`).
- `.env.local` sets `RESEND_BASE_URL=http://host.docker.internal:4657`, so the
  edge functions (running inside the Supabase Docker network) route what would
  otherwise be a real Resend API call into the sandbox instead. `host.docker.internal`
  is why the edge function reaches your host machine's port — using
  `127.0.0.1` there would resolve to the container itself and connect to
  nothing.

Because of that env var, this is **transparent to your code**: `Resend.send(...)`
in `internal-send-email` behaves identically whether it's talking to the real
API or the sandbox. Nothing in the template/registry/worker code needs to know
which one it's hitting.

## Reading captured emails (the part the agent actually needs)

The web UI at `http://127.0.0.1:4657` is for a human to click through. As an
agent, use the HTTP API directly — it's faster to check programmatically and
you can pull just the field you need instead of eyeballing a page.

### List everything captured so far

```bash
curl -s http://127.0.0.1:4657/sandbox/emails | jq
```

Newest first. Empty when nothing's been sent yet: `{"emails": []}`.

### Filter to the email you're actually testing

```bash
curl -s "http://127.0.0.1:4657/sandbox/emails?to=user@example.com" | jq
```

`to` matches case-insensitively and by substring, so `?to=example.com` catches
every recipient on that domain — handy when you don't remember the exact test
address you signed up with.

### Pull just what you need with jq

```bash
# Subject of the most recent email
curl -s http://127.0.0.1:4657/sandbox/emails | jq -r '.emails[0].subject'

# Rendered HTML body of the latest email to a specific address
curl -s "http://127.0.0.1:4657/sandbox/emails?to=user@example.com" | jq -r '.emails[0].html'

# How many emails have gone out in this session
curl -s http://127.0.0.1:4657/sandbox/emails | jq '.emails | length'
```

### Get one email by id

```bash
curl -s http://127.0.0.1:4657/sandbox/emails/{id} | jq
```

Each captured email looks like this:

```json
{
  "id": "abc123xyz",
  "source": "resend",
  "from": "noreply@myapp.com",
  "to": ["user@example.com"],
  "subject": "Welcome!",
  "html": "<h1>Welcome!</h1>",
  "text": "Welcome!",
  "createdAt": 1705312200000
}
```

`source` is `"resend"` or `"smtp"` depending on which path caught it — useful
for telling an app-driven `internal-send-email` send (`"resend"`) apart from a
Supabase Auth email if auth's SMTP mailer is ever pointed at the sandbox too.

### Clear the inbox before a test run

```bash
curl -s -X DELETE http://127.0.0.1:4657/sandbox/emails
```

Do this before triggering the flow you're verifying, especially in a session
where you've already sent several test emails — otherwise `.emails[0]` from
"list everything" might be a stale email from an earlier step, not the one you
just triggered, and you'll draw the wrong conclusion from it.

## A verification recipe

Putting it together — confirming a newly-added transactional email actually
renders right, end to end:

1. `curl -s -X DELETE http://127.0.0.1:4657/sandbox/emails` — start clean.
2. Trigger the flow (sign up a user, call the RPC, whatever fires the send).
3. Poll `public.internal_logs_email` for the row to reach `status = 'sent'`
   (see [transactional-email.md](transactional-email.md)) — this confirms the
   worker processed it and the `Resend.send()` call succeeded, but *not* that
   the content is correct.
4. `curl -s "http://127.0.0.1:4657/sandbox/emails?to=<recipient>" | jq` — this
   is the step that actually proves it: check the `subject`, and grep/read the
   `html` for the piece of dynamic content you expect (a name, a link, an
   amount) to confirm the template rendered with the right params, not just
   that *an* email went out.

Steps 3 and 4 answer different questions — "did the pipeline work" vs. "is the
email actually right" — and skipping straight to the log table only answers
the first one.

## Troubleshooting

- **`curl: (7) Failed to connect`** — resend-box isn't running. It's supposed
  to start with `pnpm dev:all`/`dev:backend`; if you started services
  individually, run `npx resend-box start` yourself.
- **Email never shows up in `/sandbox/emails`** — check
  `internal_logs_email.status` first. If it's stuck at `queued` or `failed`,
  the problem is upstream of resend-box entirely (worker not draining, wrong
  `email_id`, etc.) — see the Troubleshooting section in
  [transactional-email.md](transactional-email.md). If it's `sent` but still
  missing here, `RESEND_BASE_URL` likely isn't reaching the sandbox — confirm
  `.env.local` has it and that it's `host.docker.internal`, not `127.0.0.1` or
  `localhost` (those don't resolve to the host from inside the edge function's
  Docker container).
- **Emails from a previous test run confusing the result** — see "Clear the
  inbox before a test run" above.
