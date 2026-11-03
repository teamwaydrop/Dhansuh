-- REVIEW / REHEARSAL ONLY. HOLD. Bounded ordinary DDL requires a PG17 lock/restore drill.
BEGIN;
SET LOCAL lock_timeout='1s';
SET LOCAL statement_timeout='10s';
-- CREATE intentionally fails if the name already exists; inspect drift instead of IF NOT EXISTS.
CREATE INDEX idx_riders_kyc_id ON public.riders USING btree (kyc_id);
ROLLBACK;
