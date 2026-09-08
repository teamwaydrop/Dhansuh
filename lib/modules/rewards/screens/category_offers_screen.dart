import 'package:flutter/material.dart';
import 'package:waydrop/design_system/waydrop_design_system.dart';
import 'package:waydrop/modules/rewards/services/reward_service.dart';
import 'package:waydrop/modules/rewards/screens/offer_detail_screen.dart';
import 'package:waydrop/shared/widgets/states/app_empty_state.dart';

class CategoryOffersScreen extends StatefulWidget {
  final String categoryId;
  final String categoryName;
  final String ownerType;
  final String? rewardCycleId;
  final int activationWindowMinutes;

  const CategoryOffersScreen({
    super.key,
    required this.categoryId,
    required this.categoryName,
    required this.ownerType,
    required this.rewardCycleId,
    required this.activationWindowMinutes,
  });

  @override
  State<CategoryOffersScreen> createState() => _CategoryOffersScreenState();
}

class _CategoryOffersScreenState extends State<CategoryOffersScreen> {
  late Future<List<Map<String, dynamic>>> _offersFuture;

  @override
  void initState() {
    super.initState();
    _offersFuture = RewardService.fetchOffersForCategory(widget.categoryId);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF0F1115) : WayDropColors.background,
      appBar: AppBar(
        title: Text(widget.categoryName),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _offersFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final offers = snapshot.data ?? const [];
          if (offers.isEmpty) {
            return const AppEmptyState(
              icon: Icons.local_offer_outlined,
              title: 'No offers yet',
              message: 'Check back soon for new offers in this category.',
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: offers.length,
            itemBuilder: (context, index) => _OfferCard(
              offer: offers[index],
              ownerType: widget.ownerType,
              rewardCycleId: widget.rewardCycleId,
              activationWindowMinutes: widget.activationWindowMinutes,
            ),
          );
        },
      ),
    );
  }
}

class _OfferCard extends StatelessWidget {
  final Map<String, dynamic> offer;
  final String ownerType;
  final String? rewardCycleId;
  final int activationWindowMinutes;

  const _OfferCard({
    required this.offer,
    required this.ownerType,
    required this.rewardCycleId,
    required this.activationWindowMinutes,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final merchantName = offer['merchant_name'] as String? ?? '';
    final title = offer['title'] as String? ?? '';
    final discountType = offer['discount_type'] as String? ?? 'percentage';
    final discountValue = (offer['discount_value'] as num?) ?? 0;
    final validUntilStr = offer['valid_until'] as String?;
    final validUntil = validUntilStr != null ? DateTime.tryParse(validUntilStr)?.toLocal() : null;

    return WayDropCard(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => OfferDetailScreen(
            offer: offer,
            ownerType: ownerType,
            rewardCycleId: rewardCycleId,
            activationWindowMinutes: activationWindowMinutes,
          ),
        ),
      ),
      child: Row(
        children: [
          const WayDropIconCircle(icon: Icons.storefront_rounded),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(merchantName, style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w800, color: isDark ? Colors.white : WayDropColors.primaryText)),
                const SizedBox(height: 3),
                Text(title, style: TextStyle(fontSize: 12.5, color: isDark ? Colors.white60 : WayDropColors.secondaryText), maxLines: 1, overflow: TextOverflow.ellipsis),
                if (validUntil != null) ...[
                  const SizedBox(height: 4),
                  Text('Valid until ${validUntil.day}/${validUntil.month}/${validUntil.year}',
                      style: TextStyle(fontSize: 11, color: isDark ? Colors.white38 : Colors.grey.shade500)),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: WayDropColors.primaryEmerald.withValues(alpha: isDark ? 0.18 : 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              RewardService.formatDiscount(discountType, discountValue),
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w900, color: WayDropColors.primaryEmerald),
            ),
          ),
        ],
      ),
    );
  }
}
