import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:waydrop/features/rider/vehicles/screens/add_vehicle_screen.dart';
import 'package:waydrop/shared/widgets/kyc/kyc_upload_widgets.dart';

void main() {
  for (final title in ['RC FRONT', 'RC BACK', 'VEHICLE PHOTO']) {
    testWidgets('Add Vehicle picker result after disposal: $title', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const links = ['com.llfbandit.app_links/messages', 'com.llfbandit.app_links/events'];
      for (final name in links) {
        messenger.setMockMethodCallHandler(MethodChannel(name), (_) async => null);
      }
      final selected = Completer<String?>();
      var picks = 0;
      const picker = MethodChannel('plugins.flutter.io/image_picker');
      messenger.setMockMethodCallHandler(picker, (call) {
        picks++;
        return selected.future;
      });
      final client = MockClient((request) async => throw StateError('No API calls expected'));
      await tester.runAsync(() => Supabase.initialize(url: 'http://127.0.0.1:1', anonKey: 'synthetic',
          httpClient: client, authOptions: const FlutterAuthClientOptions(autoRefreshToken: false)));
      addTearDown(() async {
        if (!selected.isCompleted) selected.complete(null);
        await tester.runAsync(() => Supabase.instance.dispose());
        client.close();
        messenger.setMockMethodCallHandler(picker, null);
        for (final name in links) {
          messenger.setMockMethodCallHandler(MethodChannel(name), null);
        }
      });
      await tester.pumpWidget(const ProviderScope(child: MaterialApp(home: AddVehicleScreen(riderId: 'RA'))));
      final row = tester.widget<DocUploadRow>(find.byWidgetPredicate((w) => w is DocUploadRow && w.title == title));
      row.onTap();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.tap(find.text('Choose from Gallery'));
      await tester.pump();
      expect(picks, 1);
      await tester.pumpWidget(const SizedBox());
      selected.complete('synthetic-unused.png');
      await tester.pump();
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  }
}
