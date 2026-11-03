# Preserved local migration proposals

These SQL files are review material. They are outside `supabase/migrations` and must not be automatically applied.

The 2026-11-03 reconciliation preserves 19 original files, with exact original-byte hashes in `supabase/migration_manifest.json`:

- `superseded-local-history/`: 14 local files whose version/name or SQL differed from recorded production history.
- `retired-timestamp-aliases/`: three local timestamps corresponding to migrations already recorded under other production versions. Do not reapply aliases.
- `not-applied/`: two proposals absent from production history: legacy rider-matching overload removal and the dispatch fencing/delivery-outbox candidate.

The dispatch/push candidate remains blocked on coordinated SQL/Edge compatibility, managed integration, resumed-worker fencing, provider/crash behavior, and drain/rollback validation. Moving it here preserves the implementation; it does not resolve or deploy that protocol. The legacy overload removal also requires call-site compatibility review.

Tests referencing archived proposals validate their source contracts only. They do not establish that those constraints or protocols are live in production. Production history is represented by the canonical files under `supabase/migrations`.
