# Migration history and Git readiness

Reconciled on 2026-11-03 against the 291 recorded migrations in production project `yvwpchffctiagevpqgwy`. All active filenames and PostgreSQL syntax trees match those recorded statements. This comparison does not prove fresh database replay or detect unrecorded manual schema changes.

`migrations/` contains recorded, already-applied history only. Missing history was recovered from the production migration ledger through read-only inspection. No production migration, history repair, or schema change was performed during this reconciliation.

Local alternatives and unapplied proposals are preserved under [docs/migration-review](../docs/migration-review/README.md), outside the directory consumed by migration deployment. Do not move them back without the coordinated protocol review and validation described there.

Before committing:

```powershell
python tools/verify_migrations.py
python -m unittest discover -s tools -p test_verify_migrations.py -v
# Optional PostgreSQL parser validation:
python -m pip install -r tools/requirements-migration-check.txt
python tools/verify_migrations.py --syntax
git status --short
git diff --stat
```

Run these commands from the repository root. Review the existing unrelated work before selecting files for your commit. Git push publishes repository history; it does not apply SQL to Supabase. No blanket `supabase db push`, `migration repair`, or database reset is needed for this reconciliation.

`migration_manifest.json` records normalized hashes for active history and original-byte hashes for archived proposals. Future intentional migrations require a reviewed manifest update; the guard deliberately rejects new pending files until that review.

See [the reconciliation report](../docs/performance/WAYDROP_MIGRATION_GIT_READY.md) for evidence and limits.
