# Canonical baseline reconciliation runbook

## Scope and hard stop

This package was generated from the linked live project `vnvifxvtutlbivsegjtp` on 2026-08-21. The baseline is schema-only and deliberately reproduces current live behavior. It is not the P0 authorization fix.

Do not run the baseline against the existing production database. The scratch proof is green, but production `db push`, `migration repair`, and all data/schema mutations remain prohibited until a separately approved maintenance window exists.

## Scratch verification result

The isolated cloud scratch project `sostibxqqvqulmyejymv` was verified on 2026-08-21. It contained only `20260821090000_canonical_live_baseline.sql`; legacy `001–010` were not applied.

- PostgreSQL execution/syntax: PASS.
- Scratch migration history: only `20260821090000`.
- Post-apply scratch dry-run: up to date, no pending migrations.
- Object counts: exact match with production.
- Stable fingerprints: exact match for columns, constraints, indexes, policies, publications, sequences, sequence grants, table grants, and triggers.
- Semantic verification: PASS for all functions/RPCs, routine grants, schema ACLs, table ownership, and RLS state.
- Real schema drift: none found.

The three raw fingerprint differences are proven catalog/format artifacts: CRLF versus LF in three public function bodies, database-local OIDs embedded in `information_schema.specific_name`, and `private.nspacl` being default/NULL in production versus an explicit equivalent owner ACL in scratch. See `scratch_validation_2026-08-21.json` and use `verify_schema_semantics.sql` for cross-database comparison.

## Local preparation

1. Keep `001–010` unchanged until their forensic archive is reviewed.
2. Create an isolated scratch Supabase project with only `20260821090000_canonical_live_baseline.sql` in its migrations directory. Do not use the current root migrations directory while legacy files remain active.
3. Apply only the baseline, then run `verify_live_schema.sql` against both scratch and live.
4. Compare all counts and fingerprints with `object_manifest.json`. For any raw function, routine-grant, or schema-ACL difference, run `verify_schema_semantics.sql`; do not classify a raw hash difference as drift until this stable-identity comparison is complete.

## Future production history-only sequence

Run only after the scratch result is fully matching, a production backup/PITR checkpoint exists, and an approved maintenance window begins:

1. Capture current history: run `verify_migration_history.sql` and retain `remote_history_snapshot.json`.
2. Confirm live schema fingerprint still matches `object_manifest.json`.
3. Move legacy local `001–010` into the forensic archive without changing contents.
4. Move the eight comment-only files from `supabase/migration_archive/remote_history_anchors/` into `supabase/migrations/`. Their version numbers must match the eight existing production rows exactly. Do not copy historical DDL into these anchors.
5. Verify that the active migration directory now contains exactly the eight timestamp anchors, `20260821090000_canonical_live_baseline.sql`, `20260821100000_p0_authorization_hardening.sql`, and any explicitly reviewed later forward migrations.
6. Run only the approved baseline history repair below. Do not revert or delete the eight existing production history rows, and do not run the baseline SQL.

   ```powershell
   .\node_modules\.bin\supabase.cmd migration repair --linked --status applied 20260821090000
   ```

7. Verify history alignment without applying schema changes.

   ```powershell
   .\node_modules\.bin\supabase.cmd migration list --linked
   .\node_modules\.bin\supabase.cmd db push --linked --dry-run
   ```

8. Before deploying P0, the list must show the eight anchors and baseline on both LOCAL and REMOTE, with only `20260821100000` local-only. The dry run must propose exactly that one P0 migration and no legacy/baseline SQL. If anything else appears, stop and revert the baseline history marker.
9. Run `verify_live_schema.sql` and `verify_migration_history.sql` again.
10. Stop if any schema fingerprint, row count, grant count, publication membership, or dry-run result differs from the reviewed expectation.

This anchor strategy was simulated on scratch `sostibxqqvqulmyejymv`: all ten versions aligned and `db push --dry-run` returned up to date. The eight simulated anchor rows were then reverted, restoring scratch to baseline + P0 history. Supabase CLI compares migration timestamps, not SQL contents; the anchors are deliberately no-op so a fresh database reaches the canonical final schema only through the baseline.

## Rollback

If the baseline repair metadata is wrong and P0 has not been applied, do not apply migrations. Run:

```powershell
.\node_modules\.bin\supabase.cmd migration repair --linked --status reverted 20260821090000
```

Then rerun the history and schema verification. The eight original production rows remain untouched, so the full `rollback_history.sql` restore is an emergency fallback rather than the normal rollback path.
