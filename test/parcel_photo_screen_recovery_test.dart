import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:waydrop/features/local_parcels/booking/screens/parcel_details_screen.dart';
import 'package:waydrop/features/intercity/parcels/booking/intercity_details_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late File photo;
  final remote = <String, Uint8List>{};
  var fail = true;
  var posts = 0;
  var pricingCalls = 0;
  Completer<void>? gate;
  String encode(Object v) =>
      base64Url.encode(utf8.encode(jsonEncode(v))).replaceAll('=', '');
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    dir = await Directory.systemTemp.createTemp('waydrop-photo-widget-');
    photo = await File('${dir.path}/synthetic.png').writeAsBytes(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGMQVDIGAACuAGcVHqFfAAAAAElFTkSuQmCC',
      ),
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/image_picker'),
          (call) async =>
              call.method == 'pickMultiImage' ? [photo.path] : photo.path,
        );
    await Supabase.initialize(
      url: 'https://example.supabase.co',
      anonKey: 'synthetic-public',
      authOptions: const FlutterAuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((r) async {
        if (r.url.path.endsWith('/calculate-order-pricing')) {
          pricingCalls++;
          return http.Response(
            jsonEncode({
              'pricing': {'final_fare': 42},
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (r.url.path.endsWith('/token')) {
          return http.Response(
            jsonEncode({
              'access_token':
                  '${encode({'alg': 'HS256', 'typ': 'JWT'})}.${encode({'sub': '00000000-0000-4000-8000-000000000311', 'role': 'authenticated', 'exp': DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000})}.synthetic',
              'refresh_token': 'synthetic',
              'expires_in': 3600,
              'token_type': 'bearer',
              'user': {
                'id': '00000000-0000-4000-8000-000000000311',
                'aud': 'authenticated',
                'created_at': '2026-01-01T00:00:00Z',
                'app_metadata': {},
                'user_metadata': {},
              },
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (!r.url.path.contains('/object/parcel_images/')) {
          return http.Response(
            '[]',
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (r.method == 'GET') {
          final bytes = remote[r.url.path];
          return bytes == null
              ? http.Response('missing', 404)
              : http.Response.bytes(bytes, 200);
        }
        posts++;
        await gate?.future;
        if (fail) return http.Response('<html>gateway timeout</html>', 504);
        remote[r.url.path] = await photo.readAsBytes();
        return http.Response(jsonEncode({'Key': r.url.path}), 200);
      }),
    );
    await Supabase.instance.client.auth.setSession('synthetic');
  });
  setUp(() {
    remote.clear();
    fail = true;
    posts = 0;
    pricingCalls = 0;
    gate = null;
  });
  tearDownAll(() async {
    await Supabase.instance.dispose();
    await dir.delete(recursive: true);
  });
  Future<void> flush(WidgetTester tester) async {
    for (var i = 0; i < 3; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pump();
    }
  }

  testWidgets(
    'parcel specifications do not fetch a fare that is never displayed',
    (tester) async {
      try {
        await tester.pumpWidget(
          const MaterialApp(
            home: ParcelDetailsScreen(
              orderType: 'local_parcel',
              pickupAddress: 'Synthetic pickup',
              destinationAddress: 'Synthetic drop',
              pickupLat: 17.1,
              pickupLng: 78.1,
              destinationLat: 17.2,
              destinationLng: 78.2,
              totalDistanceMeters: 1000,
            ),
          ),
        );
        await flush(tester);
        expect(pricingCalls, 0);
      } finally {
        await tester.pump(const Duration(seconds: 1));
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 1));
      }
    },
  );
  for (final intercity in [false, true]) {
    final label = intercity ? 'intercity' : 'local';
    Widget screen() => intercity
        ? const IntercityDetailsScreen(orderType: 'intercity_parcel')
        : const ParcelDetailsScreen(orderType: 'local_parcel');
    Future<void> pick(WidgetTester tester) async {
      await tester.pumpWidget(MaterialApp(home: screen()));
      await flush(tester);
      await tester.ensureVisible(find.byIcon(Icons.photo_library_rounded));
      // Start real file I/O outside the widget fake-time zone.
      await tester.runAsync(() async {
        await tester.tap(find.byIcon(Icons.photo_library_rounded));
        await Future<void>.delayed(const Duration(milliseconds: 80));
      });
      await flush(tester);
    }

    testWidgets(
      '$label keeps uncertain photo and explicitly retries same selection',
      (tester) async {
        tester.view.physicalSize = const Size(1080, 2400);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await pick(tester);
        expect(
          posts,
          1,
          reason: tester
              .widgetList<Text>(find.byType(Text))
              .map((t) => t.data)
              .join(' | '),
        );
        expect(find.text('1 / 5 photos'), findsOneWidget);
        expect(find.text('Check / retry photos'), findsOneWidget);
        fail = false;
        await tester.ensureVisible(find.text('Check / retry photos'));
        await tester.runAsync(() async {
          await tester.tap(find.text('Check / retry photos'));
          await Future<void>.delayed(const Duration(milliseconds: 80));
        });
        await flush(tester);
        expect(posts, 2);
        expect(remote.length, 1);
        expect(find.text('1 / 5 photos'), findsOneWidget);
        expect(find.text('Check / retry photos'), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 5));
      },
    );
    testWidgets('$label late upload failure after disposal never sets State', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      gate = Completer<void>();
      try {
        await pick(tester);
        expect(posts, 1);
        await tester.pumpWidget(const SizedBox.shrink());
        gate!.complete();
        await flush(tester);
        expect(tester.takeException(), isNull);
      } finally {
        if (!gate!.isCompleted) gate!.complete();
        await flush(tester);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    });
  }
}
