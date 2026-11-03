-- LOCAL REVIEW PROPOSAL ONLY. NOT EXECUTED. Outside automatic migrations.
-- Requires approved staging differential tests and separate deployment approval.
BEGIN;
SET LOCAL lock_timeout = '3s';
SET LOCAL statement_timeout = '15s';
-- Candidate only: keep ONLY if representative staging plans improve.
-- Original proximity query remains unchanged, including stationary heartbeats.
CREATE INDEX idx_orders_unnotified_ongoing_rider
ON public.orders (rider_id)
WHERE order_status = 'ongoing' AND near_destination_notified = false;

-- No coordinate-change trigger gate: stationary transition checks are preserved.
ROLLBACK;
