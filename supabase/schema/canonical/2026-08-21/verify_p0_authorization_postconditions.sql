-- Read-only P0 postcondition checks. Every returned row must have passed=true.
WITH object_counts AS (
  SELECT
    (SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE' AND table_name IN ('isletmeler','kullanicilar','products','sales','sale_items','mutation_idempotency')) AS tables,
    (SELECT count(*) FROM information_schema.columns WHERE table_schema = 'public' AND table_name IN ('isletmeler','kullanicilar','products','sales','sale_items','mutation_idempotency')) AS columns,
    (SELECT count(*) FROM pg_constraint con JOIN pg_class c ON c.oid = con.conrelid JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public' AND c.relname IN ('isletmeler','kullanicilar','products','sales','sale_items','mutation_idempotency')) AS constraints,
    (SELECT count(*) FROM pg_indexes WHERE schemaname = 'public' AND tablename IN ('isletmeler','kullanicilar','products','sales','sale_items','mutation_idempotency')) AS indexes,
    (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname IN ('public','private') AND p.prokind = 'f') AS functions,
    (SELECT count(*) FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid JOIN pg_namespace n ON n.oid = c.relnamespace WHERE NOT t.tgisinternal AND n.nspname = 'public') AS triggers,
    (SELECT count(*) FROM pg_policies WHERE schemaname = 'public') AS policies,
    (SELECT count(*) FROM pg_sequences WHERE schemaname = 'public' AND sequencename = 'isletmeler_id_seq') AS sequences,
    (SELECT count(*) FROM pg_publication_tables WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename IN ('products','sales')) AS publications
), functions AS (
  SELECT p.proname, p.oid, p.prosecdef, p.prosrc,
         coalesce(array_to_string(p.proconfig, ','), '') AS config,
         pg_get_userbyid(p.proowner) AS owner
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname IN ('complete_sale','process_product_mutation','fn_set_updated_at')
), checks(check_name, passed, detail) AS (
  SELECT 'canonical_object_counts',
    (tables, columns, constraints, indexes, functions, triggers, policies, sequences, publications)
      = (6::bigint,32::bigint,17::bigint,19::bigint,10::bigint,5::bigint,19::bigint,1::bigint,2::bigint),
    concat_ws('|', tables, columns, constraints, indexes, functions, triggers, policies, sequences, publications)
  FROM object_counts

  UNION ALL SELECT 'all_six_tables_rls_enabled',
    (SELECT count(*) = 6 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relname IN ('isletmeler','kullanicilar','products','sales','sale_items','mutation_idempotency') AND c.relrowsecurity),
    'expected=6'

  UNION ALL SELECT 'authenticated_financial_select_only',
    has_table_privilege('authenticated','public.sales','SELECT')
      AND has_table_privilege('authenticated','public.sale_items','SELECT')
      AND NOT has_table_privilege('authenticated','public.sales','INSERT')
      AND NOT has_table_privilege('authenticated','public.sales','UPDATE')
      AND NOT has_table_privilege('authenticated','public.sales','DELETE')
      AND NOT has_table_privilege('authenticated','public.sales','TRUNCATE')
      AND NOT has_table_privilege('authenticated','public.sale_items','INSERT')
      AND NOT has_table_privilege('authenticated','public.sale_items','UPDATE')
      AND NOT has_table_privilege('authenticated','public.sale_items','DELETE')
      AND NOT has_table_privilege('authenticated','public.sale_items','TRUNCATE'),
    'sales/sale_items SELECT=true; client writes=false'

  UNION ALL SELECT 'authenticated_product_acl_rls_shape',
    has_table_privilege('authenticated','public.products','SELECT')
      AND has_table_privilege('authenticated','public.products','INSERT')
      AND has_table_privilege('authenticated','public.products','UPDATE')
      AND has_table_privilege('authenticated','public.products','DELETE')
      AND NOT has_table_privilege('authenticated','public.products','TRUNCATE')
      AND NOT has_table_privilege('authenticated','public.products','REFERENCES')
      AND NOT has_table_privilege('authenticated','public.products','TRIGGER'),
    'product CRUD retained behind admin-only RLS; unsafe privileges=false'

  UNION ALL SELECT 'idempotency_table_internal_only',
    NOT has_table_privilege('authenticated','public.mutation_idempotency','SELECT')
      AND NOT has_table_privilege('authenticated','public.mutation_idempotency','INSERT')
      AND NOT has_table_privilege('anon','public.mutation_idempotency','SELECT')
      AND NOT has_table_privilege('anon','public.mutation_idempotency','INSERT'),
    'anon/authenticated have no direct access'

  UNION ALL SELECT 'product_write_policies_admin_only',
    (SELECT count(*) = 3 FROM pg_policies WHERE schemaname='public' AND tablename='products' AND cmd IN ('INSERT','UPDATE','DELETE') AND (coalesce(qual,'') || coalesce(with_check,'')) LIKE '%get_my_rol%' AND (coalesce(qual,'') || coalesce(with_check,'')) LIKE '%admin%'),
    'expected=3 admin-gated write policies'

  UNION ALL SELECT 'financial_write_policies_deny',
    (SELECT count(*) = 6 FROM pg_policies WHERE schemaname='public' AND tablename IN ('sales','sale_items') AND cmd IN ('INSERT','UPDATE','DELETE') AND replace(coalesce(qual,'') || coalesce(with_check,''),' ','') NOT LIKE '%get_my_isletme_id%'),
    'expected=6 deny-only write policies'

  UNION ALL SELECT 'complete_sale_boundary',
    f.prosecdef AND f.config='search_path=""' AND f.owner='postgres'
      AND NOT has_function_privilege('anon',f.oid,'EXECUTE')
      AND NOT has_function_privilege('public',f.oid,'EXECUTE')
      AND has_function_privilege('authenticated',f.oid,'EXECUTE')
      AND strpos(f.prosrc,'v_user_id := auth.uid()') > 0
      AND strpos(f.prosrc,'v_user_id := auth.uid()') < strpos(f.prosrc,'IF p_idempotency_key IS NOT NULL')
      AND strpos(f.prosrc,'s.isletme_id = v_isletme_id') > 0
      AND strpos(f.prosrc,'deleted_at IS NULL') > 0,
    'SECURITY DEFINER; empty search_path; auth->tenant->idempotency; deleted filter'
  FROM functions f WHERE f.proname='complete_sale'

  UNION ALL SELECT 'product_mutation_boundary',
    f.prosecdef AND f.config='search_path=""' AND f.owner='postgres'
      AND NOT has_function_privilege('anon',f.oid,'EXECUTE')
      AND NOT has_function_privilege('public',f.oid,'EXECUTE')
      AND has_function_privilege('authenticated',f.oid,'EXECUTE')
      AND strpos(f.prosrc,$$v_user_role IS DISTINCT FROM 'admin'$$) > 0
      AND strpos(f.prosrc,'v_user_id := auth.uid()') < strpos(f.prosrc,'INSERT INTO public.mutation_idempotency'),
    'SECURITY DEFINER; empty search_path; auth->tenant->admin->idempotency'
  FROM functions f WHERE f.proname='process_product_mutation'

  UNION ALL SELECT 'trigger_function_not_client_executable',
    NOT has_function_privilege('anon',f.oid,'EXECUTE')
      AND NOT has_function_privilege('authenticated',f.oid,'EXECUTE')
      AND NOT has_function_privilege('service_role',f.oid,'EXECUTE')
      AND NOT has_function_privilege('public',f.oid,'EXECUTE'),
    'fn_set_updated_at EXECUTE closed to client roles'
  FROM functions f WHERE f.proname='fn_set_updated_at'
)
SELECT check_name, passed, detail
FROM checks
ORDER BY check_name;
