-- Read-only P0 authorization precondition inventory.
-- Safe for both production and scratch; contains one WITH/SELECT statement.
WITH target_tables(table_name) AS (
  VALUES
    ('isletmeler'),
    ('kullanicilar'),
    ('products'),
    ('sales'),
    ('sale_items'),
    ('mutation_idempotency')
), table_access AS (
  SELECT
    'table_access'::text AS category,
    role_name || '@public.' || table_name AS object_name,
    jsonb_build_object(
      'select', has_table_privilege(role_name, 'public.' || table_name, 'SELECT'),
      'insert', has_table_privilege(role_name, 'public.' || table_name, 'INSERT'),
      'update', has_table_privilege(role_name, 'public.' || table_name, 'UPDATE'),
      'delete', has_table_privilege(role_name, 'public.' || table_name, 'DELETE'),
      'truncate', has_table_privilege(role_name, 'public.' || table_name, 'TRUNCATE'),
      'references', has_table_privilege(role_name, 'public.' || table_name, 'REFERENCES'),
      'trigger', has_table_privilege(role_name, 'public.' || table_name, 'TRIGGER')
    ) AS detail
  FROM target_tables
  CROSS JOIN (VALUES ('anon'), ('authenticated'), ('service_role')) AS roles(role_name)
), function_access AS (
  SELECT
    'function_access'::text AS category,
    n.nspname || '.' || p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' AS object_name,
    jsonb_build_object(
      'owner', pg_get_userbyid(p.proowner),
      'security_definer', p.prosecdef,
      'search_path', coalesce(array_to_string(p.proconfig, ','), ''),
      'public_execute', has_function_privilege('public', p.oid, 'EXECUTE'),
      'anon_execute', has_function_privilege('anon', p.oid, 'EXECUTE'),
      'authenticated_execute', has_function_privilege('authenticated', p.oid, 'EXECUTE'),
      'service_role_execute', has_function_privilege('service_role', p.oid, 'EXECUTE'),
      'idempotency_before_auth', CASE
        WHEN p.proname = 'complete_sale' THEN
          strpos(p.prosrc, 'IF p_idempotency_key IS NOT NULL') > 0
          AND strpos(p.prosrc, 'IF p_idempotency_key IS NOT NULL') < strpos(p.prosrc, 'v_user_id := auth.uid()')
        ELSE NULL
      END,
      'filters_deleted_products', CASE
        WHEN p.proname = 'complete_sale' THEN strpos(p.prosrc, 'deleted_at IS NULL') > 0
        ELSE NULL
      END,
      'admin_role_check', CASE
        WHEN p.proname = 'process_product_mutation' THEN strpos(p.prosrc, $$v_user_role IS DISTINCT FROM 'admin'$$) > 0
        ELSE NULL
      END
    ) AS detail
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE (n.nspname, p.proname) IN (
    ('public', 'complete_sale'),
    ('public', 'process_product_mutation'),
    ('public', 'fn_set_updated_at')
  )
), policies AS (
  SELECT
    'policy'::text AS category,
    schemaname || '.' || tablename || '.' || policyname AS object_name,
    jsonb_build_object(
      'command', cmd,
      'roles', roles,
      'using', qual,
      'with_check', with_check
    ) AS detail
  FROM pg_policies
  WHERE schemaname = 'public'
    AND tablename IN ('products', 'sales', 'sale_items', 'kullanicilar')
), rls AS (
  SELECT
    'rls'::text AS category,
    n.nspname || '.' || c.relname AS object_name,
    jsonb_build_object('enabled', c.relrowsecurity, 'forced', c.relforcerowsecurity) AS detail
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public'
    AND c.relname IN (SELECT table_name FROM target_tables)
    AND c.relkind IN ('r', 'p')
), security_triggers AS (
  SELECT
    'security_trigger'::text AS category,
    n.nspname || '.' || c.relname || '.' || t.tgname AS object_name,
    to_jsonb(pg_get_triggerdef(t.oid, true)) AS detail
  FROM pg_trigger t
  JOIN pg_class c ON c.oid = t.tgrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE NOT t.tgisinternal
    AND n.nspname = 'public'
    AND t.tgname IN (
      'protect_user_role_and_tenant',
      'set_product_isletme_id_trigger',
      'set_sale_item_tenant_data_trigger',
      'set_sale_tenant_data_trigger'
    )
)
SELECT * FROM table_access
UNION ALL SELECT * FROM function_access
UNION ALL SELECT * FROM policies
UNION ALL SELECT * FROM rls
UNION ALL SELECT * FROM security_triggers
ORDER BY category, object_name;
