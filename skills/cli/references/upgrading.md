# Upgrading an AgentLink project

How to move an existing project onto a newer AgentLink version — and what to do when the in-place update misbehaves.

`npx agentlink-sh@latest` auto-detects an existing project (it finds `agentlink.json` in the cwd) and runs the **update** flow instead of scaffolding. There is no separate `upgrade` command — the update flow *is* the upgrade.

---

## The normal path: `check` → `--dry-run` → `--force-update` → `check`

Always try the CLI first. It knows how to merge managed files against the base snapshot, patch `config.toml`, apply the SQL, and bump the setup hash — none of which you should reproduce by hand.

1. **`pnpm exec agentlink check`** — read-only. Reports `ready`, `supabase_running`, `database` (extensions, queues, functions, secrets, api_schema), and `files`. The `setupHash` on disk vs. the template hash tells you whether there's drift. Look at which fields are `false`.

2. **`pnpm exec agentlink --dry-run`** — **this is the "what would change" tool.** It computes the full plan without touching disk, DB, or network, so it's safe on a dirty tree. It prints:
   - **Setup hash** — on-disk vs. template, with `(match)` or `(drift)`.
   - **Base snapshot** — a status block reporting whether `.agentlink/template-base/` is present and complete (it's the committed record of the templates last shipped; the merge compares disk against it).
   - **Template files** (out of the full set) grouped against the base snapshot as `unchanged` / `would create` / `would fast-forward` (disk is pristine — overwritten with the new template) / `customized` (you edited it, no upstream change — preserved silently) / `CONFLICT` (you edited it **and** the template changed — disk preserved, 3-way reconcile surfaced) / `preserved (no base)` (no base entry — disk preserved, fail-safe).
   - **Upgrade cleanup** — version-path `DROP`s that run before apply, if any.
   - **config.toml** — `no patches needed` or the list of patches that `would patch`.
   - **Side effects** (skipped in dry run) — plugin + skills update, AGENTS.md / `.claude/settings.json` rewrite, how many SQL files apply and to which DB, PostgREST + auth config (cloud), edge-function deploys (cloud), verification, and the `agentlink.json` setupHash write.

   Read this first. It almost always answers "what does the upgrade do to my project?" without any disposable-project trick.

3. **`pnpm exec agentlink --force-update`** — applies it. Updates template files (file-level merge against the base snapshot — see below), patches `config.toml`, runs the SQL setup, deploys functions on cloud, regenerates migrations if schemas changed. **Requires Supabase running** (local: `supabase start`; cloud: it links automatically). Gates on a clean git tree — commit or stash first, or pass `--allow-dirty` (rollback then gets messy because your edits and AgentLink's writes are mixed).

4. **`pnpm exec agentlink check`** again — confirm `ready: true`.

After a real update the CLI prints a **Changed files** summary grouped by area and points you at:
- `git diff` to review
- `git checkout . && git clean -fd supabase/ .claude/` to roll back

So the review/rollback story is already built in — use it before reaching for anything fancier.

### File-level merge against the base snapshot (why the upgrade won't clobber your customizations)

Schema files are **one object per file** (`database/schemas/public/tables/<table>.sql`, `database/schemas/public/functions/<fn>.sql`, `database/schemas/api/functions/<rpc>.sql`), and the CLI keeps a committed snapshot of the exact templates it last shipped at `.agentlink/template-base/`. `--force-update` merges per-file by comparing three versions — your disk file, the base, and the new template:

- **not on disk** → create
- **disk == template** → unchanged
- **disk == base (pristine, untouched)** → **fast-forward**: overwritten with the new template (deterministic, no agent needed)
- **disk ≠ base but base == template** (you changed it, no upstream change) → **customized**: preserved **silently**, never nagged
- **disk ≠ base AND base ≠ template** (you changed it **and** upstream changed it) → **conflict**: disk preserved; an actionable 3-way reconcile is surfaced
- **disk differs but no base entry / base missing entirely** → **preserved (no base)**: disk preserved, fail-safe

For conflicts, the CLI captures the previous base and the new template under `.agentlink/.incoming/{base,incoming}/supabase/<file>` so you can do a 3-way reconcile (previous base vs new template vs your disk version). `.agentlink/.incoming/` is gitignored; `.agentlink/template-base/` is committed.

This is how you customize a managed function while still receiving updates for its neighbors: each object is its own file, so editing one never affects the others. See "Customizing a managed function" in `agents/builder.md`. Annotations no longer exist — never add `-- @agentlink` comments.

**Missing base is fail-safe and self-healing.** If `.agentlink/template-base/` is deleted, nothing is ever overwritten (every differing file is treated as preserved), the next successful update rewrites the snapshot, and it's `git restore`-able since it's committed. It can also be reconstructed by re-scaffolding the applied version — see the disposable-reference section below.

---

## Fallback: a disposable reference project (and base reconstruction)

Use this **primarily to reconstruct a missing base snapshot**, and otherwise **only when the in-place update misbehaves** — `--dry-run` output looks wrong, `--force-update` errors out unclearly, or you don't trust what landed and want a pristine ground-truth to diff against. For the normal case, `--dry-run` already tells you everything below without the extra steps.

If `.agentlink/template-base/` is gone and not recoverable from git, rebuild it by re-scaffolding the **applied version** (recorded as `appliedVersion` in `agentlink.json`) files-only — that reproduces the exact templates that were last shipped:

```bash
# Reconstruct the base by re-scaffolding the applied version, files-only.
npx agentlink-sh@<appliedVersion> /tmp/agentlink-ref --skip-env --skip-install
```

The same trick doubles as a comparison source: scaffold a throwaway project **files-only** (no env, no Docker, no network), then diff its managed files against the real project to see exactly what a given template version produces.

```bash
# Pure file generation — no Supabase, no OAuth, no install, fast.
npx agentlink-sh@latest /tmp/agentlink-ref --skip-env --skip-install
```

`--skip-env` skips all Supabase setup (OAuth, project creation, Docker, DB apply, `.env.local` population). `--skip-install` skips `pnpm install` and the skills install. Together they give you just the directory and its files.

Then diff:

```bash
# Compare only the env-independent, CLI-managed trees.
diff -ru supabase/database     /tmp/agentlink-ref/supabase/database
diff -ru supabase/functions    /tmp/agentlink-ref/supabase/functions
diff -u  supabase/migrations/20200101000000_initial_agentlink_bootstrap.sql \
         /tmp/agentlink-ref/supabase/migrations/20200101000000_initial_agentlink_bootstrap.sql
```

### Watch-outs — the diff is noisy unless you control for these

**1. Scaffold output is parameterized.** Project name, selected companion skills, and frontend choice are substituted into the output. Read the real project's `agentlink.json` and scaffold the reference with the **same options** (same name, same skills, and frontend on/off via `--no-frontend`), or you'll see spurious diffs everywhere those values appear.

**2. Only trust env-independent files.** Diff these:
- `supabase/database/**` — the managed SQL (this is what matters most)
- `supabase/functions/**` — edge functions + `_shared`
- `supabase/migrations/20200101*` — the baseline migrations have **fixed** timestamps, so they line up

**Ignore** these — they hold project-specific values and secrets, so they'll always differ and tell you nothing:
- `.env.local`, `.env.example*`
- `agentlink.json` (version, setupHash, cloud config)
- `supabase/config.toml` (env-specific) — let `--dry-run`'s `config.toml` plan tell you about patches instead
- `AGENTS.md`, `.claude/settings.json`

**3. The reference is just a comparison source.** Apply deltas back into the real project by editing the schema/function files and then running `pnpm exec agentlink db apply` (and, on cloud, `supabase functions deploy`) — the same workflow as any schema change. Don't copy `agentlink.json`/`config.toml` across. Delete `/tmp/agentlink-ref` when done.

**4. Respect your customizations.** If you've edited a managed file to own it, the reference will show the template's version — that's expected drift, not a regression to "fix." The base-snapshot merge already preserves your edit (as `customized`, or surfaces a `conflict` if upstream also changed). Only port deltas you actually want.

---

## Quick reference

| Situation | Do this |
| --- | --- |
| "What will the upgrade change?" | `pnpm exec agentlink --dry-run` |
| Apply the upgrade | `pnpm exec agentlink --force-update` (Supabase must be running) |
| Dirty tree blocks the update | commit/stash, or `--force-update --allow-dirty` (messier rollback) |
| Review what landed | `git diff` |
| Roll back | `git checkout . && git clean -fd supabase/ .claude/` |
| Update produced a bad/unclear result | scaffold a `--skip-env --skip-install` reference and diff `supabase/database` + `supabase/functions` |
| `.agentlink/template-base/` missing (not in git) | reconstruct: `npx agentlink-sh@<appliedVersion> /tmp/ref --skip-env --skip-install`, or let the next `--force-update` rewrite it |
| Unclear CLI error | add `--debug`, then read/share `agentlink-debug.log` |
