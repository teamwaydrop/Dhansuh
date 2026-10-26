import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final screens = <String, String>{
    'local ride': _read(
      'lib/features/local_rides/searching/screens/ride_searching_screen.dart',
    ),
    'local parcel': _read(
      'lib/features/local_parcels/searching/screens/parcel_searching_screen.dart',
    ),
  };

  for (final entry in screens.entries) {
    group('${entry.key} nearby-rider request guard', () {
      final source = entry.value;
      final methodStart = source.indexOf('Future<void> loadNearbyRiders() async {');
      final methodEnd = source.indexOf('\n  //', methodStart);
      final method = source.substring(methodStart, methodEnd);

      test('drops overlapping triggers before starting network work', () {
        final guardCheck = method.indexOf('if (_nearbyRidersFetchInFlight) return;');
        final guardSet = method.indexOf('_nearbyRidersFetchInFlight = true;');
        final firstAwait = method.indexOf('await ');

        expect(guardCheck, greaterThanOrEqualTo(0));
        expect(guardSet, greaterThan(guardCheck));
        expect(firstAwait, greaterThan(guardSet));
      });

      test('releases the guard after success, failure, and early return', () {
        final tryIndex = method.indexOf('try {');
        final nullOrderReturn = method.indexOf('if (currentOrder == null) return;');
        final catchIndex = method.lastIndexOf('} catch (e) {');
        final finallyIndex = method.lastIndexOf('} finally {');
        final releaseIndex = method.lastIndexOf('_nearbyRidersFetchInFlight = false;');

        expect(tryIndex, greaterThanOrEqualTo(0));
        expect(nullOrderReturn, greaterThan(tryIndex));
        expect(catchIndex, greaterThan(nullOrderReturn));
        expect(finallyIndex, greaterThan(catchIndex));
        expect(releaseIndex, greaterThan(finallyIndex));
      });

      test('does not apply config or rider results after disposal', () {
        final configAwait = method.indexOf('final config = await DispatchConfigCache.get(');
        final configMountedCheck = method.indexOf('if (!mounted) return;', configAwait);
        final configAssignment = method.indexOf('_nearbyRiderRadiusKm = radius;');
        final rpcAwait = method.indexOf('final response = await supabase.rpc(');
        final resultMountedCheck = method.indexOf('if (!mounted) return;', rpcAwait);
        final riderAssignment = method.indexOf('nearbyRiders = rawRiders');

        expect(configAwait, greaterThanOrEqualTo(0));
        expect(configMountedCheck, greaterThan(configAwait));
        expect(configAssignment, greaterThan(configMountedCheck));
        expect(rpcAwait, greaterThan(configAssignment));
        expect(resultMountedCheck, greaterThan(rpcAwait));
        expect(riderAssignment, greaterThan(resultMountedCheck));
        expect(
          source.contains(
            'await loadNearbyRiders();\n    if (!mounted) return;\n    initializeMap();',
          ),
          isTrue,
        );
      });

      test('preserves the adaptive 5/10/20-second schedule', () {
        expect(
          source.contains(
            'if (elapsed < const Duration(seconds: 60)) return const Duration(seconds: 5);',
          ),
          isTrue,
        );
        expect(
          source.contains(
            'if (elapsed < const Duration(seconds: 180)) return const Duration(seconds: 10);',
          ),
          isTrue,
        );
        expect(source.contains('return const Duration(seconds: 20);'), isTrue);
      });
    });
  }
}
