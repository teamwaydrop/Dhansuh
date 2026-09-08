// Functional regression test for the Intercity Parcel ₹0.00 fare fix (docs: this fixes
// calculate-order-pricing's calculateFare() not reading the `per_km_rate` key that the live
// intercity_parcel pricing_config rows are actually seeded with, and sets the authoritative rate
// to ₹2.50/km). Unlike the other regression tests in this repo, this one is a REAL functional
// test: it makes a live HTTP call to the deployed `calculate-order-pricing` edge function and
// asserts on its actual response, proving the deployed fix works end-to-end -- not just that the
// source contains an expected string. It is read-only (a pure pricing calculation, no DB write),
// so it's safe to run repeatedly against production.
//
// Requires a local `.env` (the same file `flutter run`/`flutter build` already need via
// --dart-define-from-file=.env) with SUPABASE_URL and SUPABASE_ANON_KEY. If that file isn't
// present (e.g. a bare CI checkout with secrets injected another way), the test is skipped rather
// than failed, since it has no other way to reach the deployed function.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

Map<String, String> _readDotEnv() {
  final file = File('.env');
  if (!file.existsSync()) return {};
  final values = <String, String>{};
  for (final rawLine in file.readAsLinesSync()) {
    final line = rawLine.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final eqIndex = line.indexOf('=');
    if (eqIndex <= 0) continue;
    final key = line.substring(0, eqIndex).trim();
    var value = line.substring(eqIndex + 1).trim();
    if (value.length >= 2 &&
        ((value.startsWith('"') && value.endsWith('"')) ||
            (value.startsWith("'") && value.endsWith("'")))) {
      value = value.substring(1, value.length - 1);
    }
    values[key] = value;
  }
  return values;
}

Future<Map<String, dynamic>?> _fetchPricing(
  String baseUrl,
  String anonKey, {
  required double distanceKm,
  String vehicleType = 'bike',
}) async {
  final uri = Uri.parse('$baseUrl/functions/v1/calculate-order-pricing');
  final response = await http.post(
    uri,
    headers: {
      'Content-Type': 'application/json',
      'apikey': anonKey,
      'Authorization': 'Bearer $anonKey',
    },
    body: jsonEncode({
      'order_type': 'intercity_parcel',
      'vehicle_type': vehicleType,
      'distance_km': distanceKm,
      'pickup_address': 'Warangal',
      // Real coordinates inside the live, active ZONE_WARANGAL pricing zone (center 17.9689,
      // 79.5941, radius 25km) -- confirmed via a direct read of the production pricing_zones
      // table, not guessed, so this test exercises the real zone-resolution path too.
      'pickup_lat': 17.9689,
      'pickup_lng': 79.5941,
    }),
  );
  if (response.statusCode != 200) return null;
  final decoded = jsonDecode(response.body);
  if (decoded is! Map || decoded['success'] != true) return null;
  return Map<String, dynamic>.from(decoded['pricing'] as Map);
}

void main() {
  final env = _readDotEnv();
  final baseUrl = env['SUPABASE_URL'] ?? '';
  final anonKey = env['SUPABASE_ANON_KEY'] ?? '';
  final hasEnv = baseUrl.isNotEmpty && anonKey.isNotEmpty;

  group('calculate-order-pricing (live): Intercity Parcel is ₹2.50/km, never ₹0.00', () {
    test('1. a 100km intercity_parcel route prices at ₹250 base (100 × ₹2.50), not ₹0.00', () async {
      if (!hasEnv) {
        markTestSkipped('.env with SUPABASE_URL/SUPABASE_ANON_KEY not present in this environment');
        return;
      }
      final pricing = await _fetchPricing(baseUrl, anonKey, distanceKm: 100);
      expect(pricing, isNotNull, reason: 'calculate-order-pricing did not return a usable pricing object');
      final baseFare = double.tryParse(pricing!['base_fare'].toString());
      final finalFare = double.tryParse(pricing['final_fare'].toString());
      final discountPercent = double.parse(pricing['discount_percentage'].toString());
      final gstPercent = double.parse(pricing['gst_percentage'].toString());
      expect(baseFare, isNotNull);
      expect(finalFare, isNotNull);
      expect(baseFare!, greaterThan(0), reason: 'This is exactly the ₹0.00 bug if it fails');
      expect(baseFare, closeTo(250.0, 0.01));
      // final_fare is derived from base_fare by the config's own discount then GST (boost is 0
      // here): final = base × (1 - discount%) × (1 + gst%). Assert against the response's own
      // percentages so this stays correct if the row's discount/GST is retuned later. (±1 for the
      // whole-rupee rounding the pricing engine applies once, at this point.)
      final expectedFinal = baseFare * (1 - discountPercent / 100) * (1 + gstPercent / 100);
      expect(finalFare!, closeTo(expectedFinal, 1.0));
    });

    test('2. the fare scales linearly with distance at exactly ₹2.50/km (proves it is not a fixed/coincidental value)', () async {
      if (!hasEnv) {
        markTestSkipped('.env with SUPABASE_URL/SUPABASE_ANON_KEY not present in this environment');
        return;
      }
      final pricing40 = await _fetchPricing(baseUrl, anonKey, distanceKm: 40);
      final pricing80 = await _fetchPricing(baseUrl, anonKey, distanceKm: 80);
      expect(pricing40, isNotNull);
      expect(pricing80, isNotNull);
      final base40 = double.parse(pricing40!['base_fare'].toString());
      final base80 = double.parse(pricing80!['base_fare'].toString());
      expect(base40, closeTo(100.0, 0.01)); // 40 * 2.5
      expect(base80, closeTo(200.0, 0.01)); // 80 * 2.5
      expect(base80 - base40, closeTo(base40, 0.01)); // doubling distance doubles the base fare
    });

    test('3. auto (a second vehicle type sharing the same rate) also prices correctly, not ₹0.00', () async {
      if (!hasEnv) {
        markTestSkipped('.env with SUPABASE_URL/SUPABASE_ANON_KEY not present in this environment');
        return;
      }
      final pricing60 = await _fetchPricing(baseUrl, anonKey, distanceKm: 60, vehicleType: 'auto');
      final pricing100 = await _fetchPricing(baseUrl, anonKey, distanceKm: 100, vehicleType: 'auto');
      expect(pricing60, isNotNull);
      expect(pricing100, isNotNull);
      expect(double.parse(pricing60!['base_fare'].toString()), closeTo(150.0, 0.01)); // 60 * 2.5
      expect(double.parse(pricing100!['base_fare'].toString()), closeTo(250.0, 0.01)); // 100 * 2.5
    });

    test('4. a non-integer-rupee distance keeps the exact ₹2.50/km rate (guards against the rate being rounded to a whole number)', () async {
      if (!hasEnv) {
        markTestSkipped('.env with SUPABASE_URL/SUPABASE_ANON_KEY not present in this environment');
        return;
      }
      // 33 * 2.50 = 82.50 exactly. A rate silently coerced to ₹2 or ₹3 would give 66 or 99.
      final pricing = await _fetchPricing(baseUrl, anonKey, distanceKm: 33);
      expect(pricing, isNotNull);
      expect(double.parse(pricing!['base_fare'].toString()), closeTo(82.50, 0.01));
    });
  });
}
