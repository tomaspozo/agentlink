-- =============================================================================
-- COMMON RLS POLICIES: Reusable patterns
-- =============================================================================
-- These are templates — replace table names and column names with your own.
-- Copy the relevant patterns into the table file: supabase/database/schemas/public/tables/<table>.sql
-- Policy names use snake_case: {role}_{action}_{table}
--
-- AUTHORIZATION MODEL: RLS is ISOLATION-ONLY (scope rows by tenant/owner). It
-- is NOT where permissions are checked. Permission/action authz lives in the
-- api.* RPC via `PERFORM public.auth_verify_access('<entity>.<action>')` — see
-- Pattern 5 at the bottom. Do not put _auth_has_permission/_auth_has_role in
-- a policy.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Pattern 1: User-owns-row
-- ---------------------------------------------------------------------------
-- Use when: each row belongs to one user, no team/tenant concept
-- Requires: table has a `user_id` column
-- Always target `TO authenticated` and wrap auth.uid() in (SELECT ...) so it's
-- evaluated once per query (InitPlan), not once per row.

DROP POLICY IF EXISTS users_read_own_<table> ON public.<table>;
CREATE POLICY users_read_own_<table>
ON public.<table> FOR SELECT TO authenticated
USING (user_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS users_insert_own_<table> ON public.<table>;
CREATE POLICY users_insert_own_<table>
ON public.<table> FOR INSERT TO authenticated
WITH CHECK (user_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS users_update_own_<table> ON public.<table>;
CREATE POLICY users_update_own_<table>
ON public.<table> FOR UPDATE TO authenticated
USING (user_id = (SELECT auth.uid()))
WITH CHECK (user_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS users_delete_own_<table> ON public.<table>;
CREATE POLICY users_delete_own_<table>
ON public.<table> FOR DELETE TO authenticated
USING (user_id = (SELECT auth.uid()));


-- ---------------------------------------------------------------------------
-- Pattern 2: Tenant-scoped (isolation-only)
-- ---------------------------------------------------------------------------
-- Use when: data belongs to a tenant/org. One policy scopes ALL operations to
-- the active tenant. Permission gating ("can this member write?") goes in the
-- RPC via auth_verify_access — see Pattern 5 — NOT here.
-- Requires: table has a `tenant_id` column, _auth_tenant_id() function exists.
-- (SELECT ...) wrap promotes the helper to an InitPlan — one eval per query.

DROP POLICY IF EXISTS <table>_tenant_isolation ON public.<table>;
CREATE POLICY <table>_tenant_isolation
ON public.<table> FOR ALL TO authenticated
USING      (tenant_id = (SELECT public._auth_tenant_id()))
WITH CHECK (tenant_id = (SELECT public._auth_tenant_id()));

-- If a SELECT should be readable by every member but writes need a permission,
-- you still only need the isolation policy above — the write permission is
-- enforced by auth_verify_access in the RPC (Pattern 5), not by a second policy.


-- ---------------------------------------------------------------------------
-- Pattern 3: Public read, authenticated write
-- ---------------------------------------------------------------------------
-- Use when: content is publicly visible but only authors can create/edit

-- Published rows are readable by everyone (anon + authenticated); the write
-- and draft-read policies target authenticated only.

DROP POLICY IF EXISTS anon_read_published_<table> ON public.<table>;
CREATE POLICY anon_read_published_<table>
ON public.<table> FOR SELECT TO anon, authenticated
USING (status = 'published');

DROP POLICY IF EXISTS authors_read_own_drafts ON public.<table>;
CREATE POLICY authors_read_own_drafts
ON public.<table> FOR SELECT TO authenticated
USING (user_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS users_insert_<table> ON public.<table>;
CREATE POLICY users_insert_<table>
ON public.<table> FOR INSERT TO authenticated
WITH CHECK (user_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS authors_update_own_<table> ON public.<table>;
CREATE POLICY authors_update_own_<table>
ON public.<table> FOR UPDATE TO authenticated
USING (user_id = (SELECT auth.uid()));


-- ---------------------------------------------------------------------------
-- Pattern 4: User-owns-row with public sharing
-- ---------------------------------------------------------------------------
-- Use when: rows are private by default but can be shared publicly
-- Requires: table has `user_id` and `is_public` boolean columns

DROP POLICY IF EXISTS users_read_own_or_public_<table> ON public.<table>;
CREATE POLICY users_read_own_or_public_<table>
ON public.<table> FOR SELECT TO authenticated
USING (user_id = (SELECT auth.uid()) OR is_public = true);

DROP POLICY IF EXISTS users_insert_own_<table> ON public.<table>;
CREATE POLICY users_insert_own_<table>
ON public.<table> FOR INSERT TO authenticated
WITH CHECK (user_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS users_update_own_<table> ON public.<table>;
CREATE POLICY users_update_own_<table>
ON public.<table> FOR UPDATE TO authenticated
USING (user_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS users_delete_own_<table> ON public.<table>;
CREATE POLICY users_delete_own_<table>
ON public.<table> FOR DELETE TO authenticated
USING (user_id = (SELECT auth.uid()));


-- ---------------------------------------------------------------------------
-- Pattern 5: RPC authorization guard (the PRIMARY permission gate)
-- ---------------------------------------------------------------------------
-- Permissions are enforced HERE — in the api.* RPC — not in RLS policies.
-- `auth_verify_access` raises a 403 (SQLSTATE 42501) when the caller's active
-- workspace lacks the permission; `auth_has_access` is the boolean form for
-- branching. The matching table keeps an isolation-only policy (Pattern 2) as
-- the backstop. Declare the permission key in the RBAC reference data under
-- supabase/database/rbac/ (permissions.sql + role_permissions.sql, which fill
-- rbac_desired and are reconciled on db apply / env deploy) so
-- auth_verify_access can derive it fresh from (caller, active workspace).

CREATE OR REPLACE FUNCTION api.<table>_update(p_id uuid, p_name text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
BEGIN
  -- 1) permission gate (first statement after any auth/tenant null guards)
  PERFORM public.auth_verify_access('<entity>.update');

  -- 2) explicit tenant scope; isolation RLS backstops a forgotten WHERE
  UPDATE public.<table>
  SET name = p_name
  WHERE id = p_id
    AND tenant_id = (SELECT public._auth_tenant_id());

  IF NOT FOUND THEN
    RAISE EXCEPTION '<table> not found or not permitted';
  END IF;

  RETURN jsonb_build_object('id', p_id, 'name', p_name);
END;
$$;
