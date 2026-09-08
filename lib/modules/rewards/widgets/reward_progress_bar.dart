import 'package:flutter/material.dart';

/// "[████████░░] 2 / 3" style progress indicator for the reward-unlock card. `completed`
/// and `total` always come from the server (`get_reward_status`'s `progress_within_cycle`
/// / `required_rides`) -- never a hardcoded threshold.
class RewardProgressBar extends StatelessWidget {
  final int completed;
  final int total;
  final Color color;
  final Color? trackColor;

  const RewardProgressBar({
    super.key,
    required this.completed,
    required this.total,
    required this.color,
    this.trackColor,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fraction = total > 0 ? (completed / total).clamp(0.0, 1.0) : 0.0;

    return Row(
      children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: fraction,
              minHeight: 8,
              backgroundColor: trackColor ?? (isDark ? Colors.white.withValues(alpha: 0.08) : const Color(0xFFE2E8F0)),
              valueColor: AlwaysStoppedAnimation<Color>(color),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Text(
          '$completed / $total',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w800,
            color: isDark ? Colors.white70 : const Color(0xFF475569),
          ),
        ),
      ],
    );
  }
}
