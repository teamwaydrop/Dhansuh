import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:waydrop/features/rider/models/partner_service_mode.dart';

enum RiderAccessState {
  unauthenticated,
  none,
  pending,
  rejected,
  blocked,
  approvedWaiting,
  payoutRequired,
  serviceModeRequired,
  ready,
}

class RiderAccess {
  final RiderAccessState state;
  final Map<String, dynamic>? kyc;
  final Map<String, dynamic>? rider;
  const RiderAccess(this.state, {this.kyc, this.rider});
}

/// One decision table for startup, entry, switching mode and dashboard guards.
/// No persistent eligibility cache: approvals/blocks must be rechecked on entry.
class RiderAccessService {
  static final instance = RiderAccessService();
  final Map<String, Future<RiderAccess>> _inFlight = {};

  static RiderAccess decide({
    required bool authenticated,
    Map<String, dynamic>? kyc,
    Map<String, dynamic>? rider,
    required bool activePayout,
    DateTime? now,
  }) {
    RiderAccess result(RiderAccessState state) =>
        RiderAccess(state, kyc: kyc, rider: rider);
    if (!authenticated) return result(RiderAccessState.unauthenticated);
    if (kyc == null) return result(RiderAccessState.none);
    final blocked = DateTime.tryParse(kyc['blocked_until']?.toString() ?? '');
    if (blocked != null && blocked.isAfter(now ?? DateTime.now())) {
      return result(RiderAccessState.blocked);
    }
    if (kyc['activation_status'] == 'suspended' ||
        rider?['account_status'] == 'blocked') {
      return result(RiderAccessState.blocked);
    }
    final status = kyc['kyc_status'];
    if (status == 'rejected') return result(RiderAccessState.rejected);
    // Unknown states fail closed into the existing review flow.
    if (status != 'approved') return result(RiderAccessState.pending);
    if (kyc['activation_status'] != 'active' || rider == null) {
      return result(RiderAccessState.approvedWaiting);
    }
    if (!activePayout) return result(RiderAccessState.payoutRequired);
    if (PartnerServiceMode.fromDb(rider['service_mode']) == null) {
      return result(RiderAccessState.serviceModeRequired);
    }
    return result(RiderAccessState.ready);
  }

  Future<RiderAccess> resolve() async {
    final client = Supabase.instance.client;
    final userId = client.auth.currentUser?.id;
    if (userId == null) {
      return const RiderAccess(RiderAccessState.unauthenticated);
    }
    final existing = _inFlight[userId];
    if (existing != null) return existing;
    final request = _fetch(client, userId);
    _inFlight[userId] = request;
    try {
      return await request;
    } finally {
      _inFlight.remove(userId);
    }
  }

  Future<RiderAccess> _fetch(SupabaseClient client, String userId) async {
    final rows = await Future.wait([
      client
          .from('rider_kyc')
          .select(
            'blocked_until, kyc_status, rejection_reason, activation_status',
          )
          .eq('user_id', userId)
          .maybeSingle(),
      client
          .from('riders')
          .select(
            'id, user_id, kyc_id, rating, account_status, service_mode, subscription_active, subscription_expires_at, free_trial_started_at, free_trial_expires_at, free_trial_used, total_earnings, wallet_balance, cod_pending_amount, cod_limit, government_tax_due_balance, rider_kyc!riders_kyc_id_fkey(full_name, rider_image)',
          )
          .eq('user_id', userId)
          .maybeSingle(),
    ]).timeout(const Duration(seconds: 8));
    var access = decide(
      authenticated: true,
      kyc: rows[0],
      rider: rows[1],
      activePayout: false,
    );
    if (access.state == RiderAccessState.payoutRequired) {
      final payout = await client
          .from('rider_payout_accounts')
          .select('id')
          .eq('user_id', userId)
          .eq('cashfree_beneficiary_status', 'active')
          .limit(1)
          .maybeSingle()
          .timeout(const Duration(seconds: 8));
      access = decide(
        authenticated: true,
        kyc: rows[0],
        rider: rows[1],
        activePayout: payout != null,
      );
    }
    if (client.auth.currentUser?.id != userId) {
      return const RiderAccess(RiderAccessState.unauthenticated);
    }
    return access;
  }
}
