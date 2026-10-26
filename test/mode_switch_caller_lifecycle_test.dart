import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:waydrop/core/services/session/identity_operation_scope.dart';
import 'package:waydrop/shared/screens/not_serviceable_screen.dart';
import 'package:waydrop/features/rider/onboarding/screens/rider_entry_handler.dart';
import 'package:waydrop/shared/widgets/mode_switch_overlay.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late MockClient client;
  late Completer<void> gate;
  var reads = 0;
  const channels = ['com.llfbandit.app_links/messages', 'com.llfbandit.app_links/events'];
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    for (final name in channels) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(name), (_) async => null);
    }
    client = MockClient((request) async {
      reads++;
      await gate.future;
      return http.Response(jsonEncode({'message': 'synthetic ordinary failure', 'code': 'TEST'}),
          400, request: request, headers: {'content-type': 'application/json'});
    });
    await Supabase.initialize(url: 'http://127.0.0.1:1', anonKey: 'synthetic-local-key',
        httpClient: client, authOptions: const FlutterAuthClientOptions(autoRefreshToken: false));
  });
  setUp(() { gate = Completer<void>(); reads = 0; });
  tearDown(() { if (!gate.isCompleted) gate.complete(); });
  tearDownAll(() async {
    await Supabase.instance.dispose(); client.close();
    for (final name in channels) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(name), null);
    }
  });
  Future<void> identity(String id) async {
    final exp = DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000;
    String encode(Map<String, Object> value) => base64UrlEncode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
    final token = '${encode({'alg': 'HS256', 'typ': 'JWT'})}.${encode({'sub': id, 'exp': exp, 'role': 'authenticated'})}.synthetic';
    await Supabase.instance.client.auth.recoverSession(jsonEncode({
      'access_token': token, 'refresh_token': 'synthetic', 'token_type': 'bearer', 'expires_in': 3600,
      'user': {'id': id, 'aud': 'authenticated', 'app_metadata': {}, 'user_metadata': {},
        'created_at': DateTime.now().toUtc().toIso8601String()},
    }));
  }
  for (final entry in [false, true]) {
    for (final scenario in ['identity', 'disposal', 'ordinary']) {
      testWidgets('${entry ? 'Entry overlay' : 'NotServiceable'} suppresses only obsolete $scenario feedback', (tester) async {
        await tester.runAsync(() => identity('A'));
        await tester.pumpWidget(ProviderScope(child: MaterialApp(home:
          entry ? const ModeSwitchOverlay(child: WelcomeRiderScreen()) : const NotServiceableScreen(isRiderReady: true))));
        final button = find.text(entry ? 'Enter Drop Partner Mode' : 'Switch to Drop Partner Mode');
        await tester.ensureVisible(button);
        await tester.tap(button);
        await tester.pump();
        expect(reads, 1);
        if (scenario == 'identity') await tester.runAsync(() => identity('B'));
        if (scenario == 'disposal') await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() async { gate.complete(); });
        await tester.pump();
        await tester.runAsync(() async {});
        await tester.pump();
        await tester.pump();
        // Advance existing overlay animation, not simulated request overlap.
        if (entry && scenario != 'disposal') {
          await tester.pump(const Duration(seconds: 1));
          await tester.pump(const Duration(seconds: 1));
        }
        expect(find.byType(SnackBar), scenario == 'ordinary' ? findsOneWidget : findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      }, timeout: const Timeout(Duration(seconds: 30)));
    }
  }
  testWidgets('throwing overlay error callback still resets transition and propagates error', (tester) async {
    final action = Completer<void>();
    await tester.pumpWidget(ProviderScope(child: MaterialApp(home: ModeSwitchOverlay(
      child: Consumer(builder: (context, ref, _) => Scaffold(body: TextButton(
        onPressed: () => ref.read(modeSwitchOverlayProvider.notifier).trigger(
          asyncAction: () => action.future, onMidpoint: () {},
          onError: (_) => throw StateError('synthetic callback failure')),
        child: const Text('start')))),
    ))));
    final container = ProviderScope.containerOf(tester.element(find.byType(ModeSwitchOverlay)));
    await tester.tap(find.text('start'));
    await tester.pump();
    action.completeError(StateError('synthetic request failure'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isStateError);
    await tester.pump(const Duration(seconds: 1));
    expect(container.read(modeSwitchOverlayProvider), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  test('operation revisions fence replacement, A-B-A and disposal', () async {
    String? user = 'A';
    var alive = true;
    final identities = StreamController<String?>.broadcast(sync: true);
    final scope = IdentityOperationScope(currentUserId: () => user,
        isAlive: () => alive, identities: identities.stream);
    final old = scope.begin();
    expect(old.isCurrent, isTrue);
    final newer = scope.begin();
    expect(old.isCurrent, isFalse);
    user = 'B'; identities.add(user);
    user = 'A'; identities.add(user);
    expect(newer.isCurrent, isFalse);
    final last = scope.begin();
    alive = false;
    expect(last.isCurrent, isFalse);
    scope.dispose();
    await identities.close();
  });
}
