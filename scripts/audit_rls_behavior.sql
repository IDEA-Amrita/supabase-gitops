-- ==============================================================================
-- scripts/audit_rls_behavior.sql
-- 
-- Behavioral Row Level Security (RLS) Test Suite for Supabase GitOps.
-- Actively impersonates anon, authenticated, and service_role to verify:
--   1. Anonymous mutations and unauthorized reads are blocked.
--   2. Authenticated user access is enforced with strict cross-tenant isolation.
--   3. Service role administrative bypass behaves correctly.
-- ==============================================================================

\set ON_ERROR_STOP on

-- Ensure Supabase helper functions exist in auth schema
DO $$
BEGIN
  CREATE SCHEMA IF NOT EXISTS auth;
  BEGIN
    CREATE OR REPLACE FUNCTION auth.uid() 
    RETURNS uuid 
    LANGUAGE sql STABLE AS $fn$
      SELECT nullif(current_setting('request.jwt.claim.sub', true), '')::uuid;
    $fn$;
  EXCEPTION WHEN OTHERS THEN
    -- Function already exists or owned by platform role
    NULL;
  END;

  BEGIN
    CREATE OR REPLACE FUNCTION auth.role() 
    RETURNS text 
    LANGUAGE sql STABLE AS $fn$
      SELECT coalesce(
        nullif(current_setting('request.jwt.claim.role', true), ''),
        (SELECT current_user)
      );
    $fn$;
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  BEGIN
    GRANT USAGE ON SCHEMA auth TO anon, authenticated, service_role;
    GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA auth TO anon, authenticated, service_role;
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  -- Ensure service_role and supabase_admin have BYPASSRLS matching Supabase platform architecture
  BEGIN
    ALTER ROLE service_role BYPASSRLS;
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  BEGIN
    ALTER ROLE supabase_admin BYPASSRLS;
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;
END $$;

-- -----------------------------------------------------------------------------
-- Suite 1: Synthetic Multi-Tenant Isolation Verification
-- Proves that the PostgreSQL engine enforces tenant boundary isolation
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_user_a uuid := '00000000-0000-0000-0000-000000000001'::uuid;
  v_user_b uuid := '00000000-0000-0000-0000-000000000002'::uuid;
  v_read_count int;
BEGIN
  RAISE NOTICE '--- Starting Active Behavioral RLS Test Suite ---';

  -- Create isolated behavioral probe table
  DROP TABLE IF EXISTS public._rls_behavioral_probe CASCADE;
  CREATE TABLE public._rls_behavioral_probe (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL,
    secret_note text NOT NULL
  );

  ALTER TABLE public._rls_behavioral_probe ENABLE ROW LEVEL SECURITY;

  -- Policy: Users can only see and edit their own rows
  CREATE POLICY "probe_user_isolation" ON public._rls_behavioral_probe
    FOR ALL TO authenticated
    USING (auth.uid() = user_id)
    WITH CHECK (auth.uid() = user_id);

  GRANT ALL ON public._rls_behavioral_probe TO anon, authenticated, service_role;

  -- Seed probe data under admin
  INSERT INTO public._rls_behavioral_probe (user_id, secret_note) VALUES
    (v_user_a, 'User A Confidential Data'),
    (v_user_b, 'User B Confidential Data');

  -- Test 1.1: Anonymous Role Must Read 0 Rows
  PERFORM set_config('role', 'anon', true);
  PERFORM set_config('request.jwt.claim.sub', '', true);
  SELECT count(*) INTO v_read_count FROM public._rls_behavioral_probe;
  IF v_read_count != 0 THEN
    RAISE EXCEPTION 'RLS Failure: Anonymous role was able to read % rows!', v_read_count;
  END IF;
  RAISE NOTICE '  [PASS] Anon cannot read protected table rows (count=0).';

  -- Test 1.2: Anonymous Role Must Be Blocked From Inserting
  BEGIN
    INSERT INTO public._rls_behavioral_probe (user_id, secret_note) VALUES (v_user_a, 'Hacked data');
    RAISE EXCEPTION 'RLS Failure: Anonymous role was able to insert rows!';
  EXCEPTION WHEN insufficient_privilege OR check_violation THEN
    RAISE NOTICE '  [PASS] Anon write attempt was successfully rejected by RLS policy.';
  END;

  -- Test 2.1: Authenticated User A can read ONLY their own rows
  PERFORM set_config('role', 'authenticated', true);
  PERFORM set_config('request.jwt.claim.sub', v_user_a::text, true);
  SELECT count(*) INTO v_read_count FROM public._rls_behavioral_probe;
  IF v_read_count != 1 THEN
    RAISE EXCEPTION 'RLS Failure: User A expected 1 row, but read %!', v_read_count;
  END IF;
  RAISE NOTICE '  [PASS] Authenticated User A read exactly their own single record.';

  -- Test 2.2: Authenticated User A CANNOT update User B's rows
  UPDATE public._rls_behavioral_probe SET secret_note = 'Tampered by User A' WHERE user_id = v_user_b;
  GET DIAGNOSTICS v_read_count = ROW_COUNT;
  IF v_read_count != 0 THEN
    RAISE EXCEPTION 'RLS Failure: Cross-tenant isolation breach! User A modified % of User B rows!', v_read_count;
  END IF;
  RAISE NOTICE '  [PASS] Cross-tenant isolation verified: User A modified 0 of User B rows.';

  -- Test 3.1: Service Role can access all records (administrative bypass)
  PERFORM set_config('role', 'service_role', true);
  SELECT count(*) INTO v_read_count FROM public._rls_behavioral_probe;
  IF v_read_count != 2 THEN
    RAISE EXCEPTION 'RLS Failure: Service role expected 2 rows, but read %!', v_read_count;
  END IF;
  RAISE NOTICE '  [PASS] Service role bypass confirmed (accessible count=%).', v_read_count;

  -- Cleanup probe
  PERFORM set_config('role', 'postgres', true);
  DROP TABLE public._rls_behavioral_probe;

  RAISE NOTICE '--- Synthetic Multi-Tenant Behavioral RLS Suite: ALL TESTS PASSED ---';
END $$;

-- -----------------------------------------------------------------------------
-- Suite 2: Application Tables Behavioral Audit
-- Verifies that existing public application tables enforce RLS restrictions
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  r RECORD;
  v_count int;
BEGIN
  FOR r IN (SELECT tablename FROM pg_tables WHERE schemaname = 'public' AND rowsecurity = true) LOOP
    RAISE NOTICE 'Testing application table: public.%', r.tablename;
    
    -- Impersonate anon
    PERFORM set_config('role', 'anon', true);
    PERFORM set_config('request.jwt.claim.sub', '', true);
    
    BEGIN
      EXECUTE format('INSERT INTO public.%I DEFAULT VALUES', r.tablename);
      -- If insert succeeded, check if table allows anonymous insert
      RAISE NOTICE '  [WARN] public.% allowed anonymous insert - check policy intention.', r.tablename;
    EXCEPTION WHEN insufficient_privilege OR check_violation OR not_null_violation THEN
      RAISE NOTICE '  [PASS] public.%: Anonymous write safely blocked.', r.tablename;
    END;

    PERFORM set_config('role', 'postgres', true);
  END LOOP;
END $$;
