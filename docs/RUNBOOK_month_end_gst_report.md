# Runbook — Month-End Government Tax (GST) Report

**Owner:** Finance / Operations
**Frequency:** Monthly, after the calendar month closes (IST).
**Source of truth:** `public.government_tax_ledger` (populated by
`apply_order_government_tax()` inside `complete_order_and_settle()` at ride
completion). **Do not edit tax logic, `tax_rate_config`, or the ledger to
produce this report.**

Live rates (verify before each close — `SELECT service_category, rate_percent,
effective_from FROM tax_rate_config WHERE is_active`):

| Service category | Rate |
|---|---|
| `local_passenger_ride` | 5% |
| `intercity_passenger_ride` | 5% |
| `parcel_delivery` | 18% |

---

## Option A — In the app (recommended)

1. Open **WayDrop → Profile → Admin Panel → Month-End GST Report**
   (visible only to an active row in `public.admins`).
2. Pick the **month** and **year** (defaults to last month) → **Run**.
3. Read the cards:
   - **GST created (ORDER_TAX)** — total liability raised for the month.
   - **GST withheld — Cashfree** — negative; already recovered from rider
     earnings for Cashfree-collected fares.
   - **GST — direct-collection due** — `created + withheld`. This is the GST on
     **cash / personal-UPI** rides that WayDrop must remit and that sits on the
     riders' `government_tax_due_balance`.
   - **By service category** / **By payment method** breakdowns.
   - **⚠ Refunded after tax** — completed orders that were taxed and later
     refunded. **No automatic reversal happens.** Finance decides the treatment
     (see below).
   - **Reconciliation** — every `ORDER_TAX` row should belong to a
     `completed`/`delivered` order; anything else is an anomaly to investigate.
4. **Copy raw JSON** for the working papers / filing pack.

## Option B — Direct SQL (Supabase Studio → SQL editor, as an admin)

```sql
-- Whole month in IST:
SELECT public.report_government_tax_month(2026, 9);

-- Arbitrary window:
SELECT public.report_government_tax(
  '2026-09-01 00:00:00+05:30',
  '2026-10-01 00:00:00+05:30'
);
```

Both functions are `is_admin()`-gated and read-only.

### Raw cross-check queries

```sql
-- GST created per category (Sep 2026 IST)
SELECT service_category, count(DISTINCT order_id) AS orders, sum(taxable_base) AS base, sum(amount) AS gst
FROM public.government_tax_ledger
WHERE entry_type = 'ORDER_TAX'
  AND created_at >= '2026-09-01 00:00:00+05:30'
  AND created_at <  '2026-10-01 00:00:00+05:30'
GROUP BY service_category;

-- Net by entry type
SELECT entry_type, count(*), sum(amount)
FROM public.government_tax_ledger
WHERE created_at >= '2026-09-01 00:00:00+05:30'
  AND created_at <  '2026-10-01 00:00:00+05:30'
GROUP BY entry_type;
```

---

## Notes & known gaps

- **`created_at` is the completion time**, not booking time. A ride booked on
  30 Sep and completed on 1 Oct lands in October.
- **Cancelled orders** never reach completion → no `ORDER_TAX` row → inherently
  excluded.
- **Unpaid completed orders** still create the liability (direct-collection tax
  is added to the rider's `government_tax_due_balance`). They are included and
  visible under "By payment method".
- **Refund after completion → no automatic GST reversal.** This is a known,
  deliberate gap (see `docs/OPS_final_readiness_audit_2026-09-09.md` Part 4).
  If finance decides a refunded ride's GST should be reversed, record it as a
  manual `ADJUSTMENT` ledger row (service_role / Studio), e.g.:
  ```sql
  INSERT INTO public.government_tax_ledger
    (rider_id, order_id, entry_type, service_category, taxable_base, rate_percent, amount)
  SELECT rider_id, order_id, 'ADJUSTMENT', service_category, taxable_base, rate_percent, -amount
  FROM public.government_tax_ledger
  WHERE order_id = '<order-uuid>' AND entry_type = 'ORDER_TAX';
  ```
  The report's `adjustments_total` then reflects it. Get sign-off before doing this.
- The booking-time `orders.gst_amount` / `payments.gst_amount` fields are a
  **separate** figure set by the pricing engine and are **not** what this report
  measures. `government_tax_ledger` is authoritative.
