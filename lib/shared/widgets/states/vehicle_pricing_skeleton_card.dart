import 'package:flutter/material.dart';
import 'package:waydrop/shared/widgets/states/app_skeleton_card.dart';

class VehiclePricingSkeletonCard extends StatelessWidget {
  const VehiclePricingSkeletonCard({super.key});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF171A21) : Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0),
          width: 1.5,
        ),
      ),
      child: Row(
        children: [
          // Vehicle icon image placeholder
          const AppSkeletonCard(
            width: 64,
            height: 64,
            borderRadius: 16,
          ),
          const SizedBox(width: 16),
          // Vehicle Name & ETA text details placeholder
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const AppSkeletonCard(
                  width: 120,
                  height: 16,
                  borderRadius: 4,
                ),
                const SizedBox(height: 8),
                const AppSkeletonCard(
                  width: 80,
                  height: 12,
                  borderRadius: 4,
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          // Estimated Price loading placeholder
          const AppSkeletonCard(
            width: 70,
            height: 20,
            borderRadius: 6,
          ),
        ],
      ),
    );
  }
}
