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
import 'package:waydrop/features/user/profile/profile_tab.dart';
import 'package:waydrop/modules/rewards/screens/rewards_screen.dart';
import 'package:waydrop/modules/rewards/screens/category_offers_screen.dart';
import 'package:waydrop/modules/rewards/widgets/reward_profile_tile.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  var account = 'A';
  late Completer<void> oldProfile;
  late Completer<void> oldReward;
  var profileReads = 0;
  var rewardReads = 0;
  late Completer<void> kycGate;
  var kycReads = 0;
  var riderReads = 0;
  var payoutReads = 0;
  late MockClient transport;
  const channels = ['com.llfbandit.app_links/messages', 'com.llfbandit.app_links/events'];
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final name in channels) {
      messenger.setMockMethodCallHandler(MethodChannel(name), (_) async => null);
    }
    transport = MockClient((request) async {
      final owner = account;
      Object body = [];
      if (request.url.path.endsWith('/users')) {
        profileReads++;
        if (owner == 'A') await oldProfile.future;
        body = {'full_name': 'Synthetic $owner', 'user_code': 'TEST-$owner',
          'role': owner == 'A' ? 'admin' : 'user'};
      } else if (request.url.path.endsWith('/get_reward_status')) {
        rewardReads++;
        if (owner == 'A') await oldReward.future;
        body = {'enabled': true, 'required_rides': 10, 'rides_remaining': owner == 'A' ? 1 : 2,
          'qualifying_ride_count': owner == 'A' ? 9 : 8, 'progress_within_cycle': owner == 'A' ? 9 : 8,
          'active_cycle_count': 0, 'active_cycles': [],
          'current_cycle_id': 'synthetic-cycle-$owner', 'activation_window_minutes': 5};
      } else if (request.url.path.endsWith('/reward_offer_categories')) {
        body = [{'id': 'synthetic-category', 'code': 'restaurants', 'display_name': 'Synthetic category'}];
      } else if (request.url.path.endsWith('/rider_kyc')) {
        kycReads++;
        await kycGate.future;
        body = {'kyc_status': 'approved', 'activation_status': 'active'};
      } else if (request.url.path.endsWith('/riders')) {
        riderReads++;
        body = {'id': 'synthetic-rider'};
      } else if (request.url.path.endsWith('/rider_payout_accounts')) {
        payoutReads++;
        body = {'id': 'synthetic-payout'};
      }
      return http.Response(jsonEncode(body), 200, request: request,
          headers: {'content-type': 'application/json'});
    });
    await Supabase.initialize(url: 'http://127.0.0.1:1', anonKey: 'synthetic-local-key',
      httpClient: transport, authOptions: const FlutterAuthClientOptions(autoRefreshToken: false));
  });
  setUp(() {
    oldProfile = Completer<void>();
    oldReward = Completer<void>();
    profileReads = 0;
    rewardReads = 0;
    kycGate = Completer<void>();
    kycReads = riderReads = payoutReads = 0;
  });
  tearDown(() {
    if (!oldProfile.isCompleted) oldProfile.complete();
    if (!oldReward.isCompleted) oldReward.complete();
    if (!kycGate.isCompleted) kycGate.complete();
  });
  tearDownAll(() async {
    await Supabase.instance.dispose();
    transport.close();
    for (final name in channels) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(name), null);
    }
  });
  Future<void> identity(String id) async {
    account = id;
    final expires = DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000;
    String encode(Map<String, Object> value) => base64UrlEncode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
    final token = '${encode({'alg': 'HS256', 'typ': 'JWT'})}.${encode({'sub': id, 'exp': expires, 'role': 'authenticated'})}.synthetic';
    // Synthetic in-memory session only. No authentication endpoint or project.
    await Supabase.instance.client.auth.recoverSession(jsonEncode({
      'access_token': token, 'refresh_token': 'synthetic', 'token_type': 'bearer', 'expires_in': 3600,
      'user': {'id': id, 'aud': 'authenticated', 'app_metadata': {}, 'user_metadata': {},
        'created_at': DateTime.now().toUtc().toIso8601String()},
    }));
  }
  testWidgets('Passenger Profile never renders delayed account A role or profile after B', (tester) async {
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() => identity('A'));
    await tester.pumpWidget(const ProviderScope(child: MaterialApp(home: ProfileTab())));
    await tester.pump();
    expect(profileReads, 1);
    expect(rewardReads, 1);
    // Capture the actual cached futures supplied to the production builders.
    // Their results must be fenced even without FutureBuilder replacement.
    final aRole = tester.widget<FutureBuilder<Map<String, dynamic>?>>(
        find.byKey(const ValueKey('passenger-role:A'))).future!;
    final aReward = tester.widget<FutureBuilder<Map<String, dynamic>?>>(
        find.byKey(const ValueKey('passenger-rewards:A'))).future!;
    var retiredRoleCompleted = false;
    var retiredRewardCompleted = false;
    Object? retiredRole;
    Object? retiredReward;
    aRole.then((value) { retiredRole = value; retiredRoleCompleted = true; });
    aReward.then((value) { retiredReward = value; retiredRewardCompleted = true; });
    await tester.runAsync(() => identity('B'));
    await tester.pump();
    await tester.pump();
    await tester.runAsync(() async {
      oldProfile.complete();
      oldReward.complete();
    });
    await tester.pump();
    await tester.pump();
    expect(retiredRoleCompleted, isTrue, reason: 'retired role response must actually finish');
    expect(retiredRewardCompleted, isTrue, reason: 'retired reward response must actually finish');
    expect(retiredRole, isNull);
    expect(retiredReward, isNull);
    expect(profileReads, 2);
    expect(rewardReads, 2);
    expect(find.text('Synthetic B'), findsOneWidget);
    expect(tester.widget<RewardProfileTile>(find.byType(RewardProfileTile)).status['rides_remaining'], 2);
    expect(find.text('Complete 1 more ride'), findsNothing);
    // Positive control: prove the same admin location is built and visible,
    // then remove it by account replacement rather than off-screen omission.
    await tester.runAsync(() => identity('A'));
    await tester.pump();
    final control = tester.widget<FutureBuilder<Map<String, dynamic>?>>(
        find.byKey(const ValueKey('passenger-role:A'))).future!;
    var controlDone = false;
    Map<String, dynamic>? controlValue;
    control.then((value) { controlValue = value; controlDone = true; });
    for (var turn = 0; turn < 10 && !controlDone; turn++) {
      await tester.runAsync(() async {});
      await tester.pump();
    }
    expect(controlDone, isTrue);
    expect(controlValue?['role'], 'admin');
    await tester.pump();
    await tester.ensureVisible(find.text('Admin Support Panel'));
    expect(find.text('Admin Support Panel').hitTestable(), findsOneWidget);
    await tester.runAsync(() => identity('B'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Admin Support Panel'), findsNothing);
    expect(find.text('Synthetic A'), findsNothing);
    expect(find.text('Admin Support Panel'), findsNothing);
    expect(find.text('Synthetic B'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  }, timeout: const Timeout(Duration(seconds: 30)));
  testWidgets('mode-switch batch stops when account changes during KYC read', (tester) async {
    oldProfile.complete();
    oldReward.complete();
    await tester.runAsync(() => identity('A'));
    await tester.pumpWidget(const ProviderScope(child: MaterialApp(home: ProfileTab())));
    await tester.pump();
    await tester.tap(find.text('Switch to Drop Partner Mode'));
    await tester.pump();
    expect(kycReads, 1);
    await tester.runAsync(() => identity('B'));
    await tester.pump();
    kycGate.complete();
    await tester.pump();
    await tester.pump();
    expect(riderReads, 0);
    expect(payoutReads, 0);
    expect(find.text('Switch to Drop Partner Mode?'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('Rewards navigation consumes B cycle after delayed A reward completes', (tester) async {
    await tester.runAsync(() => identity('A'));
    await tester.pumpWidget(const MaterialApp(home: RewardsScreen(ownerType: 'user')));
    await tester.pump();
    expect(rewardReads, 1);
    await tester.runAsync(() => identity('B'));
    await tester.pump();
    await tester.pump();
    expect(rewardReads, 2);
    oldReward.complete();
    await tester.pump();
    await tester.pump();
    await tester.tap(find.text('Synthetic category'));
    await tester.pumpAndSettle();
    final destination = tester.widget<CategoryOffersScreen>(find.byType(CategoryOffersScreen));
    expect(destination.rewardCycleId, 'synthetic-cycle-B');
    expect(destination.ownerType, 'user');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
