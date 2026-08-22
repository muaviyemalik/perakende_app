# Forensic migration archive

This directory is intentionally outside `supabase/migrations` so the CLI will not replay its contents.

The legacy local numeric migrations `001–010` are stored here without content changes. Their frozen SHA-256 hashes remain enforced by the baseline and P0 offline verifiers. Keep the eight remote migration statements in `../schema/canonical/2026-08-21/remote_history_snapshot.json`.

The eight comment-only local anchors for version numbers already recorded on production are active in `supabase/migrations`. They prevent the CLI from treating valid production history rows as remote-only while keeping clean bootstrap behavior canonical: eight no-op anchors, then the canonical baseline, then forward migrations.

No historical SQL was edited or deleted; only repository paths changed.
