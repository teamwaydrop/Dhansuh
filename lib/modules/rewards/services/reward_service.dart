import 'package:supabase_flutter/supabase_flutter.dart';

/// Phase 14: WayDrop Rewards/Coupons. Server-authoritative throughout -- every value
/// this service returns comes from the `get_reward_status` RPC (see
/// supabase/migrations/20260902000000_waydrop_rewards_system.sql), which resolves the
/// caller's own identity from auth.uid() itself and returns whether the feature is
/// enabled, the configured threshold/validity/discount, and current progress. Nothing
/// here computes or caches ride counts, thresholds, or unlock state client-side --
/// this class only shapes the already-authoritative server response for the UI.
///
/// Used by both the passenger and rider profile screens (via ownerType 'user'/'rider')
/// and by the Rewards/offers screens -- kept in `modules/` (not `features/`) because it
/// is feature-agnostic and shared across both verticals, per ARCHITECTURE.md.
class RewardService {
  static final SupabaseClient _client = Supabase.instance.client;

  /// Returns the caller's own reward status for [ownerType] ('user' or 'rider').
  /// Shape (see the RPC's own doc comment):
  /// { enabled, required_rides, offer_validity_days, default_discount_type,
  ///   default_discount_value, qualifying_ride_count, current_cycle_number,
  ///   progress_within_cycle, rides_remaining, active_cycle_count, active_cycles: [...] }
  /// A disabled feature (or any fetch failure) returns `{'enabled': false}` -- callers
  /// must render nothing in that case, exactly as if the feature did not exist.
  static Future<Map<String, dynamic>> fetchStatus(String ownerType) async {
    try {
      final result = await _client.rpc('get_reward_status', params: {'p_owner_type': ownerType});
      if (result is Map<String, dynamic>) return result;
      return {'enabled': false};
    } catch (_) {
      // Fail closed and silent -- a network/RPC error must never surface as an error
      // banner on the profile screen; it just means the reward entry doesn't render
      // this load, same as "feature disabled".
      return {'enabled': false};
    }
  }

  static Future<List<Map<String, dynamic>>> fetchActiveCategories() async {
    final rows = await _client
        .from('reward_offer_categories')
        .select('id, code, display_name, sort_order')
        .eq('is_active', true)
        .order('sort_order');
    return List<Map<String, dynamic>>.from(rows);
  }

  static Future<List<Map<String, dynamic>>> fetchOffersForCategory(String categoryId) async {
    final rows = await _client
        .from('reward_offers')
        .select()
        .eq('category_id', categoryId)
        .order('sort_order');
    return List<Map<String, dynamic>>.from(rows);
  }

  static bool isUnlocked(Map<String, dynamic> status) {
    return status['enabled'] == true && (status['active_cycle_count'] as int? ?? 0) > 0;
  }

  static bool isFeatureEnabled(Map<String, dynamic> status) => status['enabled'] == true;

  /// The one-line copy shown on the profile card, matching the exact locked/unlocked
  /// wording requested for Phase 14. Never hardcodes the threshold -- always reads
  /// `rides_remaining`/`active_cycle_count`/the nearest cycle's `days_remaining` off the
  /// server response.
  static String subtitleFor(Map<String, dynamic> status) {
    if (!isFeatureEnabled(status)) return '';

    final activeCount = status['active_cycle_count'] as int? ?? 0;
    if (activeCount > 0) {
      final cycles = status['active_cycles'] as List? ?? const [];
      final daysRemaining = cycles.isNotEmpty ? (cycles.first['days_remaining'] as num?)?.toInt() ?? 0 : 0;
      if (activeCount > 1) {
        return '$activeCount rewards available • Valid for $daysRemaining more ${daysRemaining == 1 ? "day" : "days"}';
      }
      return 'Valid for $daysRemaining more ${daysRemaining == 1 ? "day" : "days"}';
    }

    final remaining = status['rides_remaining'] as int? ?? status['required_rides'] as int? ?? 0;
    final total = status['required_rides'] as int? ?? 0;
    final progress = status['progress_within_cycle'] as int? ?? 0;
    if (progress == 0 && (status['qualifying_ride_count'] as int? ?? 0) == 0) {
      return 'Complete $total ${total == 1 ? "ride" : "rides"} to unlock offers';
    }
    return 'Complete $remaining more ${remaining == 1 ? "ride" : "rides"}';
  }

  static String titleFor(Map<String, dynamic> status) {
    return isUnlocked(status) ? 'Offers unlocked' : 'WayDrop Rewards';
  }

  static String formatDiscount(String discountType, num discountValue) {
    if (discountType == 'flat') return '₹${discountValue.toStringAsFixed(0)} OFF';
    return '${discountValue.toStringAsFixed(discountValue % 1 == 0 ? 0 : 1)}% OFF';
  }

  /// The specific cycle a client should activate against right now (whichever active,
  /// unexpired cycle expires soonest) -- null if none. Comes straight from
  /// `get_reward_status`'s `current_cycle_id`; never computed client-side.
  static String? currentCycleId(Map<String, dynamic> status) => status['current_cycle_id'] as String?;

  /// The configurable activation-pass duration in minutes (default 5, see
  /// `reward_config.activation_window_minutes`) -- read from the server response so it
  /// is never hardcoded in more than the one place that formats copy with it.
  static int activationWindowMinutes(Map<String, dynamic> status) => status['activation_window_minutes'] as int? ?? 5;

  /// Activates the given [offerId] against [rewardCycleId] -- the single
  /// server-authoritative mutation for the entire reward-activation flow. Consumes the
  /// reward cycle permanently and opens a time-boxed pass in one atomic backend
  /// operation; this call either fully succeeds (pass details returned) or fully fails
  /// (nothing changes) -- there is no client-side "already used?" check to race.
  /// Shape on success: { success: true, reward_cycle_id, merchant_name, offer_title,
  /// discount_type, discount_value, activated_at, expires_at }.
  /// Shape on failure: { success: false, error: 'CYCLE_NOT_AVAILABLE' | 'OFFER_NOT_AVAILABLE'
  /// | 'OWNER_NOT_FOUND' | 'INVALID_OWNER_TYPE' | 'CONFIG_NOT_FOUND' | 'NETWORK_ERROR' }.
  static Future<Map<String, dynamic>> activateOffer({
    required String ownerType,
    required String rewardCycleId,
    required String offerId,
  }) async {
    try {
      final result = await _client.rpc('activate_reward_offer', params: {
        'p_owner_type': ownerType,
        'p_reward_cycle_id': rewardCycleId,
        'p_offer_id': offerId,
      });
      if (result is Map<String, dynamic>) return result;
      return {'success': false, 'error': 'NETWORK_ERROR'};
    } catch (_) {
      return {'success': false, 'error': 'NETWORK_ERROR'};
    }
  }

  /// Best-effort, fire-and-forget notification that the active pass ended on the client
  /// side (back navigation or app backgrounding) -- never awaited by UI logic and never
  /// throws. Not the security boundary: the reward cycle is already permanently consumed
  /// by [activateOffer] regardless of whether this call ever reaches the server.
  static Future<void> closeActivePass({required String ownerType, required String rewardCycleId}) async {
    try {
      await _client.rpc('close_active_pass', params: {
        'p_owner_type': ownerType,
        'p_reward_cycle_id': rewardCycleId,
      });
    } catch (_) {
      // Best-effort only -- nothing to recover, nothing to surface to the user.
    }
  }
}
