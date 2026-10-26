// Structural regression guards for the month-end Section 9(5) GST report
// (migration 20260912000002_report_section_9_5_month_end.sql).
//
// Source-text guards, same style as the rest of test/. They do not execute
// Postgres. Behavioural verification (execution, field-by-field cross-check
// against report_government_tax_remittance(2026,9) and directly against
// government_tax_ledger, auth-gate rejection, ledger-unchanged) was done at
// apply time via a RAISE-rollback selftest.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String p) => File(p).readAsStringSync();

void main() {
  final s = _read('supabase/migrations/20260912000002_report_section_9_5_month_end.sql');

  group('report_section_9_5_month_end -- shape & security', () {
    test('exact signature: (p_year int, p_month int) RETURNS TABLE', () {
      expect(s.contains('CREATE OR REPLACE FUNCTION public.report_section_9_5_month_end(\n    p_year  integer,\n    p_month integer\n)'), isTrue);
      expect(s.contains('RETURNS TABLE ('), isTrue);
    });

    test('STABLE + SECURITY DEFINER + search_path pinned to public', () {
      expect(s.contains('LANGUAGE plpgsql\nSTABLE\nSECURITY DEFINER'), isTrue);
      expect(s.contains("SET search_path TO 'public'"), isTrue);
    });

    test('gated: admin OR service_role OR SQL console (no JWT); anon rejected', () {
      expect(s.contains("public.is_admin()"), isTrue);
      expect(s.contains("v_jwt_role = 'service_role'"), isTrue);
      expect(s.contains("(v_jwt_uid IS NULL AND v_jwt_role <> 'anon')"), isTrue);
      expect(s.contains("USING ERRCODE = 'insufficient_privilege'"), isTrue);
    });

    test('revoked from PUBLIC + anon, granted only to authenticated + service_role', () {
      expect(s.contains('REVOKE ALL ON FUNCTION public.report_section_9_5_month_end(integer, integer) FROM PUBLIC, anon;'), isTrue);
      expect(s.contains('GRANT EXECUTE ON FUNCTION public.report_section_9_5_month_end(integer, integer) TO authenticated, service_role;'), isTrue);
      expect(s.contains('TO anon'), isFalse);
    });
  });

  group('report_section_9_5_month_end -- READ-ONLY, tax engine untouched', () {
    test('no writes to the ledger / tax config anywhere', () {
      for (final forbidden in const [
        'INSERT INTO public.government_tax_ledger',
        'UPDATE public.government_tax_ledger',
        'DELETE FROM public.government_tax_ledger',
        'UPDATE public.tax_rate_config',
        'INSERT INTO public.tax_rate_config',
        'CREATE OR REPLACE FUNCTION public.apply_order_government_tax',
        'CREATE OR REPLACE FUNCTION public.complete_order_and_settle',
      ]) {
        expect(s.contains(forbidden), isFalse, reason: 'must not: $forbidden');
      }
    });

    test('no RLS / table / trigger DDL', () {
      for (final forbidden in const [
        'CREATE POLICY', 'ALTER POLICY', 'DROP POLICY',
        'ENABLE ROW LEVEL SECURITY', 'FORCE ROW LEVEL SECURITY',
        'CREATE TRIGGER', 'DROP TRIGGER', 'ALTER TABLE', 'CREATE TABLE',
      ]) {
        expect(s.contains(forbidden), isFalse, reason: 'must not: $forbidden');
      }
    });

    test('does NOT redefine report_government_tax_remittance (kept intact)', () {
      expect(s.contains('CREATE OR REPLACE FUNCTION public.report_government_tax_remittance'), isFalse);
      expect(s.contains('DROP FUNCTION IF EXISTS public.report_government_tax_remittance'), isFalse);
    });

    test('does NOT touch the police / lawful-disclosure workflow', () {
      for (final forbidden in const [
        'lawful_disclosure_report', 'police_person_details', 'police_last_trip',
        'police_all_trips', 'police_trip_evidence', '_police_disclosure_gate',
        'parcel_security_logs',
      ]) {
        expect(s.contains(forbidden), isFalse, reason: 'GST report must not reference $forbidden');
      }
    });
  });

  group('report_section_9_5_month_end -- accounting model', () {
    test('gross Section 9(5) liability = SUM(ORDER_TAX); payable_gross adds ADJUSTMENT only', () {
      expect(s.contains(RegExp(r'SELECT sum\(amount\)\s+FROM order_tax\), 0\)\s+AS gross_tax')), isTrue);
      expect(s.contains(RegExp(r"WHERE entry_type = 'ADJUSTMENT'\), 0\)\s+AS adjustments_total")), isTrue);
      expect(s.contains('a.gross_tax + a.adjustments_total'), isTrue);
    });

    test('withholding & rider payments are reported SEPARATELY, never netted into the liability', () {
      expect(s.contains(RegExp(r"WHERE entry_type = 'ORDER_TAX_WITHHELD'\), 0\)\s+AS withheld")), isTrue);
      expect(s.contains(RegExp(r"WHERE entry_type = 'TAX_PAYMENT'\), 0\)\s+AS from_riders")), isTrue);
      expect(s.contains('a.gross_tax - a.withheld - a.from_riders'), isTrue); // outstanding receivable
      // the payable figure is gross+adjustments, NOT gross-withheld-payments
      expect(s.contains('amount_to_remit'), isTrue);
      expect(s.contains('ORDER_TAX_WITHHELD and TAX_PAYMENT are collection mechanics and are NOT netted'), isTrue);
    });

    test('IGST / CGST / SGST-UTGST / CESS are returned NULL with a stated reason', () {
      expect(s.contains('NULL::numeric, NULL::numeric, NULL::numeric, NULL::numeric,'), isTrue);
      expect(s.contains('IGST / CGST / SGST-UTGST / CESS are returned NULL'), isTrue);
      expect(s.contains('no GST state or place-of-supply field'), isTrue);
      expect(s.contains('This report does not split the combined total.'), isTrue);
    });

    test('refunds shown, never auto-reduce statutory liability; flagged for CA', () {
      expect(s.contains('refunded_after_tax_gst'), isTrue);
      expect(s.contains('refunded_after_tax_order_count'), isTrue);
      expect(s.contains('refunded_after_tax_order_codes'), isTrue);
      expect(s.contains('net_tax_liability_after_refunds'), isTrue);
      expect(s.contains('Refund / credit-note treatment REQUIRES CA/GST CONFIRMATION'), isTrue);
    });

    test('filing disclaimer present', () {
      expect(s.contains("'CA/GST confirmation required before filing.'"), isTrue);
    });

    test('same window basis as report_government_tax_remittance (ledger.created_at, IST)', () {
      expect(s.contains("(make_timestamp(p_year, p_month, 1, 0, 0, 0) AT TIME ZONE 'Asia/Kolkata')"), isTrue);
      expect(s.contains("v_to   := v_from + interval '1 month'"), isTrue);
      expect(s.contains('WHERE g.created_at >= v_from AND g.created_at < v_to'), isTrue);
    });

    test('breakdowns present: per service_category and per fare_payment_method', () {
      expect(s.contains('GROUP BY ot.service_category, ot.rate_percent'), isTrue);
      expect(s.contains('GROUP BY ot.fare_payment_method'), isTrue);
      expect(s.contains('local_passenger_orders'), isTrue);
      expect(s.contains('intercity_passenger_orders'), isTrue);
      expect(s.contains('parcel_orders'), isTrue);
    });
  });
}
