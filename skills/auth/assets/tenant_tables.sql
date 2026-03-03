-- =============================================================================
-- TENANT TABLES: Multi-tenancy foundation
-- =============================================================================
-- Copy these into your project:
--   Entities  → supabase/schemas/public/tenants.sql, memberships.sql, invitations.sql  (tables + indexes + policies)
--   Auth fns  → supabase/schemas/public/_auth.sql
--   API RPCs  → supabase/schemas/api/tenant.sql, invitation.sql
-- =============================================================================

-- Tenants
CREATE TABLE IF NOT EXISTS public.tenants (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  slug text UNIQUE NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.tenants ENABLE ROW LEVEL SECURITY;

-- Memberships
CREATE TABLE IF NOT EXISTS public.memberships (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  role text NOT NULL DEFAULT 'member' CHECK (role IN ('viewer', 'member', 'admin', 'owner')),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, user_id)
);

ALTER TABLE public.memberships ENABLE ROW LEVEL SECURITY;

-- Invitations
CREATE TABLE IF NOT EXISTS public.invitations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  email text NOT NULL,
  role text NOT NULL DEFAULT 'member' CHECK (role IN ('viewer', 'member', 'admin')),
  invited_by uuid NOT NULL REFERENCES auth.users(id),
  token text UNIQUE NOT NULL DEFAULT encode(gen_random_bytes(32), 'hex'),
  expires_at timestamptz NOT NULL DEFAULT now() + interval '7 days',
  accepted_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.invitations ENABLE ROW LEVEL SECURITY;

-- Indexes
CREATE INDEX IF NOT EXISTS idx_memberships_tenant_user
  ON public.memberships(tenant_id, user_id);
CREATE INDEX IF NOT EXISTS idx_memberships_user_id
  ON public.memberships(user_id);
CREATE INDEX IF NOT EXISTS idx_invitations_token
  ON public.invitations(token) WHERE accepted_at IS NULL;

-- Auth helper functions
CREATE OR REPLACE FUNCTION public._auth_tenant_id()
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT (auth.jwt() -> 'app_metadata' ->> 'tenant_id')::uuid;
$$;

CREATE OR REPLACE FUNCTION public._auth_tenant_role()
RETURNS text
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT (auth.jwt() -> 'app_metadata' ->> 'tenant_role')::text;
$$;

CREATE OR REPLACE FUNCTION public._auth_has_role(p_minimum_role text)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_role text := public._auth_tenant_role();
  v_levels jsonb := '{"viewer": 1, "member": 2, "admin": 3, "owner": 4}'::jsonb;
BEGIN
  RETURN COALESCE(
    (v_levels ->> v_role)::int >= (v_levels ->> p_minimum_role)::int,
    false
  );
END;
$$;

CREATE OR REPLACE FUNCTION public._auth_is_tenant_member(p_tenant_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER  -- required: avoids RLS recursion on memberships table
SET search_path = ''
AS $$
BEGIN
  RETURN EXISTS (
    SELECT 1 FROM public.memberships
    WHERE tenant_id = p_tenant_id AND user_id = auth.uid()
  );
END;
$$;

-- RLS policies
CREATE POLICY "Members can read own tenants"
ON public.tenants FOR SELECT
USING (public._auth_is_tenant_member(id));

CREATE POLICY "Members can read tenant memberships"
ON public.memberships FOR SELECT
USING (tenant_id = public._auth_tenant_id());

CREATE POLICY "Admins can insert memberships"
ON public.memberships FOR INSERT
WITH CHECK (
  tenant_id = public._auth_tenant_id() AND public._auth_has_role('admin')
);

CREATE POLICY "Admins can delete memberships"
ON public.memberships FOR DELETE
USING (
  tenant_id = public._auth_tenant_id() AND public._auth_has_role('admin')
);

CREATE POLICY "Admins can read invitations"
ON public.invitations FOR SELECT
USING (tenant_id = public._auth_tenant_id() AND public._auth_has_role('admin'));

-- API functions
CREATE OR REPLACE FUNCTION api.tenant_select(p_tenant_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER  -- required: updates auth.users metadata
SET search_path = ''
AS $$
DECLARE
  v_membership record;
BEGIN
  SELECT * INTO v_membership
  FROM public.memberships
  WHERE tenant_id = p_tenant_id AND user_id = auth.uid();

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Not a member of this tenant';
  END IF;

  UPDATE auth.users
  SET raw_app_meta_data = raw_app_meta_data
    || jsonb_build_object(
      'tenant_id', p_tenant_id,
      'tenant_role', v_membership.role
    )
  WHERE id = auth.uid();

  RETURN jsonb_build_object(
    'success', true,
    'tenant_id', p_tenant_id,
    'role', v_membership.role
  );
END;
$$;

CREATE OR REPLACE FUNCTION api.tenant_list()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
BEGIN
  RETURN COALESCE(
    (SELECT jsonb_agg(jsonb_build_object(
      'id', t.id,
      'name', t.name,
      'slug', t.slug,
      'role', m.role
    ))
    FROM public.memberships m
    JOIN public.tenants t ON t.id = m.tenant_id
    WHERE m.user_id = auth.uid()),
    '[]'::jsonb
  );
END;
$$;
