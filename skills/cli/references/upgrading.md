# Upgrading an AgentLink project

How to move an existing project onto a newer AgentLink version — and what to do when the in-place update misbehaves.

`npx agentlink-sh@latest` auto-detects an existing project (it finds `agentlink.json` in the cwd) and runs the **update** flow instead of scaffolding. There is no separate `upgrade` command — the update flow *is* the upgrade.

---

## The normal path: `check` → `--dry-run` → `--force-update` → `check`

Always try the CLI first. It knows how to merge managed blocks, patch `config.toml`, apply the SQL, and bump the setup hash — none of which you should reproduce by hand.

1. **`npx agentlink-sh@latest check`** — read-only. Reports `ready`, `supabase_running`, `database` (extensions, queues, functions, secrets, api_schema), and `files`. The `setupHash` on disk vs. the template hash tells you whether there's drift. Look at which fields are `false`.

2. **`npx agentlink-sh@latest --dry-run`** — **this is the "what would change" tool.** It computes the full plan without touching disk, DB, or network, so it's safe on a dirty tree. It prints:
   - **Setup hash** — on-disk vs. template, with `(match)` or `(drift)`.
   - **Template files** (out of the full set) grouped as `unchanged` / `would create` / `would rewrite` / `merged` (managed blocks updated, your overrides preserved) / `project-owned` (all `@agentlink` annotations removed — left untouched) / `user-customizable` (present on disk — not rewritten).
   - **Upgrade cleanup** — version-path `DROP`s that run before apply, if any.
   - **config.toml** — `no patches needed` or the list of patches that `would patch`.
   - **Side effects** (skipped in dry run) — plugin + skills update, AGENTS.md / `.claude/settings.json` rewrite, how many SQL files apply and to which DB, PostgREST + auth config (cloud), edge-function deploys (cloud), verification, and the `agentlink.json` setupHash write.

   Read this first. It almost always answers "what does the upgrade do to my project?" without any disposable-project trick.

3. **`npx agentlink-sh@latest --force-update`** — applies it. Overwrites template files (function-level merge — see below), patches `config.toml`, runs the SQL setup, deploys functions on cloud, regenerates migrations if schemas changed. **Requires Supabase running** (local: `supabase start`; cloud: it links automatically). Gates on a clean git tree — commit or stash first, or pass `--allow-dirty` (rollback then gets messy because your edits and AgentLink's writes are mixed).

4. **`npx agentlink-sh@latest check`** again — confirm `ready: true`.

After a real update the CLI prints a **Changed files** summary grouped by area and points you at:
- `git diff` to review
- `git checkout . && git clean -fd supabase/ .claude/` to roll back

So the review/rollback story is already built in — use it before reaching for anything fancier.

### Function-level merge (why the upgrade won't clobber your customizations)

`--force-update` merges per-resource, not per-file. Each `@agentlink`-annotated block in a template file is compared against the on-disk version:
- Block **still annotated** → updated from the template.
- Block where you **removed the `@agentlink` annotation** → left untouched (you own it).
- Remove **every** annotation from a file → the whole file becomes project-owned and `--force-update` skips it.

This is how you customize a managed function while still receiving updates for its neighbors. See "Customizing a managed function" in `agents/builder.md`. Never *add* `@agentlink` annotations yourself — they're CLI-only metadata.

---

## Fallback: a disposable reference project

Use this **only when the in-place update misbehaves** — `--dry-run` output looks wrong, `--force-update` errors out unclearly, or you don't trust what landed and want a pristine ground-truth to diff against. For the normal case, `--dry-run` already tells you everything below without the extra steps.

The idea: scaffold a throwaway project **files-only** (no env, no Docker, no network), then diff its managed files against the real project to see exactly what the current template version produces.

```bash
# Pure file generation — no Supabase, no OAuth, no install, fast.
npx agentlink-sh@latest /tmp/agentlink-ref --skip-env --skip-install
```

`--skip-env` skips all Supabase setup (OAuth, project creation, Docker, DB apply, `.env.local` population). `--skip-install` skips `pnpm install` and the skills install. Together they give you just the directory and its files.

Then diff:

```bash
# Compare only the env-independent, CLI-managed trees.
diff -ru supabase/schemas      /tmp/agentlink-ref/supabase/schemas
diff -ru supabase/functions    /tmp/agentlink-ref/supabase/functions
diff -u  supabase/migrations/20200101000000_initial_agentlink_bootstrap.sql \
         /tmp/agentlink-ref/supabase/migrations/20200101000000_initial_agentlink_bootstrap.sql
```

### Watch-outs — the diff is noisy unless you control for these

**1. Scaffold output is parameterized.** Project name, selected companion skills, and frontend choice are substituted into the output. Read the real project's `agentlink.json` and scaffold the reference with the **same options** (same name, same skills, and frontend on/off via `--no-frontend`), or you'll see spurious diffs everywhere those values appear.

**2. Only trust env-independent files.** Diff these:
- `supabase/schemas/**` — the managed SQL (this is what matters most)
- `supabase/functions/**` — edge functions + `_shared`
- `supabase/migrations/20200101*` — the baseline migrations have **fixed** timestamps, so they line up

**Ignore** these — they hold project-specific values and secrets, so they'll always differ and tell you nothing:
- `.env.local`, `.env.example*`
- `agentlink.json` (version, setupHash, cloud config)
- `supabase/config.toml` (env-specific) — let `--dry-run`'s `config.toml` plan tell you about patches instead
- `AGENTS.md`, `.claude/settings.json`

**3. The reference is just a comparison source.** Apply deltas back into the real project by editing the schema/function files and then running `npx agentlink-sh@latest db apply` (and, on cloud, `supabase functions deploy`) — the same workflow as any schema change. Don't copy `agentlink.json`/`config.toml` across. Delete `/tmp/agentlink-ref` when done.

**4. Respect `@agentlink` ownership.** If you've removed an annotation to own a function, the reference will show the template's version — that's expected drift, not a regression to "fix." Only port deltas for blocks you still want managed.

---

## Quick reference

| Situation | Do this |
| --- | --- |
| "What will the upgrade change?" | `npx agentlink-sh@latest --dry-run` |
| Apply the upgrade | `npx agentlink-sh@latest --force-update` (Supabase must be running) |
| Dirty tree blocks the update | commit/stash, or `--force-update --allow-dirty` (messier rollback) |
| Review what landed | `git diff` |
| Roll back | `git checkout . && git clean -fd supabase/ .claude/` |
| Update produced a bad/unclear result | scaffold a `--skip-env --skip-install` reference and diff `supabase/schemas` + `supabase/functions` |
| Unclear CLI error | add `--debug`, then read/share `agentlink-debug.log` |
