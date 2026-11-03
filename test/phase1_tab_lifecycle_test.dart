import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:waydrop/shared/widgets/lazy_indexed_stack.dart';
import 'package:waydrop/features/user/activity/activity_tab.dart';

class _TickerProbe extends StatefulWidget {
  final VoidCallback onTick;
  const _TickerProbe({super.key, required this.onTick});
  @override
  State<_TickerProbe> createState() => _TickerProbeState();
}

class _TickerProbeState extends State<_TickerProbe>
    with SingleTickerProviderStateMixin {
  late Ticker ticker;
  @override
  void initState() {
    super.initState();
    ticker = createTicker((_) => widget.onTick())..start();
  }

  @override
  void dispose() {
    ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox();
}

class _ActivityProbe extends ActivityTab {
  final VoidCallback onLoad;
  const _ActivityProbe({
    super.key,
    required super.isActive,
    required this.onLoad,
  });
  @override
  ActivityTabState createState() => _ActivityProbeState();
}

class _ActivityProbeState extends ActivityTabState {
  @override
  Future<void> loadOrders({bool showLoading = false}) async {
    (widget as _ActivityProbe).onLoad();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'https://example.invalid',
      anonKey: 'test-public-key',
      authOptions: const FlutterAuthClientOptions(autoRefreshToken: false),
    );
  });
  tearDownAll(() async {
    await Supabase.instance.dispose();
  });
  testWidgets('visited hidden tab retains State but stops ticking animations', (
    tester,
  ) async {
    final ticks = [0, 0];
    final children = [
      _TickerProbe(key: const ValueKey('a'), onTick: () => ticks[0]++),
      _TickerProbe(key: const ValueKey('b'), onTick: () => ticks[1]++),
    ];
    Future<void> select(int index) => tester.pumpWidget(
      MaterialApp(
        home: LazyIndexedStack(
          index: index,
          eagerIndices: const {0},
          children: children,
        ),
      ),
    );
    await select(0);
    await tester.pump(const Duration(milliseconds: 16));
    final first = find.byType(_TickerProbe).evaluate().first as StatefulElement;
    final firstState = first.state;
    await select(1);
    final hiddenTicks = ticks[0];
    await tester.pump(const Duration(milliseconds: 32));
    await tester.pump(const Duration(milliseconds: 32));
    expect(ticks[0], hiddenTicks);
    expect(ticks[1], greaterThan(0));
    await select(0);
    expect(
      (find.byType(_TickerProbe).evaluate().first as StatefulElement).state,
      same(firstState),
    );
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'Activity stops hidden/background polls and catches up once on return',
    (tester) async {
      var loads = 0;
      const key = ValueKey('activity');
      Future<void> show(bool active) => tester.pumpWidget(
        MaterialApp(
          home: _ActivityProbe(
            key: key,
            isActive: active,
            onLoad: () => loads++,
          ),
        ),
      );
      await show(true);
      expect(loads, 1);
      await tester.pump(const Duration(seconds: 31));
      expect(loads, 2);
      await show(false);
      await tester.pump(const Duration(seconds: 61));
      expect(loads, 2);
      await show(true);
      expect(loads, 3);
      final state = tester.state<ActivityTabState>(find.byType(_ActivityProbe));
      state.didChangeAppLifecycleState(AppLifecycleState.paused);
      await tester.pump(const Duration(seconds: 61));
      expect(loads, 3);
      state.didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(loads, 4);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'ticker wrappers preserve a GlobalKey child without duplicating its key',
    (tester) async {
      final childKey = GlobalKey<_TickerProbeState>();
      final children = [
        const SizedBox(key: ValueKey('home')),
        _TickerProbe(key: childKey, onTick: () {}),
      ];
      Future<void> select(int index) => tester.pumpWidget(
        MaterialApp(
          home: LazyIndexedStack(index: index, children: children),
        ),
      );
      await select(1);
      final originalState = childKey.currentState;
      expect(originalState, isNotNull);
      await select(0);
      await select(1);
      expect(childKey.currentState, same(originalState));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
