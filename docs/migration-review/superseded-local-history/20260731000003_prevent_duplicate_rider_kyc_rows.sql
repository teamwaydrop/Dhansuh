-- =============================================================================
-- Prevent duplicate rider_kyc rows per user
-- =============================================================================
-- rider_kyc previously had no uniqueness guarantee on user_id (only a PK on
-- id). create-rider-kyc's "does a row already exist" check and its
-- insert/update are two separate round-trips (SELECT then INSERT), so two
-- concurrent create-rider-kyc invocations for the same user_id (e.g. a
-- client retry fired while the original request was still being processed
-- server-side, which is exactly what happens once the client submit flow is
-- allowed to time out and retry) could both see "no existing row" and both
-- insert, producing two rider_kyc rows for one rider. This adds the missing
-- database-level guarantee so that scenario fails safely instead of
-- corrupting data.
--
-- Any pre-existing duplicates are collapsed first (keeping the most recent
-- row per user_id) so the unique index can be created.

DELETE FROM "public"."rider_kyc" a
USING "public"."rider_kyc" b
WHERE a.user_id = b.user_id
  AND a.created_at < b.created_at
  AND NOT EXISTS (
    SELECT 1 FROM "public"."riders" r WHERE r.kyc_id = a.id
  );

CREATE UNIQUE INDEX IF NOT EXISTS "rider_kyc_user_id_unique_idx"
  ON "public"."rider_kyc" USING "btree" ("user_id");
