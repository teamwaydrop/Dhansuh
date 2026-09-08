import 'package:supabase_flutter/supabase_flutter.dart';

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

    final user =
        supabase.auth.currentUser;

    if (user == null) {
      return;
    }

    final kyc =
        await getRiderKyc();

    if (kyc == null) {

      throw Exception(
        'KYC not found',
      );
    }

    // =========================================
    // KYC MUST BE APPROVED
    // =========================================

    if (
        kyc['kyc_status'] !=
            'approved'
    ) {

      throw Exception(
        'KYC not approved',
      );
    }

    // =========================================
    // ACCOUNT MUST BE ACTIVE
    // =========================================

    if (
        kyc['activation_status'] !=
            'active'
    ) {

      throw Exception(
        'Drop Partner account not activated',
      );
    }

    // =========================================
    // RIDER PROFILE MUST EXIST
    // =========================================

    final rider =
        await getRiderProfile();

    if (rider == null) {

      throw Exception(
        'Drop Partner profile not ready',
      );
    }

    // =========================================
    // ACTIVE PAYOUT DETAILS REQUIRED
    // =========================================

    final hasPayout = await hasActivePayoutAccount();
    if (!hasPayout) {
      throw Exception(
        'Payout details not registered or active. Please complete bank details setup.',
      );
    }

    // =========================================
    // SERVICE MODE MUST BE CHOSEN
    // =========================================
    // Mirrors RiderEntryHandler's own 'service_mode_required' gate. This
    // direct switchToRiderMode() path (triggered from the User app's
    // Home/Profile "Switch to Drop Partner Mode" action) goes straight to
    // RiderMainNavigationScreen and never passes through RiderEntryHandler,
    // so without this check a rider with service_mode still NULL (e.g. any
    // existing rider right after the service_mode column was introduced)
    // would land on the Home tab with no mode chosen — and the Service Mode
    // card's tap handler intentionally no-ops when mode is null, since it
    // shouldn't be reachable in that state. This check is what keeps that
    // true.
    if (rider['service_mode'] == null) {
      throw Exception('Service Mode not chosen');
    }

    // =========================================
    // UPDATE MODE
    // =========================================

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
        );
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
        );
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