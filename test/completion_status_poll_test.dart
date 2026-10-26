import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:waydrop/features/rider/orders/completion_status_poll.dart';

void main() {
  for (final reason in ['Realtime confirmed', 'deadline elapsed', 'disposed']) {
    test('$reason stops follow-up GETs while waiting', () async {
      final pause = Completer<void>(); final began = Completer<void>();
      var active = true; var gets = 0;
      final running = pollCompletionStatus(targetStatus: 'completed',
        ownsAttempt: () => active, fetch: () async { gets++; return 'ongoing'; }, onError: (_) {},
        wait: (_) { began.complete(); return pause.future; });
      await began.future; expect(gets, 1);
      active = false; pause.complete(); expect(await running, isFalse); expect(gets, 1);
      // Original loop, when still mounted, could continue through six more GETs.
    });
  }
  test('new same-target attempt cannot re-enable a retired polling loop', () async {
    final pause = Completer<void>(); final began = Completer<void>();
    var generation = 1; var oldGets = 0;
    final old = pollCompletionStatus(targetStatus: 'completed', ownsAttempt: () => generation == 1,
      fetch: () async { oldGets++; return 'ongoing'; }, onError: (_) {},
      wait: (_) { began.complete(); return pause.future; });
    await began.future; generation = 2;
    expect(await pollCompletionStatus(targetStatus: 'completed', ownsAttempt: () => generation == 2,
      fetch: () async => 'completed', onError: (_) {}), isTrue);
    pause.complete(); expect(await old, isFalse); expect(oldGets, 1);
  });
  test('late HTTP match from a retired attempt cannot report success', () async {
    final read = Completer<String?>(); var active = true; var gets = 0;
    final running = pollCompletionStatus(targetStatus: 'completed', ownsAttempt: () => active,
      fetch: () { gets++; return read.future; }, onError: (_) {});
    active = false; read.complete('completed'); expect(await running, isFalse); expect(gets, 1);
  });
  test('normal fallback retains seven queries, exact delays and transient-error recovery', () async {
    var gets = 0; var errors = 0; final delays = <int>[];
    expect(await pollCompletionStatus(targetStatus: 'completed', ownsAttempt: () => true,
      fetch: () async { gets++; if (gets == 1) throw StateError('synthetic'); return 'ongoing'; },
      onError: (_) { errors++; }, wait: (delay) async { delays.add(delay.inSeconds); }), isFalse);
    expect(gets, 7); expect(errors, 1); expect(delays, [3, 6, 10, 15, 20, 20]);
    expect(await pollCompletionStatus(targetStatus: 'completed', ownsAttempt: () => true,
      fetch: () async => 'completed', onError: (_) {}), isTrue);
  });
  test('retired before initial read issues zero GETs', () async {
    var gets = 0;
    expect(await pollCompletionStatus(targetStatus: 'completed', ownsAttempt: () => false,
      fetch: () async { gets++; return 'completed'; }, onError: (_) {}), isFalse);
    expect(gets, 0);
  });
}
