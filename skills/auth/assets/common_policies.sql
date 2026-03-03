-- =============================================================================
-- COMMON RLS POLICIES: Reusable patterns
-- =============================================================================
-- These are templates — replace table names and column names with your own.
-- Copy the relevant patterns into the entity file: supabase/schemas/public/<table>.sql
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Pattern 1: User-owns-row
-- ---------------------------------------------------------------------------
-- Use when: each row belongs to one user, no team/tenant concept
-- Requires: table has a `user_id` column

CREATE POLICY "Users can read own <table>"
ON public.<table> FOR SELECT
USING (user_id = auth.uid());

CREATE POLICY "Users can insert own <table>"
ON public.<table> FOR INSERT
WITH CHECK (user_id = auth.uid());

CREATE POLICY "Users can update own <table>"
ON public.<table> FOR UPDATE
USING (user_id = auth.uid())
WITH CHECK (user_id = auth.uid());

CREATE POLICY "Users can delete own <table>"
ON public.<table> FOR DELETE
USING (user_id = auth.uid());


-- ---------------------------------------------------------------------------
-- Pattern 2: Tenant-scoped (all members can read, members+ can write)
-- ---------------------------------------------------------------------------
-- Use when: data belongs to a tenant/org, all members can see it
-- Requires: table has a `tenant_id` column, _auth_tenant_id() function exists

CREATE POLICY "Tenant members can read <table>"
ON public.<table> FOR SELECT
USING (tenant_id = public._auth_tenant_id());

CREATE POLICY "Tenant members can insert <table>"
ON public.<table> FOR INSERT
WITH CHECK (
  tenant_id = public._auth_tenant_id()
  AND public._auth_has_role('member')
);

CREATE POLICY "Tenant members can update <table>"
ON public.<table> FOR UPDATE
USING (tenant_id = public._auth_tenant_id() AND public._auth_has_role('member'))
WITH CHECK (tenant_id = public._auth_tenant_id());

CREATE POLICY "Tenant admins can delete <table>"
ON public.<table> FOR DELETE
USING (tenant_id = public._auth_tenant_id() AND public._auth_has_role('admin'));


-- ---------------------------------------------------------------------------
-- Pattern 3: Public read, authenticated write
-- ---------------------------------------------------------------------------
-- Use when: content is publicly visible but only authors can create/edit

CREATE POLICY "Anyone can read published <table>"
ON public.<table> FOR SELECT
USING (status = 'published');

CREATE POLICY "Authors can read own drafts"
ON public.<table> FOR SELECT
USING (user_id = auth.uid());

CREATE POLICY "Authenticated users can insert <table>"
ON public.<table> FOR INSERT
WITH CHECK (user_id = auth.uid());

CREATE POLICY "Authors can update own <table>"
ON public.<table> FOR UPDATE
USING (user_id = auth.uid());


-- ---------------------------------------------------------------------------
-- Pattern 4: User-owns-row with public sharing
-- ---------------------------------------------------------------------------
-- Use when: rows are private by default but can be shared publicly
-- Requires: table has `user_id` and `is_public` boolean columns

CREATE POLICY "Users can read own or public <table>"
ON public.<table> FOR SELECT
USING (user_id = auth.uid() OR is_public = true);

CREATE POLICY "Users can insert own <table>"
ON public.<table> FOR INSERT
WITH CHECK (user_id = auth.uid());

CREATE POLICY "Users can update own <table>"
ON public.<table> FOR UPDATE
USING (user_id = auth.uid());

CREATE POLICY "Users can delete own <table>"
ON public.<table> FOR DELETE
USING (user_id = auth.uid());
