import 'package:flutter/material.dart';
import 'package:waydrop/modules/rewards/services/reward_service.dart';
import 'package:waydrop/modules/rewards/widgets/reward_progress_bar.dart';

/// The "WayDrop Rewards" / "Partner Rewards" entry row embedded in both profile screens.
/// Visually mirrors each screen's own private `_MenuTile` (40x40 icon circle, bold title,
/// subtitle, chevron) but adds the locked-state progress bar underneath, and is themed
/// per caller (`iconColor`/`titleColor`/`subtitleColor`) so it matches the passenger
/// profile's light palette and the rider profile's dark/lime palette without hardcoding
/// either. Every string and number shown comes from the `status` map returned by
/// `RewardService.fetchStatus` -- nothing here is hardcoded.
class RewardProfileTile extends StatelessWidget {
  final Map<String, dynamic> status;
  final VoidCallback onTap;
  final IconData icon;
  final Color iconColor;
  final Color iconBgColor;
  final Color titleColor;
  final Color subtitleColor;
  final Color chevronColor;
  final Color progressTrackColor;

  const RewardProfileTile({
    super.key,
    required this.status,
    required this.onTap,
    this.icon = Icons.confirmation_number_rounded,
    required this.iconColor,
    required this.iconBgColor,
    required this.titleColor,
    required this.subtitleColor,
    required this.chevronColor,
    required this.progressTrackColor,
  });

  @override
  Widget build(BuildContext context) {
    final unlocked = RewardService.isUnlocked(status);
    final title = RewardService.titleFor(status);
    final subtitle = RewardService.subtitleFor(status);
    final requiredRides = status['required_rides'] as int? ?? 0;
    final progress = status['progress_within_cycle'] as int? ?? 0;
    final showProgressBar = !unlocked && requiredRides > 0;

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(color: iconBgColor, borderRadius: BorderRadius.circular(12)),
                  child: Icon(unlocked ? Icons.celebration_rounded : icon, color: iconColor, size: 20),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: titleColor)),
                      if (subtitle.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(subtitle, style: TextStyle(fontSize: 11.5, color: subtitleColor, fontWeight: FontWeight.w500)),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(Icons.chevron_right_rounded, color: chevronColor, size: 20),
              ],
            ),
            if (showProgressBar) ...[
              const SizedBox(height: 10),
              Padding(
                padding: const EdgeInsets.only(left: 54),
                child: RewardProgressBar(
                  completed: progress,
                  total: requiredRides,
                  color: iconColor,
                  trackColor: progressTrackColor,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
