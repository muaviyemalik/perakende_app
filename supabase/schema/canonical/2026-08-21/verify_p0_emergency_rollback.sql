-- Read-only verifier for the emergency P0 compensating migration.
-- Every returned row must have passed=true. The expected state is the
-- authorization surface of 20260821090000_canonical_live_baseline.sql.

WITH functions AS (
  SELECT p.proname, p.oid, p.prosecdef, p.prosrc,
         coalesce(array_to_string(p.proconfig, ','), '') AS config,
         pg_get_userbyid(p.proowner) AS owner
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname IN (
      'complete_sale', 'process_product_mutation', 'fn_set_updated_at'
    )
), checks(check_name, passed, detail) AS (
  SELECT 'canonical_object_counts',
    (SELECT count(*) = 6 FROM information_schema.tables
      WHERE table_schema='public' AND table_type='BASE TABLE'
        AND table_name IN ('isletmeler','kullanicilar','products','sales','sale_items','mutation_idempotency'))
    AND (SELECT count(*) = 32 FROM information_schema.columns
      WHERE table_schema='public'
        AND table_name IN ('isletmeler','kullanicilar','products','sales','sale_items','mutation_idempotency'))
    AND (SELECT count(*) = 18 FROM pg_constraint con
      JOIN pg_class c ON c.oid=con.conrelid JOIN pg_namespace n ON n.oid=c.relnamespace
      WHERE n.nspname='public' AND c.relname IN ('isletmeler','kullanicilar','products','sales','sale_items','mutation_idempotency'))
    AND (SELECT count(*) = 20 FROM pg_indexes WHERE schemaname='public'
      AND tablename IN ('isletmeler','kullanicilar','products','sales','sale_items','mutation_idempotency'))
    AND (SELECT count(*) = 19 FROM pg_policies WHERE schemaname='public'),
    '6 tables; 32 columns; 18 constraints; 20 indexes; 19 policies'

  UNION ALL SELECT 'all_six_tables_rls_enabled',
    (SELECT count(*) = 6 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
      WHERE n.nspname='public'
        AND c.relname IN ('isletmeler','kullanicilar','products','sales','sale_items','mutation_idempotency')
        AND c.relrowsecurity),
    'expected=6'

  UNION ALL SELECT 'canonical_table_grant_count',
    (SELECT count(*) = 91 FROM information_schema.table_privileges
      WHERE table_schema='public'
        AND table_name IN ('isletmeler','kullanicilar','products','sales','sale_items','mutation_idempotency')
        AND grantee IN ('anon','authenticated','service_role')),
    'authenticated=42; service_role=42; anon mutation_idempotency=7'

  UNION ALL SELECT 'authenticated_all_table_privileges',
    (SELECT bool_and(has_table_privilege('authenticated', format('public.%I', t), p))
       FROM unnest(ARRAY['isletmeler','kullanicilar','products','sales','sale_items','mutation_idempotency']) t,
            unnest(ARRAY['SELECT','INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER']) p),
    'canonical baseline authenticated surface is intentionally broad'

  UNION ALL SELECT 'anon_only_idempotency_table',
    (SELECT bool_and(
       has_table_privilege('anon','public.mutation_idempotency',p)
       AND NOT has_table_privilege('anon','public.isletmeler',p)
       AND NOT has_table_privilege('anon','public.kullanicilar',p)
       AND NOT has_table_privilege('anon','public.products',p)
       AND NOT has_table_privilege('anon','public.sales',p)
       AND NOT has_table_privilege('anon','public.sale_items',p)
     ) FROM unnest(ARRAY['SELECT','INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER']) p),
    'anon has seven privileges only on mutation_idempotency'

  UNION ALL SELECT 'product_write_policies_tenant_only',
    (SELECT count(*) = 3 FROM pg_policies
      WHERE schemaname='public' AND tablename='products'
        AND cmd IN ('INSERT','UPDATE','DELETE')
        AND (coalesce(qual,'') || coalesce(with_check,'')) LIKE '%get_my_isletme_id%'
        AND (coalesce(qual,'') || coalesce(with_check,'')) NOT LIKE '%get_my_rol%'),
    'expected=3 tenant-only write policies without role gate'

  UNION ALL SELECT 'financial_write_policies_tenant_only',
    (SELECT count(*) = 6 FROM pg_policies
      WHERE schemaname='public' AND tablename IN ('sales','sale_items')
        AND cmd IN ('INSERT','UPDATE','DELETE')
        AND (coalesce(qual,'') || coalesce(with_check,'')) LIKE '%get_my_isletme_id%'),
    'expected=6 tenant-only financial write policies'

  UNION ALL SELECT 'idempotency_policies_tenant_scoped',
    (SELECT count(*) = 2 FROM pg_policies
      WHERE schemaname='public' AND tablename='mutation_idempotency'
        AND (coalesce(qual,'') || coalesce(with_check,'')) LIKE '%auth.uid%'
        AND replace(coalesce(qual,'') || coalesce(with_check,''),' ','') <> 'false'),
    'expected=2 tenant-scoped policies'

  UNION ALL SELECT 'complete_sale_baseline_boundary',
    f.prosecdef AND f.config='search_path=""' AND f.owner='postgres'
      AND has_function_privilege('authenticated',f.oid,'EXECUTE')
      AND has_function_privilege('service_role',f.oid,'EXECUTE')
      AND NOT has_function_privilege('anon',f.oid,'EXECUTE')
      AND NOT has_function_privilege('public',f.oid,'EXECUTE')
      AND strpos(f.prosrc,'IF p_idempotency_key IS NOT NULL') > 0
      AND strpos(f.prosrc,'IF p_idempotency_key IS NOT NULL') < strpos(f.prosrc,'v_user_id := auth.uid()')
      AND strpos(f.prosrc,'deleted_at IS NULL') = 0,
    'SECURITY DEFINER; empty search_path; baseline idempotency-before-auth behavior'
  FROM functions f WHERE f.proname='complete_sale'

  UNION ALL SELECT 'process_product_mutation_baseline_boundary',
    NOT f.prosecdef AND f.config='' AND f.owner='postgres'
      AND has_function_privilege('public',f.oid,'EXECUTE')
      AND has_function_privilege('anon',f.oid,'EXECUTE')
      AND has_function_privilege('authenticated',f.oid,'EXECUTE')
      AND has_function_privilege('service_role',f.oid,'EXECUTE')
      AND strpos(f.prosrc,'v_user_role') = 0
      AND strpos(f.prosrc,'PRODUCT_MUTATION_FORBIDDEN') = 0,
    'SECURITY INVOKER; no config; PUBLIC/anon/authenticated/service_role execute'
  FROM functions f WHERE f.proname='process_product_mutation'

  UNION ALL SELECT 'fn_set_updated_at_baseline_boundary',
    f.prosecdef AND f.config='search_path=""' AND f.owner='postgres'
      AND has_function_privilege('public',f.oid,'EXECUTE')
      AND has_function_privilege('anon',f.oid,'EXECUTE')
      AND has_function_privilege('authenticated',f.oid,'EXECUTE')
      AND has_function_privilege('service_role',f.oid,'EXECUTE'),
    'SECURITY DEFINER; empty search_path; broad canonical execute ACL'
  FROM functions f WHERE f.proname='fn_set_updated_at'

  UNION ALL SELECT 'realtime_membership_unchanged',
    (SELECT count(*) = 2 FROM pg_publication_tables
      WHERE pubname='supabase_realtime' AND schemaname='public'
        AND tablename IN ('products','sales')),
    'products and sales remain published'
)
SELECT check_name, passed, detail
FROM checks
ORDER BY check_name;
