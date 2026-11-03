-- LOCAL REVIEW PROPOSAL ONLY. NOT EXECUTED. Outside automatic migrations.
-- Requires approved staging differential tests and separate deployment approval.
BEGIN;
SET LOCAL lock_timeout = '3s';
SET LOCAL statement_timeout = '15s';
-- Optional proximity index is deliberately separate: 02b_proximity_index_candidate.sql.
-- Optional measured cleanup: unique indexes retain the same lookup keys.
-- Do not remove coordinate/freshness indexes: all three have recorded scans.
DO $index_guard$
BEGIN
  IF pg_get_indexdef('public.riders_user_id_key'::regclass) IS DISTINCT FROM 'CREATE UNIQUE INDEX riders_user_id_key ON public.riders USING btree (user_id)' THEN
    RAISE EXCEPTION 'Index definition drift: riders_user_id_key';
  END IF;
  IF pg_get_indexdef('public.riders_kyc_id_key'::regclass) IS DISTINCT FROM 'CREATE UNIQUE INDEX riders_kyc_id_key ON public.riders USING btree (kyc_id)' THEN
    RAISE EXCEPTION 'Index definition drift: riders_kyc_id_key';
  END IF;
  IF pg_get_indexdef('public.idx_riders_user_id'::regclass) IS DISTINCT FROM 'CREATE INDEX idx_riders_user_id ON public.riders USING btree (user_id)' THEN
    RAISE EXCEPTION 'Index definition drift: idx_riders_user_id';
  END IF;
  IF pg_get_indexdef('public.idx_riders_kyc_id'::regclass) IS DISTINCT FROM 'CREATE INDEX idx_riders_kyc_id ON public.riders USING btree (kyc_id)' THEN
    RAISE EXCEPTION 'Index definition drift: idx_riders_kyc_id';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_index WHERE indexrelid = 'public.riders_user_id_key'::regclass AND indisunique AND indisvalid)
     OR NOT EXISTS (SELECT 1 FROM pg_index WHERE indexrelid = 'public.riders_kyc_id_key'::regclass AND indisunique AND indisvalid)
     OR EXISTS (SELECT 1 FROM pg_constraint WHERE conindid IN ('public.idx_riders_user_id'::regclass, 'public.idx_riders_kyc_id'::regclass)) THEN
    RAISE EXCEPTION 'Required equivalent unique indexes missing or cleanup targets constraint-backed';
  END IF;
END
$index_guard$;
DROP INDEX public.idx_riders_user_id;
DROP INDEX public.idx_riders_kyc_id;
-- For approved production deployment, separately review CONCURRENTLY variants
-- outside a transaction and attach a target-specific rollback. Never run this file there.
ROLLBACK;
