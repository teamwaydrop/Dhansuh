import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:waydrop/features/rider/onboarding/services/rider_kyc_upload_service.dart';

void main() {
  testWidgets('actual flat uploader does not start or retry after retirement', (tester) async {
    final log = <String>[];
    final originalPrint = debugPrint;
    debugPrint = (message, {wrapWidth}) { if (message != null) log.add(message); };
    try {
    SharedPreferences.setMockInitialValues({});
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const links = ['com.llfbandit.app_links/messages', 'com.llfbandit.app_links/events'];
    for (final name in links) { messenger.setMockMethodCallHandler(MethodChannel(name), (_) async => null); }
    late Completer<void> started;
    late Completer<http.Response> response;
    var requests = 0;
    late http.Request request;
    final client = MockClient((value) {
      requests++; request = value; if (!started.isCompleted) started.complete(); return response.future;
    });
    late Directory directory;
    late File file;
    await tester.runAsync(() async {
      await Supabase.initialize(url: 'http://127.0.0.1:1', anonKey: 'synthetic', httpClient: client,
          authOptions: const FlutterAuthClientOptions(autoRefreshToken: false));
      directory = await Directory.systemTemp.createTemp('waydrop-synthetic-upload-');
      file = await File('${directory.path}/synthetic.jpg').writeAsBytes([1, 2, 3]);
    });
    addTearDown(() async {
      await tester.runAsync(() async {
        await Supabase.instance.dispose(); await file.delete(); await directory.delete();
      });
      client.close();
      for (final name in links) { messenger.setMockMethodCallHandler(MethodChannel(name), null); }
    });
    await tester.runAsync(() async {
      started = Completer<void>(); response = Completer<http.Response>();
      var current = false;
      await expectLater(RiderKycUploadService.uploadCompressedFile(file: file, fileName: 'rc_front',
        folderName: 'synthetic/vehicles/fixture', isCurrent: () => current), throwsA(isA<StaleUploadException>()));
      expect(requests, 0);
      current = true;
      final running = RiderKycUploadService.uploadCompressedFile(file: file, fileName: 'rc_front',
        folderName: 'synthetic/vehicles/fixture', isCurrent: () => current);
      final rejected = expectLater(running, throwsA(isA<StaleUploadException>()));
      await started.future;
      expect(request.url.path, contains('/storage/v1/object/rider_kyc/synthetic/vehicles/fixture/rc_front.jpg'));
      current = false;
      response.complete(http.Response(jsonEncode({'message': 'synthetic failure', 'statusCode': '503', 'error': 'synthetic'}),
        503, request: request, headers: {'content-type': 'application/json'}));
      await rejected;
      expect(requests, 1); // No retry or compensating delete after retirement.
      expect(log.join(), isNot(contains('synthetic/vehicles/fixture')));
      expect(log.join(), isNot(contains('synthetic failure')));
      expect(log.any((entry) => entry.startsWith('VEHICLE_UPLOAD attempt=')), isTrue);
    });
    } finally {
      debugPrint = originalPrint;
    }
  });
}
