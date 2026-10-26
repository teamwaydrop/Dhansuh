-- =============================================================================
-- SECTION 9(5) GST -- MONTH-END REPORT  (READ-ONLY, clean tabular)
--
--   public.report_section_9_5_month_end(p_year int, p_month int) -> TABLE (1 row)
--
-- A thin, operator-friendly RETURNS TABLE view of the same numbers that
-- public.report_government_tax_remittance(p_year, p_month) already returns as
-- jsonb. Built for the workflow:
--
--   Supabase Dashboard -> SQL Editor -> saved query "Section 9(5) GST - Month End"
--       SELECT * FROM public.report_section_9_5_month_end(2026, 9);
--   next month change only (2026, 10).
--
-- READ-ONLY. It only SELECTs public.government_tax_ledger (+ joins orders /
-- payments for order classification and refund flagging). It does NOT touch and
-- does NOT reference for writing:
--   * tax_rate_config
--   * apply_order_government_tax()
--   * complete_order_and_settle()
--   * government_tax_ledger write path / any tax calculation, trigger, cron
-- It is self-contained: it re-derives the aggregation from the ledger (it does
-- NOT call report_government_tax_month(), whose is_admin()-only gate cannot be
-- satisfied from the Supabase SQL console). It reproduces
-- report_government_tax_remittance()'s definitions exactly so the two agree.
--
-- ACCOUNTING MODEL (from government_tax_ledger, unchanged):
--   entry_type = 'ORDER_TAX'          -> government tax liability created on a
--                                        completed supply (Section 9(5) ECO tax)
--   entry_type = 'ADJUSTMENT'         -> direct liability adjustment (signed)
--   entry_type = 'ORDER_TAX_WITHHELD' -> collection/funding: tax withheld from
--                                        Drop Partner earnings on Cashfree-
--                                        collected fares (stored negative)
--   entry_type = 'TAX_PAYMENT'        -> collection: Drop Partner repayments
--                                        against their tax-due balance (negative)
--
--   section_9_5_gross_tax_liability      = SUM(ORDER_TAX.amount)
--   adjustments                          = SUM(ADJUSTMENT.amount)
--   amount_payable_to_government_gross   = SUM(ORDER_TAX) + SUM(ADJUSTMENT)
--   tax_withheld_via_cashfree            = ABS(SUM(ORDER_TAX_WITHHELD))   -- separate
--   tax_collected_from_riders            = ABS(SUM(TAX_PAYMENT))          -- separate
--   outstanding_rider_tax_collection     = gross - withheld - from_riders -- receivable, NOT a liability reduction
--
--   ORDER_TAX_WITHHELD and TAX_PAYMENT are collection mechanics and are NEVER
--   subtracted from the statutory GST liability.
--
-- STATUTORY FIELDS NOT DERIVABLE FROM THE DATA -> returned as NULL with a reason:
--   * IGST / CGST / SGST-UTGST / CESS: government_tax_ledger stores a single
--     combined `amount` at `rate_percent`; there is no tax-component column, and
--     orders carry only a free-text pickup_city / destination_city (no GST state
--     / place-of-supply field). The intra-state vs inter-state split, and hence
--     the CGST/SGST vs IGST allocation, must be determined by the CA from
--     WayDrop's GST registration state(s) and the place-of-supply rules. This
--     report does NOT manufacture a split from the combined total.
--
-- IDEMPOTENT: CREATE OR REPLACE + guarded GRANT/REVOKE. No schema/data change.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.report_section_9_5_month_end(
    p_year  integer,
    p_month integer
)
RETURNS TABLE (
    reporting_month                     text,
    period_start                        timestamptz,
    period_end                          timestamptz,
    report_timezone                     text,
    basis                               text,

    total_taxable_value                 numeric,
    section_9_5_gross_tax_liability      numeric,
    adjustments                         numeric,
    amount_payable_to_government_gross   numeric,

    refunded_after_tax_gst              numeric,
    refunded_after_tax_order_count      integer,
    refunded_after_tax_order_codes      jsonb,
    net_tax_liability_after_refunds     numeric,

    amount_to_remit                     numeric,
    amount_to_remit_basis               text,

    tax_withheld_via_cashfree           numeric,
    tax_collected_from_riders           numeric,
    outstanding_rider_tax_collection    numeric,

    taxable_orders                      integer,
    local_passenger_orders             integer,
    intercity_passenger_orders         integer,
    parcel_orders                      integer,

    igst                                numeric,
    cgst                                numeric,
    sgst_utgst                          numeric,
    cess                                numeric,
    tax_component_split_note            text,

    category_breakdown                  jsonb,
    payment_method_breakdown            jsonb,

    ledger_rows_in_window              integer,
    reconciliation                      jsonb,

    filing_disclaimer                   text,
    refund_credit_note_note             text,
    section_9_5_applicability_note      text,
    caveats                             jsonb
)
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
BEGIN
    -- authorization: admin JWT, service_role, or the Supabase SQL console (no JWT)
    IF NOT (
        public.is_admin()
        OR v_jwt_role = 'service_role'
        OR (v_jwt_uid IS NULL AND v_jwt_role <> 'anon')
    ) THEN
        RAISE EXCEPTION 'report_section_9_5_month_end: authorized admin / service_role / SQL console only'
            USING ERRCODE = 'insufficient_privilege';
    END IF;

    IF p_month < 1 OR p_month > 12 OR p_year < 2024 OR p_year > 2100 THEN
        RAISE EXCEPTION 'Invalid year/month' USING ERRCODE = 'check_violation';
    END IF;

    v_from := (make_timestamp(p_year, p_month, 1, 0, 0, 0) AT TIME ZONE 'Asia/Kolkata');
    v_to   := v_from + interval '1 month';

    RETURN QUERY
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
            COALESCE((SELECT sum(amount)      FROM order_tax), 0)                                   AS gross_tax,
            COALESCE((SELECT sum(taxable_base) FROM order_tax), 0)                                   AS taxable_value,
            COALESCE((SELECT sum(amount) FROM ledger WHERE entry_type = 'ADJUSTMENT'), 0)            AS adjustments_total,
            COALESCE(-(SELECT sum(amount) FROM ledger WHERE entry_type = 'ORDER_TAX_WITHHELD'), 0)   AS withheld,
            COALESCE(-(SELECT sum(amount) FROM ledger WHERE entry_type = 'TAX_PAYMENT'), 0)          AS from_riders,
            (SELECT count(DISTINCT order_id)::int FROM order_tax)                                    AS taxable_orders,
            (SELECT count(DISTINCT order_id)::int FROM order_tax WHERE service_category = 'local_passenger_ride')    AS local_orders,
            (SELECT count(DISTINCT order_id)::int FROM order_tax WHERE service_category = 'intercity_passenger_ride') AS intercity_orders,
            (SELECT count(DISTINCT order_id)::int FROM order_tax WHERE service_category = 'parcel_delivery')          AS parcel_orders,
            (SELECT count(*)::int FROM ledger)                                                       AS ledger_rows,
            COALESCE((SELECT sum(amount) FROM refunded), 0)                                          AS refunded_gst,
            (SELECT count(DISTINCT order_id)::int FROM refunded)                                     AS refunded_count
    )
    SELECT
        to_char(v_from, 'YYYY-MM'),
        v_from,
        v_to,
        'Asia/Kolkata',
        'government_tax_ledger.created_at (= order completion time), IST calendar month',

        a.taxable_value,
        a.gross_tax,
        a.adjustments_total,
        a.gross_tax + a.adjustments_total,

        a.refunded_gst,
        a.refunded_count,
        COALESCE((SELECT jsonb_agg(DISTINCT r.order_code) FROM refunded r WHERE r.order_code IS NOT NULL), '[]'::jsonb),
        (a.gross_tax + a.adjustments_total) - a.refunded_gst,

        a.gross_tax + a.adjustments_total,
        'GROSS = SUM(ORDER_TAX) + SUM(ADJUSTMENT) from government_tax_ledger. This is the mechanically-derivable gross Section 9(5) ECO liability for supplies completed in the window. It is NOT reduced by Cashfree withholding or rider repayments (those are collection mechanics). Whether refund / credit-note amounts reduce it, and the final filing figure, REQUIRE CA/GST CONFIRMATION.',

        a.withheld,
        a.from_riders,
        a.gross_tax - a.withheld - a.from_riders,

        a.taxable_orders,
        a.local_orders,
        a.intercity_orders,
        a.parcel_orders,

        NULL::numeric, NULL::numeric, NULL::numeric, NULL::numeric,
        'IGST / CGST / SGST-UTGST / CESS are returned NULL: government_tax_ledger records only a single combined `amount` at `rate_percent` (no tax-component column), and orders carry only a free-text pickup_city / destination_city with no GST state or place-of-supply field. The intra-state vs inter-state determination, and therefore the CGST/SGST vs IGST allocation and any CESS, must be made by the CA from WayDrop''s GST registration state(s) and the place-of-supply rules. This report does not split the combined total.',

        COALESCE((
            SELECT jsonb_agg(to_jsonb(t))
            FROM (
                SELECT COALESCE(ot.service_category,'unclassified')  AS service_category,
                       ot.rate_percent                              AS rate_percent,
                       count(DISTINCT ot.order_id)                   AS orders,
                       COALESCE(sum(ot.taxable_base),0)              AS taxable_value,
                       COALESCE(sum(ot.amount),0)                    AS gross_tax,
                       COALESCE(-(SELECT sum(w.amount) FROM ledger w
                                  WHERE w.entry_type='ORDER_TAX_WITHHELD'
                                    AND COALESCE(w.service_category,'unclassified')=COALESCE(ot.service_category,'unclassified')),0)
                                                                    AS withheld_via_cashfree
                FROM order_tax ot
                GROUP BY ot.service_category, ot.rate_percent
                ORDER BY ot.service_category
            ) t), '[]'::jsonb),

        COALESCE((
            SELECT jsonb_agg(to_jsonb(t))
            FROM (
                SELECT COALESCE(ot.fare_payment_method,'unknown') AS fare_payment_method,
                       count(DISTINCT ot.order_id)                AS orders,
                       COALESCE(sum(ot.taxable_base),0)           AS taxable_value,
                       COALESCE(sum(ot.amount),0)                 AS gross_tax
                FROM order_tax ot
                GROUP BY ot.fare_payment_method
                ORDER BY ot.fare_payment_method
            ) t), '[]'::jsonb),

        a.ledger_rows,
        jsonb_build_object(
            'order_status_of_taxed_rows', COALESCE((
                SELECT jsonb_agg(to_jsonb(t))
                FROM (SELECT COALESCE(ot.order_status,'order_row_missing') AS order_status,
                             count(*) AS rows, COALESCE(sum(ot.amount),0) AS gross_tax
                      FROM order_tax ot GROUP BY ot.order_status ORDER BY 1) t), '[]'::jsonb),
            'identity_check', 'section_9_5_gross_tax_liability + adjustments = amount_payable_to_government_gross',
            'cross_check', 'Every figure here equals the identically-named field in public.report_government_tax_remittance(' || p_year::text || ', ' || p_month::text || ').',
            'note', 'ORDER_TAX rows should belong only to completed/delivered orders; anything else is an anomaly to investigate before filing.'),

        'CA/GST confirmation required before filing.',
        'Refund / credit-note treatment REQUIRES CA/GST CONFIRMATION: refunded_after_tax_gst and net_tax_liability_after_refunds are provided for finance only. Do NOT reduce the statutory liability by refunds unless a CA confirms the credit-note treatment and the return period.',
        'Section 9(5) applicability to WayDrop''s model, the service-category -> rate mapping (local_passenger_ride 5%, intercity_passenger_ride 5%, parcel_delivery 18% from tax_rate_config), ITC treatment, and the statutory return period all REQUIRE CA/GST CONFIRMATION. Migration comments label this "Section 9(5)"; there is no formal legal-basis document in the system.',
        jsonb_build_array(
            'CA/GST confirmation required before filing.',
            'IGST/CGST/SGST-UTGST/CESS not derivable from stored data -> returned NULL (see tax_component_split_note). No split is manufactured from the combined total.',
            'ORDER_TAX_WITHHELD and TAX_PAYMENT are collection mechanics and are NOT netted into amount_payable_to_government_gross.',
            'Refund / credit-note reduction of liability REQUIRES CA/GST CONFIRMATION (see refund_credit_note_note).',
            'Section 9(5) applicability, category->rate mapping and statutory return period REQUIRE CA/GST CONFIRMATION.',
            'Cancelled orders never create an ORDER_TAX row (auto-excluded). Unpaid completed orders still create the liability and are included.',
            'Window basis = government_tax_ledger.created_at (order completion time, IST). Time-of-supply basis REQUIRES CA/GST CONFIRMATION.'
        )
    FROM agg a;
END;
$function$;

REVOKE ALL ON FUNCTION public.report_section_9_5_month_end(integer, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.report_section_9_5_month_end(integer, integer) TO authenticated, service_role;

-- =============================================================================
-- ROLLBACK (manual):
--   DROP FUNCTION IF EXISTS public.report_section_9_5_month_end(integer, integer);
-- (No schema/data/tax-engine change to undo -- read-only.)
-- =============================================================================
