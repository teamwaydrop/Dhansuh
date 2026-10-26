import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:waydrop/features/rider/vehicles/screens/add_vehicle_screen.dart';
import 'package:waydrop/features/rider/vehicles/vehicle_submission.dart';

Future<void> _identity(String id) async {
  final exp = DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000;
  String encode(Map<String, Object> value) => base64UrlEncode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  await Supabase.instance.client.auth.recoverSession(jsonEncode({
    'access_token': '${encode({'alg': 'HS256', 'typ': 'JWT'})}.${encode({'sub': id, 'exp': exp, 'role': 'authenticated'})}.synthetic',
    'refresh_token': 'synthetic', 'token_type': 'bearer', 'expires_in': 3600,
    'user': {'id': id, 'aud': 'authenticated', 'app_metadata': {}, 'user_metadata': {}, 'created_at': '2026-10-14T00:00:00Z'},
  }));
}


void main() {
  for (final scenario in ['switch-upload', 'switch-insert', 'dispose', 'success', 'uncertain']) {
    testWidgets('actual Add Vehicle submission: $scenario', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const links = ['com.llfbandit.app_links/messages', 'com.llfbandit.app_links/events'];
      for (final name in links) { messenger.setMockMethodCallHandler(MethodChannel(name), (_) async => null); }
      final client = MockClient((request) async => throw StateError('No real API expected'));
      late Directory directory;
      late File image;
      await tester.runAsync(() async {
        await Supabase.initialize(url: 'http://127.0.0.1:1', anonKey: 'synthetic', httpClient: client,
          authOptions: const FlutterAuthClientOptions(autoRefreshToken: false));
        await _identity('A');
        directory = await Directory.systemTemp.createTemp('waydrop-synthetic-vehicle-');
        final recorder = ui.PictureRecorder();
        Canvas(recorder).drawColor(Colors.white, BlendMode.src);
        final picture = recorder.endRecording();
        final bitmap = await picture.toImage(1, 1);
        final bytes = await bitmap.toByteData(format: ui.ImageByteFormat.png);
        image = File('${directory.path}/synthetic.png');
        await image.writeAsBytes(bytes!.buffer.asUint8List());
        bitmap.dispose(); picture.dispose();
      });
      final uploadsReady = Completer<void>();
      final insertReady = Completer<void>();
      final uploadGate = Completer<void>();
      final insertGate = Completer<void>();
      var ownerReads = 0; var uploads = 0; var writes = 0;
      final ops = VehicleSubmission(
        ownsRider: (account, rider) async { ownerReads++; expectSync(account, 'A'); expectSync(rider, 'RA'); return true; },
        validate: (_) async {}, compress: (_) async => image,
        upload: (_, name, folder, current) async {
          uploads++; if (uploads == 3) uploadsReady.complete();
          await uploadGate.future; return '$folder/$name.jpg';
        }, insert: (row) async {
          writes++; expectSync(row['rider_id'], 'RA'); expectSync(row['vehicle_number'], 'SYNTHETIC');
          insertReady.complete(); await insertGate.future;
        });
      addTearDown(() async {
        if (!uploadGate.isCompleted) uploadGate.complete();
        if (!insertGate.isCompleted) insertGate.complete();
        await tester.runAsync(() async { await Supabase.instance.dispose(); await image.delete(); await directory.delete(); });
        client.close();
        for (final name in links) { messenger.setMockMethodCallHandler(MethodChannel(name), null); }
      });
      await tester.pumpWidget(ProviderScope(overrides: [vehicleSubmissionProvider.overrideWithValue(ops)],
        child: const MaterialApp(home: Scaffold(body: Text('Root')))));
      final navigator = tester.state<NavigatorState>(find.byType(Navigator).first);
      final result = navigator.push<bool>(MaterialPageRoute(builder: (_) => const AddVehicleScreen(riderId: 'RA')));
      await tester.pump(); await tester.pump(const Duration(milliseconds: 350));
      final state = tester.state(find.byType(AddVehicleScreen)) as dynamic;
      state.vehicleType = 'bike'; state.vehicleNumberController.text = 'synthetic';
      state.rcFront = XFile(image.path); state.rcBack = XFile(image.path); state.vehiclePhoto = XFile(image.path);
      final callback = tester.widget<ElevatedButton>(find.widgetWithText(ElevatedButton, 'SUBMIT FOR VERIFICATION')).onPressed!;
      callback(); callback(); // Even a saved button callback cannot double-submit.
      await tester.pump(); await uploadsReady.future;
      expect(ownerReads, 1); expect(uploads, 3); expect(writes, 0);
      if (scenario == 'switch-insert' || scenario == 'success' || scenario == 'uncertain') {
        uploadGate.complete(); await tester.pump(); await insertReady.future;
      }
      if (scenario.startsWith('switch')) {
        await tester.runAsync(() => _identity('B')); await tester.pump();
        await tester.runAsync(() => _identity('A')); await tester.pump();
        expect(find.text('Account changed. Return to My Vehicles to continue.'), findsOneWidget);
        callback(); expect(ownerReads, 1);
      } else if (scenario == 'dispose') {
        await tester.pumpWidget(const SizedBox());
      }
      if (!uploadGate.isCompleted) uploadGate.complete();
      if (scenario == 'uncertain') {
        insertGate.completeError(StateError('synthetic lost acknowledgement'));
      } else { insertGate.complete(); }
      await tester.pump(); await tester.pump(const Duration(milliseconds: 350));
      expect(writes, ['success', 'switch-insert', 'uncertain'].contains(scenario) ? 1 : 0);
      if (scenario == 'success') {
        expect(await result, isTrue); await tester.pumpAndSettle();
        expect(find.byType(AddVehicleScreen), findsNothing);
      } else if (scenario == 'uncertain') {
        expect(find.byType(AddVehicleScreen), findsOneWidget);
        expect(tester.widget<ElevatedButton>(find.widgetWithText(ElevatedButton, 'REFRESH MY VEHICLES BEFORE RETRYING')).onPressed, isNull);
        callback(); expect(writes, 1); expect(ownerReads, 1);
        expect(find.text('Vehicle submitted for verification'), findsNothing);
        navigator.pop(); await tester.pump(); await tester.pump(const Duration(milliseconds: 350));
        expect(await result, isNull);
      } else if (scenario.startsWith('switch')) {
        expect(find.byType(AddVehicleScreen), findsOneWidget);
        expect(find.text('Vehicle submitted for verification'), findsNothing);
        navigator.pop(); await tester.pump(); await tester.pump(const Duration(milliseconds: 350));
        expect(await result, isNull);
      }
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    });
  }
}
