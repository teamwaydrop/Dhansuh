# Waydrop staging security deployment — pending target

User authorization: apply and test security fixes on STAGING / TEST ONLY. Production deployment is not authorized.

## Discovery and current state

The connected Supabase project inventory returned only waydrop, reference yvwpchffctiagevpqgwy, PostgreSQL 17, ACTIVE_HEALTHY. This is the previously identified production project and is excluded from all migration and mutating test calls. Its development-branch inventory returned an empty list. These were management-metadata reads only; no database SQL, migrations, function deployments, orders or financial operations were sent to that project.

No staging reference, test credentials or provider sandbox configuration has been identified. Staging application, API authorization tests and live business-flow regressions cannot begin until that environment is supplied or provisioned. Staging authorization is already granted; the pending question concerns the target, not permission to repeat the approved work.

Prepared security changes remain exactly in ../proposals/waydrop_security_review.sql and ../proposals/waydrop_promo_ownership_review.sql. They end in ROLLBACK and are outside automatic migrations. They have NOT been applied to a connected Supabase staging environment. The local checks do not substitute for that application.

## Before the staging apply

1. Resolve the user-supplied staging reference with Supabase management metadata. Reject yvwpchffctiagevpqgwy and any URL resolving to production. Record the staging name, reference, API URL, parent/branch if applicable and engine version. Every subsequent tool call must specify that exact staging reference. Do not merge/rebase a branch to production or run a linked default push.
2. Inspect staging logs, security/performance advisories, affected schemas, RLS and exact routine overloads. Run waydrop_security_preflight.sql there and privately save the complete result before any DDL. This captures 14 routine definitions/settings/grants, both sensitive views, all three protected tables, their policies and triggers. It contains implementation details and belongs in an ignored private backup directory, not a public artifact.
3. Stop on any missing object, different ownership/overload, existing same-name guard, unexpected grantor or schema drift. Compare the captured function bodies to the proposal assumptions; adapt only after reviewing the real staging definition. Confirm the existing UPDATE role/developer guard remains active.
4. Confirm staging uses test-only identities, outbound recipients and provider sandbox credentials. Disable or isolate outbound production integrations before fixture creation or dispatch/payment tests. Do not copy production service secrets or real user data into test fixtures.
5. Compile the reviewed changes into a single staging-only transaction from the two rollback-default proposals. Save its exact SQL/hash and the pre-change rollback package. Keep it outside supabase/migrations to avoid automatic production deployment. Apply with the explicit verified staging project reference; set bounded lock/statement timeouts. One transaction must encompass triggers, grants, fixed paths and promo ownership so a failure rolls the entire change back.

## Exact rollback procedure

A complete executable rollback must be generated from the target staging snapshot, not the old production catalog. Until that snapshot exists, an exact ACL/body rollback is unavailable; guessing would be unsafe.

- If the staging transaction fails before commit: roll back that transaction; no partial DDL should remain.
- If post-commit regressions require rollback: pause the staging test traffic, reconfirm the same staging reference, verify that affected definitions have no unrelated concurrent changes, and run one bounded transaction.
- Drop only the three newly introduced triggers guard_client_user_security_fields on public.users, guard_client_kyc_decisions on public.rider_kyc, and guard_client_payout_activation on public.rider_payout_accounts. Drop their newly introduced trigger functions afterward. Preflight must have confirmed these did not previously exist; never remove an older guard to make a deployment succeed.
- Restore validate_and_calculate_promo(character varying,numeric,uuid) from its exact pre-apply pg_get_functiondef result. Restore the seven altered search_path settings to their original per-function state (including absence of a setting); preserve other settings, signatures, ownership and function bodies. Definitions in the snapshot permit a reviewed exact reconstruction if necessary.
- For each of the seven internal RPC overloads, restore only the changed EXECUTE ACL entries for PUBLIC, anon, authenticated and service_role from the captured explicit grants, including grant options and grantor semantics. For the promo function, restore its changed EXECUTE entries too. For the two sensitive views restore only the changed SELECT ACL entries. Do not blindly grant broad SELECT/EXECUTE or rely on has_function_privilege alone, because inherited PUBLIC privileges differ from explicit ACL entries.
- Retain every pre-existing policy, role/financial guard and trigger. No payment, ledger, KYC or user data is rewritten by the security migration, so a schema rollback must not restore or rewind unrelated database data.
- Commit only after the catalog matches the captured state for all changed fields. Run the existing positive-flow smoke tests and record the rollback result. Restoring vulnerable baseline permissions is for isolated staging recovery only; it is not a production remediation.

## Required staging tests

Replay all local negative authorization scenarios through real anon/account A/account B/staff/server JWTs. Verify denial AND unchanged rows for forged profile roles, self-approved/activated KYC, fabricated active payouts, other-user promo IDs, sensitive views and privileged direct RPCs. Verify ordinary own-profile creation/edit, pending KYC resubmission, existing authorized staff review, server approval/activation/payout and same-user/server promo pricing.

Run rider login and refresh/logout; all KYC/payout/service-mode entry states; two-account passenger/rider create/offer/accept/complete/cancel; rematch and expiry through actual cron/trigger callers; GPS/realtime tracking and notification isolation. Payments/payouts require provider sandbox success/failure/pending/retry/duplicate signed webhook/concurrent withdrawal checks and exact ledger/fee/earnings comparisons. The seven internal RPC bodies must be real on staging, not the ACL fixture bodies used locally. See ../WAYDROP_DEVICE_AND_STAGING_VERIFICATION.md for the detailed workflow matrix and Android procedures. Any unavailable scenario remains explicitly unverified.

## Production deployment plan — provisional, not authorized

Only after staging passes: publish the exact staging-applied SQL and rollback hashes, target catalog diff, API negative tests, business-flow results, provider ledger evidence and outstanding limitations. Compare current production definitions read-only to the approved staging baseline and report drift. Prepare one narrowly scoped transactional migration, a production-specific pre-change backup/rollback and post-deploy authorization/positive smoke tests. Define the operator, window, timeouts, stop conditions and monitoring for permissions, failed KYC/payment/withdrawal jobs, dispatch and notifications.

Present that final evidence and deployment plan to the user and WAIT for separate explicit production approval. Do not merge staging, deploy a production migration, change production grants/triggers, or run production mutation tests under the present authorization.
