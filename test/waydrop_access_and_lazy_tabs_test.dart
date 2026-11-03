import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:waydrop/core/services/session/rider_access_service.dart';
import 'package:waydrop/features/auth/screens/login_screen.dart';
import 'package:waydrop/features/rider/onboarding/screens/rider_entry_handler.dart';
import 'package:waydrop/shared/widgets/lazy_indexed_stack.dart';

class _Probe extends StatefulWidget {
  final VoidCallback onInit;
  const _Probe({super.key, required this.onInit});
  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  int count = 0;
  @override
  void initState() {
    super.initState();
    widget.onInit();
  }

  @override
  Widget build(BuildContext context) => TextButton(
    onPressed: () => setState(() => count++),
    child: Text('count=$count'),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'https://example.supabase.co',
      anonKey: 'test-public-key',
      authOptions: const FlutterAuthClientOptions(autoRefreshToken: false),
    );
  });
  tearDownAll(() async => Supabase.instance.dispose());

  test(
    'eligibility uses existing KYC, activation, payout and service-mode rules',
    () {
      final now = DateTime.utc(2026, 10, 31);
      Map<String, dynamic> kyc(String status) => {
        'kyc_status': status,
        'activation_status': 'active',
      };
      const rider = {'id': 'rider', 'service_mode': 'local'};
      RiderAccessState decide({
        bool authenticated = true,
        Map<String, dynamic>? k,
        Map<String, dynamic>? r = rider,
        bool payout = true,
      }) => RiderAccessService.decide(
        authenticated: authenticated,
        kyc: k,
        rider: r,
        activePayout: payout,
        now: now,
      ).state;
      expect(
        decide(authenticated: false, k: kyc('approved')),
        RiderAccessState.unauthenticated,
      );
      expect(decide(), RiderAccessState.none);
      for (final status in [
        'pending',
        'under_review',
        'resubmitted',
        'unknown',
      ]) {
        expect(decide(k: kyc(status)), RiderAccessState.pending);
      }
      expect(decide(k: kyc('rejected')), RiderAccessState.rejected);
      expect(
        decide(
          k: {
            ...kyc('approved'),
            'blocked_until': now
                .add(const Duration(minutes: 1))
                .toIso8601String(),
          },
        ),
        RiderAccessState.blocked,
      );
      expect(
        decide(k: {...kyc('approved'), 'blocked_until': now.toIso8601String()}),
        RiderAccessState.ready,
      );
      expect(
        decide(k: {...kyc('approved'), 'activation_status': 'inactive'}),
        RiderAccessState.approvedWaiting,
      );
      expect(
        decide(k: kyc('approved'), r: null),
        RiderAccessState.approvedWaiting,
      );
      expect(
        decide(k: kyc('approved'), payout: false),
        RiderAccessState.payoutRequired,
      );
      expect(
        decide(k: kyc('approved'), r: {'service_mode': null}),
        RiderAccessState.serviceModeRequired,
      );
      expect(
        decide(k: kyc('approved'), r: {'service_mode': 'invalid'}),
        RiderAccessState.serviceModeRequired,
      );
      for (final mode in ['local', 'intercity']) {
        expect(
          decide(k: kyc('approved'), r: {'service_mode': mode}),
          RiderAccessState.ready,
        );
      }
    },
  );

  testWidgets('null session finishes rider entry and displays Login', (
    tester,
  ) async {
    expect(Supabase.instance.client.auth.currentUser, isNull);
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: RiderEntryHandler())),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(LoginScreen), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('hidden tabs mount on selection and retain State on return', (
    tester,
  ) async {
    final initialized = [0, 0, 0];
    final children = List.generate(
      3,
      (i) => _Probe(key: ValueKey(i), onInit: () => initialized[i]++),
    );
    Future<void> select(int i) => tester.pumpWidget(
      MaterialApp(
        home: LazyIndexedStack(index: i, children: children),
      ),
    );
    await select(0);
    expect(initialized, [1, 0, 0]);
    await select(1);
    expect(initialized, [1, 1, 0]);
    await tester.tap(find.text('count=0').last);
    await tester.pump();
    await select(0);
    await select(1);
    expect(initialized, [1, 1, 0]);
    expect(find.text('count=1'), findsOneWidget);
  });

  testWidgets(
    'Home service owner stays mounted with an initial Orders selection',
    (tester) async {
      final initialized = [0, 0, 0];
      final children = List.generate(
        3,
        (i) => _Probe(key: ValueKey(i), onInit: () => initialized[i]++),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: LazyIndexedStack(
            index: 1,
            eagerIndices: const {0},
            children: children,
          ),
        ),
      );
      expect(initialized, [1, 1, 0]);
      // Removing Orders when switching to intercity must preserve Home identity.
      await tester.pumpWidget(
        MaterialApp(
          home: LazyIndexedStack(
            index: 0,
            eagerIndices: const {0},
            children: [children[0], children[2]],
          ),
        ),
      );
      expect(initialized, [1, 1, 0]);
    },
  );
}
