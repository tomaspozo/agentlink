-- =============================================================================
-- CHECK SETUP: Verify required infrastructure is in place
-- =============================================================================
-- Run this via psql to verify that all required extensions, internal
-- functions, and Vault secrets exist before starting development.
--
-- Returns a single JSON object with the verification results:
--   {
--     "extensions":  { "pg_net": true, "vault": true },
--     "functions":   { "_internal_get_secret": true, ... },
--     "secrets":     { "SUPABASE_URL": true, ... },
--     "ready": true
--   }
--
-- The agent should parse the result and act on any `false` values.
-- Secret values are NEVER exposed — only presence is checked.
-- =============================================================================

SELECT jsonb_build_object(
  'extensions', jsonb_build_object(
    'pg_net', EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_net'),
    'vault',  EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'supabase_vault')
  ),
  'functions', jsonb_build_object(
    '_internal_get_secret',
      EXISTS (
        SELECT 1 FROM information_schema.routines
        WHERE routine_schema = 'public'
          AND routine_name = '_internal_get_secret'
      ),
    '_internal_call_edge_function',
      EXISTS (
        SELECT 1 FROM information_schema.routines
        WHERE routine_schema = 'public'
          AND routine_name = '_internal_call_edge_function'
      ),
    '_internal_call_edge_function_sync',
      EXISTS (
        SELECT 1 FROM information_schema.routines
        WHERE routine_schema = 'public'
          AND routine_name = '_internal_call_edge_function_sync'
      )
  ),
  'secrets', jsonb_build_object(
    'SUPABASE_URL',
      EXISTS (SELECT 1 FROM vault.secrets WHERE name = 'SUPABASE_URL'),
    'SB_PUBLISHABLE_KEY',
      EXISTS (SELECT 1 FROM vault.secrets WHERE name = 'SB_PUBLISHABLE_KEY'),
    'SB_SECRET_KEY',
      EXISTS (SELECT 1 FROM vault.secrets WHERE name = 'SB_SECRET_KEY')
  ),
  'api_schema', EXISTS (
    SELECT 1 FROM information_schema.schemata WHERE schema_name = 'api'
  ),
  'ready', (
    -- All extensions present
    EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_net')
    AND EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'supabase_vault')
    -- api schema exists
    AND EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name = 'api')
    -- All functions present
    AND EXISTS (
      SELECT 1 FROM information_schema.routines
      WHERE routine_schema = 'public' AND routine_name = '_internal_get_secret'
    )
    AND EXISTS (
      SELECT 1 FROM information_schema.routines
      WHERE routine_schema = 'public' AND routine_name = '_internal_call_edge_function'
    )
    AND EXISTS (
      SELECT 1 FROM information_schema.routines
      WHERE routine_schema = 'public' AND routine_name = '_internal_call_edge_function_sync'
    )
    -- All secrets present (use vault.secrets, not decrypted_secrets — no need to decrypt)
    AND EXISTS (SELECT 1 FROM vault.secrets WHERE name = 'SUPABASE_URL')
    AND EXISTS (SELECT 1 FROM vault.secrets WHERE name = 'SB_PUBLISHABLE_KEY')
    AND EXISTS (SELECT 1 FROM vault.secrets WHERE name = 'SB_SECRET_KEY')
  )
) AS setup_status;
