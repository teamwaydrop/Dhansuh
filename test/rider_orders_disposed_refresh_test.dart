import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:waydrop/core/services/location/location_cache_service.dart';
import 'package:waydrop/features/rider/orders/rider_orders_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final disposeAt in ['configuration', 'assignments']) {
  testWidgets('Orders disposal during $disposeAt prevents queued/future assignment reads', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final channels = [
      'xyz.luan/audioplayers', 'xyz.luan/audioplayers.global',
      'xyz.luan/audioplayers.global/events',
      'com.llfbandit.app_links/messages', 'com.llfbandit.app_links/events',
    ];
    for (final channel in channels) {
      messenger.setMockMethodCallHandler(MethodChannel(channel), (_) async => null);
    }
    final assignmentStarted = Completer<void>();
    final assignmentResponse = Completer<http.Response>();
    final configStarted = Completer<void>();
    final configReleased = Completer<void>();
    var assignmentReads = 0;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/dispatch_config')) {
        configStarted.complete();
        if (disposeAt == 'configuration') await configReleased.future;
        return http.Response('{"max_search_duration_sec":900}', 200,
            headers: {'content-type': 'application/json'}, request: request);
      }
      if (request.url.path.endsWith('/rider_assignments')) {
        assignmentReads++;
        if (!assignmentStarted.isCompleted) assignmentStarted.complete();
        final response = await assignmentResponse.future;
        return http.Response(response.body, response.statusCode,
            headers: response.headers, request: request);
      }
      throw StateError('Unexpected local mock request');
    });
    await tester.runAsync(() => Supabase.initialize(
        url: 'http://127.0.0.1:1', anonKey: 'synthetic-local-key', httpClient: client,
        authOptions: const FlutterAuthClientOptions(autoRefreshToken: false))
        .timeout(const Duration(seconds: 10)));
    final oldPosition = LocationCacheService.cachedPosition;
    final oldUpdated = LocationCacheService.lastUpdated;
    LocationCacheService.cachedPosition = Position(latitude: 0, longitude: 0,
        timestamp: DateTime.now(), accuracy: 1, altitude: 0, altitudeAccuracy: 1,
        heading: 0, headingAccuracy: 1, speed: 0, speedAccuracy: 1);
    LocationCacheService.lastUpdated = DateTime.now();
    addTearDown(() async {
      if (!configReleased.isCompleted) configReleased.complete();
      if (!assignmentResponse.isCompleted) {
        assignmentResponse.complete(http.Response('[]', 200,
            headers: {'content-type': 'application/json'}));
      }
      await Supabase.instance.dispose();
      client.close();
      LocationCacheService.cachedPosition = oldPosition;
      LocationCacheService.lastUpdated = oldUpdated;
      for (final channel in channels) {
        messenger.setMockMethodCallHandler(MethodChannel(channel), null);
      }
    });
    await tester.pumpWidget(const MaterialApp(home: RiderOrdersScreen(
        riderId: 'synthetic-rider', vehicleType: 'bike')));
    await tester.pump();
    expect(disposeAt == 'configuration' ? configStarted.isCompleted : assignmentStarted.isCompleted, isTrue);
    final dynamic state = tester.state(find.byType(RiderOrdersScreen));
    await state.fetchSearchingOrders(); // Queue behind the actual initial handler.
    await tester.pumpWidget(const SizedBox());
    if (!configReleased.isCompleted) configReleased.complete();
    assignmentResponse.complete(http.Response('[]', 200,
        headers: {'content-type': 'application/json'}));
    await tester.pump();
    await state.fetchSearchingOrders(); // An external late trigger must also stop.
    await tester.pump();
    expect(assignmentReads, disposeAt == 'configuration' ? 0 : 1);
    expect(tester.takeException(), isNull);
  }, timeout: const Timeout(Duration(seconds: 30)));
  }
}
