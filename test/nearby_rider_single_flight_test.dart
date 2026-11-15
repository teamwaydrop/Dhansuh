import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:waydrop/core/services/network/single_flight_refresh.dart';

void main() {
  for (final guarded in [false, true]) {
    test(
      'actual SDK held read: ten refreshes ${guarded ? 'share one request' : 'overlap without guard (control)'}',
      () async {
        final release = Completer<void>();
        final started = Completer<void>();
        var calls = 0;
        var active = 0;
        var peak = 0;
        final client = SupabaseClient(
          'https://example.supabase.co',
          'synthetic-public-key',
          httpClient: MockClient((request) async {
            calls++;
            active++;
            if (active > peak) peak = active;
            if (calls == (guarded ? 1 : 10)) started.complete();
            try {
              await release.future;
              return http.Response('[]', 200, request: request);
            } finally {
              active--;
            }
          }),
        );
        final flight = SingleFlightRefresh();
        Future<void> query() async {
          await client
              .from('riders')
              .select('id')
              .eq('account_status', 'online');
        }

        final work = List.generate(
          10,
          (_) => guarded ? flight.run(query) : query(),
        );
        try {
          await started.future;
          expect(calls, guarded ? 1 : 10);
          expect(peak, guarded ? 1 : 10);
        } finally {
          release.complete();
          await Future.wait(work);
        }
        if (guarded) {
          await flight.run(query);
          expect(
            calls,
            2,
            reason: 'later timer ticks still refresh after completion',
          );
        }
        await client.dispose();
      },
    );
  }

  test(
    'failed and synchronously throwing work releases ownership without retry',
    () async {
      final flight = SingleFlightRefresh();
      var calls = 0;
      await expectLater(
        flight.run(() {
          calls++;
          throw StateError('synthetic failure');
        }),
        throwsStateError,
      );
      expect(calls, 1);
      await flight.run(() async {
        calls++;
      });
      expect(calls, 2);
    },
  );

  for (final path in [
    'lib/features/local_rides/booking/screens/ride_location_screen.dart',
    'lib/features/local_parcels/booking/screens/parcel_booking_screen.dart',
  ]) {
    test(
      '$path wires the shared guard and rejects stale/disposed map results',
      () {
        final source = File(path).readAsStringSync();
        final start = source.indexOf('Future<void> _fetchNearbyRiders()');
        final end = source.indexOf('Future<void> _updateRidersOnMap', start);
        final method = source.substring(start, end);
        expect(
          method,
          contains('return _nearbyRiderRefresh.run(_fetchNearbyRidersOnce);'),
        );
        expect(method, contains('if (!mounted'));
        // Invariant: the stale/disposed guard (pickupLat != originLat) must run
        // before nearbyRiders is committed. The commit is a plain assignment (no
        // setState) because nearbyRiders is never read in build() -- it is pushed
        // to the map via _updateRidersOnMap()/JS. See the [PERF] comment at the
        // assignment site.
        expect(
          method.indexOf('!= originLat'),
          lessThan(method.indexOf('nearbyRiders = riders')),
        );
        expect(method, contains('final originLat ='));
        expect(method, contains('final originLng ='));
        expect(method, contains("rider_kyc!riders_kyc_id_fkey(vehicle_type)"));
        expect(method, contains(".eq('account_status', 'online')"));
        expect(method, contains('const double radiusKm = 5.0'));
        expect(
          source.substring(
            end,
            source.indexOf('Future<void> _fetchPricing', end),
          ),
          contains('if (!mounted || !mapLoaded'),
        );
      },
    );
  }
}
