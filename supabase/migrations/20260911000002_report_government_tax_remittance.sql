-- =============================================================================
-- MONTH-END GOVERNMENT-TAX REMITTANCE REPORT  (READ-ONLY wrapper)
--
-- public.report_government_tax_remittance(p_year int, p_month int) -> jsonb
--
-- Answers, for one statutory/reporting month:
--   "how much government tax was CREATED, how much was WITHHELD/COLLECTED,
--    how much has been PAID, and what is the AMOUNT PAYABLE to government?"
--
-- READ-ONLY. It only SELECTs public.government_tax_ledger (+ joins orders /
-- payments for refund flagging). It does NOT touch:
--   * tax_rate_config
--   * apply_order_government_tax()
--   * complete_order_and_settle()
--   * any tax calculation, trigger, or write path
-- It is self-contained (it re-derives the aggregation rather than calling the
-- existing report_government_tax_month(), whose is_admin()-only gate cannot be
-- satisfied from the Supabase SQL console -- which carries no JWT).
--
-- DEFINITION (mechanically unambiguous from the ledger):
--   amount_payable_to_government_gross = SUM(ORDER_TAX) + SUM(ADJUSTMENT)
--     = the gross government tax on the supplies COMPLETED in the month.
--   ORDER_TAX_WITHHELD and TAX_PAYMENT are COLLECTION mechanics (how WayDrop
--   recovers the cash from the Drop Partner / withholds it) -- they do NOT
--   reduce the statutory liability and are reported separately as
--   collected_via_cashfree_withholding / collected_from_riders.
--
-- REQUIRES CA / GST CONFIRMATION (flagged in the `caveats` output):
--   * whether refunded-after-tax orders reduce the remittance, and in which
--     return period (credit-note treatment);
--   * Section 9(5) applicability, category mapping, ITC treatment;
--   * the statutory return period / time-of-supply basis (this report windows on
--     ledger.created_at = order completion time, IST).
--
-- IDEMPOTENT: CREATE OR REPLACE + guarded GRANT/REVOKE.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.report_government_tax_remittance(
    p_year  integer,
    p_month integer
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_jwt_uid  uuid := (SELECT auth.uid());
    v_jwt_role text := COALESCE((SELECT auth.role()), '');
    v_from     timestamptz;
    v_to       timestamptz;
    v_result   jsonb;
BEGIN
    -- authorization: admin JWT, service_role, or the Supabase SQL console (no JWT)
    IF NOT (
        public.is_admin()
        OR v_jwt_role = 'service_role'
        OR (v_jwt_uid IS NULL AND v_jwt_role <> 'anon')
    ) THEN
        RAISE EXCEPTION 'report_government_tax_remittance: authorized admin / service_role / SQL console only'
            USING ERRCODE = 'insufficient_privilege';
    END IF;

    IF p_month < 1 OR p_month > 12 OR p_year < 2024 OR p_year > 2100 THEN
        RAISE EXCEPTION 'Invalid year/month' USING ERRCODE = 'check_violation';
    END IF;

    v_from := (make_timestamp(p_year, p_month, 1, 0, 0, 0) AT TIME ZONE 'Asia/Kolkata');
    v_to   := v_from + interval '1 month';

    WITH ledger AS (
        SELECT g.entry_type, g.service_category, g.taxable_base, g.rate_percent, g.amount,
               g.order_id, g.payment_id,
               o.order_status::text        AS order_status,
               o.order_type::text          AS order_type,
               o.fare_payment_method::text AS fare_payment_method,
               o.payment_status::text      AS order_payment_status,
               o.order_code                AS order_code,
               p.refunded_at               AS payment_refunded_at
        FROM public.government_tax_ledger g
        LEFT JOIN public.orders   o ON o.id = g.order_id
        LEFT JOIN public.payments p ON p.id = o.payment_id
        WHERE g.created_at >= v_from AND g.created_at < v_to
    ),
    order_tax AS (SELECT * FROM ledger WHERE entry_type = 'ORDER_TAX'),
    refunded  AS (
        SELECT * FROM order_tax
        WHERE order_payment_status IN ('refunded','partial_refund')
           OR payment_refunded_at IS NOT NULL
    ),
    agg AS (
        SELECT
            COALESCE((SELECT sum(amount) FROM order_tax), 0)                                   AS gst_created_total,
            COALESCE((SELECT sum(amount) FROM ledger WHERE entry_type = 'ADJUSTMENT'), 0)      AS adjustments_total,
            COALESCE(-(SELECT sum(amount) FROM ledger WHERE entry_type = 'ORDER_TAX_WITHHELD'), 0) AS collected_via_cashfree_withholding,
            COALESCE(-(SELECT sum(amount) FROM ledger WHERE entry_type = 'TAX_PAYMENT'), 0)    AS collected_from_riders,
            COALESCE((SELECT sum(taxable_base) FROM order_tax), 0)                             AS taxable_base_total,
            (SELECT count(DISTINCT order_id) FROM order_tax)                                   AS taxable_orders,
            (SELECT count(*) FROM ledger)                                                      AS ledger_rows_in_window,
            COALESCE((SELECT sum(amount) FROM refunded), 0)                                    AS refunded_after_tax_gst,
            (SELECT count(DISTINCT order_id) FROM refunded)                                    AS refunded_after_tax_count
    )
    SELECT jsonb_build_object(
        'period', jsonb_build_object(
            'year', p_year, 'month', p_month, 'timezone', 'Asia/Kolkata',
            'from', v_from, 'to', v_to,
            'basis', 'government_tax_ledger.created_at (= order completion time)'),

        'taxable_orders',                    a.taxable_orders,
        'taxable_base_total',                a.taxable_base_total,
        'ledger_rows_in_window',             a.ledger_rows_in_window,

        'gst_created_total',                 a.gst_created_total,
        'adjustments_total',                 a.adjustments_total,
        'amount_payable_to_government_gross', a.gst_created_total + a.adjustments_total,

        'collected_via_cashfree_withholding', a.collected_via_cashfree_withholding,
        'collected_from_riders',              a.collected_from_riders,
        'outstanding_from_riders',
            a.gst_created_total - a.collected_via_cashfree_withholding - a.collected_from_riders,

        'refunded_after_tax_gst',             a.refunded_after_tax_gst,
        'refunded_after_tax_count',           a.refunded_after_tax_count,
        'refunded_after_tax_order_codes', COALESCE(
            (SELECT jsonb_agg(DISTINCT r.order_code) FROM refunded r WHERE r.order_code IS NOT NULL), '[]'::jsonb),
        'amount_payable_to_government_net_of_refunds',
            (a.gst_created_total + a.adjustments_total) - a.refunded_after_tax_gst,

        'by_category', COALESCE((
            SELECT jsonb_agg(to_jsonb(t))
            FROM (
                SELECT COALESCE(ot.service_category,'unclassified') AS service_category,
                       count(DISTINCT ot.order_id)                  AS orders,
                       COALESCE(sum(ot.taxable_base),0)             AS taxable_base,
                       COALESCE(sum(ot.amount),0)                   AS gst_created,
                       COALESCE(-(SELECT sum(w.amount) FROM ledger w
                                  WHERE w.entry_type='ORDER_TAX_WITHHELD'
                                    AND COALESCE(w.service_category,'unclassified')=COALESCE(ot.service_category,'unclassified')),0)
                                                                   AS withheld_via_cashfree
                FROM order_tax ot GROUP BY ot.service_category ORDER BY ot.service_category
            ) t), '[]'::jsonb),

        'by_payment_method', COALESCE((
            SELECT jsonb_agg(to_jsonb(t))
            FROM (
                SELECT COALESCE(ot.fare_payment_method,'unknown') AS fare_payment_method,
                       count(DISTINCT ot.order_id)                AS orders,
                       COALESCE(sum(ot.amount),0)                 AS gst_created
                FROM order_tax ot GROUP BY ot.fare_payment_method ORDER BY ot.fare_payment_method
            ) t), '[]'::jsonb),

        'reconciliation', jsonb_build_object(
            'order_status_of_taxed_rows', COALESCE((
                SELECT jsonb_agg(to_jsonb(t))
                FROM (SELECT COALESCE(ot.order_status,'order_row_missing') AS order_status,
                             count(*) AS rows, COALESCE(sum(ot.amount),0) AS gst
                      FROM order_tax ot GROUP BY ot.order_status ORDER BY ot.order_status) t), '[]'::jsonb),
            'note', 'ORDER_TAX rows should belong only to completed/delivered orders; anything else is an anomaly.'),

        'definitions', jsonb_build_object(
            'amount_payable_to_government_gross', 'SUM(ORDER_TAX) + SUM(ADJUSTMENT) in the window = gross government tax on supplies completed this month.',
            'collected_via_cashfree_withholding', 'ABS(SUM(ORDER_TAX_WITHHELD)) = tax withheld from Drop Partner earnings on Cashfree-collected fares (already held by WayDrop).',
            'collected_from_riders', 'ABS(SUM(TAX_PAYMENT)) = payments made by Drop Partners against their government_tax_due_balance in the window (may relate to earlier months'' liability).',
            'outstanding_from_riders', 'gross created MINUS withheld MINUS rider payments -- informational receivable, NOT a reduction of the government payable.',
            'amount_payable_to_government_net_of_refunds', 'gross MINUS refunded_after_tax_gst -- provided for finance; whether refunds reduce the remittance requires CA/GST confirmation.'),

        'caveats', jsonb_build_array(
            'REQUIRES CA/GST CONFIRMATION: whether refunded-after-tax orders reduce the remittance and in which return period (credit-note treatment). Use amount_payable_to_government_net_of_refunds only if a CA confirms it.',
            'REQUIRES CA/GST CONFIRMATION: Section 9(5) applicability to WayDrop''s model, the service-category -> rate mapping (currently local_passenger_ride 5%, intercity_passenger_ride 5%, parcel_delivery 18% from tax_rate_config), and ITC treatment. The code labels this "Section 9(5)" in migration comments only; there is no formal legal-basis document.',
            'REQUIRES CA/GST CONFIRMATION: the statutory return period and time-of-supply basis. This report windows on government_tax_ledger.created_at (order completion time, IST).',
            'ORDER_TAX_WITHHELD and TAX_PAYMENT are collection mechanics and are NOT netted into amount_payable_to_government_gross.',
            'Cancelled orders never create an ORDER_TAX row (auto-excluded). Unpaid completed orders still create the liability and are included.'
        )
    )
    INTO v_result
    FROM agg a;

    RETURN v_result;
END;
$function$;

REVOKE ALL ON FUNCTION public.report_government_tax_remittance(integer, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.report_government_tax_remittance(integer, integer) TO authenticated, service_role;

-- =============================================================================
-- ROLLBACK (manual):
--   DROP FUNCTION IF EXISTS public.report_government_tax_remittance(integer, integer);
-- (No schema/data/tax-engine change to undo -- read-only.)
-- =============================================================================
