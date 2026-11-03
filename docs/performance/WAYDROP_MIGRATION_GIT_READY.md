# Migration Git reconciliation — 2026-11-03

Migration history is ready for Git review. This is not an unrestricted application/backend release approval.

## Findings and corrections

Initial inspection found 270 local migration files against 291 recorded production versions: 26 missing versions, six version/name collisions, three old timestamp aliases, and two unapplied proposals in the automatic migration directory. Cumulative counts alone did not establish which SQL was live; the production migration ledger supplied the recorded statements.

Reconciliation leaves 291 unique active versions with exact production names. All 291 parsed SQL syntax trees match the production ledger after excluding parser source-position fields. Eight same-name local SQL differences were also replaced with recorded source. Fourteen divergent originals, three timestamp aliases, and two unapplied proposals remain preserved byte-for-byte outside the deployment folder. Twenty-four semantically equivalent originals were retained to avoid formatting-only rewrites.

References in six Flutter regression files and the affected performance reports/native harness now point to canonical history or explicitly preserved proposals. No application behavior or production schema was changed by this task. Existing fixes and the user's previously staged test remain intact.

## Verification

- Full Flutter suite: **2,233 passed, 10 skipped, 0 failed**. This verifies the current working tree, not a separately reconstructed staged-only checkout.
- Focused migration-reference Flutter checks: **80 passed, 0 failed**.
- Offline guard regression suite: **9 passed, 0 failed**; covers extra pending files, duplicate versions, missing history, source drift, path traversal, archive tampering, UTF-8, credentials, and CRLF checkout normalization.
- Offline integrity guard and PostgreSQL parser: **291 passed**, 19 archive hashes verified.
- Recorded-source AST comparison: **291 matched, 0 mismatched**. No fresh database replay, managed integration test, or live-schema equivalence claim.
- Scoped tracked-file `git diff --check`: passed; Git reported normal SQL CRLF-to-LF normalization notices.

Evidence is in [migration-git-20261103](migration-git-20261103/MANIFEST.json): remote version/name ledger, before-reconciliation inventory, final AST comparison, reference updates, and original-file hashes. Raw statement recovery and test logs remain in ignored `.dart_tool/waydrop-local-runtime/`.

## Git and production boundaries

The offline guard is `tools/verify_migrations.py`; instructions are in [supabase/MIGRATIONS.md](../../supabase/MIGRATIONS.md). Local release binaries and Flutter crash logs are ignored; production credentials and signing material must remain excluded. Archived originals have a binary Git attribute to preserve original bytes.

The repository already contained extensive uncommitted work. No automatic staging, commit, push, index reset, production migration, Edge deployment, or migration-history repair was performed. Review your complete diff before committing. Pushing these files to Git does not execute SQL.

Coordinated dispatch/acceptance/push/atomic-photo/Chat changes retain their previous deployment gates. The unapplied recovery/outbox proposal is excluded from automatic migration application. Do not use a blanket database push to turn these proposals on. The original database slowdown and Storage 504 initiating resource cause remain unproven.
