// Structural regression guards for the pre-launch blocker fixes
// (backend migrations 20260910000000..20260910000003).
//
// Ref: docs/OPS_final_readiness_audit_2026-09-09.md
//
// These are source-text guards in the same style as the rest of test/: they do
// not execute Postgres / Flutter, they assert that the security-critical shape
// of each fix is present and has not regressed.
//
// NOTE: the mobile Admin Panel UI (lib/modules/admin/{admin_service,admin_home_screen,
// kyc,gst,disclosure}) was intentionally removed -- a separate admin panel exists.
// The admin DB workflow (migrations + RPCs) is unchanged and still guarded here.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String p) => File(p).readAsStringSync();

void main() {
  final sosRls = _read('supabase/migrations/20260910000000_fix_police_sos_logs_rls.sql');
  final kyc = _read('supabase/migrations/20260910000001_admin_kyc_review_workflow.sql');
  final gst = _read('supabase/migrations/20260910000002_government_tax_month_end_report.sql');
  final disc = _read('supabase/migrations/20260910000003_lawful_disclosure_workflow.sql');
  final userProfile = _read('lib/features/user/profile/profile_tab.dart');
  final riderProfile = _read('lib/features/rider/profile/rider_profile_tab.dart');

  group('FIX 1 -- police_sos_logs RLS', () {
    test('the two USING(true)/CHECK(true) policies are dropped', () {
      expect(sosRls.contains('DROP POLICY IF EXISTS "Allow authenticated to select police sos logs" ON public.police_sos_logs;'), isTrue);
      expect(sosRls.contains('DROP POLICY IF EXISTS "Allow riders to insert police sos logs"        ON public.police_sos_logs;'), isTrue);
    });

    test('SELECT is restricted to the reporting rider or an admin -- never USING (true)', () {
      final sel = sosRls.substring(
        sosRls.indexOf('CREATE POLICY "police_sos_logs_select_own_or_admin"'),
        sosRls.indexOf('CREATE POLICY "police_sos_logs_insert_own_rider"'),
      );
      expect(sel.contains('FOR SELECT'), isTrue);
      expect(sel.contains('public.is_admin()'), isTrue);
      expect(sel.contains('r.user_id = (SELECT auth.uid())'), isTrue);
      expect(sel.contains('USING (true)'), isFalse);
      expect(sel.contains('USING ( true )'), isFalse);
    });

    test('INSERT can only create a row for a rider profile the caller owns', () {
      final from = sosRls.indexOf('CREATE POLICY "police_sos_logs_insert_own_rider"');
      // scope to the statement itself, not the rollback comment block further down
      final ins = sosRls.substring(from, sosRls.indexOf('ROLLBACK', from));
      expect(ins.contains('FOR INSERT'), isTrue);
      expect(ins.contains('WITH CHECK ('), isTrue);
      expect(ins.contains('r.user_id = (SELECT auth.uid())'), isTrue);
      expect(ins.contains('WITH CHECK (true)'), isFalse);
    });

    test('no UPDATE or DELETE policy is (re)introduced -- rows stay immutable to clients', () {
      final active = sosRls.substring(0, sosRls.indexOf('ROLLBACK'));
      expect(active.contains('FOR UPDATE'), isFalse);
      expect(active.contains('FOR DELETE'), isFalse);
    });

    test('a rollback block is documented', () {
      expect(sosRls.contains('ROLLBACK'), isTrue);
    });
  });

  group('FIX 2 -- admin KYC review workflow', () {
    test('both functions self-enforce is_admin() and are never granted to anon/public', () {
      expect(kyc.contains('IF NOT public.is_admin() THEN'), isTrue);
      expect(kyc.contains('REVOKE ALL ON FUNCTION public.admin_list_kyc_queue()                          FROM PUBLIC, anon;'), isTrue);
      expect(kyc.contains('REVOKE ALL ON FUNCTION public.admin_review_rider_kyc(uuid, text, text)        FROM PUBLIC, anon;'), isTrue);
      expect(kyc.contains('GRANT EXECUTE ON FUNCTION public.admin_review_rider_kyc(uuid, text, text)     TO authenticated, service_role;'), isTrue);
    });

    test('approve sets activation_status = active (fires the EXISTING rider-creation trigger, not a duplicate)', () {
      expect(kyc.contains("kyc_status        = 'approved',"), isTrue);
      expect(kyc.contains("activation_status = 'active',"), isTrue);
      // it must NOT itself INSERT INTO riders -- that is trigger_create_rider_profile's job.
      expect(kyc.contains('INSERT INTO public.riders'), isFalse);
      expect(kyc.contains('INSERT INTO riders'), isFalse);
    });

    test('reject requires a reason and applies the 7-day block on the 2nd rejection', () {
      expect(kyc.contains('A rejection reason is required'), isTrue);
      expect(kyc.contains('IF v_new_count >= 2 THEN'), isTrue);
      expect(kyc.contains("v_blocked_until := now() + interval '7 days';"), isTrue);
    });

    test('every decision writes an admin_logs audit row and fires the existing notification path', () {
      expect(kyc.contains("INSERT INTO public.admin_logs ("), isTrue);
      expect(kyc.contains("'kyc_approve'"), isTrue);
      expect(kyc.contains("'kyc_reject'"), isTrue);
      expect(kyc.contains('PERFORM public.send_push_notification_fnc('), isTrue);
    });

    test('it refuses to act on an already-decided KYC', () {
      expect(kyc.contains("IF v_kyc.kyc_status NOT IN ('pending', 'under_review', 'resubmitted') THEN"), isTrue);
    });

    test('tax / ride / trigger logic is not touched by this migration', () {
      for (final forbidden in [
        'apply_order_government_tax',
        'complete_order_and_settle',
        'tax_rate_config',
        'CREATE TRIGGER',
        'DROP TRIGGER',
        'supabase_realtime',
      ]) {
        expect(kyc.contains(forbidden), isFalse, reason: 'KYC migration must not reference $forbidden');
      }
    });

    test('the KYC migration never makes the private rider_kyc bucket public', () {
      expect(kyc.contains('public = true'), isFalse);
      expect(kyc.contains('UPDATE storage.buckets'), isFalse);
      expect(kyc.contains('storage.buckets'), isFalse);
    });
  });

  group('FIX 3 -- month-end GST report', () {
    test('report functions are read-only: no writes to the ledger or tax config', () {
      expect(gst.contains('INSERT INTO public.government_tax_ledger'), isFalse);
      expect(gst.contains('UPDATE public.government_tax_ledger'), isFalse);
      expect(gst.contains('UPDATE public.tax_rate_config'), isFalse);
      expect(gst.contains('CREATE OR REPLACE FUNCTION public.apply_order_government_tax'), isFalse);
    });

    test('is_admin() gated, granted to authenticated + service_role only', () {
      expect(gst.contains('IF NOT public.is_admin() THEN'), isTrue);
      expect(gst.contains('REVOKE ALL ON FUNCTION public.report_government_tax(timestamptz, timestamptz) FROM PUBLIC, anon;'), isTrue);
      expect(gst.contains('GRANT EXECUTE ON FUNCTION public.report_government_tax_month(integer, integer)   TO authenticated, service_role;'), isTrue);
    });

    test('accepts an arbitrary date range AND a whole-month convenience wrapper (no hardcoded month)', () {
      expect(gst.contains('CREATE OR REPLACE FUNCTION public.report_government_tax(\n    p_from timestamptz,\n    p_to   timestamptz\n)'), isTrue);
      expect(gst.contains('CREATE OR REPLACE FUNCTION public.report_government_tax_month(\n    p_year  integer,\n    p_month integer\n)'), isTrue);
      expect(gst.contains("AT TIME ZONE 'Asia/Kolkata'"), isTrue);
      // no month literal baked into the logic
      expect(RegExp(r"= *'2026-09").hasMatch(gst), isFalse);
    });

    test('cancelled excluded implicitly; refunded-after-tax is FLAGGED, not reversed', () {
      expect(gst.contains("entry_type = 'ORDER_TAX'"), isTrue);
      expect(gst.contains("order_payment_status IN ('refunded', 'partial_refund')"), isTrue);
      expect(gst.contains('payment_refunded_at IS NOT NULL'), isTrue);
      expect(gst.contains("'refunded_after_tax'"), isTrue);
      expect(gst.toLowerCase().contains('no automatic gst reversal'), isTrue);
    });

    test('direct-collection due = ORDER_TAX + ORDER_TAX_WITHHELD (cash/UPI portion)', () {
      expect(gst.contains("entry_type IN ('ORDER_TAX','ORDER_TAX_WITHHELD')"), isTrue);
      expect(gst.contains("'gst_direct_collection_due'"), isTrue);
    });
  });

  group('FIX 4 -- lawful disclosure workflow', () {
    test('disclosure table is immutable to clients: SELECT-only admin policy, no INSERT/UPDATE/DELETE policy', () {
      expect(disc.contains('CREATE POLICY "lawful_disclosure_admin_select"'), isTrue);
      expect(disc.contains('USING (public.is_admin())'), isTrue);
      expect(disc.contains('FOR INSERT'), isFalse);
      expect(disc.contains('FOR UPDATE'), isFalse);
      expect(disc.contains('FOR DELETE'), isFalse);
      expect(disc.contains('ENABLE ROW LEVEL SECURITY'), isTrue);
    });

    test('every RPC is is_admin() gated and never granted to anon/public', () {
      // one guard per function (lookup, record, retrieve) + the table policy uses is_admin too
      expect('public.is_admin()'.allMatches(disc).length >= 4, isTrue);
      expect(disc.contains('FROM PUBLIC, anon;'), isTrue);
      expect(disc.contains('TO authenticated, service_role;'), isTrue);
      expect(disc.contains('TO anon'), isFalse);
    });

    test('the full phone number is never stored -- only the last 4 digits', () {
      expect(disc.contains('target_phone_last4'), isTrue);
      expect(disc.contains("right(regexp_replace(COALESCE(v_phone,''), '\\D', '', 'g'), 4)"), isTrue);
      // the disclosure INSERT must not persist a full phone column
      expect(disc.contains('target_phone text'), isFalse);
      expect(disc.contains('full_phone'), isFalse);
    });

    test('phone search normalizes to the last 10 digits (matches the stored 91XXXXXXXXXX format)', () {
      expect(disc.contains("right(regexp_replace(u.phone, '\\D', '', 'g'), 10) = v_ten"), isTrue);
      expect(disc.contains('_normalize_in_phone_10'), isTrue);
    });

    test('ride history cannot be pulled without a recorded disclosure id', () {
      expect(disc.contains('CREATE OR REPLACE FUNCTION public.admin_get_disclosure_ride_history(p_disclosure_id uuid)'), isTrue);
      expect(disc.contains('FROM public.lawful_disclosure_requests WHERE id = p_disclosure_id'), isTrue);
    });

    test('results are scoped to one target user (WHERE user_id / rider_id = target), with a row cap', () {
      expect(disc.contains('WHERE o.user_id = v_target'), isTrue);
      expect(disc.contains('WHERE o.rider_id = v_rider_id'), isTrue);
      expect(disc.contains('LIMIT 500'), isTrue);
    });

    test('lookup + record + retrieval each write an admin_logs audit row', () {
      expect("INSERT INTO public.admin_logs".allMatches(disc).length >= 3, isTrue);
      expect(disc.contains("'lawful_lookup'"), isTrue);
      expect(disc.contains("'lawful_disclosure'"), isTrue);
      expect(disc.contains("'lawful_disclosure_retrieval'"), isTrue);
    });

    test('there is no public phone-search endpoint anywhere in the client', () {
      final clientFiles = Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'));
      for (final f in clientFiles) {
        final src = f.readAsStringSync();
        // Only the audited admin RPC may be referenced, and only from the admin service.
        if (src.contains('admin_lookup_user_by_phone')) {
          expect(f.path.replaceAll('\\', '/').contains('lib/modules/admin/'), isTrue,
              reason: '${f.path} references the phone lookup RPC but is not under modules/admin');
        }
        expect(src.contains(".from('users').select") && src.contains('.ilike(') && src.contains('phone'), isFalse,
            reason: '${f.path} looks like a client-side phone search on users');
      }
    });
  });

  group('Admin authorization model -- single source of truth', () {
    test('all four migrations gate on the same public.is_admin() helper', () {
      for (final m in [kyc, gst, disc]) {
        expect(m.contains('public.is_admin()'), isTrue);
      }
      expect(sosRls.contains('public.is_admin()'), isTrue);
    });
  });

  group('Mobile Admin Panel UI stays removed (a separate admin panel exists)', () {
    test('the deleted mobile admin UI files are absent', () {
      for (final p in const [
        'lib/modules/admin/admin_service.dart',
        'lib/modules/admin/admin_home_screen.dart',
        'lib/modules/admin/kyc/admin_kyc_review_screen.dart',
        'lib/modules/admin/kyc/admin_kyc_detail_screen.dart',
        'lib/modules/admin/gst/admin_gst_report_screen.dart',
        'lib/modules/admin/disclosure/admin_lawful_disclosure_screen.dart',
      ]) {
        expect(File(p).existsSync(), isFalse, reason: '$p should not exist');
      }
    });

    test('neither profile tab references a mobile Admin Panel', () {
      for (final src in [userProfile, riderProfile]) {
        expect(src.contains('AdminHomeScreen'), isFalse);
        expect(src.contains('fetchCurrentAdmin'), isFalse);
        expect(src.contains('modules/admin/admin_service'), isFalse);
        expect(src.contains('modules/admin/admin_home_screen'), isFalse);
        expect(src.contains("label: 'Admin Panel'"), isFalse);
      }
    });

    test('the existing Admin Support Panel entry is left intact', () {
      for (final src in [userProfile, riderProfile]) {
        expect(src.contains('AdminSupportChatsScreen'), isTrue);
        expect(src.contains("label: 'Admin Support Panel'"), isTrue);
      }
    });
  });
}
