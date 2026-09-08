import 'package:flutter/material.dart';
import 'package:waydrop/features/intercity/shared/services/intercity_matching_service.dart';
import 'package:waydrop/features/intercity/shared/widgets/verified_badge.dart';
import 'package:waydrop/shared/helpers/time_format_helper.dart';

/// Same authoritative 'bike' | 'auto' | 'cab' vehicle_type values used everywhere else in the app
/// (e.g. intercity_tracking_screen.dart's Vehicle Verification row) -- this card previously always
/// rendered a hardcoded car icon regardless of the actual vehicle_type, so the icon next to a
/// correctly-labelled "BIKE • ..." or "AUTO • ..." row never matched the text.
IconData _vehicleIconFor(String vehicleType) {
  switch (vehicleType.toLowerCase()) {
    case 'bike':
      return Icons.two_wheeler_rounded;
    case 'auto':
      return Icons.electric_rickshaw_rounded;
    default:
      return Icons.directions_car_filled_rounded;
  }
}

/// Partner Card shown to a User browsing the Available Partners screen (Part 8): profile photo,
/// name, verified badge, vehicle, vehicle number, available seats, pickup, destination, travel
/// date/time, estimated fare, rating, reviews count, and a "Travel Together" button.
///
/// Expects the shape produced by IntercityMatchingService.fetchAvailablePartnersForDate().
class PartnerCard extends StatelessWidget {
  final Map<String, dynamic> partner;
  final bool isSending;
  final bool alreadySent;
  final bool isParcel;
  final VoidCallback onTravelTogether;

  /// When a request already exists for this partner and has progressed beyond a bare
  /// "sent" state (negotiating, accepted, rejected, in transit, ...), the caller renders
  /// its own status row (badge + reject/call/chat actions) here instead of the default
  /// Travel Together / Request Sent ✓ button — keeps one card layout for both the
  /// pre-request and in-negotiation states instead of two separate card implementations.
  final Widget? statusWidget;

  // Optional: the VIEWER'S OWN payable fare for their own trip (final_fare ?? current_fare on
  // their order), as opposed to `partner['price_per_seat']` (the traveller's rate for their own,
  // usually different-distance, posted route). When provided, this is what's shown as the primary
  // price -- and is also what actually gets sent as proposed_fare -- so the number displayed here
  // always matches what the passenger will actually be charged. Null preserves the previous
  // behavior for callers (e.g. the traveller-side searching screen) that don't have a single
  // "viewer's own order" to price against.
  final double? yourFare;

  const PartnerCard({
    super.key,
    required this.partner,
    required this.onTravelTogether,
    this.isSending = false,
    this.alreadySent = false,
    this.isParcel = false,
    this.statusWidget,
    this.yourFare,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardColor = isDark ? const Color(0xFF171A21) : Colors.white;
    final textColor = isDark ? Colors.white : const Color(0xFF1A1A1A);
    final subTextColor = isDark ? const Color(0xFFA9B0BE) : const Color(0xFF6B7280);

    final name = (partner['full_name'] ?? 'Rider Partner').toString();
    final isVerified = partner['is_verified'] == true;
    final vehicleType = (partner['vehicle_type'] ?? 'Vehicle').toString();
    final vehicleNumber = (partner['vehicle_number'] ?? '').toString();
    final availableSeats = partner['available_seats'] ?? 0;
    final weightCapacityKg = double.tryParse((partner['remaining_capacity_kg'] ?? partner['max_weight_kg'] ?? 50.0).toString()) ?? 50.0;
    final pickup = (partner['pickup_city'] ?? '').toString();
    final destination = (partner['destination_city'] ?? '').toString();
    final travelDate = partner['travel_date'] != null ? DateTime.tryParse(partner['travel_date'].toString())?.toLocal() : null;
    final pricePerSeat = double.tryParse((partner['price_per_seat'] ?? 0).toString()) ?? 0;
    final rating = double.tryParse((partner['rating'] ?? 5).toString()) ?? 5.0;
    final reviewsCount = partner['reviews_count'] ?? 0;
    final riderImage = (partner['rider_image'] ?? '').toString();
    final completedTrips = (partner['completed_trips'] as num?)?.toInt() ?? 0;
    final distanceFromPickupKm = partner['distance_from_pickup_km'] as double?;
    final estimatedArrivalMinutes = partner['estimated_arrival_minutes'] as int?;

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
                backgroundImage: riderImage.isNotEmpty ? NetworkImage(riderImage) : null,
                child: riderImage.isEmpty ? Icon(Icons.person, color: subTextColor) : null,
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
                  Text('₹${(yourFare ?? pricePerSeat).toStringAsFixed(0)}',
                      style: const TextStyle(color: Color(0xFF10B981), fontWeight: FontWeight.bold, fontSize: 15)),
                  Text(yourFare != null ? 'your fare' : (isParcel ? 'estimate' : 'per seat'),
                      style: TextStyle(color: subTextColor, fontSize: 10)),
                ],
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Icon(_vehicleIconFor(vehicleType), size: 14, color: subTextColor),
              const SizedBox(width: 4),
              Text(vehicleType.toUpperCase(), style: TextStyle(color: subTextColor, fontSize: 11)),
              if (vehicleNumber.isNotEmpty) ...[
                const SizedBox(width: 6),
                Text('• $vehicleNumber', style: TextStyle(color: subTextColor, fontSize: 11)),
              ],
              const SizedBox(width: 10),
              if (isParcel) ...[
                Icon(Icons.scale_rounded, size: 14, color: subTextColor),
                const SizedBox(width: 4),
                Text('Up to ${weightCapacityKg.toStringAsFixed(1)} kg', style: TextStyle(color: subTextColor, fontSize: 11)),
              ] else ...[
                Icon(Icons.event_seat_rounded, size: 14, color: subTextColor),
                const SizedBox(width: 4),
                Text('$availableSeats seats left', style: TextStyle(color: subTextColor, fontSize: 11)),
              ],
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text('$pickup → $destination',
                    style: TextStyle(color: textColor, fontSize: 13, fontWeight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
          if (travelDate != null) ...[
            const SizedBox(height: 4),
            Text(
              '${IntercityMatchingService.formatShortDate(travelDate)} • ${TimeFormatHelper.formatTime12Hour(travelDate)}',
              style: TextStyle(color: subTextColor, fontSize: 12),
            ),
          ],
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(Icons.military_tech_rounded, size: 14, color: subTextColor),
              const SizedBox(width: 4),
              Text('$completedTrips trips completed', style: TextStyle(color: subTextColor, fontSize: 11)),
              if (distanceFromPickupKm != null) ...[
                const SizedBox(width: 10),
                Icon(Icons.social_distance_rounded, size: 14, color: subTextColor),
                const SizedBox(width: 4),
                Text('${distanceFromPickupKm.toStringAsFixed(1)} km away', style: TextStyle(color: subTextColor, fontSize: 11)),
              ],
              if (estimatedArrivalMinutes != null) ...[
                const SizedBox(width: 10),
                Icon(Icons.timer_outlined, size: 14, color: subTextColor),
                const SizedBox(width: 4),
                Text('ETA $estimatedArrivalMinutes min', style: TextStyle(color: subTextColor, fontSize: 11)),
              ],
            ],
          ),
          const SizedBox(height: 12),
          if (statusWidget != null)
            statusWidget!
          else
            Row(
              children: [
                OutlinedButton(
                  onPressed: () => _showProfileSheet(context, isDark, name: name, isVerified: isVerified,
                      rating: rating, reviewsCount: reviewsCount, completedTrips: completedTrips,
                      vehicleType: vehicleType, vehicleNumber: vehicleNumber, riderImage: riderImage),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: textColor,
                    side: BorderSide(color: isDark ? Colors.white24 : const Color(0xFFD1D5DB)),
                    padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  child: const Text('View Profile', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton(
                    onPressed: (isSending || alreadySent) ? null : () {
                      debugPrint('[RUNTIME_TRACE] Travel Together button pressed (partner_card.dart) riderId=${partner['rider_id']}');
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
        ],
      ),
    );
  }

  void _showProfileSheet(
    BuildContext context,
    bool isDark, {
    required String name,
    required bool isVerified,
    required double rating,
    required dynamic reviewsCount,
    required int completedTrips,
    required String vehicleType,
    required String vehicleNumber,
    required String riderImage,
  }) {
    final cardColor = isDark ? const Color(0xFF171A21) : Colors.white;
    final textColor = isDark ? Colors.white : const Color(0xFF1A1A1A);
    final subTextColor = isDark ? const Color(0xFFA9B0BE) : const Color(0xFF6B7280);

    showModalBottomSheet(
      context: context,
      backgroundColor: cardColor,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 28,
                  backgroundColor: isDark ? Colors.white10 : const Color(0xFFF3F4F6),
                  backgroundImage: riderImage.isNotEmpty ? NetworkImage(riderImage) : null,
                  child: riderImage.isEmpty ? Icon(Icons.person, color: subTextColor, size: 28) : null,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(child: Text(name, style: TextStyle(color: textColor, fontWeight: FontWeight.bold, fontSize: 16))),
                          const SizedBox(width: 6),
                          VerifiedBadge(isVerified: isVerified),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          const Icon(Icons.star_rounded, size: 16, color: Color(0xFFFBBF24)),
                          const SizedBox(width: 4),
                          Text('${rating.toStringAsFixed(1)} ($reviewsCount reviews)', style: TextStyle(color: subTextColor, fontSize: 13)),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            _ProfileRow(icon: Icons.military_tech_rounded, label: 'Completed trips', value: '$completedTrips', textColor: textColor, subTextColor: subTextColor),
            const SizedBox(height: 10),
            _ProfileRow(icon: _vehicleIconFor(vehicleType), label: 'Vehicle', value: vehicleNumber.isNotEmpty ? '${vehicleType.toUpperCase()} • $vehicleNumber' : vehicleType.toUpperCase(), textColor: textColor, subTextColor: subTextColor),
            const SizedBox(height: 10),
            _ProfileRow(icon: Icons.verified_user_rounded, label: 'KYC status', value: isVerified ? 'Verified' : 'Pending', textColor: textColor, subTextColor: subTextColor),
          ],
        ),
      ),
    );
  }
}

class _ProfileRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color textColor;
  final Color subTextColor;

  const _ProfileRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.textColor,
    required this.subTextColor,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 18, color: subTextColor),
        const SizedBox(width: 10),
        Text(label, style: TextStyle(color: subTextColor, fontSize: 13)),
        const Spacer(),
        Text(value, style: TextStyle(color: textColor, fontSize: 13, fontWeight: FontWeight.w600)),
      ],
    );
  }
}
