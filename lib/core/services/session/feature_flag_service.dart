import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:waydrop/core/services/cache/cache_service.dart';

class FeatureFlagService {
  static final FeatureFlagService instance = FeatureFlagService._internal();
  FeatureFlagService._internal();

  final supabase = Supabase.instance.client;
  static const String appVersion = '1.0.0';

  // In-memory cache of resolved flags with safe defaults
  final Map<String, bool> _flags = {
    'wallet_enabled': true,
    'scheduled_rides_enabled': true,
    'heatmap_enabled': false,
    'realtime_enabled': true,
    'trip_sharing_enabled': true,
    'dispatch_enabled': true,
  };

  /// Initial fetch from remote, with cache fallback
  Future<void> init() async {
    // Disable remote fetching, use in-memory defaults
    debugPrint('FeatureFlagService: Disabled remote fetching, using hardcoded defaults: $_flags');
  }

  Future<void> fetchFlags() async {
    // No-op - remote feature flags are disabled
  }

  bool isEnabled(String key) {
    return _flags[key] ?? false;
  }

  /// Compares version compatibility (returns true if current >= required)
  bool _isVersionCompatible(String current, String required) {
    try {
      // Clean versions (e.g. remove trailing build numbers or spaces)
      final cleanCurrent = current.split('+').first.trim();
      final cleanRequired = required.split('+').first.trim();

      final currentParts = cleanCurrent.split('.').map((e) => int.tryParse(e) ?? 0).toList();
      final requiredParts = cleanRequired.split('.').map((e) => int.tryParse(e) ?? 0).toList();

      final maxLength = currentParts.length > requiredParts.length ? currentParts.length : requiredParts.length;

      for (int i = 0; i < maxLength; i++) {
        final currentPart = i < currentParts.length ? currentParts[i] : 0;
        final requiredPart = i < requiredParts.length ? requiredParts[i] : 0;

        if (currentPart > requiredPart) return true;
        if (currentPart < requiredPart) return false;
      }
      return true;
    } catch (e) {
      debugPrint('Version comparison failed (current: $current, required: $required): $e');
      return false;
    }
  }
}
