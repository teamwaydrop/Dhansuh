-- PRE-LAUNCH BLOCKER FIX 3 -- Month-end government-tax (GST) reporting (READ-ONLY)
-- File: supabase/migrations/20260910000002_government_tax_month_end_report.sql
-- Ref: docs/OPS_final_readiness_audit_2026-09-09.md (Part 4)

CREATE OR REPLACE FUNCTION public.report_government_tax(
    p_from timestamptz,
    p_to   timestamptz
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_result jsonb;
BEGIN
    IF NOT public.is_admin() THEN
        RAISE EXCEPTION 'Not authorized' USING ERRCODE = 'insufficient_privilege';
    END IF;

    IF p_from IS NULL OR p_to IS NULL OR p_to <= p_from THEN
        RAISE EXCEPTION 'Invalid window: p_to must be after p_from' USING ERRCODE = 'check_violation';
    END IF;

    WITH ledger AS (
        SELECT g.*,
               o.order_status::text        AS order_status,
               o.order_type::text          AS order_type,
               o.fare_payment_method::text AS fare_payment_method,
               o.payment_status::text      AS order_payment_status,
               p.refunded_at               AS payment_refunded_at
        FROM public.government_tax_ledger g
        LEFT JOIN public.orders   o ON o.id = g.order_id
        LEFT JOIN public.payments p ON p.id = o.payment_id
        WHERE g.created_at >= p_from
          AND g.created_at <  p_to
    ),
    order_tax AS (
        SELECT * FROM ledger WHERE entry_type = 'ORDER_TAX'
    ),
    refunded AS (
        SELECT * FROM order_tax
        WHERE order_payment_status IN ('refunded', 'partial_refund')
           OR payment_refunded_at IS NOT NULL
    )
    SELECT jsonb_build_object(
        'period', jsonb_build_object(
            'from', p_from,
            'to',   p_to
        ),
        'summary', jsonb_build_object(
            'orders_taxed',                (SELECT count(DISTINCT order_id) FROM order_tax),
            'taxable_base_total',          COALESCE((SELECT sum(taxable_base) FROM order_tax), 0),
            'gst_created_total',           COALESCE((SELECT sum(amount) FROM order_tax), 0),
            'gst_withheld_cashfree_total', COALESCE((SELECT sum(amount) FROM ledger WHERE entry_type = 'ORDER_TAX_WITHHELD'), 0),
            'gst_direct_collection_due',   COALESCE((SELECT sum(amount) FROM ledger WHERE entry_type IN ('ORDER_TAX','ORDER_TAX_WITHHELD')), 0),
            'tax_payments_received_total', COALESCE((SELECT sum(amount) FROM ledger WHERE entry_type = 'TAX_PAYMENT'), 0),
            'adjustments_total',           COALESCE((SELECT sum(amount) FROM ledger WHERE entry_type = 'ADJUSTMENT'), 0),
            'ledger_rows_in_window',       (SELECT count(*) FROM ledger)
        ),
        'by_category', COALESCE((
            SELECT jsonb_agg(to_jsonb(t))
            FROM (
                SELECT
                    COALESCE(ot.service_category, 'unclassified') AS service_category,
                    count(DISTINCT ot.order_id)                   AS orders_taxed,
                    COALESCE(sum(ot.taxable_base), 0)             AS taxable_base,
                    COALESCE(sum(ot.amount), 0)                   AS gst_created,
                    COALESCE((
                        SELECT sum(w.amount) FROM ledger w
                        WHERE w.entry_type = 'ORDER_TAX_WITHHELD'
                          AND COALESCE(w.service_category,'unclassified') = COALESCE(ot.service_category,'unclassified')
                    ), 0)                                         AS gst_withheld_cashfree
                FROM order_tax ot
                GROUP BY ot.service_category
                ORDER BY ot.service_category
            ) t
        ), '[]'::jsonb),
        'by_payment_method', COALESCE((
            SELECT jsonb_agg(to_jsonb(t))
            FROM (
                SELECT
                    COALESCE(ot.fare_payment_method, 'unknown') AS fare_payment_method,
                    count(DISTINCT ot.order_id)                 AS orders_taxed,
                    COALESCE(sum(ot.amount), 0)                 AS gst_created
                FROM order_tax ot
                GROUP BY ot.fare_payment_method
                ORDER BY ot.fare_payment_method
            ) t
        ), '[]'::jsonb),
        'refunded_after_tax', jsonb_build_object(
            'count',      (SELECT count(DISTINCT order_id) FROM refunded),
            'gst_amount', COALESCE((SELECT sum(amount) FROM refunded), 0),
            'order_codes', COALESCE((
                SELECT jsonb_agg(DISTINCT o.order_code)
                FROM refunded r JOIN public.orders o ON o.id = r.order_id
            ), '[]'::jsonb),
            'note', 'These completed orders were taxed at completion and later refunded. '
                 || 'No automatic GST reversal is performed (see audit Part 4). '
                 || 'Finance/business must decide the reversal treatment -- e.g. a manual '
                 || 'ADJUSTMENT ledger entry or an external credit note.'
        ),
        'reconciliation', jsonb_build_object(
            'order_status_breakdown', COALESCE((
                SELECT jsonb_agg(to_jsonb(t))
                FROM (
                    SELECT COALESCE(ot.order_status, 'order_row_missing') AS order_status,
                           count(*)                    AS ledger_rows,
                           COALESCE(sum(ot.amount), 0) AS gst_created
                    FROM order_tax ot
                    GROUP BY ot.order_status
                    ORDER BY ot.order_status
                ) t
            ), '[]'::jsonb),
            'note', 'ORDER_TAX rows should only ever belong to completed/delivered orders. '
                 || 'Any other status (or order_row_missing) is an anomaly to investigate.'
        ),
        'excluded_note', 'Cancelled orders never reach completion and have no ORDER_TAX row (auto-excluded). '
                      || 'Unpaid completed orders still create the liability and are included.'
    )
    INTO v_result;

    RETURN v_result;
END;
$function$;


CREATE OR REPLACE FUNCTION public.report_government_tax_month(
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
    v_from timestamptz;
    v_to   timestamptz;
BEGIN
    IF NOT public.is_admin() THEN
        RAISE EXCEPTION 'Not authorized' USING ERRCODE = 'insufficient_privilege';
    END IF;

    IF p_month < 1 OR p_month > 12 OR p_year < 2024 OR p_year > 2100 THEN
        RAISE EXCEPTION 'Invalid year/month' USING ERRCODE = 'check_violation';
    END IF;

    v_from := (make_timestamp(p_year, p_month, 1, 0, 0, 0) AT TIME ZONE 'Asia/Kolkata');
    v_to   := (v_from + interval '1 month');

    RETURN public.report_government_tax(v_from, v_to)
        || jsonb_build_object('month', jsonb_build_object(
               'year', p_year, 'month', p_month, 'timezone', 'Asia/Kolkata'));
END;
$function$;


REVOKE ALL ON FUNCTION public.report_government_tax(timestamptz, timestamptz) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.report_government_tax_month(integer, integer)    FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.report_government_tax(timestamptz, timestamptz) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.report_government_tax_month(integer, integer)   TO authenticated, service_role;
