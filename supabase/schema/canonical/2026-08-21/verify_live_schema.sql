-- Read-only live/scratch schema fingerprint query.
-- Expected fingerprints are recorded in object_manifest.json.
WITH objects(category, object_name, definition) AS (
  SELECT 'columns', table_schema||'.'||table_name||'.'||column_name, concat_ws('|', ordinal_position, data_type, udt_name, is_nullable, coalesce(column_default,''), is_identity, is_generated)
  FROM information_schema.columns WHERE table_schema IN ('public','private')
  UNION ALL SELECT 'constraints', n.nspname||'.'||c.relname||'.'||con.conname, concat_ws('|', con.contype, pg_get_constraintdef(con.oid,true), con.convalidated, con.condeferrable, con.condeferred)
  FROM pg_constraint con JOIN pg_class c ON c.oid=con.conrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname IN ('public','private')
  UNION ALL SELECT 'indexes', schemaname||'.'||tablename||'.'||indexname, indexdef FROM pg_indexes WHERE schemaname IN ('public','private')
  UNION ALL SELECT 'policies', schemaname||'.'||tablename||'.'||policyname, concat_ws('|', permissive, array_to_string(roles,','), cmd, coalesce(qual,''), coalesce(with_check,'')) FROM pg_policies WHERE schemaname IN ('public','private')
  UNION ALL SELECT 'functions', n.nspname||'.'||p.proname||'('||pg_get_function_identity_arguments(p.oid)||')', pg_get_functiondef(p.oid)||'|acl='||coalesce(p.proacl::text,'') FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname IN ('public','private') AND p.prokind='f'
  UNION ALL SELECT 'triggers', n.nspname||'.'||c.relname||'.'||t.tgname, pg_get_triggerdef(t.oid,true) FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE NOT t.tgisinternal AND n.nspname IN ('public','private')
  UNION ALL SELECT 'publications', pt.pubname||'.'||pt.schemaname||'.'||pt.tablename, concat_ws('|',coalesce(array_to_string(pt.attnames,','),'*'),coalesce(pt.rowfilter,'')) FROM pg_publication_tables pt WHERE pt.schemaname IN ('public','private')
  UNION ALL SELECT 'table_grants', table_schema||'.'||table_name||'@'||grantee||':'||privilege_type, is_grantable FROM information_schema.role_table_grants WHERE table_schema IN ('public','private') AND grantee IN ('anon','authenticated','service_role')
  UNION ALL SELECT 'routine_grants', routine_schema||'.'||specific_name||'@'||grantee||':'||privilege_type, is_grantable FROM information_schema.role_routine_grants WHERE routine_schema IN ('public','private') AND grantee IN ('anon','authenticated','service_role')
  UNION ALL SELECT 'sequences', schemaname||'.'||sequencename, concat_ws('|',sequenceowner,data_type,start_value,increment_by,min_value,max_value,cycle,cache_size) FROM pg_sequences WHERE schemaname IN ('public','private')
  UNION ALL SELECT 'sequence_grants', n.nspname||'.'||c.relname||'@'||CASE WHEN x.grantee=0 THEN 'PUBLIC' ELSE pg_get_userbyid(x.grantee) END||':'||x.privilege_type, x.is_grantable::text FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace CROSS JOIN LATERAL aclexplode(coalesce(c.relacl,acldefault('S',c.relowner))) x WHERE n.nspname IN ('public','private') AND c.relkind='S' AND CASE WHEN x.grantee=0 THEN 'PUBLIC' ELSE pg_get_userbyid(x.grantee) END IN ('PUBLIC','anon','authenticated','service_role')
  UNION ALL SELECT 'schema_acl', n.nspname, concat_ws('|',pg_get_userbyid(n.nspowner),coalesce(n.nspacl::text,''),has_schema_privilege('anon',n.oid,'USAGE'),has_schema_privilege('authenticated',n.oid,'USAGE'),has_schema_privilege('service_role',n.oid,'USAGE')) FROM pg_namespace n WHERE n.nspname IN ('public','private')
)
SELECT category, count(*) AS object_count, md5(string_agg(object_name||'='||definition, E'\n' ORDER BY object_name)) AS fingerprint
FROM objects GROUP BY category ORDER BY category;
