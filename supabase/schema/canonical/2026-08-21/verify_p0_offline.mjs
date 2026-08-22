import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const root = resolve(import.meta.dirname, "../../../..");
const migrationsDir = resolve(root, "supabase/migrations");
const migrationArchiveDir = resolve(root, "supabase/migration_archive");
const canonicalDir = resolve(root, "supabase/schema/canonical/2026-08-21");

const decoder = new TextDecoder("utf-8", { fatal: true });
const readUtf8 = (path) => decoder.decode(readFileSync(path));
const sha256 = (text) =>
  createHash("sha256").update(text, "utf8").digest("hex");
const count = (text, pattern) => [...text.matchAll(pattern)].length;

const baselinePath = resolve(
  migrationsDir,
  "20260821090000_canonical_live_baseline.sql",
);
const p0Path = resolve(
  migrationsDir,
  "20260821100000_p0_authorization_hardening.sql",
);
const testPath = resolve(
  root,
  "supabase/tests/database/01_p0_authorization.test.sql",
);
const preconditionsPath = resolve(
  canonicalDir,
  "verify_p0_authorization_preconditions.sql",
);
const postconditionsPath = resolve(
  canonicalDir,
  "verify_p0_authorization_postconditions.sql",
);

const baseline = readUtf8(baselinePath);
const p0 = readUtf8(p0Path);
const testSql = readUtf8(testPath);
const preconditions = readUtf8(preconditionsPath);
const postconditions = readUtf8(postconditionsPath);

const checkpointHashes = {
  "20260821090000_canonical_live_baseline.sql":
    "5d629f32110ffa2c634df3a9b637e3f7fa842188ca3a7e4f8df07cc498ea04dc",
  "001_kullanicilar_rls.sql":
    "c06fdf52e4cb129985930b5a69c00f7a1a2052dbad2051d8e7ef0a9ca98b8fbf",
  "002_tenant_rls_policies.sql":
    "a018c2fe827f63179f320d2285e5f428aa7059978eb9e0bd324cce9998ea2c87",
  "003_complete_sale_rpc.sql":
    "630f2d5c96dde02b1b200294e0724c3ee8a7bf096e432d210734d8942ccb7b4b",
  "004_indexes_and_constraints.sql":
    "8ee21932855ce8f9386891a4824da47a84701e14b251fa40d721299a4e05d372",
  "005_idempotency_key.sql":
    "ace7cf915ad77d33082bbed245513f175bfba08a107beE957232b23b37c56958".toLowerCase(),
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

const checkpointResults = Object.fromEntries(
  Object.entries(checkpointHashes).map(([file, expected]) => {
    const directory = file.startsWith("202608")
      ? migrationsDir
      : migrationArchiveDir;
    const actual = sha256(readUtf8(resolve(directory, file)));
    return [file, { expected, actual, matches: expected === actual }];
  }),
);

const strippedFunctionBodies = p0.replace(
  /\$function\$[\s\S]*?\$function\$;/g,
  "",
);

const completeSaleStart = p0.indexOf(
  "CREATE OR REPLACE FUNCTION public.complete_sale",
);
const completeSaleEnd = p0.indexOf(
  "ALTER FUNCTION public.complete_sale",
);
const completeSaleBody = p0.slice(completeSaleStart, completeSaleEnd);
const productMutationStart = p0.indexOf(
  "CREATE OR REPLACE FUNCTION public.process_product_mutation",
);
const productMutationEnd = p0.indexOf(
  "ALTER FUNCTION public.process_product_mutation",
);
const productMutationBody = p0.slice(productMutationStart, productMutationEnd);

const checks = {
  validUtf8Files: 5,
  replacementCharacterFiles: [
    baseline,
    p0,
    testSql,
    preconditions,
    postconditions,
  ].filter((text) => text.includes("\uFFFD")).length,
  createOrReplaceFunctions: count(
    p0,
    /^CREATE OR REPLACE FUNCTION /gm,
  ),
  functionStatementTerminators: count(p0, /^\$function\$;$/gm),
  securityDefiners: count(p0, /^SECURITY DEFINER$/gm),
  emptySearchPaths: count(p0, /^SET search_path TO ''$/gm),
  alteredPolicies: count(p0, /^ALTER POLICY /gm),
  topLevelForbiddenDdlOrDml: count(
    strippedFunctionBodies,
    /^\s*(?:CREATE TABLE|ALTER TABLE|DROP|INSERT|UPDATE|DELETE|TRUNCATE)\b/gim,
  ),
  completeSaleAuthBeforeIdempotency:
    completeSaleBody.indexOf("v_user_id := auth.uid()") >= 0 &&
    completeSaleBody.indexOf("v_user_id := auth.uid()") <
      completeSaleBody.indexOf("IF p_idempotency_key IS NOT NULL"),
  completeSaleTenantScopedIdempotency: completeSaleBody.includes(
    "s.isletme_id = v_isletme_id",
  ),
  completeSaleFiltersDeletedProducts:
    count(completeSaleBody, /deleted_at IS NULL/g) >= 5,
  productMutationAuthBeforeIdempotency:
    productMutationBody.indexOf("v_user_id := auth.uid()") >= 0 &&
    productMutationBody.indexOf("v_user_id := auth.uid()") <
      productMutationBody.indexOf(
        "INSERT INTO public.mutation_idempotency",
      ),
  productMutationAdminCheck: productMutationBody.includes(
    "v_user_role IS DISTINCT FROM 'admin'",
  ),
  financialWriteRevoke: p0.includes(
    "ON TABLE public.sales, public.sale_items",
  ),
  idempotencyTableRevoke: p0.includes(
    "ON TABLE public.mutation_idempotency",
  ),
  testIsTransactional:
    /^BEGIN;$/m.test(testSql) &&
    /^ROLLBACK;$/m.test(testSql) &&
    testSql.includes("P0_AUTHORIZATION_TEST_PASS"),
  preconditionsReadOnly: /^\s*--[\s\S]*?WITH\b/m.test(preconditions),
  postconditionsReadOnly: /^\s*--[\s\S]*?WITH\b/m.test(postconditions),
};

const expected = {
  replacementCharacterFiles: 0,
  createOrReplaceFunctions: 2,
  functionStatementTerminators: 2,
  securityDefiners: 2,
  emptySearchPaths: 2,
  alteredPolicies: 11,
  topLevelForbiddenDdlOrDml: 0,
  completeSaleAuthBeforeIdempotency: true,
  completeSaleTenantScopedIdempotency: true,
  completeSaleFiltersDeletedProducts: true,
  productMutationAuthBeforeIdempotency: true,
  productMutationAdminCheck: true,
  financialWriteRevoke: true,
  idempotencyTableRevoke: true,
  testIsTransactional: true,
  preconditionsReadOnly: true,
  postconditionsReadOnly: true,
};

const failures = Object.entries(expected)
  .filter(([name, value]) => checks[name] !== value)
  .map(([name, value]) => ({ name, expected: value, actual: checks[name] }));

for (const [file, result] of Object.entries(checkpointResults)) {
  if (!result.matches) {
    failures.push({
      name: `checkpointHash:${file}`,
      expected: result.expected,
      actual: result.actual,
    });
  }
}

const result = {
  status: failures.length === 0 ? "PASS" : "FAIL",
  checks,
  expected,
  checkpointMigrations: checkpointResults,
  fileSha256: {
    p0Migration: sha256(p0),
    authorizationTest: sha256(testSql),
    preconditions: sha256(preconditions),
    postconditions: sha256(postconditions),
  },
  failures,
};

console.log(JSON.stringify(result, null, 2));
process.exitCode = failures.length === 0 ? 0 : 1;
