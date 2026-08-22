import { resolve } from "node:path";

import {
  hashNormalizedText,
  readNormalizedUtf8,
} from "./offline_verifier_utils.mjs";

const root = resolve(import.meta.dirname, "../../../..");
const migrationsDir = resolve(root, "supabase/migrations");
const migrationArchiveDir = resolve(root, "supabase/migration_archive");
const canonicalDir = resolve(root, "supabase/schema/canonical/2026-08-21");

const sha256 = (text) => hashNormalizedText("sha256", text);
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

const baseline = readNormalizedUtf8(baselinePath);
const p0 = readNormalizedUtf8(p0Path);
const testSql = readNormalizedUtf8(testPath);
const preconditions = readNormalizedUtf8(preconditionsPath);
const postconditions = readNormalizedUtf8(postconditionsPath);

// Frozen hashes use UTF-8 text after deterministic CRLF/CR -> LF normalization.
const checkpointHashes = {
  "20260821090000_canonical_live_baseline.sql":
    "5d629f32110ffa2c634df3a9b637e3f7fa842188ca3a7e4f8df07cc498ea04dc",
  "001_kullanicilar_rls.sql":
    "cd871d83fb7a5f2c65aa208ebfb666d662ee959050d788763f11e50ac21b4be3",
  "002_tenant_rls_policies.sql":
    "6054a072b3ec260efe68b4a86db53f5126980081ef85dfb8bc74a2ca920088da",
  "003_complete_sale_rpc.sql":
    "17d0ee8e5751f9713d133e2999b22b3d17e43500618e10b635796bac4b8a9cee",
  "004_indexes_and_constraints.sql":
    "2aa7bfa10cabe0f582734fcbd3011b48db2cedea6134becffb28e3d2fa792683",
  "005_idempotency_key.sql":
    "1633de653b895d0dd5c461fb0a833755ff06905241b4ebda986301c618363f61",
  "006_secure_complete_sale_cleanup.sql":
    "f3b0fbc0839ca3a7253484cb57e3c3dc578ec9fafe3e1cf4e33fdf6c7a694388",
  "007_products_updated_at_trigger.sql":
    "cce780e54deb060efe6fb0a6e4d072a6a10ed52490afa21f6059a59a8fdf8042",
  "008_products_soft_delete.sql":
    "02baf85ef8362cc06f6ea453eda3f4f0e325e2ab5ed521462bef1e64caf690ff",
  "009_products_unique_barcode.sql":
    "2c29a7d7ea84d27f9eb7f54d45c20668259603ea7384c8663f2a38dee82eefc4",
  "010_product_mutations_rpc.sql":
    "4c83baf3b99e8164c8e184e814aacc47f8e46a864662b53a1fa55d5e927958b2",
};

const checkpointResults = Object.fromEntries(
  Object.entries(checkpointHashes).map(([file, expected]) => {
    const directory = file.startsWith("202608")
      ? migrationsDir
      : migrationArchiveDir;
    const actual = sha256(readNormalizedUtf8(resolve(directory, file)));
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
