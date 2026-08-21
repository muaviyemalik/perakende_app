# Forensic migration archive

This directory is intentionally outside `supabase/migrations` so the CLI will not replay its contents.

When the approved history-only reconciliation starts, move the existing local numeric migrations `001–010` here without editing their contents. Keep the eight remote migration statements in `../schema/canonical/2026-08-21/remote_history_snapshot.json`.

`remote_history_anchors/` contains comment-only local anchors for the eight version numbers already recorded on production. During the approved reconciliation these files move into `supabase/migrations` unchanged. They prevent the CLI from treating valid production history rows as remote-only while keeping clean bootstrap behavior canonical: eight no-op anchors, then the canonical baseline, then forward migrations.

No historical SQL has been moved, changed, or deleted in this implementation stage.
