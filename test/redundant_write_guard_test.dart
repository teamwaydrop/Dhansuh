import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:waydrop/features/rider/services/rider_status_service.dart';
import 'package:waydrop/modules/notifications/services/notification_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const uid = '00000000-0000-4000-8000-000000000411';
  bool? read = false;
  var markWrites = 0;
  var modeWrites = 0;
  var preferred = 'user';
  String? last = 'user';
  String? firstReadAt;
  final patches = <http.Request>[];
  String encode(Object v) =>
      base64Url.encode(utf8.encode(jsonEncode(v))).replaceAll('=', '');
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'https://example.supabase.co',
      anonKey: 'synthetic-public',
      authOptions: const FlutterAuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((r) async {
        Object? body = {};
        final table = r.url.pathSegments.last;
        if (table == 'token') {
          body = {
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
          };
        } else if (r.method == 'PATCH') {
          patches.add(r);
          final values = jsonDecode(r.body) as Map;
          if (table == 'notifications') {
            // Atomic WHERE contract fixture, not a production Postgres test.
            if (!(r.url.queryParameters['or'] != null && read == true)) {
              markWrites++;
              read = true;
              firstReadAt = values['read_at'] as String?;
            }
          } else if (table == 'users') {
            final target = values['preferred_mode'] as String;
            final filter = r.url.queryParameters['or'];
            if (filter == null || preferred != target || last != target) {
              modeWrites++;
              preferred = target;
              last = values['last_active_mode'] as String?;
            }
          }
          body = [];
        } else if (table == 'rider_kyc') {
          body = {'kyc_status': 'approved', 'activation_status': 'active'};
        } else if (table == 'riders') {
          body = {
            'id': 'synthetic-rider',
            'user_id': uid,
            'account_status': 'offline',
            'service_mode': 'local',
          };
        } else if (table == 'rider_payout_accounts') {
          body = {'id': 'synthetic-payout'};
        }
        return http.Response(
          jsonEncode(body),
          200,
          request: r,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    await Supabase.instance.client.auth.setSession('synthetic');
  });
  setUp(() {
    read = false;
    markWrites = 0;
    modeWrites = 0;
    preferred = 'user';
    last = 'user';
    firstReadAt = null;
    patches.clear();
  });
  tearDownAll(() async => Supabase.instance.dispose());
  Future<void> tap() async {
    await NotificationService().handleNotificationTap({
      'notification_id': 'synthetic-notification',
      'type': 'synthetic-no-navigation',
    });
    await Future<void>.delayed(Duration.zero);
  }

  test('legacy NULL unread state can still be marked read', () async {
    read = null;
    await tap();
    expect(markWrites, 1);
    expect(read, isTrue);
    expect(
      patches.single.url.queryParameters['or'],
      contains('is_read.is.null'),
    );
  });
  test(
    'already-read tap preserves read time and avoids a row UPDATE',
    () async {
      read = true;
      firstReadAt = 'original';
      await tap();
      expect(markWrites, 0);
      expect(firstReadAt, 'original');
    },
  );
  test(
    'five read taps cause one row effect with owner and unread predicates',
    () async {
      await Future.wait(List.generate(5, (_) => tap()));
      expect(markWrites, 1);
      expect(
        patches.every((r) => r.url.queryParameters['user_id'] == 'eq.$uid'),
        isTrue,
      );
      expect(
        patches.every(
          (r) =>
              r.url.queryParameters['or'] ==
              '(is_read.is.null,is_read.eq.false)',
        ),
        isTrue,
      );
    },
  );
  test(
    'repeated user mode writes do not touch an already-correct row',
    () async {
      await RiderStatusService.switchToUserMode();
      await RiderStatusService.switchToUserMode();
      expect(modeWrites, 0);
      expect(
        patches.every((r) => r.url.queryParameters['id'] == 'eq.$uid'),
        isTrue,
      );
    },
  );
  test(
    'NULL last mode is repaired once and never hidden by SQL NULL semantics',
    () async {
      last = null;
      await RiderStatusService.switchToUserMode();
      await RiderStatusService.switchToUserMode();
      expect(modeWrites, 1);
      expect(last, 'user');
      final filter = patches.first.url.queryParameters['or'] ?? '';
      expect(filter, contains('preferred_mode.is.null'));
      expect(filter, contains('last_active_mode.is.null'));
    },
  );
  test(
    'eligible repeated rider mode retains access gate without rewriting row',
    () async {
      preferred = 'rider';
      last = 'rider';
      await RiderStatusService.switchToRiderMode();
      await RiderStatusService.switchToRiderMode();
      expect(modeWrites, 0);
      expect(
        patches.every(
          (r) =>
              r.url.queryParameters['or']!.contains('preferred_mode.neq.rider'),
        ),
        isTrue,
      );
    },
  );
}
