# RPC Patterns

Complete patterns for building client-facing functions in the `api` schema.

## Contents
- CRUD Templates (create, get, list, update, delete)
- Pagination (cursor-based, offset-based)
- Search and Filtering
- Batch Operations
- Multi-Table Operations
- Input Validation
- Return Types
- Grants

---

## CRUD Templates

### Create

```sql
CREATE OR REPLACE FUNCTION api.chart_create(
  p_name text,
  p_description text DEFAULT ''
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_chart_id uuid;
BEGIN
  -- Validate
  IF p_name IS NULL OR trim(p_name) = '' THEN
    RAISE EXCEPTION 'Name is required';
  END IF;

  INSERT INTO public.charts (name, description, user_id)
  VALUES (trim(p_name), p_description, auth.uid())
  RETURNING id INTO v_chart_id;

  RETURN jsonb_build_object(
    'id', v_chart_id,
    'name', trim(p_name)
  );
END;
$$;
```

### Get by ID

```sql
CREATE OR REPLACE FUNCTION api.chart_get_by_id(p_chart_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_result jsonb;
BEGIN
  SELECT jsonb_build_object(
    'id', c.id,
    'name', c.name,
    'description', c.description,
    'user_id', c.user_id,
    'created_at', c.created_at,
    'updated_at', c.updated_at
  ) INTO v_result
  FROM public.charts c
  WHERE c.id = p_chart_id;

  IF v_result IS NULL THEN
    RAISE EXCEPTION 'Chart not found: %', p_chart_id;
  END IF;

  RETURN v_result;
END;
$$;
```

### List (with cursor pagination)

```sql
CREATE OR REPLACE FUNCTION api.chart_list(
  p_limit int DEFAULT 20,
  p_cursor timestamptz DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_items jsonb;
  v_next_cursor timestamptz;
  v_has_more boolean;
  v_actual_limit int;
BEGIN
  -- Cap limit to prevent abuse
  v_actual_limit := LEAST(GREATEST(p_limit, 1), 100);

  -- Fetch one extra row to detect if there are more results
  SELECT
    jsonb_agg(row_to_json(t)),
    (count(*) > v_actual_limit)
  INTO v_items, v_has_more
  FROM (
    SELECT c.id, c.name, c.created_at, c.updated_at
    FROM public.charts c
    WHERE (p_cursor IS NULL OR c.created_at < p_cursor)
    ORDER BY c.created_at DESC
    LIMIT v_actual_limit + 1
  ) t;

  -- Trim the extra row and extract cursor
  IF v_has_more THEN
    v_items := v_items - (jsonb_array_length(v_items) - 1);
  END IF;

  IF jsonb_array_length(COALESCE(v_items, '[]'::jsonb)) > 0 THEN
    v_next_cursor := (v_items -> -1 ->> 'created_at')::timestamptz;
  END IF;

  RETURN jsonb_build_object(
    'items', COALESCE(v_items, '[]'::jsonb),
    'next_cursor', v_next_cursor,
    'has_more', COALESCE(v_has_more, false)
  );
END;
$$;
```

**Client usage:**

```typescript
// First page
const { data: page1 } = await supabase.rpc("chart_list", { p_limit: 20 });

// Next page
const { data: page2 } = await supabase.rpc("chart_list", {
  p_limit: 20,
  p_cursor: page1.next_cursor,
});
```

### List (with offset pagination)

Use offset when you need page numbers (e.g., "Page 3 of 10"). Prefer cursor-based for infinite scroll or "load more" patterns — offsets are slower on large tables because the database still scans skipped rows.

```sql
CREATE OR REPLACE FUNCTION api.chart_list_paged(
  p_limit int DEFAULT 20,
  p_offset int DEFAULT 0
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_items jsonb;
  v_total_count bigint;
BEGIN
  v_limit := LEAST(GREATEST(p_limit, 1), 100);
  v_offset := GREATEST(p_offset, 0);

  SELECT count(*) INTO v_total_count FROM public.charts;

  SELECT COALESCE(jsonb_agg(row_to_json(t)), '[]'::jsonb)
  INTO v_items
  FROM (
    SELECT c.id, c.name, c.created_at
    FROM public.charts c
    ORDER BY c.created_at DESC
    LIMIT v_limit OFFSET v_offset
  ) t;

  RETURN jsonb_build_object(
    'items', v_items,
    'total', v_total_count,
    'limit', v_limit,
    'offset', v_offset
  );
END;
$$;
```

### Update

```sql
CREATE OR REPLACE FUNCTION api.chart_update(
  p_chart_id uuid,
  p_name text DEFAULT NULL,
  p_description text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_result jsonb;
BEGIN
  UPDATE public.charts
  SET
    name = COALESCE(p_name, name),
    description = COALESCE(p_description, description),
    updated_at = now()
  WHERE id = p_chart_id
  RETURNING jsonb_build_object(
    'id', id,
    'name', name,
    'description', description,
    'updated_at', updated_at
  ) INTO v_result;

  IF v_result IS NULL THEN
    RAISE EXCEPTION 'Chart not found: %', p_chart_id;
  END IF;

  RETURN v_result;
END;
$$;
```

**Pattern: partial updates with COALESCE.** Parameters default to NULL. `COALESCE(p_name, name)` keeps the existing value when the parameter isn't provided. This lets clients update only the fields they care about.

### Delete

```sql
CREATE OR REPLACE FUNCTION api.chart_delete(p_chart_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
BEGIN
  DELETE FROM public.charts WHERE id = p_chart_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Chart not found: %', p_chart_id;
  END IF;

  RETURN jsonb_build_object('success', true);
END;
$$;
```

For soft delete, use an `archived_at` timestamp instead:

```sql
CREATE OR REPLACE FUNCTION api.chart_archive(p_chart_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
BEGIN
  UPDATE public.charts
  SET archived_at = now()
  WHERE id = p_chart_id AND archived_at IS NULL;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Chart not found or already archived: %', p_chart_id;
  END IF;

  RETURN jsonb_build_object('success', true);
END;
$$;
```

---

## Search and Filtering

### Parameterized filtering

Add filter parameters to list functions. Use `NULL` defaults to make them optional:

```sql
CREATE OR REPLACE FUNCTION api.chart_list(
  p_status text DEFAULT NULL,
  p_search text DEFAULT NULL,
  p_limit int DEFAULT 20,
  p_cursor timestamptz DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_items jsonb;
  v_has_more boolean;
BEGIN
  SELECT
    jsonb_agg(row_to_json(t)),
    (count(*) > LEAST(p_limit, 100))
  INTO v_items, v_has_more
  FROM (
    SELECT c.id, c.name, c.status, c.created_at
    FROM public.charts c
    WHERE (p_cursor IS NULL OR c.created_at < p_cursor)
      AND (p_status IS NULL OR c.status = p_status)
      AND (p_search IS NULL OR c.name ILIKE '%' || p_search || '%')
    ORDER BY c.created_at DESC
    LIMIT LEAST(p_limit, 100) + 1
  ) t;

  IF v_has_more THEN
    v_items := v_items - (jsonb_array_length(v_items) - 1);
  END IF;

  RETURN jsonb_build_object(
    'items', COALESCE(v_items, '[]'::jsonb),
    'has_more', COALESCE(v_has_more, false)
  );
END;
$$;
```

### Full-text search

For serious search, use PostgreSQL's full-text search instead of `ILIKE`:

```sql
-- Add a tsvector column to the table (in public/charts.sql)
ALTER TABLE public.charts ADD COLUMN IF NOT EXISTS
  search_vector tsvector GENERATED ALWAYS AS (
    to_tsvector('english', coalesce(name, '') || ' ' || coalesce(description, ''))
  ) STORED;

-- Add a GIN index (in public/charts.sql)
CREATE INDEX IF NOT EXISTS idx_charts_search ON public.charts USING gin(search_vector);

-- Search function
CREATE OR REPLACE FUNCTION api.chart_search(
  p_query text,
  p_limit int DEFAULT 20
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
BEGIN
  RETURN COALESCE(
    (SELECT jsonb_agg(row_to_json(t))
     FROM (
       SELECT c.id, c.name, ts_rank(c.search_vector, websearch_to_tsquery('english', p_query)) AS rank
       FROM public.charts c
       WHERE c.search_vector @@ websearch_to_tsquery('english', p_query)
       ORDER BY rank DESC
       LIMIT LEAST(p_limit, 100)
     ) t),
    '[]'::jsonb
  );
END;
$$;
```

---

## Batch Operations

### Batch create

```sql
CREATE OR REPLACE FUNCTION api.chart_create_batch(p_charts jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_ids jsonb;
BEGIN
  -- p_charts: [{"name": "Chart 1"}, {"name": "Chart 2"}]
  WITH inserted AS (
    INSERT INTO public.charts (name, description, user_id)
    SELECT
      item ->> 'name',
      COALESCE(item ->> 'description', ''),
      auth.uid()
    FROM jsonb_array_elements(p_charts) AS item
    RETURNING id
  )
  SELECT jsonb_agg(id) INTO v_ids FROM inserted;

  RETURN jsonb_build_object(
    'ids', v_ids,
    'count', jsonb_array_length(v_ids)
  );
END;
$$;
```

### Batch delete

```sql
CREATE OR REPLACE FUNCTION api.chart_delete_batch(p_chart_ids uuid[])
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_deleted_count int;
BEGIN
  DELETE FROM public.charts
  WHERE id = ANY(p_chart_ids);

  GET DIAGNOSTICS v_deleted_count = ROW_COUNT;

  RETURN jsonb_build_object(
    'deleted', v_deleted_count,
    'requested', array_length(p_chart_ids, 1)
  );
END;
$$;
```

---

## Multi-Table Operations

For operations that span multiple tables (e.g., closing an order creates an invoice and updates inventory):

1. **Start with SECURITY INVOKER** — if all tables have RLS for the calling user, INVOKER is correct
2. **Use SECURITY DEFINER only** when the operation must touch tables the user role can't access
3. **Lock rows** with `FOR UPDATE` to prevent race conditions
4. **Validate first** — check preconditions before making changes

```sql
CREATE OR REPLACE FUNCTION api.order_close(p_order_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_order record;
  v_invoice_id uuid;
BEGIN
  -- 1. Lock and validate
  SELECT * INTO v_order
  FROM public.orders
  WHERE id = p_order_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Order not found: %', p_order_id;
  END IF;

  IF v_order.status = 'closed' THEN
    RAISE EXCEPTION 'Order already closed: %', p_order_id;
  END IF;

  -- 2. Update primary entity
  UPDATE public.orders
  SET status = 'closed', closed_at = now()
  WHERE id = p_order_id;

  -- 3. Create related records
  INSERT INTO public.invoices (order_id, amount)
  VALUES (p_order_id, v_order.total)
  RETURNING id INTO v_invoice_id;

  -- 4. Trigger async side effects
  PERFORM public._internal_call_edge_function(
    'notify-order-closed',
    jsonb_build_object('order_id', p_order_id, 'invoice_id', v_invoice_id)
  );

  RETURN jsonb_build_object(
    'success', true,
    'order_id', p_order_id,
    'invoice_id', v_invoice_id
  );

EXCEPTION
  WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;
```

---

## Input Validation

Validate at the function boundary. Check parameters before any database operations:

```sql
-- Null/empty check
IF p_name IS NULL OR trim(p_name) = '' THEN
  RAISE EXCEPTION 'Name is required';
END IF;

-- Length check
IF length(p_name) > 255 THEN
  RAISE EXCEPTION 'Name must be 255 characters or less';
END IF;

-- Enum/allowed values check
IF p_status NOT IN ('draft', 'published', 'archived') THEN
  RAISE EXCEPTION 'Invalid status: %. Must be draft, published, or archived', p_status;
END IF;

-- Array size check (for batch operations)
IF jsonb_array_length(p_items) > 100 THEN
  RAISE EXCEPTION 'Batch size limited to 100 items';
END IF;
```

---

## Return Types

**Default: `jsonb`** — flexible, self-describing, works well with PostgREST and supabase-js.

```sql
-- Single record
RETURN jsonb_build_object('id', v_id, 'name', v_name);

-- List with pagination
RETURN jsonb_build_object('items', v_items, 'has_more', v_has_more);

-- Success/error
RETURN jsonb_build_object('success', true, 'chart_id', v_id);
```

**When to use `SETOF`:** When you need PostgREST's built-in filtering, ordering, and range headers on the result. This is rare with the `api` schema pattern since you control the query inside the function.

---

## Grants

Schema-level default privileges handle grants automatically. The `_schemas.sql` file contains:

```sql
GRANT USAGE ON SCHEMA api TO anon, authenticated, service_role;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA api TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA api
  GRANT EXECUTE ON FUNCTIONS TO anon, authenticated, service_role;
```

Every function created in the `api` schema is automatically callable by both `anon` and `authenticated` roles. No per-function `GRANT EXECUTE` is needed.

`_auth_*` and `_internal_*` functions in `public` do **not** get grants — they're called internally by RLS policies and other functions, not by clients.
