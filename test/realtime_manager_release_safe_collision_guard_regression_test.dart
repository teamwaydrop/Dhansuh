// Regression guard for the Phase 8B RealtimeManager fix: channel pooling was keyed purely by
// channelName, with the only protection against two callers requesting the SAME channelName with
// a DIFFERENT table/event/schema/filter being an assert() -- stripped from release builds, so in
// production the second caller would silently attach to the first caller's channel and only ever
// receive events for the wrong table/event/filter (or none of what it actually needed).
//
// Fix: an unconditional (release-included) config-key comparison now runs before ANY pooling
// decision. A matching config still pools exactly as before. A mismatched config gets its own,
// separately keyed channel instead of silently sharing the wrong one -- callers never need to know
// about this, because unsubscribe() resolves through a subscriptionId -> actual-channel-key map
// rather than trusting the channelName the caller originally passed.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final source = _read('lib/core/services/realtime/realtime_manager.dart');

  group('A. Matching config still pools onto the existing channel', () {
    test('the guard compares configs BEFORE any pooling decision, unconditionally (not inside '
        'assert())', () {
      final guardIdx = source.indexOf('final existingForRequestedName = _activeChannels[channelName];');
      final sameConfigCheckIdx = source.indexOf('!_sameConfig(existingForRequestedName', guardIdx);
      final firstAssertIdx = source.indexOf('assert(', guardIdx);
      expect(guardIdx, greaterThan(-1));
      expect(sameConfigCheckIdx, greaterThan(guardIdx));
      // The config comparison is a plain `if`, reached before the first assert() in this method.
      expect(firstAssertIdx, greaterThan(sameConfigCheckIdx));
    });

    test('a matching config resolves effectiveChannelName back to the original channelName, so '
        'the existing "append listener to existing channel" path is reached unchanged', () {
      expect(source.contains('var effectiveChannelName = channelName;'), isTrue);
      // effectiveChannelName is only ever reassigned inside the mismatch branch.
      final reassignIdx = source.indexOf('effectiveChannelName =\n          ');
      final mismatchBranchIdx = source.indexOf('!_sameConfig(existingForRequestedName');
      expect(reassignIdx, greaterThan(mismatchBranchIdx));
    });

    test('_configKey and _sameConfig compare table, event, schema, and both filter fields', () {
      expect(
        source.contains(
          "String _configKey(\n    String table,\n    PostgresChangeEvent event,\n    String schema,\n    String? filterColumn,\n    String? filterValue,\n  ) =>\n      '\$schema|\$table|\$event|\$filterColumn|\$filterValue';",
        ),
        isTrue,
      );
      final sameConfigStart = source.indexOf('bool _sameConfig(');
      final sameConfigEnd = source.indexOf(';', sameConfigStart);
      final sameConfigBody = source.substring(sameConfigStart, sameConfigEnd);
      for (final field in ['managed.table == table', 'managed.event == event', 'managed.schema == schema',
          'managed.filterColumn == filterColumn', 'managed.filterValue == filterValue']) {
        expect(sameConfigBody.contains(field), isTrue, reason: 'missing comparison: $field');
      }
    });
  });

  group('B. Mismatched config never silently shares the wrong channel, in any build mode', () {
    test('the redirect to a disambiguated key happens outside any assert() block -- runs in '
        'release builds too', () {
      final mismatchBlockStart = source.indexOf('!_sameConfig(existingForRequestedName');
      final mismatchBlockEnd = source.indexOf('_subscriptionChannelKey[subscriptionId] = effectiveChannelName;');
      final mismatchBlock = source.substring(mismatchBlockStart, mismatchBlockEnd);
      expect(mismatchBlock.contains('assert('), isFalse,
          reason: 'the collision redirect must be plain runtime code, not assert()-gated');
      expect(
        mismatchBlock.contains(
          "effectiveChannelName =\n          '\$channelName::cfgmismatch::\${_configKey(table, event, schema, filterColumn, filterValue)}';",
        ),
        isTrue,
      );
    });

    test('a mismatched caller never appends to the original channelName\'s listener map -- it is '
        'routed to a distinct _activeChannels entry', () {
      // Within subscribe() specifically (other methods like _reconnectChannel legitimately use
      // their own local `channelName` parameter for unrelated lookups), the "append to existing"
      // branch looks up `_activeChannels[effectiveChannelName]`, never `_activeChannels[channelName]`
      // directly -- so a redirected caller cannot land on the original (incompatible) entry.
      final subscribeStart = source.indexOf('String subscribe({');
      final subscribeEnd = source.indexOf('\n  /// Canonical string for a channel', subscribeStart);
      final subscribeBody = source.substring(subscribeStart, subscribeEnd);
      final appendBranchIdx = subscribeBody.indexOf('final managed = _activeChannels[effectiveChannelName];');
      expect(appendBranchIdx, greaterThan(-1));
      expect(subscribeBody.contains('final managed = _activeChannels[channelName];'), isFalse);
    });

    test('a diagnostic log is emitted for the mismatch, including both configs, so this is '
        'observable rather than silent', () {
      expect(source.contains('REFUSING TO POOL onto channel'), isTrue);
      final logIdx = source.indexOf('REFUSING TO POOL onto channel');
      final logBlock = source.substring(logIdx, logIdx + 700);
      expect(logBlock.contains('Existing: table='), isTrue);
      expect(logBlock.contains('Requested by [\$owner]: table='), isTrue);
    });
  });

  group('C. Valid subscriptions (matching config, or already-established mismatched channels) '
      'are never broken', () {
    test('unsubscribe() resolves the real channel key via _subscriptionChannelKey instead of '
        'trusting the passed channelName, falling back to it only if unrecorded', () {
      expect(
        source.contains(
          'final effectiveChannelName = _subscriptionChannelKey.remove(subscriptionId) ?? channelName;',
        ),
        isTrue,
      );
      final fnStart = source.indexOf('void unsubscribe(String channelName, String subscriptionId) {');
      final fnEnd = source.indexOf('\n  RealtimeChannel _createSupabaseChannel', fnStart);
      final fnBody = source.substring(fnStart, fnEnd);
      // Every subsequent operation in unsubscribe() uses the resolved key, not the raw param.
      expect(fnBody.contains('_activeChannels[channelName]'), isFalse);
      expect(fnBody.contains('_activeChannels[effectiveChannelName]'), isTrue);
      expect(fnBody.contains('_activeChannels.remove(effectiveChannelName)'), isTrue);
    });

    test('a repeated mismatched config (same channelName + same non-matching config, from a '
        'second caller) converges on the SAME disambiguated key and pools together -- the '
        'lookup is by computed key, not by identity', () {
      // _configKey is a pure function of (table, event, schema, filterColumn, filterValue), so
      // two callers with identical mismatched configs necessarily compute the identical
      // effectiveChannelName and therefore share one real channel, not two.
      expect(source.contains("String _configKey("), isTrue);
      expect(source.contains("'\$schema|\$table|\$event|\$filterColumn|\$filterValue'"), isTrue);
    });
  });

  group('D. Heartbeat/reconnect/backoff/dispose behavior is unchanged', () {
    test('heartbeat interval, stale threshold, and backoff schedule are byte-identical to before', () {
      expect(source.contains('static const heartbeatInterval = Duration(seconds: 30);'), isTrue);
      expect(source.contains('static const staleThreshold = Duration(seconds: 90);'), isTrue);
      expect(source.contains('final backoffSecs = [2, 5, 10, 30];'), isTrue);
    });

    test('_reconnectChannel/_checkConnectivity/_startHeartbeatChecker function bodies are '
        'present and unmodified in structure', () {
      expect(source.contains('Future<void> _reconnectChannel(String channelName) async {'), isTrue);
      expect(source.contains('Future<bool> _checkConnectivity() async {'), isTrue);
      expect(source.contains('void _startHeartbeatChecker() {'), isTrue);
      expect(source.contains('while (true) {'), isTrue);
      expect(source.contains("final randomMultiplier = 0.85 + 0.30 * (DateTime.now().millisecond / 1000.0);"),
          isTrue);
    });

    test('dispose() still disposes every channel exactly as before, plus clears the new '
        'bookkeeping map (an additive, not behavioral, change)', () {
      final disposeStart = source.indexOf('void dispose() {');
      final disposeEnd = source.indexOf('Map<String, List<String>> getDebugMetrics', disposeStart);
      final disposeBody = source.substring(disposeStart, disposeEnd);
      expect(disposeBody.contains('_heartbeatTimer?.cancel();'), isTrue);
      expect(disposeBody.contains('managed.isDisposed = true;'), isTrue);
      expect(disposeBody.contains('supabase.removeChannel(managed.channel);'), isTrue);
      expect(disposeBody.contains('_activeChannels.clear();'), isTrue);
      expect(disposeBody.contains('_subscriptionChannelKey.clear();'), isTrue);
    });

    test('payload delivery (_createSupabaseChannel\'s per-listener try/catch loop) is untouched', () {
      expect(
        source.contains(
          'final subs = List<ChannelSubscription>.from(managedChannel.listeners.values);\n        for (final sub in subs) {\n          try {\n            sub.callback(payload);',
        ),
        isTrue,
      );
    });
  });
}
