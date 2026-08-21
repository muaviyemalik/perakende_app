-- Read-only migration-history verification. Run before and after the future history-only repair.
WITH actual AS (
  SELECT version, name, statements FROM supabase_migrations.schema_migrations ORDER BY version
), current_expected(version, name) AS (
  VALUES
    ('20260817175921', 'harden_rls_and_user_protection'),
    ('20260817175945', 'close_trigger_rpc_surface'),
    ('20260817175955', 'restrict_tenant_helper_rpc_execution'),
    ('20260817181420', 'move_rls_helpers_to_private_schema_v2'),
    ('20260817181445', 'move_trigger_security_functions_private'),
    ('20260817181504', 'grant_private_rls_helpers_to_authenticated'),
    ('20260818131542', '003_complete_sale_rpc'),
    ('20260818132659', '004_revoke_anon_complete_sale_execute')
), current_check AS (
  SELECT count(*) = 8 AND bool_and(e.name = a.name) AS matches_pre_repair_history
  FROM current_expected e LEFT JOIN actual a USING (version)
), post_repair_check AS (
  SELECT count(*) = 1 AND min(version) = '20260821090000' AS matches_post_repair_history FROM actual
)
SELECT
  (SELECT matches_pre_repair_history FROM current_check) AS matches_pre_repair_history,
  (SELECT matches_post_repair_history FROM post_repair_check) AS matches_post_repair_history,
  (SELECT count(*) FROM actual) AS actual_history_rows,
  (SELECT md5(string_agg(version||'|'||coalesce(name,'')||'|'||coalesce(array_to_string(statements,E'\\n--next-statement--\\n'),''),E'\\n--next-migration--\\n' ORDER BY version)) FROM actual) AS actual_history_fingerprint;
