import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:waydrop/core/services/session/rider_access_service.dart';

class RiderStatusService {

  static final supabase =
      Supabase.instance.client;

  // =====================================================
  // GET RIDER KYC
  // =====================================================

  static Future<Map<String, dynamic>?>
      getRiderKyc() async {

    final user =
        supabase.auth.currentUser;

    if (user == null) {
      return null;
    }

    // Egress fix: getRiderKyc() has no external callers (grepped the whole lib/ tree) -- only
    // switchToRiderMode() below reads kyc_status/activation_status off the result.
    return await supabase

        .from('rider_kyc')

        .select('kyc_status, activation_status')

        .eq(
          'user_id',
          user.id,
        )

        .maybeSingle();
  }

  // =====================================================
  // GET RIDER PROFILE
  // =====================================================

  static Future<Map<String, dynamic>?>
      getRiderProfile() async {

    final user =
        supabase.auth.currentUser;

    if (user == null) {
      return null;
    }

    // Egress fix: getRiderProfile() has no external callers (grepped the whole lib/ tree) --
    // riderProfileExists() only checks existence, switchToRiderMode() only reads service_mode.
    return await supabase

        .from('riders')

        .select('service_mode')

        .eq(
          'user_id',
          user.id,
        )

        .maybeSingle();
  }

  // =====================================================
  // CHECK RIDER PROFILE EXISTS
  // =====================================================

  static Future<bool>
      riderProfileExists() async {

    final rider =
        await getRiderProfile();

    return rider != null;
  }

  static Future<bool> hasActivePayoutAccount() async {
    final user = supabase.auth.currentUser;
    if (user == null) return false;
    try {
      // Egress fix: only existence is checked below.
      final payout = await supabase
          .from('rider_payout_accounts')
          .select('id')
          .eq('user_id', user.id)
          .eq('cashfree_beneficiary_status', 'active')
          .maybeSingle();
      return payout != null;
    } catch (e) {
      return false;
    }
  }

  // =====================================================
  // SWITCH TO RIDER MODE
  // =====================================================

  static Future<void>
      switchToRiderMode() async {

    final access = await RiderAccessService.instance.resolve();
    if (access.state != RiderAccessState.ready) {
      throw Exception('Partner setup incomplete: '+access.state.name);
    }
    final user = supabase.auth.currentUser;
    if (user == null) throw const AuthException('Please sign in again');

    await supabase

        .from('users')

        .update({

      'preferred_mode':
          'rider',

      'last_active_mode':
          'rider',
    })

        .eq(
          'id',
          user.id,
        )
        .or('preferred_mode.is.null,preferred_mode.neq.rider,last_active_mode.is.null,last_active_mode.neq.rider');
  }

  // =====================================================
  // SWITCH TO USER MODE
  // =====================================================

  static Future<void>
      switchToUserMode() async {

    final user =
        supabase.auth.currentUser;

    if (user == null) {
      return;
    }

    await supabase

        .from('users')

        .update({

      'preferred_mode':
          'user',

      'last_active_mode':
          'user',
    })

        .eq(
          'id',
          user.id,
        )
        .or('preferred_mode.is.null,preferred_mode.neq.user,last_active_mode.is.null,last_active_mode.neq.user');
  }

  // =====================================================
  // GET CURRENT MODE
  // =====================================================

  static Future<String>
      getCurrentMode() async {

    final user =
        supabase.auth.currentUser;

    if (user == null) {
      return 'user';
    }

    final profile =
        await supabase

            .from('users')

            .select(
              'preferred_mode',
            )

            .eq(
              'id',
              user.id,
            )

            .single();

    return profile[
            'preferred_mode'] ??
        'user';
  }
}