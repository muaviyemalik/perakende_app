-- Read-only cross-database semantic verification query.
-- Unlike verify_live_schema.sql, this query removes database-local OIDs from
-- routine grant identities and normalizes CRLF/LF differences in function DDL.
WITH function_acl AS (
  SELECT
    p.oid,
    string_agg(
      (CASE WHEN acl.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(acl.grantee) END)
        || ':' || acl.privilege_type || ':' || acl.is_grantable::text,
      ',' ORDER BY
        (CASE WHEN acl.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(acl.grantee) END),
        acl.privilege_type,
        acl.is_grantable
    ) AS normalized_acl
  FROM pg_proc p
  CROSS JOIN LATERAL aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) acl
  GROUP BY p.oid
), function_details AS (
  SELECT
    n.nspname || '.' || p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' AS object_name,
    md5(pg_get_functiondef(p.oid) || '|acl=' || coalesce(p.proacl::text, '')) AS strict_hash,
    md5(replace(pg_get_functiondef(p.oid), E'\r\n', E'\n') || '|acl=' || coalesce(a.normalized_acl, '')) AS line_ending_normalized_hash,
    md5(p.prosrc) AS body_strict_hash,
    md5(replace(p.prosrc, E'\r\n', E'\n')) AS body_line_ending_normalized_hash,
    md5(concat_ws('|',
      pg_get_function_result(p.oid),
      l.lanname,
      p.provolatile,
      p.proisstrict,
      p.prosecdef,
      p.proleakproof,
      p.proparallel,
      coalesce(array_to_string(p.proconfig, ','), ''),
      pg_get_userbyid(p.proowner),
      coalesce(a.normalized_acl, '')
    )) AS structural_hash,
    coalesce(a.normalized_acl, '') AS normalized_acl
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  JOIN pg_language l ON l.oid = p.prolang
  LEFT JOIN function_acl a ON a.oid = p.oid
  WHERE n.nspname IN ('public', 'private')
    AND p.prokind = 'f'
), routine_grant_rows AS (
  SELECT
    n.nspname || '.' || p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')@'
      || (CASE WHEN acl.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(acl.grantee) END)
      || ':' || acl.privilege_type AS object_name,
    acl.is_grantable::text AS definition
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  CROSS JOIN LATERAL aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) acl
  WHERE n.nspname IN ('public', 'private')
    AND p.prokind = 'f'
    AND (CASE WHEN acl.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(acl.grantee) END)
      IN ('anon', 'authenticated', 'service_role')
), schema_acl_rows AS (
  SELECT
    n.nspname AS object_name,
    concat_ws('|',
      pg_get_userbyid(n.nspowner),
      coalesce(string_agg(
        (CASE WHEN acl.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(acl.grantee) END)
          || ':' || acl.privilege_type || ':' || acl.is_grantable::text,
        ',' ORDER BY
          (CASE WHEN acl.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(acl.grantee) END),
          acl.privilege_type,
          acl.is_grantable
      ), ''),
      has_schema_privilege('anon', n.oid, 'USAGE'),
      has_schema_privilege('authenticated', n.oid, 'USAGE'),
      has_schema_privilege('service_role', n.oid, 'USAGE')
    ) AS definition
  FROM pg_namespace n
  LEFT JOIN LATERAL aclexplode(coalesce(n.nspacl, acldefault('n', n.nspowner))) acl ON true
  WHERE n.nspname IN ('public', 'private')
  GROUP BY n.oid, n.nspname, n.nspowner
), table_rls_rows AS (
  SELECT
    n.nspname || '.' || c.relname AS object_name,
    concat_ws('|', c.relkind, pg_get_userbyid(c.relowner), c.relrowsecurity, c.relforcerowsecurity) AS definition
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname IN ('public', 'private')
    AND c.relkind IN ('r', 'p')
)
SELECT
  'functions_detail' AS category,
  object_name,
  jsonb_build_object(
    'strict_hash', strict_hash,
    'line_ending_normalized_hash', line_ending_normalized_hash,
    'body_strict_hash', body_strict_hash,
    'body_line_ending_normalized_hash', body_line_ending_normalized_hash,
    'structural_hash', structural_hash,
    'normalized_acl', normalized_acl
  ) AS definition
FROM function_details
UNION ALL
SELECT 'routine_grants_semantic', object_name, to_jsonb(definition) FROM routine_grant_rows
UNION ALL
SELECT 'schema_acl_semantic', object_name, to_jsonb(definition) FROM schema_acl_rows
UNION ALL
SELECT 'tables_rls', object_name, to_jsonb(definition) FROM table_rls_rows
ORDER BY category, object_name;
