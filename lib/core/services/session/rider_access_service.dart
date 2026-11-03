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

class _RiderAccessFlight {
  final String? credential;
  _RiderAccessFlight(this.credential);
  late final Future<RiderAccess> result;
  int pendingReads = 0;
  bool resultSettled = false;
}

/// One decision table for startup, entry, switching mode and dashboard guards.
/// No persistent eligibility cache: approvals/blocks must be rechecked on entry.
class RiderAccessService {
  static final instance = RiderAccessService();
  final Map<String, _RiderAccessFlight> _inFlight = {};

  static bool requiresLogin(Object failure) =>
      failure is AuthSessionMissingException ||
      (failure is AuthException &&
          (failure.statusCode == '401' || failure.code == 'invalid_jwt')) ||
      (failure is PostgrestException &&
          (failure.code == 'PGRST301' || failure.code == 'PGRST303'));

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
    final credential = client.auth.currentSession?.accessToken;
    if (existing != null && existing.credential == credential) {
      return existing.result;
    }
    final flight = _RiderAccessFlight(credential);
    _inFlight[userId] = flight;
    flight.result = _fetch(client, userId, flight);
    try {
      return await flight.result;
    } finally {
      flight.resultSettled = true;
      _releaseIfSettled(userId, flight);
    }
  }

  void _releaseIfSettled(String userId, _RiderAccessFlight flight) {
    if (flight.resultSettled &&
        flight.pendingReads == 0 &&
        identical(_inFlight[userId], flight)) {
      _inFlight.remove(userId);
    }
  }

  Future<T> _read<T>(
    String userId,
    _RiderAccessFlight flight,
    Future<T> Function() action,
  ) {
    flight.pendingReads++;
    // Materialize the lazy PostgREST builder once. UI .timeout() does not
    // cancel this transport, so ownership must survive until it really settles.
    return Future<T>.sync(action).whenComplete(() {
      flight.pendingReads--;
      _releaseIfSettled(userId, flight);
    });
  }

  Future<RiderAccess> _fetch(
    SupabaseClient client,
    String userId,
    _RiderAccessFlight flight,
  ) async {
    final rows = await Future.wait([
      _read<Map<String, dynamic>?>(
        userId,
        flight,
        () => client
            .from('rider_kyc')
            .select(
              'blocked_until, kyc_status, rejection_reason, activation_status',
            )
            .eq('user_id', userId)
            .maybeSingle(),
      ),
      _read<Map<String, dynamic>?>(
        userId,
        flight,
        () => client
            .from('riders')
            .select(
              'id, user_id, kyc_id, rating, account_status, service_mode, subscription_active, subscription_expires_at, free_trial_started_at, free_trial_expires_at, free_trial_used, total_earnings, wallet_balance, cod_pending_amount, cod_limit, government_tax_due_balance, rider_kyc!riders_kyc_id_fkey(full_name, rider_image)',
            )
            .eq('user_id', userId)
            .maybeSingle(),
      ),
    ]).timeout(const Duration(seconds: 8));
    if (client.auth.currentUser?.id != userId) {
      return const RiderAccess(RiderAccessState.unauthenticated);
    }
    var access = decide(
      authenticated: true,
      kyc: rows[0],
      rider: rows[1],
      activePayout: false,
    );
    if (access.state == RiderAccessState.payoutRequired) {
      final payout = await _read<Map<String, dynamic>?>(
        userId,
        flight,
        () => client
            .from('rider_payout_accounts')
            .select('id')
            .eq('user_id', userId)
            .eq('cashfree_beneficiary_status', 'active')
            .limit(1)
            .maybeSingle(),
      ).timeout(const Duration(seconds: 8));
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
