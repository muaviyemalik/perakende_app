# P0 authorization emergency compensation runbook

This is an incident-only escape hatch for a critical application regression
after `20260821100000_p0_authorization_hardening.sql` has been applied.

The compensation file is deliberately stored under
`supabase/emergency_migrations/`, outside `supabase/migrations/`. Therefore a
normal `supabase db push` cannot discover or apply it accidentally.

## Security warning

Applying the compensation deliberately restores the weaker canonical-baseline
authorization surface: cashier product writes, authenticated direct financial
writes, direct idempotency-table access, public/anonymous product-mutation RPC
execution grants, and broad trigger-function execution grants return. It also
restores the old `complete_sale` idempotency-before-auth ordering and permits
soft-deleted products in that RPC. This is temporary risk acceptance, not a
normal rollback mechanism.

## Activation preconditions

1. Declare a production incident and record an accountable approver.
2. Confirm the P0 migration is present in migration history and its
   postconditions currently pass.
3. Confirm a fresh recoverable backup/PITR point and test its restore path.
4. Reproduce the critical regression and prove compensation fixes it on a
   production-like scratch clone.
5. Pause client writes or enter a maintenance window.
6. Copy only
   `20260822120000_emergency_rollback_p0_authorization.sql` into
   `supabase/migrations/` in a dedicated incident branch. Review its SHA-256.
7. Require `supabase db push --linked --dry-run` to propose exactly that one
   timestamp and nothing else.

Do not use `migration repair`, delete history rows, or mark P0 reverted. The P0
row remains applied; the compensation receives its own later history row.

## Scratch verification

Apply canonical baseline, P0, then compensation. Run, in order:

- `verify_p0_emergency_rollback.sql` (every row must be `passed=true`)
- `supabase/tests/database/02_p0_emergency_rollback.test.sql`
- `verify_live_schema.sql` and `verify_schema_semantics.sql`

The authorization semantics must match the canonical baseline. Any mismatch is
a stop condition.

## Production procedure (not authorized by this runbook alone)

1. Reconfirm backup/PITR and maintenance window.
2. Reconfirm production project ref and current migration list.
3. Run P0 postcondition verifier read-only.
4. Run dry-run; require only `20260822120000` pending.
5. Obtain explicit production-write approval.
6. Apply the single compensation migration.
7. Verify the new history row, run the rollback verifier, and perform tenant,
   admin, cashier, sale, offline-queue, and account-switch smoke tests.
8. Monitor authorization/audit logs and end the incident window.

If migration execution fails, its transaction rolls back atomically. If it
succeeds but application health remains unacceptable, restore via the verified
database recovery path or deploy a new forward-only corrective migration; do
not edit migration history.
