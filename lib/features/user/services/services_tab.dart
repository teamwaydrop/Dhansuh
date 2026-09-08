import 'package:flutter/material.dart';
import 'package:waydrop/core/services/location/location_cache_service.dart';
import 'package:waydrop/features/local_rides/booking/screens/ride_location_screen.dart';
import 'package:waydrop/features/local_parcels/booking/screens/parcel_details_screen.dart';
import 'package:waydrop/features/intercity/parcels/dashboard/intercity_parcels_screen.dart';
import 'package:waydrop/features/intercity/rides/dashboard/intercity_rides_screen.dart';
import 'package:waydrop/core/theme/responsive_layout.dart';
import 'package:waydrop/shared/helpers/insets.dart';

class ServicesTab extends StatelessWidget {
  const ServicesTab({super.key});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final subtitleColor = isDark ? const Color(0xFF94A3B8) : Colors.grey.shade700;

    return ValueListenableBuilder<bool>(
      valueListenable: LocationCacheService.isServiceableNotifier,
      builder: (context, isServiceable, child) {
        final services = [
          if (isServiceable) ...[
            {
              "title": "Ride",
              "imagePath": "assets/images/ride.png",
              "color": const Color(0xFF10B981),
              "promo": "BEST",
            },
            {
              "title": "Parcel",
              "imagePath": "assets/images/parcel.png",
              "color": const Color(0xFF059669),
            },
          ],
          {
            "title": "Intercity Parcel",
            "imagePath": "assets/images/intercity.png",
            "color": const Color(0xFF7C3AED),
            "promo": "NEW",
          },
          {
            "title": "Intercity Rides",
            "imagePath": "assets/images/ride.png",
            "color": const Color(0xFF2563EB),
          },
        ];

        return Scaffold(
          backgroundColor: Theme.of(context).scaffoldBackgroundColor,
          body: SafeArea(
            bottom: false,
            child: CustomScrollView(
              physics: const BouncingScrollPhysics(),
              slivers: [
                // =================================================
                // HEADER
                // =================================================
                SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                      ResponsiveLayout.horizontalPadding(context),
                      24,
                      ResponsiveLayout.horizontalPadding(context),
                      0,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Services',
                          style: TextStyle(
                            fontSize: 36,
                            fontWeight: FontWeight.w900,
                            letterSpacing: -1.5,
                            fontStyle: FontStyle.italic,
                            color: textColor,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Go anywhere, deliver anything',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: subtitleColor,
                          ),
                        ),
                        const SizedBox(height: 24),


                      ],
                    ),
                  ),
                ),

                // =================================================
                // SERVICES GRID
                // =================================================
                SliverPadding(
                  padding: EdgeInsets.symmetric(
                    horizontal: ResponsiveLayout.horizontalPadding(context),
                  ),
                  sliver: SliverGrid(
                    delegate: SliverChildBuilderDelegate(
                      (context, index) {
                        final service = services[index];
                        return _buildServiceCard(
                          context: context,
                          title: service["title"] as String,
                          imagePath: service["imagePath"] as String,
                          color: service["color"] as Color,
                          promo: service["promo"] as String?,
                        );
                      },
                      childCount: services.length,
                    ),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                      mainAxisSpacing: 18,
                      crossAxisSpacing: 18,
                      childAspectRatio: 0.82,
                    ),
                  ),
                ),

                // =================================================
                // BOTTOM SPACE
                // =================================================
                SliverToBoxAdapter(
                  child: SizedBox(height: 96 + Insets.bottom(context)), // padding for floating navigation bar
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // =====================================================
  // CARD
  // =====================================================
  Widget _buildServiceCard({
    required BuildContext context,
    required String title,
    required String imagePath,
    required Color color,
    String? promo,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardBgColor = isDark ? const Color(0xFF171A21) : Colors.white;
    final borderColor = isDark ? color.withOpacity(0.2) : const Color(0xFFE2E8F0);
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final cardSubtitleColor = isDark ? const Color(0xFF94A3B8) : Colors.grey.shade600;

    return GestureDetector(
      onTap: () {
        if (title == 'Ride') {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => const RideLocationScreen(orderType: 'ride'),
            ),
          );
        } else if (title == 'Parcel') {
          final currentAddr = LocationCacheService.cachedAddress;
          final currentPos = LocationCacheService.cachedPosition;
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => ParcelDetailsScreen(
                orderType: 'local_parcel',
                pickupAddress: currentAddr,
                pickupLat: currentPos?.latitude,
                pickupLng: currentPos?.longitude,
                pickupCity: LocationCacheService.cachedCity,
              ),
            ),
          );
        } else if (title == 'Intercity Parcel') {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => const IntercityParcelsScreen(),
            ),
          );
        } else if (title == 'Intercity Rides') {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => const IntercityRidesScreen(),
            ),
          );
        }
      },
      child: Container(
        decoration: BoxDecoration(
          color: cardBgColor,
          borderRadius: BorderRadius.circular(28),
          border: Border.all(
            color: borderColor,
            width: 1.5,
          ),
          boxShadow: [
            BoxShadow(
              color: color.withOpacity(isDark ? 0.08 : 0.04),
              blurRadius: 14,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Stack(
          children: [
            // ===========================================
            // CONTENT
            // ===========================================
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Centered Image Box
                  Container(
                    height: 48,
                    width: 48,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: const Color(0xFFE2E8F0),
                        width: 1.5,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: color.withValues(alpha: isDark ? 0.12 : 0.06),
                          blurRadius: 8,
                          offset: const Offset(0, 3),
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: Center(
                        child: Transform.scale(
                          scale: 1.1,
                          child: Image.asset(
                            imagePath,
                            width: 36,
                            height: 36,
                            fit: BoxFit.contain,
                            errorBuilder: (context, error, stackTrace) {
                              return Icon(
                                Icons.image_rounded,
                                color: color,
                                size: 18,
                              );
                            },
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),

                  // Centered Title
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -0.5,
                      color: textColor,
                    ),
                  ),
                  const SizedBox(height: 4),

                  // Centered Subtitle (flexible wrapper)
                  Expanded(
                    child: Text(
                      _getSubtitle(title),
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        height: 1.3,
                        fontWeight: FontWeight.w500,
                        color: cardSubtitleColor,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),

                  // Centered Button
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: color.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: color.withOpacity(0.15),
                        width: 1,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Open',
                          style: TextStyle(
                            color: color,
                            fontWeight: FontWeight.w900,
                            fontSize: 11,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Icon(
                          Icons.arrow_forward_rounded,
                          color: color,
                          size: 12,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // Promo Badge Positioned at top right
            if (promo != null)
              Positioned(
                top: 8,
                right: 8,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: isDark ? const Color(0xFF064E3B) : const Color(0xFFDCFCE7),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    promo,
                    style: TextStyle(
                      color: isDark ? const Color(0xFF34D399) : const Color(0xFF166534),
                      fontWeight: FontWeight.w900,
                      fontSize: 8,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // =====================================================
  // SUBTITLE
  // =====================================================
  String _getSubtitle(String title) {
    switch (title) {
      case 'Ride':
        return 'Affordable city rides';
      case 'Parcel':
        return 'Send local parcels instantly';
      case 'Intercity Parcel':
        return 'City-to-city package delivery';
      case 'Intercity Rides':
        return 'City-to-city travel';
      default:
        return '';
    }
  }
}