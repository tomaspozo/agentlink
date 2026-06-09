# Known Issues

Current quirks in the toolchain AgentLink sits on (Supabase CLI, pg-delta, Docker) that are **not** AgentLink bugs and usually aren't worth debugging — recognize them, apply the workaround, move on. Distinct from `troubleshooting.md` (which is for genuine errors + fixes); this file is for transient/upstream behaviors.

---

## `supabase start` transiently fails a storage health check on first start

**Symptom:** During `supabase start` (most often the very first start right after scaffolding, or after a CLI upgrade), the command aborts with something like:

```
supabase_storage_<project> container is not ready: starting
Try rerunning the command with --debug to troubleshoot the error.
```

and the stack rolls back (no containers left running). The scaffold's "Starting Supabase" step can fail the same way.

**Cause:** On the Supabase CLI 2.10x line, the storage container's health check can time out on a **cold Docker image pull** — the images are still downloading/initializing when the health gate runs. It's a startup race, not a real failure, and not an AgentLink bug. The CLI does **not** auto-retry this step yet.

**Fix:** Just run it again.

```bash
supabase start          # in the project dir — succeeds once images are cached
```

If a scaffold aborted here, the project files are already written — re-run `supabase start` in the project directory (or re-run the scaffold). Once the Docker images are pulled, subsequent starts are reliable.

---

## First `supabase` command may pull a platform binary

**Symptom:** The first `supabase` invocation after install is slower than expected / appears to do a download.

**Cause:** The Supabase CLI 2.10x npm package ships a small Node shim (`dist/supabase.js`) rather than a bundled native binary, so the platform binary may be fetched/initialized on first use. (Older packaging bundled the binary directly.)

**Fix:** None needed — let the first command complete. Subsequent calls are fast. Requires network on first run.
