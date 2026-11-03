import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:waydrop/core/services/location/serviceability_service.dart';
import 'package:waydrop/features/local_rides/booking/screens/ride_location_screen.dart';
import 'package:waydrop/shared/widgets/states/vehicle_pricing_skeleton_card.dart';
import 'package:waydrop/modules/payments/controllers/pricing_controller.dart';
import 'package:waydrop/core/services/maps/ola_map_service.dart';
import 'package:dio/dio.dart' as dio;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const uid = '00000000-0000-4000-8000-000000000811';
  final gates = <String, Completer<void>>{};
  final calls = <Map<String, dynamic>>[];
  final statuses = <String, int>{};
  Completer<void>? promoGate;
  var promoCalls = 0;
  Object fare = 37;
  String encode(Object v) =>
      base64Url.encode(utf8.encode(jsonEncode(v))).replaceAll('=', '');
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'https://example.supabase.co',
      anonKey: 'synthetic-public',
      authOptions: const FlutterAuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((r) async {
        http.Response reply(Object v, int status) => http.Response(
          jsonEncode(v),
          status,
          request: r,
          headers: {'content-type': 'application/json'},
        );
        if (r.url.path.endsWith('/token'))
          return reply({
            'access_token':
                '${encode({'alg': 'HS256', 'typ': 'JWT'})}.${encode({'sub': uid, 'role': 'authenticated', 'exp': DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000})}.synthetic',
            'refresh_token': 'synthetic',
            'expires_in': 3600,
            'token_type': 'bearer',
            'user': {
              'id': uid,
              'aud': 'authenticated',
              'created_at': '2026-01-01T00:00:00Z',
              'app_metadata': {},
              'user_metadata': {},
            },
          }, 200);
        if (r.url.path.endsWith('/pricing_zones'))
          return reply([
            {
              'id': 'synthetic-zone',
              'zone_code': 'SYNTHETIC',
              'zone_name': 'Synthetic',
              'center_lat': 0,
              'center_lng': 0,
              'radius_km': 100,
              'cities': ['Synthetic'],
            },
          ], 200);
        if (r.url.path.endsWith('/calculate-order-pricing')) {
          final body = Map<String, dynamic>.from(jsonDecode(r.body));
          calls.add(body);
          final vehicle = body['vehicle_type'] as String;
          await gates[vehicle]?.future;
          final status = statuses[vehicle] ?? 200;
          return reply(
            status == 200
                ? {
                    'pricing': {
                      'final_fare': fare,
                      'base_fare': 35.24,
                      'gst_amount': 1.76,
                      'gst_percent': 5,
                      'vehicle_type': vehicle,
                      'config_id': 'synthetic-config',
                    },
                  }
                : {'message': 'synthetic unavailable'},
            status,
          );
        }
        if (r.url.path.endsWith('/validate_and_calculate_promo')) {
          promoCalls++;
          await promoGate?.future;
          return reply({'success': true, 'discount_amount': 5.0}, 200);
        }
        return reply([], 200);
      }),
    );
    await Supabase.instance.client.auth.setSession('synthetic-refresh');
    await ServiceabilityService.loadActiveZones(forceRefresh: true);
  });
  setUp(() {
    fare = 37;
    promoGate = null;
    promoCalls = 0;
    gates.clear();
    calls.clear();
    statuses.clear();
    for (final v in ['bike', 'auto', 'cab']) {
      gates[v] = Completer<void>();
    }
  });
  tearDownAll(() => Supabase.instance.dispose());
  Future<void> flush(WidgetTester t) async {
    await t.pump(const Duration(milliseconds: 1));
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await t.pump();
  }

  Future<void> settleReplies(WidgetTester t) async {
    for (var n = 0; n < 12; n++) {
      await flush(t);
    }
  }

  Future<void> reveal(WidgetTester t, String label) async {
    final view = t.widget<ListView>(
      find
          .descendant(
            of: find.byType(DraggableScrollableSheet),
            matching: find.byType(ListView),
          )
          .first,
    );
    final controller = view.controller!;
    for (
      double offset = 0;
      offset <= controller.position.maxScrollExtent + 150;
      offset += 150
    ) {
      if (find.text(label).evaluate().isNotEmpty) break;
      controller.jumpTo(offset.clamp(0, controller.position.maxScrollExtent));
      await t.pump();
    }
    await t.ensureVisible(find.text(label));
    await t.pump();
  }

  Future<dynamic> open(WidgetTester t) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    t.view.physicalSize = const Size(430, 1000);
    t.view.devicePixelRatio = 1;
    await t.pumpWidget(
      const MaterialApp(
        home: RideLocationScreen(
          prefillPickupAddress: 'Synthetic pickup',
          prefillPickupLat: 0,
          prefillPickupLng: 0,
        ),
      ),
    );
    await t.pump();
    final dynamic state = t.state(find.byType(RideLocationScreen));
    // Existing quote tests start after route resolution. Initial prefilled
    // navigation is exercised separately, without seeding distance.
    state.destinationController.text = 'Synthetic drop';
    state.destinationLat = 0.0;
    state.destinationLng = .01;
    state.distanceMeters = 1000.0;
    state.durationSeconds = 120.0;
    await state.continueFlow();
    await t.pump(const Duration(milliseconds: 150));
    for (var n = 0; n < 20 && calls.length < 3; n++) {
      await flush(t);
    }
    for (var n = 0; n < 4; n++) {
      final view = t.widget<ListView>(
        find
            .descendant(
              of: find.byType(DraggableScrollableSheet),
              matching: find.byType(ListView),
            )
            .first,
      );
      if (view.controller!.hasClients)
        view.controller!.jumpTo(view.controller!.position.maxScrollExtent);
      await t.pump();
    }
    return state;
  }

  Future<void> close(WidgetTester t) async {
    if (promoGate != null && !promoGate!.isCompleted) promoGate!.complete();
    for (final g in gates.values) {
      if (!g.isCompleted) g.complete();
    }
    for (var n = 0; n < 20; n++) {
      await flush(t);
    }
    await t.pumpWidget(const SizedBox.shrink());
    await t.pump();
    t.view.resetPhysicalSize();
    t.view.resetDevicePixelRatio();
    debugDefaultTargetPlatformOverride = null;
  }

  ElevatedButton book(WidgetTester t) => t.widget<ElevatedButton>(
    find.widgetWithText(ElevatedButton, 'Book Ride Now'),
  );
  test(
    'controlled wall-clock first-quote latency: batch versus progressive',
    () async {
      final measurements = <String, Object>{
        'scope':
            'mocked HTTP; pricing request to first published Auto quote; not Android or production timing',
        'injected_auto_ms': 100,
        'injected_other_ms': 700,
      };
      for (final progressive in [false, true]) {
        calls.clear();
        for (final v in gates.keys.toList()) {
          gates[v] = Completer<void>();
        }
        final controller = PricingController();
        final watch = Stopwatch()..start();
        int? first;
        controller.addListener(() {
          if (controller.pricingData.containsKey('auto'))
            first ??= watch.elapsedMilliseconds;
        });
        final pending = controller.fetchMultiplePricing(
          orderType: 'ride',
          distanceKm: 1,
          pickupAddress: 'Synthetic pickup',
          maxBoostAmount: 0,
          pickupLat: 0,
          pickupLng: 0,
          publishAsReady: progressive,
        );
        final timers = [
          Timer(
            const Duration(milliseconds: 100),
            () => gates['auto']!.complete(),
          ),
          Timer(const Duration(milliseconds: 700), () {
            gates['bike']!.complete();
            gates['cab']!.complete();
          }),
        ];
        try {
          await pending;
          expect(calls.length, 3);
          expect(first, isNotNull);
          measurements[progressive ? 'after_ms' : 'before_ms'] = first!;
        } finally {
          for (final timer in timers) {
            timer.cancel();
          }
          controller.dispose();
        }
      }
      expect(
        measurements['after_ms'] as int,
        lessThan(measurements['before_ms'] as int),
      );
      // Opt-in export keeps normal test runs free of repository mutations.
      if (const bool.fromEnvironment('WAYDROP_CHOOSE_TIMINGS')) {
        File(
          'docs/performance/choose-route-20261103/CONTROLLED_TIMING.json',
        ).writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert(measurements),
        );
      }
      // ignore: avoid_print
      print('CHOOSE_ROUTE_CONTROLLED ${jsonEncode(measurements)}');
    },
  );
  testWidgets(
    'Auto quote is selectable before unrelated bike/cab requests settle',
    (t) async {
      try {
        await open(t);
        expect(calls.length, 3);
        expect(book(t).onPressed, isNull);
        gates['auto']!.complete();
        for (var n = 0; n < 10; n++) {
          await flush(t);
        }
        expect(find.text('Auto'), findsOneWidget);
        expect(book(t).onPressed, isNotNull);
        expect(gates['bike']!.isCompleted, isFalse);
        expect(gates['cab']!.isCompleted, isFalse);
      } finally {
        await close(t);
      }
    },
  );
  testWidgets('all failed quotes end skeleton and expose explicit Retry', (
    t,
  ) async {
    try {
      await open(t);
      for (final v in gates.keys) {
        statuses[v] = 503;
        gates[v]!.complete();
      }
      for (var n = 0; n < 10; n++) {
        await flush(t);
      }
      expect(find.byType(VehiclePricingSkeletonCard), findsNothing);
      expect(find.text('Retry pricing'), findsOneWidget);
      expect(book(t).onPressed, isNull);
    } finally {
      await close(t);
    }
  });

  testWidgets(
    'late Bike cannot replace selected Auto; GST stays server supplied',
    (t) async {
      try {
        final dynamic state = await open(t);
        gates['auto']!.complete();
        await settleReplies(t);
        expect(state.selectedVehicle, 'auto');
        expect(find.text('incl. GST'), findsOneWidget);
        expect(state.pricingController.pricingData['auto']['final_fare'], 37);
        expect(state.pricingController.pricingData['auto']['gst_amount'], 1.76);
        gates['bike']!.complete();
        await settleReplies(t);
        expect(state.selectedVehicle, 'auto');
        expect(book(t).onPressed, isNotNull);
      } finally {
        await close(t);
      }
    },
  );

  testWidgets(
    '15 second timeout ends loading; retry shares pending transports',
    (t) async {
      try {
        await open(t);
        await t.pump(const Duration(seconds: 16));
        await settleReplies(t);
        expect(find.text('Retry pricing'), findsOneWidget);
        await t.tap(find.text('Retry pricing'));
        await settleReplies(t);
        expect(calls.length, 3);
        gates['auto']!.complete();
        await settleReplies(t);
        expect(book(t).onPressed, isNotNull);
      } finally {
        await close(t);
      }
    },
  );

  testWidgets(
    'settled failures allow one explicit fresh retry, without automatic loop',
    (t) async {
      try {
        await open(t);
        for (final v in gates.keys) {
          statuses[v] = 503;
          gates[v]!.complete();
        }
        await settleReplies(t);
        expect(calls.length, 3);
        await t.pump(const Duration(seconds: 1));
        expect(calls.length, 3);
        statuses.clear();
        for (final v in gates.keys.toList()) {
          gates[v] = Completer<void>();
        }
        await t.tap(find.text('Retry pricing'));
        await settleReplies(t);
        expect(calls.length, 6);
        gates['auto']!.complete();
        await settleReplies(t);
        expect(book(t).onPressed, isNotNull);
      } finally {
        await close(t);
      }
    },
  );

  testWidgets('rebuild and Cash/UPI changes do not restart pricing', (t) async {
    try {
      final dynamic state = await open(t);
      gates['auto']!.complete();
      await settleReplies(t);
      state.setState(() {});
      await settleReplies(t);
      expect(calls.length, 3);
      // Real payment-chip gestures. They only change the booking payment mode.
      await reveal(t, 'Pay via UPI');
      await t.tap(find.text('Pay via UPI'));
      await settleReplies(t);
      expect(state.paymentMode, 'online');
      await reveal(t, 'Pay via Cash');
      await t.tap(find.text('Pay via Cash'));
      await settleReplies(t);
      expect(state.paymentMode, 'cash');
      expect(calls.length, 3);
    } finally {
      await close(t);
    }
  });

  testWidgets(
    'changed coordinates cannot display or book an old pending quote',
    (t) async {
      try {
        final dynamic state = await open(t);
        state.setState(() {
          state.destinationLng = .02;
        });
        gates['auto']!.complete();
        await settleReplies(t);
        expect(find.text('Auto'), findsNothing);
        expect(book(t).onPressed, isNull);
      } finally {
        await close(t);
      }
    },
  );

  testWidgets(
    'disposing a screen while requests are pending rejects late replies',
    (t) async {
      try {
        await open(t);
        await t.pumpWidget(const SizedBox.shrink());
        for (final g in gates.values) {
          g.complete();
        }
        await settleReplies(t);
        expect(t.takeException(), isNull);
      } finally {
        await close(t);
      }
    },
  );

  testWidgets(
    'older directions finishing last cannot replace newer coordinates or distance',
    (t) async {
      final oldRoute = Completer<void>(), newRoute = Completer<void>();
      var routeCalls = 0;
      final interceptor = dio.InterceptorsWrapper(
        onRequest: (r, h) async {
          if (r.path.contains('/details')) {
            final newer = r.queryParameters['place_id'] == 'route-new';
            h.resolve(
              dio.Response(
                requestOptions: r,
                statusCode: 200,
                data: {
                  'result': {
                    'geometry': {
                      'location': {'lat': 0.0, 'lng': newer ? 0.03 : 0.02},
                    },
                  },
                },
              ),
            );
          } else if (r.path.contains('/directions')) {
            routeCalls++;
            final newer = r.queryParameters['destination'] == '0.0,0.03';
            await (newer ? newRoute : oldRoute).future;
            h.resolve(
              dio.Response(
                requestOptions: r,
                statusCode: 200,
                data: {
                  'routes': [
                    {
                      'legs': [
                        {'distance': newer ? 2000 : 1500, 'duration': 120},
                      ],
                      'overview_polyline': '_p~iF~ps|U_ulLnnqC_mqNvxq`@',
                    },
                  ],
                },
              ),
            );
          } else {
            h.reject(
              dio.DioException(
                requestOptions: r,
                error: 'Unexpected mock endpoint',
              ),
            );
          }
        },
      );
      OlaMapService.clearCaches();
      OlaMapService.dio.interceptors.add(interceptor);
      try {
        final dynamic state = await open(t);
        late Future<void> older;
        await t.runAsync(() async {
          older = state.selectDestination({
            'description': 'Old drop',
            'place_id': 'route-old',
          });
          await Future<void>.delayed(const Duration(milliseconds: 20));
        });
        await settleReplies(t);
        expect(state.distanceMeters, 0);
        expect(book(t).onPressed, isNull);
        late Future<void> newer;
        await t.runAsync(() async {
          newer = state.selectDestination({
            'description': 'New drop',
            'place_id': 'route-new',
          });
          await Future<void>.delayed(const Duration(milliseconds: 20));
        });
        await settleReplies(t);
        expect(routeCalls, 2);
        await t.runAsync(() async {
          newRoute.complete();
          await newer.timeout(const Duration(seconds: 3));
        });
        await settleReplies(t);
        expect(state.destinationLng, .03);
        expect(state.distanceMeters, 2000);
        await t.runAsync(() async {
          oldRoute.complete();
          await older.timeout(const Duration(seconds: 3));
        });
        await settleReplies(t);
        expect(state.distanceMeters, 2000);
        expect(state.destinationLng, .03);
        expect(calls.where((b) => b['distance_km'] == 1.5), isEmpty);
        expect(calls.where((b) => b['distance_km'] == 2).length, 3);
        gates['auto']!.complete();
        await settleReplies(t);
        expect(book(t).onPressed, isNotNull);
      } finally {
        if (!oldRoute.isCompleted) oldRoute.complete();
        if (!newRoute.isCompleted) newRoute.complete();
        await settleReplies(t);
        OlaMapService.dio.interceptors.remove(interceptor);
        OlaMapService.clearCaches();
        await close(t);
      }
    },
  );

  testWidgets(
    'failed directions cannot retry pricing with the previous distance',
    (t) async {
      final interceptor = dio.InterceptorsWrapper(
        onRequest: (r, h) {
          h.resolve(
            dio.Response(
              requestOptions: r,
              statusCode: 200,
              data: r.path.contains('/details')
                  ? {
                      'result': {
                        'geometry': {
                          'location': {'lat': 0.0, 'lng': .04},
                        },
                      },
                    }
                  : {'routes': []},
            ),
          );
        },
      );
      OlaMapService.clearCaches();
      OlaMapService.dio.interceptors.add(interceptor);
      try {
        final dynamic state = await open(t);
        await t.runAsync(() async {
          await state.selectDestination({
            'description': 'Failed drop',
            'place_id': 'route-failed',
          });
        });
        await settleReplies(t);
        expect(state.distanceMeters, 0);
        expect(book(t).onPressed, isNull);
        expect(find.text('Retry route'), findsOneWidget);
        await t.tap(find.text('Retry route'));
        await settleReplies(t);
        expect(calls.length, 3);
        expect(state.distanceMeters, 0);
      } finally {
        OlaMapService.dio.interceptors.remove(interceptor);
        OlaMapService.clearCaches();
        await close(t);
      }
    },
  );
  for (final changeVehicle in [false, true]) {
    testWidgets(
      'promo result retains quote ownership (change vehicle: $changeVehicle)',
      (t) async {
        try {
          final dynamic state = await open(t);
          gates['auto']!.complete();
          await settleReplies(t);
          gates['bike']!.complete();
          await settleReplies(t);
          await reveal(t, 'Pay via UPI');
          state.setState(() {
            state.showPromoField = true;
          });
          await t.pump(const Duration(milliseconds: 250));
          final field = find.byWidgetPredicate(
            (w) =>
                w is TextField &&
                w.decoration?.hintText == 'Enter promo code...',
          );
          await t.ensureVisible(field);
          await t.enterText(field, 'TEST');
          promoGate = Completer<void>();
          await reveal(t, 'Apply');
          await t.pump(const Duration(milliseconds: 250));
          await t.tap(find.text('Apply'));
          await settleReplies(t);
          expect(promoCalls, 1);
          if (changeVehicle) {
            await reveal(t, 'Bike');
            await t.tap(find.text('Bike'));
            await settleReplies(t);
          }
          promoGate!.complete();
          await settleReplies(t);
          if (changeVehicle) {
            expect(find.text('TEST Applied'), findsNothing);
          } else {
            await reveal(t, 'TEST Applied');
            expect(find.text('TEST Applied'), findsOneWidget);
          }
        } finally {
          await close(t);
        }
      },
    );
  }
  testWidgets('malformed backend fare never enables booking', (t) async {
    try {
      fare = 'NaN';
      await open(t);
      for (final g in gates.values) {
        g.complete();
      }
      await settleReplies(t);
      expect(book(t).onPressed, isNull);
      expect(find.text('Retry pricing'), findsOneWidget);
    } finally {
      await close(t);
    }
  });

  testWidgets(
    'overlapping identical direction requests share one raw provider operation',
    (t) async {
      final gate = Completer<void>();
      var directions = 0;
      final interceptor = dio.InterceptorsWrapper(
        onRequest: (r, h) async {
          if (r.path.contains('/details')) {
            h.resolve(
              dio.Response(
                requestOptions: r,
                statusCode: 200,
                data: {
                  'result': {
                    'geometry': {
                      'location': {'lat': 0.0, 'lng': .05},
                    },
                  },
                },
              ),
            );
          } else {
            directions++;
            await gate.future;
            h.resolve(
              dio.Response(
                requestOptions: r,
                statusCode: 200,
                data: {
                  'routes': [
                    {
                      'legs': [
                        {'distance': 2000, 'duration': 120},
                      ],
                      'overview_polyline': '_p~iF~ps|U_ulLnnqC_mqNvxq`@',
                    },
                  ],
                },
              ),
            );
          }
        },
      );
      OlaMapService.clearCaches();
      OlaMapService.dio.interceptors.add(interceptor);
      try {
        final dynamic state = await open(t);
        late Future<void> first, second;
        await t.runAsync(() async {
          first = state.selectDestination({
            'description': 'Same drop',
            'place_id': 'route-same',
          });
          await Future<void>.delayed(const Duration(milliseconds: 25));
          second = state.selectDestination({
            'description': 'Same drop',
            'place_id': 'route-same',
          });
          await Future<void>.delayed(const Duration(milliseconds: 25));
        });
        expect(directions, 1);
        await t.runAsync(() async {
          gate.complete();
          await Future.wait([
            first,
            second,
          ]).timeout(const Duration(seconds: 3));
        });
        await settleReplies(t);
        expect(state.distanceMeters, 2000);
        expect(calls.where((b) => b['distance_km'] == 2).length, 3);
      } finally {
        if (!gate.isCompleted) gate.complete();
        await settleReplies(t);
        OlaMapService.dio.interceptors.remove(interceptor);
        OlaMapService.clearCaches();
        await close(t);
      }
    },
  );
  testWidgets(
    'prefilled route starts pricing without a WebView page-finished event',
    (t) async {
      var directions = 0;
      final interceptor = dio.InterceptorsWrapper(
        onRequest: (r, h) {
          directions++;
          h.resolve(
            dio.Response(
              requestOptions: r,
              statusCode: 200,
              data: {
                'routes': [
                  {
                    'legs': [
                      {'distance': 1000, 'duration': 120},
                    ],
                    'overview_polyline': '_p~iF~ps|U_ulLnnqC_mqNvxq`@',
                  },
                ],
              },
            ),
          );
        },
      );
      OlaMapService.clearCaches();
      OlaMapService.dio.interceptors.add(interceptor);
      try {
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        t.view.physicalSize = const Size(430, 1000);
        t.view.devicePixelRatio = 1;
        await t.pumpWidget(
          const MaterialApp(
            home: RideLocationScreen(
              prefillPickupAddress: 'Synthetic pickup',
              prefillPickupLat: 0,
              prefillPickupLng: 0,
              prefillDestinationAddress: 'Synthetic drop',
              prefillDestinationLat: 0,
              prefillDestinationLng: .01,
            ),
          ),
        );
        await settleReplies(t);
        expect(directions, 1);
        expect(calls.length, 3);
        final dynamic state = t.state(find.byType(RideLocationScreen));
        expect(state.distanceMeters, 1000);
        await state.handleMapReady();
        await state.handleMapReady();
        await settleReplies(t);
        expect(directions, 1);
        expect(calls.length, 3);
      } finally {
        OlaMapService.dio.interceptors.remove(interceptor);
        OlaMapService.clearCaches();
        await close(t);
      }
    },
  );
}
