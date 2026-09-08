import 'package:flutter/material.dart';
import 'package:waydrop/design_system/waydrop_design_system.dart';
import 'package:waydrop/modules/rewards/services/reward_service.dart';
import 'package:waydrop/modules/rewards/screens/active_pass_screen.dart';

/// Pre-activation merchant detail/confirmation screen. Tapping a merchant from the
/// category list lands here -- browsing this screen never consumes anything. Only the
/// explicit "ACTIVATE OFFER" -> confirm-dialog -> server round trip below can ever
/// consume the reward cycle; there is no other path to activation anywhere in this file.
class OfferDetailScreen extends StatefulWidget {
  final Map<String, dynamic> offer;
  final String ownerType;
  final String? rewardCycleId;
  final int activationWindowMinutes;

  const OfferDetailScreen({
    super.key,
    required this.offer,
    required this.ownerType,
    required this.rewardCycleId,
    required this.activationWindowMinutes,
  });

  @override
  State<OfferDetailScreen> createState() => _OfferDetailScreenState();
}

class _OfferDetailScreenState extends State<OfferDetailScreen> {
  bool _activating = false;

  Future<void> _confirmAndActivate() async {
    final cycleId = widget.rewardCycleId;
    if (cycleId == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Activate this offer?'),
        content: Text(
          'Once you activate this offer, it will be available for ${widget.activationWindowMinutes} '
          'minutes only. Show the offer screen at the merchant reception or while paying the bill to '
          'claim the discount. If you go back, leave the app, or the offer times out, the reward is '
          'consumed and cannot be restored.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('CANCEL')),
          ElevatedButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: ElevatedButton.styleFrom(backgroundColor: WayDropColors.primaryEmerald, foregroundColor: Colors.white),
            child: const Text('OK, ACTIVATE OFFER'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() => _activating = true);
    final result = await RewardService.activateOffer(
      ownerType: widget.ownerType,
      rewardCycleId: cycleId,
      offerId: widget.offer['id'] as String,
    );
    if (!mounted) return;
    setState(() => _activating = false);

    if (result['success'] == true) {
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => ActivePassScreen(ownerType: widget.ownerType, activation: result)));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_errorMessage(result['error'] as String?))),
      );
    }
  }

  String _errorMessage(String? error) {
    switch (error) {
      case 'CYCLE_NOT_AVAILABLE':
        return 'This reward is no longer available. It may have already been used or expired.';
      case 'OFFER_NOT_AVAILABLE':
        return 'This offer is no longer available.';
      default:
        return 'Could not activate this offer right now. Please try again.';
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final offer = widget.offer;
    final merchantName = offer['merchant_name'] as String? ?? '';
    final title = offer['title'] as String? ?? '';
    final description = offer['description'] as String?;
    final discountType = offer['discount_type'] as String? ?? 'percentage';
    final discountValue = (offer['discount_value'] as num?) ?? 0;
    final terms = offer['terms'] as String?;
    final address = offer['address'] as String?;
    final phone = offer['phone'] as String?;
    final imageUrl = offer['image_url'] as String?;

    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF0F1115) : WayDropColors.background,
      appBar: AppBar(
        title: const Text('Offer Details'),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          if (imageUrl != null && imageUrl.isNotEmpty)
            ClipRRect(
              child: Image.network(imageUrl, height: 180, width: double.infinity, fit: BoxFit.cover,
                  errorBuilder: (context, error, stackTrace) => const SizedBox.shrink()),
            ),
          const SizedBox(height: 8),
          WayDropCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const WayDropIconCircle(icon: Icons.storefront_rounded),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(merchantName,
                              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: isDark ? Colors.white : WayDropColors.primaryText)),
                          const SizedBox(height: 2),
                          Text(title,
                              style: TextStyle(fontSize: 13, color: isDark ? Colors.white70 : WayDropColors.secondaryText, fontWeight: FontWeight.w600)),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: WayDropColors.primaryEmerald.withValues(alpha: isDark ? 0.16 : 0.08),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(
                    RewardService.formatDiscount(discountType, discountValue),
                    style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900, color: WayDropColors.primaryEmerald, letterSpacing: -0.5),
                  ),
                ),
                if (description != null && description.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Text(description, style: TextStyle(fontSize: 13.5, color: isDark ? Colors.white70 : WayDropColors.secondaryText, height: 1.4)),
                ],
              ],
            ),
          ),

          WayDropCard(
            border: Border.all(color: WayDropColors.goldAccent.withValues(alpha: 0.4), width: 1.2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.timer_outlined, size: 18, color: isDark ? WayDropColors.goldAccent : WayDropColors.primaryEmerald),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Once activated, this offer is available for ${widget.activationWindowMinutes} minutes only. '
                    'Show it at reception or at bill payment. Going back or leaving the app ends the offer.',
                    style: TextStyle(fontSize: 12.5, color: isDark ? Colors.white70 : WayDropColors.primaryText, height: 1.4, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),

          if (terms != null && terms.isNotEmpty)
            WayDropCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Terms', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: isDark ? Colors.white54 : WayDropColors.secondaryText, letterSpacing: 0.5)),
                  const SizedBox(height: 8),
                  Text(terms, style: TextStyle(fontSize: 12.5, color: isDark ? Colors.white60 : Colors.grey.shade600, height: 1.4)),
                ],
              ),
            ),

          if ((address != null && address.isNotEmpty) || (phone != null && phone.isNotEmpty))
            WayDropCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Merchant Contact', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: isDark ? Colors.white54 : WayDropColors.secondaryText, letterSpacing: 0.5)),
                  const SizedBox(height: 8),
                  if (address != null && address.isNotEmpty)
                    Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Icon(Icons.location_on_outlined, size: 16, color: isDark ? Colors.white54 : WayDropColors.secondaryText),
                      const SizedBox(width: 8),
                      Expanded(child: Text(address, style: TextStyle(fontSize: 13, color: isDark ? Colors.white70 : WayDropColors.primaryText))),
                    ]),
                  if (phone != null && phone.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Row(children: [
                      Icon(Icons.call_outlined, size: 16, color: isDark ? Colors.white54 : WayDropColors.secondaryText),
                      const SizedBox(width: 8),
                      Text(phone, style: TextStyle(fontSize: 13, color: isDark ? Colors.white70 : WayDropColors.primaryText)),
                    ]),
                  ],
                ],
              ),
            ),

          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: WayDropPrimaryButton(
              text: 'ACTIVATE OFFER',
              loading: _activating,
              onPressed: widget.rewardCycleId == null ? null : _confirmAndActivate,
            ),
          ),
        ],
      ),
    );
  }
}
