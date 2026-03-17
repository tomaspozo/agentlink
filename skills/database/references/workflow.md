# Development

The daily development loop. How agents build features and apply changes.

## Contents
- Core Principle
- Development Loop (making changes, fixing errors)
- Generating Types
- Examples (new entity, new field, triggers)

---

## Core Principle

The agent applies every change in two places simultaneously:

1. **The live database** (local or cloud) — via `npx @agentlinksh/cli@latest db apply` or `psql`, so changes take effect immediately
2. **The schema files** — in `supabase/schemas/`, so the source of truth stays in sync

Schema files are the canonical representation of your database. The live database is the working copy. Both must always reflect the same state.

**Apply methods:**
- **Batch (recommended):** `npx @agentlinksh/cli@latest db apply` — applies all schema files with correct ordering via `pgdelta`. DB URL auto-resolved from `.env.local`.
- **Single statement:** `psql <db_url> -c "SQL"` — fine for quick one-off changes.

Schema files are clean declarations — no `DROP` statements. Use `CREATE TABLE IF NOT EXISTS`, `CREATE OR REPLACE FUNCTION`, `CREATE INDEX IF NOT EXISTS`, `DROP POLICY IF EXISTS` + `CREATE POLICY`. DROPs belong in migrations only.

**The database is never reset unless the user explicitly requests it.**

---

## Development Loop

### Making Changes

When building a feature, the agent:

1. Writes the SQL in the appropriate schema file (see [naming conventions](./naming_conventions.md))
2. Applies via `npx @agentlinksh/cli@latest db apply` — every file write must be followed by an apply
   - DB URL auto-resolved from `.env.local` (no `--db-url` needed)
   - **Single statement:** `psql <db_url> -c "SQL"` is fine for quick one-off changes
3. If something breaks, fixes it with more SQL — never resets
4. Continues building until the feature is complete

### Security Check

After applying changes, run the Supabase security advisor:

```
supabase:get_advisors
```

Review the results and fix any findings (e.g., mutable `search_path`, missing `SECURITY INVOKER`) before continuing. This catches issues like unsafe function definitions early, before they reach migration.

### Fixing Errors

When `psql` returns an error:

- **Constraint violation** — Fix the data, then retry the schema change
- **Duplicate object** — The schema file should already use `IF NOT EXISTS` / `CREATE OR REPLACE`
- **Dependency conflict** — Drop and recreate in the correct order
- **Data type mismatch** — Migrate the data first, then alter the column

The agent handles errors with more SQL. The database accumulates real state during development — treat it like a production database that happens to be local.

---

## Generating Types

After any schema change, regenerate the TypeScript types:

```bash
# Local
supabase gen types typescript --local > src/types/database.ts

# Cloud (project ref from agentlink.json or CLAUDE.md)
supabase gen types typescript --project-id <ref> > src/types/database.ts
```

Run this after completing a set of related changes, not after every individual statement.

**Prerequisite:** `pgdelta` is bundled with the CLI — no separate install needed.

---

## Examples

### Adding a New Entity

Example: Adding a `readings` entity to a project that already has `charts`.

**1. Create auth functions** — `supabase/schemas/public/_auth_reading.sql`:
```sql
CREATE OR REPLACE FUNCTION public._auth_reading_can_read(p_reading_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  RETURN EXISTS (
    SELECT 1 FROM public.readings
    WHERE id = p_reading_id
    AND (user_id = auth.uid() OR is_public = true)
  );
END;
$$;

CREATE OR REPLACE FUNCTION public._auth_reading_is_owner(p_reading_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  RETURN EXISTS (
    SELECT 1 FROM public.readings
    WHERE id = p_reading_id
    AND user_id = auth.uid()
  );
END;
$$;
```

Apply via `npx @agentlinksh/cli@latest db apply`.

**2. Create the entity file** — `supabase/schemas/public/readings.sql`:
```sql
-- Table
CREATE TABLE IF NOT EXISTS public.readings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  chart_id uuid NOT NULL REFERENCES public.charts(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  content jsonb NOT NULL DEFAULT '{}',
  is_public boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.readings ENABLE ROW LEVEL SECURITY;

-- Indexes
CREATE INDEX IF NOT EXISTS idx_readings_chart_id ON public.readings(chart_id);
CREATE INDEX IF NOT EXISTS idx_readings_user_id ON public.readings(user_id);
CREATE INDEX IF NOT EXISTS idx_readings_created_at ON public.readings(created_at DESC);

-- RLS policies
CREATE POLICY "Users can read own or public readings"
ON public.readings FOR SELECT
USING (public._auth_reading_can_read(id));

CREATE POLICY "Users can insert own readings"
ON public.readings FOR INSERT
WITH CHECK (user_id = auth.uid());

CREATE POLICY "Users can update own readings"
ON public.readings FOR UPDATE
USING (public._auth_reading_is_owner(id));

CREATE POLICY "Users can delete own readings"
ON public.readings FOR DELETE
USING (public._auth_reading_is_owner(id));
```

Apply via `npx @agentlinksh/cli@latest db apply`.

**3. Create API functions** — `supabase/schemas/api/reading.sql`:
```sql
CREATE OR REPLACE FUNCTION api.reading_create(
  p_chart_id uuid,
  p_content jsonb DEFAULT '{}'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_reading_id uuid;
BEGIN
  INSERT INTO public.readings (chart_id, user_id, content)
  VALUES (p_chart_id, auth.uid(), p_content)
  RETURNING id INTO v_reading_id;

  RETURN jsonb_build_object(
    'success', true,
    'reading_id', v_reading_id
  );
END;
$$;

CREATE OR REPLACE FUNCTION api.reading_get_by_id(p_reading_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_result jsonb;
BEGIN
  SELECT jsonb_build_object(
    'id', r.id,
    'chart_id', r.chart_id,
    'content', r.content,
    'is_public', r.is_public,
    'created_at', r.created_at
  ) INTO v_result
  FROM public.readings r
  WHERE r.id = p_reading_id;

  RETURN v_result;
END;
$$;
```

Apply via `npx @agentlinksh/cli@latest db apply`.

**4. Generate types:**
```bash
supabase gen types typescript --local > src/types/database.ts
```

---

### Adding a Field to an Existing Table

Example: Adding `archived_at` to `readings`.

**1. Update the table definition** in `supabase/schemas/public/readings.sql` and apply the ALTER via `psql`:
```sql
-- Add to the CREATE TABLE definition (for fresh setups)
archived_at timestamptz DEFAULT NULL

-- Apply to live database
ALTER TABLE public.readings ADD COLUMN IF NOT EXISTS archived_at timestamptz DEFAULT NULL;
```

**2. Add index** if needed — update `supabase/schemas/public/readings.sql` and apply via `psql`:
```sql
CREATE INDEX IF NOT EXISTS idx_readings_archived_at
ON public.readings(archived_at)
WHERE archived_at IS NOT NULL;
```

**3. Add the function** — update `supabase/schemas/api/reading.sql` and apply via `psql`:
```sql
CREATE OR REPLACE FUNCTION api.reading_archive(p_reading_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
BEGIN
  UPDATE public.readings
  SET archived_at = now()
  WHERE id = p_reading_id
    AND archived_at IS NULL;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Not found or already archived');
  END IF;

  RETURN jsonb_build_object('success', true);
END;
$$;
```

**4. Fix data errors** if any exist, via `psql`:
```sql
UPDATE public.readings SET archived_at = NULL WHERE archived_at = '0001-01-01';
```

**5. Generate types:**
```bash
supabase gen types typescript --local > src/types/database.ts
```

---

### Creating a Trigger

Example: Auto-update `updated_at` on row changes.

The trigger function `public.set_updated_at()` is scaffolded by the CLI in `supabase/schemas/public/_internal_admin.sql` — the agent doesn't need to create it.

**1. Create trigger** — `supabase/schemas/public/readings.sql`. Apply via `psql`:
```sql
CREATE TRIGGER trg_readings_updated_at
  BEFORE UPDATE ON public.readings
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();
```
