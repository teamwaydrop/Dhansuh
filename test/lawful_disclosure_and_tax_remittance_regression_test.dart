// Structural regression guards for the Supabase-SQL-Editor lawful-disclosure
// workflow + month-end government-tax remittance report
// (migrations 20260911000000..20260911000002).
//
// Source-text guards in the same style as the rest of test/. They do not execute
// Postgres; they assert that the security-critical shape of each change is
// present and has not regressed. Behavioural verification (function execution,
// RLS simulation, ledger cross-check) was done against production at apply time.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String p) => File(p).readAsStringSync();

void main() {
  final psl = _read('supabase/migrations/20260911000000_fix_parcel_security_logs_rls.sql');
  final ldr = _read('supabase/migrations/20260911000001_lawful_disclosure_report_function.sql');
  final tax = _read('supabase/migrations/20260911000002_report_government_tax_remittance.sql');

  group('FIX -- parcel_security_logs RLS', () {
    test('the USING(true) / WITH CHECK(true) policies are dropped', () {
      expect(psl.contains('DROP POLICY IF EXISTS "Allow users/riders to select their parcel security logs" ON public.parcel_security_logs;'), isTrue);
      expect(psl.contains('DROP POLICY IF EXISTS "Allow authenticated users to insert security logs"        ON public.parcel_security_logs;'), isTrue);
    });

    test('new SELECT is participant-or-admin, never USING (true)', () {
      final active = psl.substring(0, psl.indexOf('ROLLBACK'));
      final sel = active.substring(active.indexOf('CREATE POLICY "parcel_security_logs_select_participant_or_admin"'));
      expect(sel.contains('FOR SELECT'), isTrue);
      expect(sel.contains('public.is_admin()'), isTrue);
      expect(sel.contains('sender_user_id = (SELECT auth.uid())'), isTrue);
      expect(sel.contains('r.user_id = (SELECT auth.uid())'), isTrue);
      expect(sel.contains('USING (true)'), isFalse);
    });

    test('new INSERT is scoped to the acting participant, never WITH CHECK (true)', () {
      final active = psl.substring(0, psl.indexOf('ROLLBACK'));
      final ins = active.substring(active.indexOf('CREATE POLICY "parcel_security_logs_insert_own_participant"'));
      expect(ins.contains('FOR INSERT'), isTrue);
      expect(ins.contains('WITH CHECK ('), isTrue);
      expect(ins.contains('WITH CHECK (true)'), isFalse);
    });

    test('no UPDATE/DELETE policy added -- rows stay immutable to clients', () {
      final active = psl.substring(0, psl.indexOf('ROLLBACK'));
      expect(active.contains('FOR UPDATE'), isFalse);
      expect(active.contains('FOR DELETE'), isFalse);
    });
  });

  group('lawful_disclosure_report -- security shape', () {
    test('exact signature (8 params) as approved', () {
      expect(ldr.contains('CREATE OR REPLACE FUNCTION public.lawful_disclosure_report('), isTrue);
      for (final p in const [
        'p_phone                  text',
        'p_requesting_authority   text',
        'p_legal_basis            text',
        'p_disclosed_scope        text[]',
        'p_reference_number       text    DEFAULT NULL',
        'p_legal_review_confirmed boolean DEFAULT false',
        'p_notes                  text    DEFAULT NULL',
        'p_generate_signed_urls   boolean DEFAULT false',
      ]) {
        expect(ldr.contains(p), isTrue, reason: 'missing param line: $p');
      }
    });

    test('SECURITY DEFINER, VOLATILE, search_path pinned', () {
      expect(ldr.contains('LANGUAGE plpgsql\nVOLATILE'), isTrue);
      expect(ldr.contains('SECURITY DEFINER'), isTrue);
      expect(ldr.contains("SET search_path TO 'public'"), isTrue);
    });

    test('gated: admin OR service_role OR SQL console (no JWT); anon rejected', () {
      expect(ldr.contains("v_jwt_role = 'service_role'"), isTrue);
      expect(ldr.contains("(v_jwt_uid IS NULL AND v_jwt_role <> 'anon')"), isTrue);
      expect(ldr.contains("USING ERRCODE = 'insufficient_privilege'"), isTrue);
      expect(ldr.contains('v_is_admin      boolean := public.is_admin();'), isTrue);
    });

    test('revoked from PUBLIC/anon, granted only to authenticated + service_role', () {
      expect(ldr.contains('REVOKE ALL ON FUNCTION public.lawful_disclosure_report(text, text, text, text[], text, boolean, text, boolean) FROM PUBLIC, anon;'), isTrue);
      expect(ldr.contains('GRANT EXECUTE ON FUNCTION public.lawful_disclosure_report(text, text, text, text[], text, boolean, text, boolean) TO authenticated, service_role;'), isTrue);
      expect(ldr.contains('TO anon'), isFalse);
    });

    test('phone normalised via the EXISTING helper; never silently picks one user', () {
      expect(ldr.contains('public._normalize_in_phone_10(p_phone)'), isTrue);
      expect(ldr.contains("right(regexp_replace(u.phone,'\\D','','g'), 10) = v_ten"), isTrue);
      expect(ldr.contains("'multiple_phone_matches', v_multi"), isTrue);
      expect(ldr.contains("'user_not_found', true"), isTrue);
      expect(ldr.contains("'matched_users', v_matches"), isTrue);
    });

    test('Aadhaar returned ONLY when scope has aadhaar AND legal_review_confirmed = true', () {
      expect(ldr.contains(
        "CASE WHEN ('aadhaar' = ANY(v_scope) OR 'all' = ANY(v_scope))\n"
        "                          AND COALESCE(p_legal_review_confirmed,false) = true\n"
        "                     THEN k.aadhaar_number ELSE NULL END"), isTrue);
    });

    test('audit-first: records lawful_disclosure_requests before returning data', () {
      final insLdr = ldr.indexOf('INSERT INTO public.lawful_disclosure_requests');
      final firstReturn = ldr.indexOf('RETURN jsonb_build_object');
      expect(insLdr, greaterThan(-1));
      expect(firstReturn, greaterThan(insLdr));
      expect(ldr.contains("target_phone_last4"), isTrue);
      // never persists the full phone
      expect(ldr.contains("right(v_ten, 4)"), isTrue);
    });

    test('does NOT alter RLS on the evidence tables -- SECURITY DEFINER is the read path', () {
      for (final forbidden in const [
        'CREATE POLICY', 'ALTER POLICY', 'DROP POLICY',
        'ENABLE ROW LEVEL SECURITY', 'FORCE ROW LEVEL SECURITY',
      ]) {
        expect(ldr.contains(forbidden), isFalse, reason: 'lawful_disclosure_report migration must not $forbidden');
      }
      // the only schema touch: make the audit FK column nullable (0-row table)
      expect(ldr.contains('ALTER COLUMN handled_by_admin_id DROP NOT NULL'), isTrue);
    });

    test('does not touch ride/booking/payment/completion/dispatch/GPS/realtime', () {
      for (final forbidden in const [
        'complete_order_and_settle', 'apply_order_government_tax', 'tax_rate_config',
        'CREATE TRIGGER', 'DROP TRIGGER', 'supabase_realtime',
        'sync_riders_gps_to_rider_locations', 'update-order-status',
      ]) {
        expect(ldr.contains(forbidden), isFalse);
      }
    });

    test('last-known-location is explicitly a snapshot, not a route', () {
      expect(ldr.contains("'snapshot_not_route', true"), isTrue);
      expect(ldr.contains("'continuous_route_history_available', false"), isTrue);
      expect(ldr.contains("'live_location_while_offline', false"), isTrue);
    });
  });

  group('report_government_tax_remittance -- read-only wrapper', () {
    test('exact signature + STABLE + SECURITY DEFINER + search_path', () {
      expect(tax.contains('CREATE OR REPLACE FUNCTION public.report_government_tax_remittance(\n    p_year  integer,\n    p_month integer\n)'), isTrue);
      expect(tax.contains('LANGUAGE plpgsql\nSTABLE\nSECURITY DEFINER'), isTrue);
      expect(tax.contains("SET search_path TO 'public'"), isTrue);
    });

    test('READ-ONLY: no writes to the ledger or tax config; tax engine untouched', () {
      for (final forbidden in const [
        'INSERT INTO public.government_tax_ledger',
        'UPDATE public.government_tax_ledger',
        'DELETE FROM public.government_tax_ledger',
        'UPDATE public.tax_rate_config',
        'CREATE OR REPLACE FUNCTION public.apply_order_government_tax',
        'CREATE OR REPLACE FUNCTION public.complete_order_and_settle',
      ]) {
        expect(tax.contains(forbidden), isFalse);
      }
    });

    test('gated + revoked from anon/PUBLIC', () {
      expect(tax.contains("(v_jwt_uid IS NULL AND v_jwt_role <> 'anon')"), isTrue);
      expect(tax.contains('REVOKE ALL ON FUNCTION public.report_government_tax_remittance(integer, integer) FROM PUBLIC, anon;'), isTrue);
      expect(tax.contains('GRANT EXECUTE ON FUNCTION public.report_government_tax_remittance(integer, integer) TO authenticated, service_role;'), isTrue);
    });

    test('amount_payable_to_government_gross = gst_created_total + adjustments_total', () {
      expect(tax.contains("'amount_payable_to_government_gross', a.gst_created_total + a.adjustments_total"), isTrue);
      expect(tax.contains("'gst_created_total',                 a.gst_created_total"), isTrue);
      expect(tax.contains("'adjustments_total',                 a.adjustments_total"), isTrue);
    });

    test('withholding / rider payments are collection mechanics -- NOT netted into the gross payable', () {
      expect(tax.contains('ORDER_TAX_WITHHELD and TAX_PAYMENT are collection mechanics and are NOT netted into amount_payable_to_government_gross.'), isTrue);
      expect(tax.contains("'collected_via_cashfree_withholding'"), isTrue);
      expect(tax.contains("'collected_from_riders'"), isTrue);
    });

    test('refund treatment + Section 9(5) applicability flagged as REQUIRES CA/GST CONFIRMATION', () {
      expect(tax.contains('REQUIRES CA/GST CONFIRMATION: whether refunded-after-tax orders reduce the remittance'), isTrue);
      expect(tax.contains('REQUIRES CA/GST CONFIRMATION: Section 9(5) applicability'), isTrue);
      expect(tax.contains('REQUIRES CA/GST CONFIRMATION: the statutory return period'), isTrue);
      expect(tax.contains("'amount_payable_to_government_net_of_refunds'"), isTrue);
    });
  });
}
