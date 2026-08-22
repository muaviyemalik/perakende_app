import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const root = resolve(import.meta.dirname, "../../../..");
const canonicalDir = resolve(root, "supabase/schema/canonical/2026-08-21");
const baselinePath = resolve(
  root,
  "supabase/migrations/20260821090000_canonical_live_baseline.sql",
);

const paths = {
  baseline: baselinePath,
  manifest: resolve(canonicalDir, "object_manifest.json"),
  history: resolve(canonicalDir, "remote_history_snapshot.json"),
  scratchValidation: resolve(
    canonicalDir,
    "scratch_validation_2026-08-21.json",
  ),
  verifyLive: resolve(canonicalDir, "verify_live_schema.sql"),
  verifySemantics: resolve(canonicalDir, "verify_schema_semantics.sql"),
  verifyHistory: resolve(canonicalDir, "verify_migration_history.sql"),
  runbook: resolve(canonicalDir, "reconciliation_runbook.md"),
  rollback: resolve(canonicalDir, "rollback_history.sql"),
  verifier: resolve(canonicalDir, "verify_baseline_offline.mjs"),
  archiveReadme: resolve(root, "supabase/migration_archive/README.md"),
};

const decoder = new TextDecoder("utf-8", { fatal: true });
const readUtf8 = (path) => decoder.decode(readFileSync(path));
const md5 = (value) => createHash("md5").update(value, "utf8").digest("hex");
const sha256 = (value) =>
  createHash("sha256").update(value, "utf8").digest("hex");
const count = (value, pattern) => [...value.matchAll(pattern)].length;

const texts = Object.fromEntries(
  Object.entries(paths).map(([name, path]) => [name, readUtf8(path)]),
);
const baseline = texts.baseline;
const manifest = JSON.parse(texts.manifest);
const history = JSON.parse(texts.history);
const scratchValidation = JSON.parse(texts.scratchValidation);

const historyMaterial = [...history.rows]
  .sort((a, b) => a.version.localeCompare(b.version))
  .map(
    (row) =>
      `${row.version}|${row.name}|${row.statements.join(
        "\n--next-statement--\n",
      )}`,
  )
  .join("\n--next-migration--\n");

const strippedTopLevel = baseline
  .replace(/\$function\$[\s\S]*?\$function\$/g, "")
  .replace(/\$publication\$[\s\S]*?\$publication\$/g, "");

const checks = {
  validUtf8Files: Object.keys(texts).length,
  replacementCharacterFiles: Object.values(texts).filter((text) =>
    text.includes("\uFFFD"),
  ).length,
  tables: count(baseline, /^CREATE TABLE /gm),
  columns: manifest.objects.tables.reduce(
    (total, table) => total + table.columns.length,
    0,
  ),
  constraints: count(
    baseline,
    /^ALTER TABLE ONLY .* ADD CONSTRAINT /gm,
  ),
  explicitIndexes: count(baseline, /^CREATE (?:UNIQUE )?INDEX /gm),
  constraintBackedIndexes: 7,
  totalIndexes:
    count(baseline, /^CREATE (?:UNIQUE )?INDEX /gm) + 7,
  functions: count(baseline, /^CREATE OR REPLACE FUNCTION /gm),
  functionStatementTerminators: count(baseline, /\$function\$;/g),
  securityDefinerFunctions: count(baseline, /\bSECURITY DEFINER\b/g),
  emptySearchPathFunctions: count(baseline, /^ SET search_path TO ''$/gm),
  functionOwners: count(baseline, /^ALTER FUNCTION .* OWNER TO /gm),
  triggers: count(baseline, /^CREATE TRIGGER /gm),
  rlsEnabledTables: count(
    baseline,
    /^ALTER TABLE .* ENABLE ROW LEVEL SECURITY;$/gm,
  ),
  policies: count(baseline, /^CREATE POLICY /gm),
  tableGrantStatements: count(baseline, /^GRANT .* ON TABLE /gm),
  realtimeMembershipStatements: count(
    baseline,
    /ALTER PUBLICATION supabase_realtime ADD TABLE public\.(?:products|sales)/g,
  ),
  sequenceGrantMatrixMatches:
    baseline.includes(
      "REVOKE ALL ON SEQUENCE public.isletmeler_id_seq FROM PUBLIC, anon, authenticated, service_role;",
    ) &&
    baseline.includes(
      "GRANT SELECT, UPDATE, USAGE ON SEQUENCE public.isletmeler_id_seq TO anon, authenticated, service_role;",
    ),
  routineGrantMatrixMatches:
    baseline.includes(
      'GRANT EXECUTE ON FUNCTION "public"."complete_sale"(p_items jsonb, p_idempotency_key text) TO authenticated, service_role;',
    ) &&
    baseline.includes(
      'GRANT EXECUTE ON FUNCTION "public"."fn_set_updated_at"() TO PUBLIC, anon, authenticated, service_role;',
    ) &&
    baseline.includes(
      'GRANT EXECUTE ON FUNCTION "public"."process_product_mutation"(p_idempotency_key uuid, p_isletme_id integer, p_operation_type text, p_product_id uuid, p_payload jsonb, p_base_updated_at timestamp with time zone) TO PUBLIC, anon, authenticated, service_role;',
    ),
  dependentConstraintOrderMatches:
    baseline.indexOf('ADD CONSTRAINT "isletmeler_pkey"') <
      baseline.indexOf('ADD CONSTRAINT "kullanicilar_isletme_id_fkey"') &&
    baseline.indexOf('ADD CONSTRAINT "products_pkey"') <
      baseline.indexOf('ADD CONSTRAINT "sale_items_product_id_fkey"') &&
    baseline.indexOf('ADD CONSTRAINT "sales_pkey"') <
      baseline.indexOf('ADD CONSTRAINT "sale_items_sale_id_fkey"'),
  topLevelForbiddenDml: count(
    strippedTopLevel,
    /^\s*(?:INSERT|UPDATE|DELETE|TRUNCATE|DROP)\b/gim,
  ),
  historyRows: history.rows.length,
  historyRowsWithNameAndStatements: history.rows.filter(
    (row) =>
      typeof row.name === "string" &&
      row.name.length > 0 &&
      Array.isArray(row.statements) &&
      row.statements.length > 0,
  ).length,
  uniqueHistoryVersions: new Set(history.rows.map((row) => row.version)).size,
  historyFingerprint: md5(historyMaterial),
  rollbackContainsExactHistory: history.rows.every(
    (row) =>
      texts.rollback.includes(row.version) &&
      texts.rollback.includes(row.name) &&
      row.statements.every((statement) => texts.rollback.includes(statement)),
  ),
  scratchValidationStatus: scratchValidation.status,
  scratchSchemaEqualsProduction:
    scratchValidation.semantic_comparison
      .scratch_schema_equals_current_production_schema,
  scratchValidationBaselineHashMatches:
    scratchValidation.baseline.sha256 === sha256(baseline),
  manifestTables: manifest.objects.tables.length,
  manifestConstraints: manifest.objects.constraints.length,
  manifestIndexes: manifest.objects.indexes.length,
  manifestFunctions: manifest.objects.functions.length,
  manifestTriggers: manifest.objects.triggers.length,
  manifestPolicies: manifest.objects.policies.length,
  manifestPublications: manifest.objects.publications.length,
  manifestSequences: manifest.objects.sequences.length,
  manifestSchemaAcl: manifest.objects.schema_acl.length,
  manifestSequenceGrants: manifest.counts.sequence_grants,
  manifestRoutineGrants: manifest.counts.routine_grants,
};

const expected = {
  replacementCharacterFiles: 0,
  tables: 6,
  columns: 32,
  constraints: 18,
  explicitIndexes: 13,
  constraintBackedIndexes: 7,
  totalIndexes: 20,
  functions: 10,
  functionStatementTerminators: 10,
  securityDefinerFunctions: 9,
  emptySearchPathFunctions: 9,
  functionOwners: 10,
  triggers: 5,
  rlsEnabledTables: 6,
  policies: 19,
  tableGrantStatements: 91,
  realtimeMembershipStatements: 2,
  sequenceGrantMatrixMatches: true,
  routineGrantMatrixMatches: true,
  dependentConstraintOrderMatches: true,
  topLevelForbiddenDml: 0,
  historyRows: 8,
  historyRowsWithNameAndStatements: 8,
  uniqueHistoryVersions: 8,
  historyFingerprint: history.fingerprint,
  rollbackContainsExactHistory: true,
  scratchValidationStatus: "PASS",
  scratchSchemaEqualsProduction: "PASS",
  scratchValidationBaselineHashMatches: true,
  manifestTables: 6,
  manifestConstraints: 18,
  manifestIndexes: 20,
  manifestFunctions: 10,
  manifestTriggers: 5,
  manifestPolicies: 19,
  manifestPublications: 2,
  manifestSequences: 1,
  manifestSchemaAcl: 2,
  manifestSequenceGrants: 9,
  manifestRoutineGrants: 11,
};

const legacyHashes = {
  "001_kullanicilar_rls.sql":
    "c06fdf52e4cb129985930b5a69c00f7a1a2052dbad2051d8e7ef0a9ca98b8fbf",
  "002_tenant_rls_policies.sql":
    "a018c2fe827f63179f320d2285e5f428aa7059978eb9e0bd324cce9998ea2c87",
  "003_complete_sale_rpc.sql":
    "630f2d5c96dde02b1b200294e0724c3ee8a7bf096e432d210734d8942ccb7b4b",
  "004_indexes_and_constraints.sql":
    "8ee21932855ce8f9386891a4824da47a84701e14b251fa40d721299a4e05d372",
  "005_idempotency_key.sql":
    "ace7cf915ad77d33082bbed245513f175bfba08a107bee957232b23b37c56958",
  "006_secure_complete_sale_cleanup.sql":
    "6756f57cab93f8596bab9accf366f7af95f53581975f806b3c16ea4d59f7b0d4",
  "007_products_updated_at_trigger.sql":
    "d14cc1423bda62c58efb9fcef56b42ba8c9d7ac601fe797899cec6b3aaa8b6a2",
  "008_products_soft_delete.sql":
    "3072b1f82f7182b459f277c9230be64aa74e0fd06003e7cabec9c87df3c7a16d",
  "009_products_unique_barcode.sql":
    "e80f87475af2defe59ee6c8d9be3cb079babdb22be3fc71e5f5c57abb1a2b066",
  "010_product_mutations_rpc.sql":
    "1d0d64d6220e3a41b46103a50a7f48ed5609f81fde0504b1c6048db11e5d271d",
};

const legacyResults = Object.fromEntries(
  Object.entries(legacyHashes).map(([file, expectedHash]) => {
    const actualHash = sha256(
      readUtf8(resolve(root, "supabase/migration_archive", file)),
    );
    return [file, { expected: expectedHash, actual: actualHash, matches: actualHash === expectedHash }];
  }),
);

const failures = Object.entries(expected)
  .filter(([name, value]) => checks[name] !== value)
  .map(([name, value]) => ({ name, expected: value, actual: checks[name] }));

for (const [file, result] of Object.entries(legacyResults)) {
  if (!result.matches) {
    failures.push({
      name: `legacyHash:${file}`,
      expected: result.expected,
      actual: result.actual,
    });
  }
}

const result = {
  status: failures.length === 0 ? "PASS" : "FAIL",
  checks,
  expected,
  legacyMigrations: legacyResults,
  fileSha256: Object.fromEntries(
    Object.entries(texts).map(([name, text]) => [name, sha256(text)]),
  ),
  failures,
};

console.log(JSON.stringify(result, null, 2));
process.exitCode = failures.length === 0 ? 0 : 1;
