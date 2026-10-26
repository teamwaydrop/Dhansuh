import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:waydrop/core/services/database/government_tax_ledger_cache.dart';

void main() {
  setUp(GovernmentTaxLedgerCache.clearAll);
  tearDown(GovernmentTaxLedgerCache.clearAll);
  for (final outcome in ['null', 'row', 'error']) {
    test('retired $outcome completion cannot release or overwrite replacement read', () async {
      final old = Completer<Map<String, dynamic>?>();
      final next = Completer<Map<String, dynamic>?>();
      var reads = 0;
      final first = GovernmentTaxLedgerCache.get('synthetic-order', () { reads++; return old.future; });
      final failed = outcome == 'error' ? expectLater(first, throwsStateError) : null;
      GovernmentTaxLedgerCache.clearAll();
      final second = GovernmentTaxLedgerCache.get('synthetic-order', () { reads++; return next.future; });
      if (outcome == 'error') {
        old.completeError(StateError('synthetic failure'));
        await failed;
      } else {
        old.complete(outcome == 'null' ? null : {'amount': 1, 'rate_percent': 1});
        await first;
      }
      final third = GovernmentTaxLedgerCache.get('synthetic-order', () async {
        reads++;
        return {'amount': 99, 'rate_percent': 99};
      });
      var completed = false;
      third.then((_) { completed = true; });
      await Future<void>.value();
      expect(completed, isFalse); // Neither stale row nor duplicate fetch.
      next.complete({'amount': 2, 'rate_percent': 2});
      expect(await second, {'amount': 2, 'rate_percent': 2});
      expect(await third, {'amount': 2, 'rate_percent': 2});
      expect(reads, 2); // Broken ownership permitted a third request after null/error.
      expect(await GovernmentTaxLedgerCache.get('synthetic-order', () async {
        reads++; return null;
      }), {'amount': 2, 'rate_percent': 2});
      expect(reads, 2);
    });
  }
  test('null and failed reads remain uncached; unrelated orders never share', () async {
    var reads = 0;
    expect(await GovernmentTaxLedgerCache.get('one', () async { reads++; return null; }), isNull);
    await expectLater(GovernmentTaxLedgerCache.get('one', () async {
      reads++; throw StateError('synthetic failure');
    }), throwsStateError);
    await GovernmentTaxLedgerCache.get('one', () async { reads++; return {'amount': 3}; });
    await GovernmentTaxLedgerCache.get('two', () async { reads++; return {'amount': 4}; });
    expect(reads, 4);
  });
}
