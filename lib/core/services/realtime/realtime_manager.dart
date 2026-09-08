import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:waydrop/core/config/env.dart';
import 'package:waydrop/core/services/realtime/realtime_observability.dart';

class ChannelSubscription {
  final String id;
  final String owner; // E.g., 'RiderOrdersScreen', 'NavigationBadgeProvider'
  final Function(PostgresChangePayload) callback;

  ChannelSubscription({
    required this.id,
    required this.owner,
    required this.callback,
  });
}

class ManagedChannel {
  // Assigned once by RealtimeManager immediately after construction (see subscribe()).
  // Declared `late` instead of a required constructor param so that no throwaway
  // RealtimeChannel has to be created just to satisfy this field before the real,
  // fully-configured channel exists.
  late RealtimeChannel channel;
  final Map<String, ChannelSubscription> listeners; // Mapped by unique subscriptionId
  final String schema;
  final String table;
  final PostgresChangeEvent event;
  final String? filterColumn;
  final String? filterValue;
  int reconnectAttempts = 0;
  bool isDisposed = false;
  bool isReconnecting = false;
  RealtimeSubscribeStatus? currentStatus;

  // Heartbeat check verification fields
  DateTime lastMessageReceived;
  DateTime lastStatusConfirmed;

  ManagedChannel({
    required this.listeners,
    required this.schema,
    required this.table,
    required this.event,
    this.filterColumn,
    this.filterValue,
    required this.lastMessageReceived,
    required this.lastStatusConfirmed,
    this.currentStatus,
  });

  int get subscriberCount => listeners.length;
}

class RealtimeManager {
  static final RealtimeManager instance = RealtimeManager._internal();
  RealtimeManager._internal() {
    _startHeartbeatChecker();
  }

  final supabase = Supabase.instance.client;
  final Map<String, ManagedChannel> _activeChannels = {};
  // Maps a subscriptionId to the ACTUAL channel key it lives under in [_activeChannels] -- almost
  // always identical to the channelName the caller passed to subscribe(), except for a
  // config-mismatched caller (see subscribe()'s collision guard below), which is redirected to a
  // disambiguated key. unsubscribe() resolves through this map so callers never need to know
  // about that redirection.
  final Map<String, String> _subscriptionChannelKey = {};
  Timer? _heartbeatTimer;

  int get activeChannelCount => _activeChannels.length;

  static const heartbeatInterval = Duration(seconds: 30);
  static const staleThreshold = Duration(seconds: 90);

  /// Subscribes a listener to a specific database stream channel.
  /// Returns a subscriptionId that can be used to unsubscribe later.
  String subscribe({
    required String channelName,
    required String table,
    required String owner,
    PostgresChangeEvent event = PostgresChangeEvent.all,
    String schema = 'public',
    String? filterColumn,
    String? filterValue,
    required Function(PostgresChangePayload) callback,
  }) {
    RealtimeObservability.instance.recordSubscriptionCreate();
    final subscriptionId = '${owner}_${DateTime.now().microsecondsSinceEpoch}';
    final newSubscription = ChannelSubscription(
      id: subscriptionId,
      owner: owner,
      callback: callback,
    );

    // RELEASE-SAFE COLLISION GUARD: pooling is keyed by channelName, but two callers requesting
    // the SAME channelName with a DIFFERENT table/event/schema/filter used to be caught only by
    // an assert() below -- which is stripped from release builds, so in production the second
    // caller would silently attach to the first caller's channel and only ever receive events
    // for the FIRST caller's table/event/filter (or none of the events it actually needed). This
    // config-key comparison runs unconditionally (release included) and, on a mismatch, gives the
    // new caller its OWN correctly-configured channel under a disambiguated key instead of
    // silently sharing the wrong one. A caller requesting a matching config still pools onto the
    // existing channel exactly as before -- this only changes behavior for the incompatible case,
    // which previously had no real protection at all.
    var effectiveChannelName = channelName;
    final existingForRequestedName = _activeChannels[channelName];
    if (existingForRequestedName != null &&
        !_sameConfig(existingForRequestedName, table, event, schema, filterColumn, filterValue)) {
      effectiveChannelName =
          '$channelName::cfgmismatch::${_configKey(table, event, schema, filterColumn, filterValue)}';
      debugPrint(
        '[RealtimeManager] REFUSING TO POOL onto channel [$channelName]: requested config differs '
        'from the config already registered there. Existing: table=${existingForRequestedName.table}, '
        'event=${existingForRequestedName.event}, schema=${existingForRequestedName.schema}, '
        'filterColumn=${existingForRequestedName.filterColumn}, filterValue=${existingForRequestedName.filterValue}. '
        'Requested by [$owner]: table=$table, event=$event, schema=$schema, filterColumn=$filterColumn, '
        'filterValue=$filterValue. Creating a SEPARATE channel [$effectiveChannelName] for this '
        'subscriber instead of silently attaching it to the wrong stream. Use a unique channelName '
        'per distinct config to avoid this in future.',
      );
    }
    _subscriptionChannelKey[subscriptionId] = effectiveChannelName;

    final managed = _activeChannels[effectiveChannelName];
    if (managed != null) {
      // Channel already exists (with a matching config, by construction of effectiveChannelName
      // above), append the listener and return
      managed.listeners[subscriptionId] = newSubscription;
      RealtimeObservability.instance.updateActiveChannelCount(_activeChannels.length);
      debugPrint('[INSTR] ${DateTime.now().toIso8601String()} RealtimeManager: Appended listener [$subscriptionId] owned by [$owner] to EXISTING channel [$effectiveChannelName] (existing channel was created for table=${managed.table}, event=${managed.event}, filterColumn=${managed.filterColumn}, filterValue=${managed.filterValue}; this new subscribe() requested table=$table, event=$event, filterColumn=$filterColumn, filterValue=$filterValue, currentStatus=${managed.currentStatus}). Subscriber count: ${managed.subscriberCount}');
      debugPrint('RealtimeManager: Appended listener [$subscriptionId] owned by [$owner] to existing channel [$effectiveChannelName]. Subscriber count: ${managed.subscriberCount}');
      // Now purely a defensive double-check -- effectiveChannelName is only ever resolved to an
      // existing entry whose config already matches, by the guard above.
      assert(
        managed.table == table &&
            managed.event == event &&
            managed.filterColumn == filterColumn &&
            managed.filterValue == filterValue,
        'RealtimeManager: internal invariant violated -- effectiveChannelName [$effectiveChannelName] '
        'resolved to a channel with a mismatched config. This should be unreachable.',
      );
      return subscriptionId;
    }

    // Channel does not exist, initialize it
    debugPrint('[INSTR] ${DateTime.now().toIso8601String()} RealtimeManager: Creating NEW channel [$effectiveChannelName] for owner [$owner] table=$table event=$event filterColumn=$filterColumn filterValue=$filterValue');
    debugPrint('RealtimeManager: Creating new channel [$effectiveChannelName] for owner [$owner] on table [$table]');
    final managedChannel = ManagedChannel(
      listeners: {subscriptionId: newSubscription},
      schema: schema,
      table: table,
      event: event,
      filterColumn: filterColumn,
      filterValue: filterValue,
      lastMessageReceived: DateTime.now(),
      lastStatusConfirmed: DateTime.now(),
    );

    final realChannel = _createSupabaseChannel(
      channelName: effectiveChannelName,
      managedChannel: managedChannel,
    );

    managedChannel.channel = realChannel;

    _activeChannels[effectiveChannelName] = managedChannel;
    RealtimeObservability.instance.updateActiveChannelCount(_activeChannels.length);

    _subscribeToChannel(effectiveChannelName, managedChannel, null);

    assert(() {
      debugPrint('Realtime channels: ${RealtimeManager.instance.activeChannelCount}');
      return true;
    }());

    return subscriptionId;
  }

  /// Canonical string for a channel's realtime configuration -- used by the release-safe
  /// collision guard in subscribe() above to detect an incompatible channelName reuse.
  String _configKey(
    String table,
    PostgresChangeEvent event,
    String schema,
    String? filterColumn,
    String? filterValue,
  ) =>
      '$schema|$table|$event|$filterColumn|$filterValue';

  bool _sameConfig(
    ManagedChannel managed,
    String table,
    PostgresChangeEvent event,
    String schema,
    String? filterColumn,
    String? filterValue,
  ) =>
      managed.table == table &&
      managed.event == event &&
      managed.schema == schema &&
      managed.filterColumn == filterColumn &&
      managed.filterValue == filterValue;

  /// Unsubscribes a specific listener.
  /// If the subscriberCount drops to 0, the channel is destroyed.
  void unsubscribe(String channelName, String subscriptionId) {
    RealtimeObservability.instance.recordSubscriptionDispose();
    // Resolve through the channelName a caller actually landed on -- identical to the passed
    // channelName for every normal subscription, but redirected for one that subscribe()'s
    // collision guard above moved onto a disambiguated key. Falls back to the passed channelName
    // if this subscriptionId was never recorded (defensive; should not happen).
    final effectiveChannelName = _subscriptionChannelKey.remove(subscriptionId) ?? channelName;
    final managed = _activeChannels[effectiveChannelName];
    if (managed == null) return;

    final removed = managed.listeners.remove(subscriptionId);
    if (removed != null) {
      debugPrint('RealtimeManager: Removed listener [$subscriptionId] owned by [${removed.owner}] from channel [$effectiveChannelName]. Remaining subscribers: ${managed.subscriberCount}');
    }

    if (managed.subscriberCount == 0) {
      debugPrint('RealtimeManager: Channel [$effectiveChannelName] has 0 subscribers. Disposing channel.');
      managed.isDisposed = true;
      try {
        supabase.removeChannel(managed.channel);
      } catch (e) {
        debugPrint('Error removing channel: $e');
      }
      _activeChannels.remove(effectiveChannelName);
      RealtimeObservability.instance.updateActiveChannelCount(_activeChannels.length);

      assert(() {
        debugPrint('Realtime channels: ${RealtimeManager.instance.activeChannelCount}');
        return true;
      }());
    }
  }

  RealtimeChannel _createSupabaseChannel({
    required String channelName,
    required ManagedChannel managedChannel,
  }) {
    PostgresChangeFilter? filter;
    if (managedChannel.filterColumn != null && managedChannel.filterValue != null) {
      filter = PostgresChangeFilter(
        type: PostgresChangeFilterType.eq,
        column: managedChannel.filterColumn!,
        value: managedChannel.filterValue!,
      );
    }

    final channel = supabase.channel(channelName);
    
    channel.onPostgresChanges(
      event: managedChannel.event,
      schema: managedChannel.schema,
      table: managedChannel.table,
      filter: filter,
      callback: (payload) {
        managedChannel.lastMessageReceived = DateTime.now();
        
        // Safe iteration over copies
        final subs = List<ChannelSubscription>.from(managedChannel.listeners.values);
        for (final sub in subs) {
          try {
            sub.callback(payload);
          } catch (e) {
            debugPrint('RealtimeManager callback error [${sub.owner}]: $e');
          }
        }
      },
    );

    return channel;
  }

  void _subscribeToChannel(String channelName, ManagedChannel managed, int? reconnectStartTime) {
    managed.channel.subscribe((status, [error]) {
      if (managed.isDisposed) return;
      
      managed.currentStatus = status;
      debugPrint('[INSTR] ${DateTime.now().toIso8601String()} RealtimeManager: Channel [$channelName] status changed to [$status], error: $error, subscriberCount=${managed.subscriberCount}, owners=${managed.listeners.values.map((l) => l.owner).toList()}');
      debugPrint('RealtimeManager: Channel [$channelName] status is [$status], error: $error');

      if (status == RealtimeSubscribeStatus.subscribed) {
        managed.lastStatusConfirmed = DateTime.now();
        managed.reconnectAttempts = 0;
        
        if (reconnectStartTime != null) {
          final duration = DateTime.now().millisecondsSinceEpoch - reconnectStartTime;
          RealtimeObservability.instance.recordReconnect(duration);
        }
      } else if (status == RealtimeSubscribeStatus.channelError || 
                 status == RealtimeSubscribeStatus.timedOut ||
                 (status == RealtimeSubscribeStatus.closed && managed.subscriberCount > 0)) {
        RealtimeObservability.instance.recordChannelError();
        _reconnectChannel(channelName);
      }
    });
  }

  Future<void> _reconnectChannel(String channelName) async {
    final managed = _activeChannels[channelName];
    if (managed == null || managed.isDisposed) return;
    if (managed.isReconnecting) {
      debugPrint('RealtimeManager: Channel [$channelName] is already reconnecting. Skipping parallel trigger.');
      return;
    }

    managed.isReconnecting = true;

    try {
      while (true) {
        if (managed.isDisposed || !_activeChannels.containsKey(channelName)) return;

        // Exponential backoff with jitter
        final backoffSecs = [2, 5, 10, 30];
        final attempts = managed.reconnectAttempts;
        final backoffIndex = attempts >= backoffSecs.length ? backoffSecs.length - 1 : attempts;
        final baseBackoff = Duration(seconds: backoffSecs[backoffIndex]);
        final randomMultiplier = 0.85 + 0.30 * (DateTime.now().millisecond / 1000.0);
        final backoff = Duration(milliseconds: (baseBackoff.inMilliseconds * randomMultiplier).toInt());

        managed.reconnectAttempts++;
        debugPrint('RealtimeManager: Reconnecting [$channelName] in ${backoff.inMilliseconds}ms (attempt ${managed.reconnectAttempts})...');

        await Future.delayed(backoff);
        if (managed.isDisposed || !_activeChannels.containsKey(channelName)) return;

        // Ping check internet/Supabase connectivity
        final isOnline = await _checkConnectivity();
        if (!isOnline) {
          debugPrint('RealtimeManager: Supabase connectivity check failed. Will retry after delay.');
          continue; // Loop again, increasing backoff
        }

        final startTime = DateTime.now().millisecondsSinceEpoch;

        try {
          await supabase.removeChannel(managed.channel);
        } catch (e) {
          // Ignore
        }

        final newChannel = _createSupabaseChannel(
          channelName: channelName,
          managedChannel: managed,
        );

        managed.channel = newChannel;
        managed.lastMessageReceived = DateTime.now();
        managed.lastStatusConfirmed = DateTime.now();

        _subscribeToChannel(channelName, managed, startTime);
        break; // Successfully reconnected, exit loop
      }
    } finally {
      final currentManaged = _activeChannels[channelName];
      if (currentManaged != null) {
        currentManaged.isReconnecting = false;
      }
    }
  }

  Future<bool> _checkConnectivity() async {
    try {
      final baseUrl = Env.supabaseUrl.isNotEmpty
          ? Env.supabaseUrl
          : 'https://yvwpchffctiagevpqgwy.supabase.co';
      final uri = Uri.parse('$baseUrl/rest/v1/');
      final response = await http.get(uri).timeout(const Duration(seconds: 5));
      // 200 or 401 means server is reachable and active
      return response.statusCode == 200 || response.statusCode == 401;
    } catch (e) {
      return false;
    }
  }

  void _startHeartbeatChecker() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(heartbeatInterval, (timer) async {
      final now = DateTime.now();
      final List<String> staleChannels = [];

      _activeChannels.forEach((name, managed) {
        if (managed.isDisposed || managed.subscriberCount == 0) return;
        
        // If the channel is currently successfully subscribed, update lastStatusConfirmed
        // so that it is never considered stale.
        if (managed.currentStatus == RealtimeSubscribeStatus.subscribed) {
          managed.lastStatusConfirmed = now;
          return;
        }

        // Otherwise, check how long it's been in a non-subscribed state
        final diff = now.difference(managed.lastStatusConfirmed);
        if (diff > staleThreshold) {
          staleChannels.add(name);
        }
      });

      for (final name in staleChannels) {
        debugPrint('RealtimeManager: Heartbeat failure on channel [$name] (stale for ${now.difference(_activeChannels[name]!.lastStatusConfirmed).inSeconds}s). Forcing reconnect.');
        RealtimeObservability.instance.recordHeartbeatFailure();
        _reconnectChannel(name);
      }
    });
  }

  void dispose() {
    _heartbeatTimer?.cancel();
    _activeChannels.forEach((name, managed) {
      managed.isDisposed = true;
      try {
        supabase.removeChannel(managed.channel);
      } catch (_) {}
    });
    _activeChannels.clear();
    _subscriptionChannelKey.clear();
    RealtimeObservability.instance.updateActiveChannelCount(0);
  }

  Map<String, List<String>> getDebugMetrics() {
    final Map<String, List<String>> metrics = {};
    _activeChannels.forEach((channelName, managed) {
      metrics[channelName] = managed.listeners.values.map((sub) => sub.owner).toList();
    });
    return metrics;
  }
}
