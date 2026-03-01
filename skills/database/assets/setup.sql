-- =============================================================================
-- SETUP: Internal Utility Functions
-- =============================================================================
-- Defines the _internal_* functions required by the database skill.
-- Copy these into supabase/schemas/public/_internal.sql in your project.
--
-- Before applying these functions, ensure setup verification passes:
--   1. Run check_setup.sql via psql to see what's missing.
--   2. Extensions must be enabled: pg_net, supabase_vault.
--   3. Vault secrets must be stored. See assets/seed.sql for the full template
--      and explanation. Append its content to supabase/seed.sql so secrets
--      persist across `supabase db reset`.
--
-- See references/setup.md for the full verification flow.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- _internal_get_secret
-- -----------------------------------------------------------------------------
-- Retrieves a secret from Vault by name.
--
-- Usage:
--   SELECT _internal_get_secret('SUPABASE_URL');
--
-- Returns:
--   The decrypted secret value, or NULL if not found.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION _internal_get_secret(secret_name text)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  secret_value text;
BEGIN
  SELECT decrypted_secret INTO secret_value
  FROM vault.decrypted_secrets
  WHERE name = secret_name
  LIMIT 1;
  
  RETURN secret_value;
END;
$$;

-- Restrict access to service role only
REVOKE ALL ON FUNCTION _internal_get_secret(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION _internal_get_secret(text) FROM anon;
REVOKE ALL ON FUNCTION _internal_get_secret(text) FROM authenticated;
GRANT EXECUTE ON FUNCTION _internal_get_secret(text) TO service_role;


-- -----------------------------------------------------------------------------
-- _internal_call_edge_function
-- -----------------------------------------------------------------------------
-- Calls a Supabase Edge Function using pg_net with service role authentication.
--
-- Usage:
--   SELECT _internal_call_edge_function(
--     'my-function',
--     '{"key": "value"}'::jsonb
--   );
--
-- Parameters:
--   - function_name: Name of the edge function (without path)
--   - payload: JSONB payload to send in the request body
--
-- Returns:
--   The request_id from pg_net (use net._http_response to check results)
--
-- Note:
--   This is an async call. To get the response, query:
--   SELECT * FROM net._http_response WHERE id = <returned_request_id>;
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION _internal_call_edge_function(
  function_name text,
  payload jsonb DEFAULT '{}'::jsonb
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  supabase_url text;
  service_key text;
  request_id bigint;
  full_url text;
BEGIN
  -- Retrieve secrets
  supabase_url := _internal_get_secret('SUPABASE_URL');
  service_key := _internal_get_secret('SB_SECRET_KEY');

  IF supabase_url IS NULL THEN
    RAISE EXCEPTION 'SUPABASE_URL secret not found in Vault';
  END IF;

  IF service_key IS NULL THEN
    RAISE EXCEPTION 'SB_SECRET_KEY secret not found in Vault';
  END IF;
  
  -- Build the full URL
  full_url := supabase_url || '/functions/v1/' || function_name;
  
  -- Make the HTTP request via pg_net
  SELECT net.http_post(
    url := full_url,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'apikey', service_key
    ),
    body := payload
  ) INTO request_id;
  
  RETURN request_id;
END;
$$;

-- Restrict access to service role only
REVOKE ALL ON FUNCTION _internal_call_edge_function(text, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION _internal_call_edge_function(text, jsonb) FROM anon;
REVOKE ALL ON FUNCTION _internal_call_edge_function(text, jsonb) FROM authenticated;
GRANT EXECUTE ON FUNCTION _internal_call_edge_function(text, jsonb) TO service_role;


-- -----------------------------------------------------------------------------
-- _internal_call_edge_function_sync (Optional)
-- -----------------------------------------------------------------------------
-- Synchronous wrapper that waits for the edge function response.
-- Use with caution as it blocks until response is received or timeout.
--
-- Usage:
--   SELECT _internal_call_edge_function_sync(
--     'my-function',
--     '{"key": "value"}'::jsonb,
--     5  -- timeout in seconds
--   );
--
-- Returns:
--   JSONB response body from the edge function, or NULL on timeout/error.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION _internal_call_edge_function_sync(
  function_name text,
  payload jsonb DEFAULT '{}'::jsonb,
  timeout_seconds integer DEFAULT 5
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
SET statement_timeout = '30s'
AS $$
DECLARE
  request_id bigint;
  response_body jsonb;
  response_status integer;
  wait_until timestamptz;
BEGIN
  -- Make the async call
  request_id := _internal_call_edge_function(function_name, payload);
  
  -- Calculate timeout
  wait_until := clock_timestamp() + (timeout_seconds || ' seconds')::interval;
  
  -- Poll for response
  LOOP
    SELECT status, body::jsonb INTO response_status, response_body
    FROM net._http_response
    WHERE id = request_id;
    
    -- Check if we got a response
    IF response_status IS NOT NULL THEN
      IF response_status >= 200 AND response_status < 300 THEN
        RETURN response_body;
      ELSE
        RAISE WARNING 'Edge function returned status %: %', response_status, response_body;
        RETURN NULL;
      END IF;
    END IF;
    
    -- Check timeout
    IF clock_timestamp() > wait_until THEN
      RAISE WARNING 'Edge function call timed out after % seconds', timeout_seconds;
      RETURN NULL;
    END IF;
    
    -- Small delay before next poll
    PERFORM pg_sleep(0.1);
  END LOOP;
END;
$$;

-- Restrict access to service role only
REVOKE ALL ON FUNCTION _internal_call_edge_function_sync(text, jsonb, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION _internal_call_edge_function_sync(text, jsonb, integer) FROM anon;
REVOKE ALL ON FUNCTION _internal_call_edge_function_sync(text, jsonb, integer) FROM authenticated;
GRANT EXECUTE ON FUNCTION _internal_call_edge_function_sync(text, jsonb, integer) TO service_role;
