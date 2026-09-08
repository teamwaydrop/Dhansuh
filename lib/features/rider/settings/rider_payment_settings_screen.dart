import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:waydrop/core/services/cache/qr_image_cache_manager.dart';
import 'package:waydrop/core/services/cache/qr_signed_url_cache.dart';
import 'package:waydrop/core/services/database/rider_payout_account_cache.dart';
import 'package:waydrop/features/rider/onboarding/screens/rider_payout_details_screen.dart';
import 'package:waydrop/shared/widgets/app_snackbar.dart';

/// Lets a driver choose how passengers pay them at trip completion -- their own self-certified
/// personal UPI (default; no Cashfree fee) or Cashfree checkout (always available, platform-
/// collected, fee applies). Reads rider_payout_accounts directly and writes via the narrow
/// set_default_fare_payment_method RPC (which refuses to switch to personal_upi unless the VPA on
/// file has been self-certified). "Self-certified" is the driver's own explicit confirmation of
/// ownership (see rider_payout_details_screen) -- not a Cashfree/gateway verification, which this
/// account has no access to and which is never depended on or faked.
class RiderPaymentSettingsScreen extends StatefulWidget {
  const RiderPaymentSettingsScreen({super.key});

  @override
  State<RiderPaymentSettingsScreen> createState() => _RiderPaymentSettingsScreenState();
}

class _RiderPaymentSettingsScreenState extends State<RiderPaymentSettingsScreen> {
  static const Color primaryLime = Color(0xFFC5FF30);
  static const Color primaryGreen = Color(0xFF10B981);
  static const Color darkBg = Color(0xFF0B0F19);
  static const Color darkCard = Color(0xFF131926);
  static const Color textGray = Color(0xFF94A3B8);

  final supabase = Supabase.instance.client;

  bool _loading = true;
  bool _switching = false;
  Map<String, dynamic>? _payoutAccount;
  String? _qrPreviewUrl;

  @override
  void initState() {
    super.initState();
    _loadPayoutAccount();
  }

  Future<void> _loadPayoutAccount() async {
    setState(() => _loading = true);
    try {
      final user = supabase.auth.currentUser;
      if (user == null) return;

      // Egress fix (Fix #6 completion): shared via RiderPayoutAccountCache with the other
      // display/edit reads of this same row -- see that class's doc comment.
      final result = await RiderPayoutAccountCache.get(
        user.id,
        () => supabase
            .from('rider_payout_accounts')
            .select(
              'beneficiary_name, beneficiary_phone, beneficiary_email, upi_vpa, '
              'personal_qr_path, account_number, ifsc_code, beneficiary_id, '
              'cashfree_beneficiary_status, default_fare_payment_method, upi_self_certified',
            )
            .eq('user_id', user.id)
            .maybeSingle(),
      );

      String? qrUrl;
      final qrPath = result?['personal_qr_path']?.toString();
      if (qrPath != null && qrPath.isNotEmpty) {
        try {
          // Egress fix (Fix #10B): cached per storage path for its ~1hr validity instead of
          // re-signing on every screen open.
          qrUrl = await QrSignedUrlCache.get(
            qrPath,
            () => supabase.storage.from('driver_personal_qr').createSignedUrl(qrPath, 3600),
          );
        } catch (e) {
          debugPrint('RIDER PAYMENT SETTINGS => failed to sign QR url: $e');
        }
      }

      if (!mounted) return;
      setState(() {
        _payoutAccount = result;
        _qrPreviewUrl = qrUrl;
        _loading = false;
      });
    } catch (e) {
      debugPrint('RIDER PAYMENT SETTINGS => failed to load payout account: $e');
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _setMethod(String method) async {
    if (_switching) return;
    setState(() => _switching = true);

    try {
      final response = await supabase.rpc(
        'set_default_fare_payment_method',
        params: {'p_method': method},
      );

      final success = response is Map && response['success'] == true;
      if (!mounted) return;

      if (success) {
        RiderPayoutAccountCache.invalidate();
        await _loadPayoutAccount();
        if (!mounted) return;
        showAppSnackBar(context, 'Default payment method updated.', type: SnackBarType.success);
      } else {
        final message = (response is Map ? response['message']?.toString() : null) ??
            'Could not update your payment method.';
        showAppSnackBar(context, message, type: SnackBarType.error);
      }
    } catch (e) {
      debugPrint('SET DEFAULT FARE PAYMENT METHOD ERROR => $e');
      if (!mounted) return;
      showAppSnackBar(context, 'Could not update your payment method. Try again.', type: SnackBarType.error);
    } finally {
      if (mounted) setState(() => _switching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final vpa = _payoutAccount?['upi_vpa']?.toString();
    // Driver's own ownership confirmation -- not a Cashfree/gateway verification. Never shown to
    // passengers or drivers as "Verified".
    final selfCertified = _payoutAccount?['upi_self_certified'] == true;
    final currentMethod = _payoutAccount?['default_fare_payment_method']?.toString() ?? 'personal_upi';
    final hasVpa = vpa != null && vpa.isNotEmpty;

    return Scaffold(
      backgroundColor: darkBg,
      appBar: AppBar(
        backgroundColor: darkBg,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white, size: 20),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text(
          'Payment Settings',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 20),
        ),
        centerTitle: true,
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator(color: primaryLime))
            : _payoutAccount == null
                ? _buildNoAccountState()
                : ListView(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                    children: [
                      const Padding(
                        padding: EdgeInsets.only(left: 4, bottom: 12),
                        child: Text(
                          'DEFAULT FARE PAYMENT METHOD',
                          style: TextStyle(
                            color: primaryLime,
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.2,
                          ),
                        ),
                      ),
                      _buildMethodOption(
                        method: 'personal_upi',
                        title: 'Personal UPI (Recommended)',
                        subtitle: hasVpa
                            ? (selfCertified
                                ? 'Passengers pay you directly -- no Cashfree fee.'
                                : 'Confirm your UPI ID in Payout Details before you can select this.')
                            : 'Add a UPI ID in your payout details first.',
                        icon: Icons.qr_code_rounded,
                        selected: currentMethod == 'personal_upi',
                        enabled: hasVpa && selfCertified,
                      ),
                      const SizedBox(height: 12),
                      _buildMethodOption(
                        method: 'cashfree',
                        title: 'Cashfree Checkout',
                        subtitle: 'Passenger pays via Cashfree checkout; settles to your wallet. Cashfree fee applies.',
                        icon: Icons.account_balance_wallet_rounded,
                        selected: currentMethod == 'cashfree',
                        enabled: true,
                      ),
                      const SizedBox(height: 28),
                      if (hasVpa) ...[
                        const Padding(
                          padding: EdgeInsets.only(left: 4, bottom: 12),
                          child: Text(
                            'YOUR PERSONAL QR',
                            style: TextStyle(
                              color: primaryLime,
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 1.2,
                            ),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.all(20),
                          decoration: BoxDecoration(
                            color: darkCard,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: Colors.white.withValues(alpha: 0.05), width: 1.5),
                          ),
                          child: Column(
                            children: [
                              Container(
                                width: 160,
                                height: 160,
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                clipBehavior: Clip.antiAlias,
                                child: _qrPreviewUrl != null
                                    ? CachedNetworkImage(
                                        imageUrl: _qrPreviewUrl!,
                                        fit: BoxFit.contain,
                                        cacheManager: QrImageCacheManager.instance,
                                        memCacheWidth: (160 * MediaQuery.of(context).devicePixelRatio).round(),
                                        memCacheHeight: (160 * MediaQuery.of(context).devicePixelRatio).round(),
                                      )
                                    : const Center(
                                        child: Icon(Icons.qr_code_2_rounded, color: Color(0xFFCBD5E1), size: 56),
                                      ),
                              ),
                              const SizedBox(height: 16),
                              Text(
                                vpa,
                                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 15),
                              ),
                              const SizedBox(height: 8),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    selfCertified ? Icons.check_circle_rounded : Icons.error_outline_rounded,
                                    size: 16,
                                    color: selfCertified ? primaryGreen : const Color(0xFFEF4444),
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    selfCertified ? 'Confirmed by you' : 'Not confirmed yet',
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                      color: selfCertified ? primaryGreen : const Color(0xFFEF4444),
                                    ),
                                  ),
                                ],
                              ),
                              if (_qrPreviewUrl == null) ...[
                                const SizedBox(height: 8),
                                const Text(
                                  'No Personal QR uploaded yet -- add one in Edit Payment Details.',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(fontSize: 11, color: textGray, fontWeight: FontWeight.w600),
                                ),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(height: 20),
                      ],
                      SizedBox(
                        width: double.infinity,
                        height: 50,
                        child: OutlinedButton.icon(
                          onPressed: () async {
                            await Navigator.push(
                              context,
                              MaterialPageRoute(builder: (_) => const RiderPayoutDetailsScreen()),
                            );
                            _loadPayoutAccount();
                          },
                          icon: const Icon(Icons.edit_rounded, color: primaryLime, size: 18),
                          label: const Text(
                            'Edit Payment Details',
                            style: TextStyle(color: primaryLime, fontWeight: FontWeight.w800, fontSize: 13),
                          ),
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(color: primaryLime, width: 1.5),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                          ),
                        ),
                      ),
                      const SizedBox(height: 40),
                    ],
                  ),
      ),
    );
  }

  Widget _buildNoAccountState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.account_balance_wallet_outlined, color: textGray, size: 48),
            const SizedBox(height: 16),
            const Text(
              'Complete your payout details first',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: () async {
                await Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const RiderPayoutDetailsScreen()),
                );
                _loadPayoutAccount();
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: primaryLime,
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              child: const Text('Set Up Payout Details', style: TextStyle(fontWeight: FontWeight.w800)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMethodOption({
    required String method,
    required String title,
    required String subtitle,
    required IconData icon,
    required bool selected,
    required bool enabled,
  }) {
    return GestureDetector(
      onTap: (!enabled || selected || _switching) ? null : () => _setMethod(method),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: darkCard,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected ? primaryLime : Colors.white.withValues(alpha: 0.05),
            width: selected ? 2 : 1.5,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: selected ? primaryLime.withValues(alpha: 0.15) : Colors.white.withValues(alpha: 0.04),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: enabled ? (selected ? primaryLime : Colors.white) : textGray, size: 20),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: enabled ? Colors.white : textGray,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(subtitle, style: const TextStyle(fontSize: 11, color: textGray)),
                ],
              ),
            ),
            if (_switching)
              const SizedBox(
                height: 18,
                width: 18,
                child: CircularProgressIndicator(strokeWidth: 2, color: primaryLime),
              )
            else if (selected)
              const Icon(Icons.check_circle_rounded, color: primaryLime, size: 22)
            else
              Icon(Icons.circle_outlined, color: Colors.white.withValues(alpha: 0.2), size: 22),
          ],
        ),
      ),
    );
  }
}
