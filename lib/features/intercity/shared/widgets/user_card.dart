import 'package:flutter/material.dart';
import 'package:waydrop/features/intercity/shared/services/intercity_matching_service.dart';
import 'package:waydrop/features/intercity/shared/widgets/verified_badge.dart';
import 'package:waydrop/shared/helpers/time_format_helper.dart';

/// User Card shown to a Partner browsing Travel Requests for their own plan (Part 9): profile
/// photo, name, verified badge, passenger count, pickup, destination, travel date/time, rating,
/// reviews count, and a "Travel Together" button.
///
/// Expects an `orders` row shaped like match-intercity-riders Mode 2's `matches` response, joined
/// with `users(full_name, phone, rating, total_ratings, profile_completed)`.
class UserCard extends StatelessWidget {
  final Map<String, dynamic> order;
  final bool isSending;
  final bool alreadySent;
  final VoidCallback onTravelTogether;

  const UserCard({
    super.key,
    required this.order,
    required this.onTravelTogether,
    this.isSending = false,
    this.alreadySent = false,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardColor = isDark ? const Color(0xFF171A21) : Colors.white;
    final textColor = isDark ? Colors.white : const Color(0xFF1A1A1A);
    final subTextColor = isDark ? const Color(0xFFA9B0BE) : const Color(0xFF6B7280);

    final userInfo = (order['users'] as Map<String, dynamic>?) ?? const {};
    final name = (userInfo['full_name'] ?? 'Passenger').toString();
    final isVerified = userInfo['profile_completed'] == true;
    final rating = double.tryParse((userInfo['rating'] ?? 5).toString()) ?? 5.0;
    final reviewsCount = userInfo['total_ratings'] ?? 0;
    final passengersCount = order['seats_requested'] ?? 1;
    final pickup = (order['pickup_city'] ?? order['pickup_address'] ?? '').toString();
    final destination = (order['destination_city'] ?? order['destination_address'] ?? '').toString();
    final travelDateRaw = order['travel_date'] ?? order['created_at'];
    final travelDate = travelDateRaw != null ? DateTime.tryParse(travelDateRaw.toString())?.toLocal() : null;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: isDark ? Colors.white10 : const Color(0xFFE5E7EB)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 22,
                backgroundColor: isDark ? Colors.white10 : const Color(0xFFF3F4F6),
                child: Icon(Icons.person, color: subTextColor),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(name,
                              style: TextStyle(color: textColor, fontWeight: FontWeight.bold, fontSize: 14),
                              overflow: TextOverflow.ellipsis),
                        ),
                        const SizedBox(width: 4),
                        VerifiedBadge(isVerified: isVerified),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        const Icon(Icons.star_rounded, size: 14, color: Color(0xFFFBBF24)),
                        const SizedBox(width: 2),
                        Text('${rating.toStringAsFixed(1)} ($reviewsCount)',
                            style: TextStyle(color: subTextColor, fontSize: 12)),
                      ],
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Icon(Icons.people_alt_rounded, size: 16, color: subTextColor),
                  Text('$passengersCount pax', style: TextStyle(color: subTextColor, fontSize: 11)),
                ],
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text('$pickup → $destination',
              style: TextStyle(color: textColor, fontSize: 13, fontWeight: FontWeight.w600),
              overflow: TextOverflow.ellipsis),
          if (travelDate != null) ...[
            const SizedBox(height: 4),
            Text(
              '${IntercityMatchingService.formatShortDate(travelDate)} • ${TimeFormatHelper.formatTime12Hour(travelDate)}',
              style: TextStyle(color: subTextColor, fontSize: 12),
            ),
          ],
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: (isSending || alreadySent) ? null : () {
                debugPrint('[RUNTIME_TRACE] Travel Together button pressed (user_card.dart) orderId=${order['id']}');
                onTravelTogether();
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: alreadySent ? const Color(0xFF2A2F3A) : const Color(0xFFC5FF30),
                foregroundColor: alreadySent ? Colors.white54 : Colors.black,
                disabledBackgroundColor: alreadySent ? const Color(0xFF2A2F3A) : null,
                disabledForegroundColor: alreadySent ? Colors.white54 : null,
                padding: const EdgeInsets.symmetric(vertical: 10),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              child: isSending
                  ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(
                      alreadySent ? 'Request Sent ✓' : 'Travel Together',
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
