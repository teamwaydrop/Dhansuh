import 'package:flutter/material.dart';
import 'package:waydrop/design_system/waydrop_design_system.dart';
import 'package:waydrop/modules/rewards/services/reward_service.dart';
import 'package:waydrop/modules/rewards/screens/category_offers_screen.dart';
import 'package:waydrop/shared/widgets/states/app_empty_state.dart';

/// "WayDrop Rewards" -- the unlocked-rewards landing page. Category cards are entirely
/// database-driven (`reward_offer_categories`) so an admin can add "Gyms", "Salons", etc.
/// later via a Studio row insert with zero Flutter changes. The trailing "More Offers —
/// Coming Soon" card is static UI copy (not DB-backed) since inactive category rows are
/// deliberately not readable by clients (RLS filters `is_active = true`) -- it's just an
/// affordance that there's more to come, not a specific pending category being teased.
class RewardsScreen extends StatefulWidget {
  final String ownerType;

  const RewardsScreen({super.key, required this.ownerType});

  @override
  State<RewardsScreen> createState() => _RewardsScreenState();
}

class _RewardsScreenState extends State<RewardsScreen> {
  late Future<List<Map<String, dynamic>>> _categoriesFuture;
  late Future<Map<String, dynamic>> _statusFuture;

  @override
  void initState() {
    super.initState();
    _categoriesFuture = RewardService.fetchActiveCategories();
    // Re-fetched here (rather than threaded from the profile tile) so the cycle a
    // merchant activation targets is always current at the moment of browsing, not a
    // possibly-stale snapshot from when the profile screen loaded.
    _statusFuture = RewardService.fetchStatus(widget.ownerType);
  }

  static IconData _iconFor(String code) {
    switch (code) {
      case 'restaurants':
        return Icons.restaurant_rounded;
      case 'shopping_malls':
        return Icons.storefront_rounded;
      default:
        return Icons.local_offer_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF0F1115) : WayDropColors.background,
      appBar: AppBar(
        title: const Text('WayDrop Rewards'),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: FutureBuilder<Map<String, dynamic>>(
        future: _statusFuture,
        builder: (context, statusSnapshot) {
          final status = statusSnapshot.data ?? const {'enabled': false};
          final rewardCycleId = RewardService.currentCycleId(status);
          final activationWindowMinutes = RewardService.activationWindowMinutes(status);

          return FutureBuilder<List<Map<String, dynamic>>>(
            future: _categoriesFuture,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              final categories = snapshot.data ?? const [];
              if (categories.isEmpty) {
                return const AppEmptyState(
                  icon: Icons.card_giftcard_rounded,
                  title: 'No offers yet',
                  message: 'Check back soon for new WayDrop offers.',
                );
              }
              return ListView(
                padding: const EdgeInsets.symmetric(vertical: 8),
                children: [
                  for (final category in categories)
                    WayDropCard(
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => CategoryOffersScreen(
                            categoryId: category['id'] as String,
                            categoryName: category['display_name'] as String? ?? '',
                            ownerType: widget.ownerType,
                            rewardCycleId: rewardCycleId,
                            activationWindowMinutes: activationWindowMinutes,
                          ),
                        ),
                      ),
                      child: Row(
                        children: [
                          WayDropIconCircle(icon: _iconFor(category['code'] as String? ?? '')),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Text(
                              category['display_name'] as String? ?? '',
                              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: isDark ? Colors.white : WayDropColors.primaryText),
                            ),
                          ),
                          Icon(Icons.chevron_right_rounded, color: isDark ? const Color(0xFF475569) : const Color(0xFFCBD5E1)),
                        ],
                      ),
                    ),
                  WayDropCard(
                    border: Border.all(color: isDark ? Colors.white.withValues(alpha: 0.06) : const Color(0xFFE2E8F0), width: 1.5),
                    child: Row(
                      children: [
                        WayDropIconCircle(
                          icon: Icons.hourglass_top_rounded,
                          bgColor: isDark ? Colors.white.withValues(alpha: 0.04) : const Color(0xFFF1F5F9),
                          iconColor: isDark ? Colors.white38 : Colors.grey.shade500,
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('More Offers', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: isDark ? Colors.white54 : Colors.grey.shade600)),
                              const SizedBox(height: 2),
                              Text('Coming soon', style: TextStyle(fontSize: 12.5, color: isDark ? Colors.white38 : Colors.grey.shade500)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}
