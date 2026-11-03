import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:waydrop/core/services/cache/cache_service.dart';
import 'package:waydrop/core/services/config/production_config_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final cacheDirectory = Directory.systemTemp.createTempSync(
    'waydrop_config_retry_',
  );
  var calls = 0;
  var status = 503;
  var rows = <Map<String, dynamic>>[];
  Completer<void>? gate;
  final config = ProductionConfigService.instance;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => cacheDirectory.path,
        );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async {
          if (call.method == 'read') {
              return base64Encode(List<int>.filled(32, 7));
          }
            return null;
          },
        );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('dev.fluttercommunity.plus/package_info'),
          (_) async => {
            'appName': 'Waydrop',
            'packageName': 'test.waydrop',
            'version': '1.0.0',
            'buildNumber': '55',
            'buildSignature': '',
          },
        );
    await CacheService.instance.init();
    await Supabase.initialize(
      url: 'https://synthetic.supabase.co',
      anonKey: 'synthetic-public-key',
      authOptions: const FlutterAuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((request) async {
        expect(request.url.path, '/rest/v1/production_config');
        calls++;
        await gate?.future;
        return http.Response(
          jsonEncode(
            status == 200
                ? rows
                : {'code': '503', 'message': 'synthetic failure'},
          ),
          status,
          request: request,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
  });
  tearDownAll(() async {
    await Supabase.instance.dispose();
    await Hive.close();
    // Delete only the exact test-created directory after resolving its boundary.
    final resolved = cacheDirectory.resolveSymbolicLinksSync();
    final tempRoot = Directory.systemTemp.resolveSymbolicLinksSync();
    if (!resolved.startsWith(
      '$tempRoot${Platform.pathSeparator}waydrop_config_retry_',
    )) {
      throw StateError('Unexpected test cache location');
    }
    await Directory(resolved).delete(recursive: true);
  });

  test(
    'a failed session fetch is shared and not repeated by later init calls',
    () async {
      calls = 0;
      status = 503;
      gate = Completer<void>();
      final first = config.refresh();
      final second = config.init();
      await Future<void>.delayed(Duration.zero);
      expect(calls, 1);
      gate!.complete();
      await Future.wait([first, second]);
      gate = null;
      for (var i = 0; i < 8; i++) {
        await config.init();
      }
      expect(calls, 1);
    },
  );

  test(
    'explicit refresh retries and failure preserves cached maintenance/update gates',
    () async {
      calls = 0;
      status = 200;
      rows = [
        {
          'maintenance_mode': true,
          'force_update': true,
          'notifications_enabled': false,
        },
      ];
      await config.refresh();
      await Future<void>.delayed(Duration.zero);
      expect(config.maintenanceMode, isTrue);
      expect(config.forceUpdate, isTrue);
      expect(config.getFlag('notifications_enabled'), isFalse);
      status = 503;
      await config.refresh();
      await config.init();
      expect(calls, 2);
      expect(config.maintenanceMode, isTrue);
      expect(config.forceUpdate, isTrue);
      expect(config.getFlag('notifications_enabled'), isFalse);
      status = 200;
      rows = [
        {
          'maintenance_mode': false,
          'force_update': false,
          'notifications_enabled': true,
        },
      ];
      await config.refresh();
      expect(calls, 3);
      expect(config.maintenanceMode, isFalse);
      expect(config.forceUpdate, isFalse);
    },
  );

  test(
    'a missing active config row also completes the session attempt',
    () async {
      calls = 0;
      status = 200;
      rows = [];
      await config.refresh();
      await config.init();
      expect(calls, 1);
    },
  );
}
