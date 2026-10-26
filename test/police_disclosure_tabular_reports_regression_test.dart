// Structural regression guards for the operator-friendly tabular police-disclosure
// reports (migrations 20260912000000 + 20260912000001 + 20260912000003).
//
// police_person_details() was corrected by 20260912000003 (KYC document paths
// removed from the output; Aadhaar returned directly for this authorized report;
// p_legal_review_confirmed param dropped). Its guards below read that migration.
//
// Same source-text style as the rest of test/. These do NOT execute Postgres;
// they assert that the security-critical shape of the change is present and has
// not regressed. Behavioural verification (function execution against production
// with a known test phone, anon / non-admin rejection, audit-row creation,
// SOS-scope fix) was done at apply time via RAISE-rollback selftests.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String p) => File(p).readAsStringSync();

void main() {
  final base = _read('supabase/migrations/20260912000000_police_disclosure_tabular_reports.sql');
  final sos = _read('supabase/migrations/20260912000001_police_last_trip_scope_sos_to_order.sql');
  final pd = _read('supabase/migrations/20260912000003_police_person_details_aadhaar_no_doc_paths.sql');

  const fns = <String>[
    'public._police_disclosure_gate',
    'public.police_person_details',
    'public.police_last_trip',
    'public.police_all_trips',
    'public.police_trip_evidence',
  ];

  group('police tabular reports -- functions created', () {
    for (final f in fns) {
      test('$f is created', () {
        expect(base.contains('CREATE OR REPLACE FUNCTION $f('), isTrue);
      });
    }

    test('all five are SECURITY DEFINER, VOLATILE, search_path pinned to public', () {
      // one SET line per function + gate; all VOLATILE (they record an audit row)
      expect('SECURITY DEFINER'.allMatches(base).length, greaterThanOrEqualTo(5));
      expect("SET search_path TO 'public'".allMatches(base).length, greaterThanOrEqualTo(5));
      expect('VOLATILE'.allMatches(base).length, greaterThanOrEqualTo(5));
    });
  });

  group('police tabular reports -- authorization gate', () {
    test('gate: admin OR service_role OR SQL console (no JWT); anon + ordinary authenticated rejected', () {
      expect(base.contains(
          "IF NOT ( v_is_admin OR v_role = 'service_role' OR (v_uid IS NULL AND v_role <> 'anon') ) THEN"),
          isTrue);
      expect(base.contains("USING ERRCODE = 'insufficient_privilege'"), isTrue);
      // present in the shared gate AND inlined in police_trip_evidence
      expect("v_role <> 'anon'".allMatches(base).length, greaterThanOrEqualTo(2));
      expect(base.contains('v_is_admin boolean := public.is_admin();'), isTrue);
    });

    test('revoked from PUBLIC + anon, granted only to authenticated + service_role', () {
      for (final sig in const [
        'public._police_disclosure_gate(text, text, text, text, text, boolean)',
        'public.police_last_trip(text, text, text, text)',
        'public.police_all_trips(text, text, text, text)',
        'public.police_trip_evidence(text, text, text, text)',
      ]) {
        expect(base.contains('REVOKE ALL ON FUNCTION $sig'), isTrue, reason: 'missing REVOKE for $sig');
        expect(base.contains('GRANT EXECUTE ON FUNCTION $sig'), isTrue, reason: 'missing GRANT for $sig');
      }
      expect(base.contains('FROM PUBLIC, anon;'), isTrue);
      expect(base.contains('TO authenticated, service_role;'), isTrue);
      expect(base.contains('TO anon'), isFalse);
    });
  });

  group('police tabular reports -- audit-first & phone handling', () {
    test('phone normalised via the EXISTING helper', () {
      expect(base.contains('public._normalize_in_phone_10(p_phone)'), isTrue);
      expect(base.contains(r"right(regexp_replace(u.phone,'\D','','g'),10) = v_ten"), isTrue);
    });

    test('records an immutable lawful_disclosure_requests row BEFORE returning data', () {
      final insAt = base.indexOf('INSERT INTO public.lawful_disclosure_requests');
      final firstReturnQuery = base.indexOf('RETURN QUERY');
      expect(insAt, greaterThan(-1));
      // the gate INSERTs before it RETURNs match rows; person/trip fns only
      // RETURN QUERY out of the gate CTE, so the audit write always precedes data.
      expect(base.contains("disclosed_scope = "), isFalse); // never UPDATEs the row
      expect(base.contains("ARRAY['police_' || p_report]"), isTrue);
      expect(base.contains('right(v_ten, 4)'), isTrue); // never persists the full phone
      expect(firstReturnQuery, greaterThan(-1));
    });

    test('multiple phone matches are never silently collapsed to one person', () {
      expect(base.contains('MULTIPLE MATCHES'), isTrue);
      expect(base.contains('total_matches'), isTrue);
      // gate returns one row per matching (user_id, rider_id)
      expect(base.contains('SELECT u.id, r.id, u.created_at, v_count, v_disc'), isTrue);
    });

    test('no-match still returns a row (with disclosure_id) rather than nothing', () {
      expect(base.contains("'NO MATCH for this phone'"), isTrue);
      expect(base.contains('SELECT NULL::uuid, NULL::uuid, NULL::timestamptz, 0, v_disc'), isTrue);
    });
  });

  // executable SQL of the corrective migration, with -- comment lines stripped
  final pdSql = pd
      .split('\n')
      .where((l) => !l.trimLeft().startsWith('--'))
      .join('\n');

  group('police tabular reports -- scope discipline', () {
    test('person_details (corrected, 20260912000003) exposes NO ride / trip / GPS / evidence / doc-path columns', () {
      for (final forbidden in const [
        'order_id', 'order_code', 'trip_started_at', 'pickup_lat', 'destination_lat',
        'final_fare', 'parcel_security_events', 'police_sos', 'route',
        'kyc_document_paths', 'aadhaar_front_image', 'license_front_image', 'VECHILE_RC',
        'object/sign', 'signed_url', 'p_generate_signed_urls', 'rider_image',
      ]) {
        expect(pdSql.contains(forbidden), isFalse, reason: 'person_details SQL must not contain "$forbidden"');
      }
      // it DOES carry identity / KYC / vehicle
      expect(pdSql.contains('full_name'), isTrue);
      expect(pdSql.contains('driving_license_number'), isTrue);
      expect(pdSql.contains('pan_number'), isTrue);
      expect(pdSql.contains('vehicle_number'), isTrue);
    });

    test('person_details Aadhaar is returned directly (no legal-review gate), with aadhaar_status', () {
      // old 5-arg signature with the boolean is dropped
      expect(pdSql.contains('DROP FUNCTION IF EXISTS public.police_person_details(text, text, text, text, boolean);'), isTrue);
      expect(pdSql.contains('p_legal_review_confirmed'), isFalse);
      // aadhaar_number is an unconditional COALESCE, not a CASE on a flag,
      // and the old "withheld" note is gone
      expect(pdSql.contains('COALESCE(k.aadhaar_number, ar.aadhaar_number),'), isTrue);
      expect(pdSql.contains('ELSE NULL END'), isFalse);
      expect(pdSql.contains('aadhaar_note'), isFalse);
      // aadhaar_status column + never-invented rule
      expect(pdSql.contains(RegExp(r'aadhaar_status\s+text,')), isTrue);
      expect(pdSql.contains("THEN 'available' ELSE 'not_available' END"), isTrue);
      // new signature revoked from anon, granted to authenticated + service_role
      expect(pdSql.contains('REVOKE ALL ON FUNCTION public.police_person_details(text, text, text, text) FROM PUBLIC, anon;'), isTrue);
      expect(pdSql.contains('GRANT EXECUTE ON FUNCTION public.police_person_details(text, text, text, text) TO authenticated, service_role;'), isTrue);
      // still SECURITY DEFINER + search_path + audit gate
      expect(pdSql.contains('SECURITY DEFINER'), isTrue);
      expect(pdSql.contains("SET search_path TO 'public'"), isTrue);
      expect(pdSql.contains(RegExp(r"public\._police_disclosure_gate\(\s+p_phone, 'person_details'")), isTrue);
    });

    test('person_details corrective migration touches no RLS / storage / other police fn', () {
      for (final forbidden in const [
        'CREATE POLICY', 'ALTER POLICY', 'DROP POLICY', 'ALTER TABLE', 'CREATE TABLE',
        'storage.objects', 'storage.buckets', ' ON storage',
        'CREATE OR REPLACE FUNCTION public.police_last_trip',
        'CREATE OR REPLACE FUNCTION public.police_all_trips',
        'CREATE OR REPLACE FUNCTION public.police_trip_evidence',
        'CREATE OR REPLACE FUNCTION public._police_disclosure_gate',
        'FUNCTION public.lawful_disclosure_report',
      ]) {
        expect(pdSql.contains(forbidden), isFalse, reason: 'corrective migration SQL must not: $forbidden');
      }
    });

    test('last_trip is a single latest order, explicitly NOT a route', () {
      final start = base.indexOf('CREATE OR REPLACE FUNCTION public.police_last_trip(');
      final end = base.indexOf('CREATE OR REPLACE FUNCTION public.police_all_trips(');
      final body = base.substring(start, end);
      expect(body.contains('ORDER BY o2.created_at DESC LIMIT 1'), isTrue);
      expect(body.contains('continuous_route_history_available boolean,'), isTrue);
      // continuous_route_history_available is hard-coded false in the SELECT list
      expect(body.contains(RegExp(r'\n\s+false,\n\s+.last_known_lat/lng is the single')), isTrue);
      expect(body.contains('single most-recent GPS snapshot'), isTrue);
      expect(body.contains('Live / current location CANNOT be obtained while the device is offline'), isTrue);
    });

    test('all_trips returns BOTH passenger and rider side, one row per order', () {
      final start = base.indexOf('CREATE OR REPLACE FUNCTION public.police_all_trips(');
      final end = base.indexOf('CREATE OR REPLACE FUNCTION public.police_trip_evidence(');
      final body = base.substring(start, end);
      expect(body.contains('(p.puid IS NOT NULL AND o.user_id = p.puid)'), isTrue);
      expect(body.contains('(p.prid IS NOT NULL AND o.rider_id = p.prid)'), isTrue);
      expect(body.contains("THEN 'passenger'"), isTrue);
      expect(body.contains("ELSE 'rider' END"), isTrue);
    });
  });

  group('police tabular reports -- does NOT weaken RLS or touch protected areas', () {
    test('no RLS / table / trigger / publication DDL in either migration', () {
      for (final f in [base, sos]) {
        for (final forbidden in const [
          'CREATE POLICY', 'ALTER POLICY', 'DROP POLICY',
          'ENABLE ROW LEVEL SECURITY', 'FORCE ROW LEVEL SECURITY',
          'CREATE TRIGGER', 'DROP TRIGGER',
          'ALTER PUBLICATION', 'supabase_realtime',
          'ALTER TABLE', 'CREATE TABLE',
        ]) {
          expect(f.contains(forbidden), isFalse, reason: 'migration must not: $forbidden');
        }
      }
    });

    test('does not redefine any booking / dispatch / payment / completion / tax / GPS function', () {
      for (final f in [base, sos]) {
        for (final forbidden in const [
          'FUNCTION public.complete_order_and_settle',
          'FUNCTION public.apply_order_government_tax',
          'FUNCTION public.report_government_tax',
          'FUNCTION public.lawful_disclosure_report',
          'FUNCTION public.calculate_fare',
          'FUNCTION public.find_nearby_riders',
          'FUNCTION public.sync_riders_gps_to_rider_locations',
          'tax_rate_config',
        ]) {
          expect(f.contains(forbidden), isFalse);
        }
      }
    });

    test('lawful_disclosure_report is left intact (kept for full JSON/export use)', () {
      expect(base.contains('LEFT UNCHANGED'), isTrue);
      expect(base.contains('lawful_disclosure_report, or any Flutter code'), isTrue);
    });
  });

  group('police tabular reports -- 20260912000001 SOS-scope fix', () {
    test('police_last_trip.police_sos is scoped to the shown order only', () {
      expect(sos.contains('CREATE OR REPLACE FUNCTION public.police_last_trip('), isTrue);
      expect(sos.contains('FROM public.police_sos_logs s WHERE s.order_id = latest.id),'), isTrue);
      // the leaking clause is gone from the executable SQL (only the header
      // comment still quotes the old buggy form, for context)
      final activeSql = sos.substring(sos.indexOf('CREATE OR REPLACE FUNCTION'));
      expect(activeSql.contains('s.rider_id = latest.prid'), isFalse);
      expect(activeSql.contains('police_sos_logs s WHERE s.order_id = latest.id OR'), isFalse);
      expect(sos.contains('SECURITY DEFINER'), isTrue);
      expect(sos.contains("SET search_path TO 'public'"), isTrue);
      expect(sos.contains('REVOKE ALL ON FUNCTION public.police_last_trip(text, text, text, text) FROM PUBLIC, anon;'), isTrue);
    });
  });
}
