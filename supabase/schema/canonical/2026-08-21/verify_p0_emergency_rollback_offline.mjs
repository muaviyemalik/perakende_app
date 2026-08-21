import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const root = resolve(import.meta.dirname, "../../../..");
const paths = {
  baseline: resolve(root, "supabase/migrations/20260821090000_canonical_live_baseline.sql"),
  p0: resolve(root, "supabase/migrations/20260821100000_p0_authorization_hardening.sql"),
  rollback: resolve(root, "supabase/emergency_migrations/20260822120000_emergency_rollback_p0_authorization.sql"),
  runbook: resolve(root, "supabase/schema/canonical/2026-08-21/p0_emergency_rollback_runbook.md"),
  sqlVerifier: resolve(root, "supabase/schema/canonical/2026-08-21/verify_p0_emergency_rollback.sql"),
  dbTest: resolve(root, "supabase/tests/database/02_p0_emergency_rollback.test.sql"),
};

const decoder = new TextDecoder("utf-8", { fatal: true });
const read = (path) => decoder.decode(readFileSync(path));
const sha256 = (value) => createHash("sha256").update(value, "utf8").digest("hex");
const text = Object.fromEntries(Object.entries(paths).map(([key, path]) => [key, read(path)]));

const frozen = {
  baseline: "5d629f32110ffa2c634df3a9b637e3f7fa842188ca3a7e4f8df07cc498ea04dc",
  p0: "1eefc022b6d0ad6a57cbc4af2fd7813a0eafd533e7455a358c0e3345fbcaadc5",
};

const functionStart = text.baseline.indexOf("CREATE OR REPLACE FUNCTION public.complete_sale");
const functionEndMarker = 'ALTER FUNCTION "public"."process_product_mutation"(p_idempotency_key uuid, p_isletme_id integer, p_operation_type text, p_product_id uuid, p_payload jsonb, p_base_updated_at timestamp with time zone) OWNER TO "postgres";';
const functionEnd = text.baseline.indexOf(functionEndMarker, functionStart) + functionEndMarker.length;
const baselineFunctions = text.baseline.slice(functionStart, functionEnd);

const checks = {
  baselineHashFrozen: sha256(text.baseline) === frozen.baseline,
  p0HashFrozen: sha256(text.p0) === frozen.p0,
  exactBaselineFunctionBlockEmbedded: text.rollback.includes(baselineFunctions),
  outsideActiveMigrationDirectory: paths.rollback.includes("emergency_migrations"),
  transactional: text.rollback.includes("BEGIN;") && text.rollback.includes("COMMIT;"),
  p0HistoryGuard: text.rollback.includes("EMERGENCY_ROLLBACK_ABORTED:P0_HISTORY_NOT_PRESENT"),
  p0SemanticGuard: text.rollback.includes("EMERGENCY_ROLLBACK_ABORTED:P0_POSTCONDITIONS_NOT_PRESENT"),
  noHistoryMutation: !/\b(?:INSERT|UPDATE|DELETE)\s+(?:INTO\s+|FROM\s+)?supabase_migrations\./i.test(text.rollback),
  restoresElevenPolicies: (text.rollback.match(/^ALTER POLICY /gm) ?? []).length === 11,
  resetsSixTableAcls: text.rollback.includes("public.mutation_idempotency\n  FROM PUBLIC, anon, authenticated, service_role"),
  restoresRoutineAcls: text.rollback.includes("TO PUBLIC, anon, authenticated, service_role"),
  explicitSecurityInvoker: text.rollback.includes(") SECURITY INVOKER;"),
  explicitConfigReset: text.rollback.includes(") RESET ALL;"),
  runbookWarnsWeakerSurface: text.runbook.includes("weaker canonical-baseline"),
  runbookRequiresDryRun: text.runbook.includes("db push --linked --dry-run"),
  runbookForbidsRepair: text.runbook.includes("Do not use `migration repair`"),
  verifierHasExpectedCoverage: [
    "canonical_table_grant_count",
    "product_write_policies_tenant_only",
    "financial_write_policies_tenant_only",
    "complete_sale_baseline_boundary",
    "process_product_mutation_baseline_boundary",
    "fn_set_updated_at_baseline_boundary",
  ].every((name) => text.sqlVerifier.includes(name)),
  databaseTestRollsBack: text.dbTest.includes("BEGIN;") && text.dbTest.includes("ROLLBACK;"),
};

const failures = Object.entries(checks)
  .filter(([, passed]) => !passed)
  .map(([name]) => name);

console.log(JSON.stringify({
  status: failures.length === 0 ? "PASS" : "FAIL",
  checks,
  sha256: Object.fromEntries(Object.entries(text).map(([key, value]) => [key, sha256(value)])),
  failures,
}, null, 2));

process.exitCode = failures.length === 0 ? 0 : 1;
