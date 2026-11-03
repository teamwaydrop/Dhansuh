-- REVIEW / REHEARSAL ONLY. HOLD. Bounded ordinary DDL requires a PG17 lock/restore drill.
BEGIN;
SET LOCAL lock_timeout='1s';
SET LOCAL statement_timeout='10s';
DO $guard$
BEGIN
 IF pg_get_indexdef('public.idx_riders_kyc_id'::regclass) IS DISTINCT FROM 'CREATE INDEX idx_riders_kyc_id ON public.riders USING btree (kyc_id)' OR pg_get_indexdef('public.riders_kyc_id_key'::regclass) IS DISTINCT FROM 'CREATE UNIQUE INDEX riders_kyc_id_key ON public.riders USING btree (kyc_id)' THEN RAISE EXCEPTION 'Index DDL drift'; END IF;
 IF NOT EXISTS (SELECT 1 FROM pg_index t JOIN pg_index k ON k.indexrelid='public.riders_kyc_id_key'::regclass WHERE t.indexrelid='public.idx_riders_kyc_id'::regclass AND t.indrelid=k.indrelid AND t.indkey=k.indkey AND t.indclass=k.indclass AND t.indcollation=k.indcollation AND t.indoption=k.indoption AND t.indnkeyatts=k.indnkeyatts AND t.indnatts=k.indnatts AND t.indexprs IS NULL AND k.indexprs IS NULL AND t.indpred IS NULL AND k.indpred IS NULL AND t.indisvalid AND t.indisready AND t.indislive AND NOT t.indisunique AND NOT t.indisreplident AND k.indisunique AND k.indisvalid AND k.indisready AND k.indislive) THEN RAISE EXCEPTION 'Equivalent live unique index unavailable'; END IF;
 IF EXISTS (SELECT 1 FROM pg_depend WHERE refclassid='pg_class'::regclass AND refobjid='public.idx_riders_kyc_id'::regclass) OR EXISTS (SELECT 1 FROM pg_constraint WHERE conindid='public.idx_riders_kyc_id'::regclass) OR EXISTS (SELECT 1 FROM pg_inherits WHERE inhrelid='public.idx_riders_kyc_id'::regclass OR inhparent='public.idx_riders_kyc_id'::regclass) OR EXISTS (SELECT 1 FROM pg_depend WHERE classid='pg_class'::regclass AND objid='public.idx_riders_kyc_id'::regclass AND deptype='e') THEN RAISE EXCEPTION 'Index dependency detected'; END IF;
END $guard$;
DROP INDEX public.idx_riders_kyc_id;
ROLLBACK;
