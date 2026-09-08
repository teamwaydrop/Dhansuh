import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:waydrop/core/services/location/location_cache_service.dart';
import 'package:waydrop/features/intercity/shared/services/intercity_matching_service.dart';
import 'package:waydrop/features/intercity/shared/widgets/partner_card.dart';
import 'package:waydrop/features/intercity/shared/widgets/travel_together_confirm_dialog.dart';

/// Available Partners screen (Parts 5/6/8/26) — reached from Home/Activity after a User creates
/// a Travel Request, not from a new bottom-nav tab (existing 4-tab shell is kept unchanged).
/// Auto-opens on the request's own travel date, with a date strip to browse nearby dates and see
/// per-date partner counts, and a persistent list of matching Travel Plans that stays populated
/// even if the corresponding push notification was dismissed.
class AvailablePartnersScreen extends StatefulWidget {
  final String orderId;
  final String pickupCity;
  final String destinationCity;
  final DateTime initialDate;
  final bool isParcel;
  // Issue 4 fix: when this screen is opened from a 'traveller_available' match notification, the
  // notification's own plan_id -- the specific plan that generated it -- is passed here so it can
  // be guaranteed to appear even if it falls outside the generic date/city-string search below
  // (see _loadPartnersForSelectedDate). Null for every other entry point (Home/Activity), and for
  // the aggregate 'travel_partners_available' notification type which has no single plan.
  final String? initialPlanId;

  const AvailablePartnersScreen({
    super.key,
    required this.orderId,
    required this.pickupCity,
    required this.destinationCity,
    required this.initialDate,
    this.isParcel = false,
    this.initialPlanId,
  });

  @override
  State<AvailablePartnersScreen> createState() => _AvailablePartnersScreenState();
}

class _AvailablePartnersScreenState extends State<AvailablePartnersScreen> {
  late DateTime _selectedDate;
  late final List<DateTime> _dates;
  Map<String, int> _dateCounts = {};
  List<Map<String, dynamic>> _partners = [];
  bool _loadingPartners = true;
  bool _loadingCounts = true;
  String? _sendingPlanId;
  Set<String> _alreadySentRiderIds = {};
  // Display-only cache of this passenger's own payable fare (final_fare ?? current_fare) --
  // _travelTogether always re-fetches fresh at send time for the value that's actually submitted,
  // this is only so every PartnerCard on this screen shows that same number up front instead of
  // each traveller's own (different-distance) price_per_seat.
  double? _yourFare;

  @override
  void initState() {
    super.initState();
    debugPrint('[RUNTIME_TRACE] ENTER AvailablePartnersScreen (available_partners_screen.dart) orderId=${widget.orderId}');
    _selectedDate = DateTime(widget.initialDate.year, widget.initialDate.month, widget.initialDate.day);
    _dates = List.generate(7, (i) => _selectedDate.add(Duration(days: i)));
    _loadCounts();
    _loadPartnersForSelectedDate();
    _loadYourFare();
  }

  Future<void> _loadYourFare() async {
    final orderRow = await Supabase.instance.client
        .from('orders')
        .select('current_fare, final_fare')
        .eq('id', widget.orderId)
        .maybeSingle();
    final fare = double.tryParse((orderRow?['final_fare'] ?? orderRow?['current_fare'] ?? 0).toString());
    if (mounted && fare != null && fare > 0) {
      setState(() => _yourFare = fare);
    }
  }

  String _dateKey(DateTime date) {
    return '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  Future<void> _loadCounts() async {
    setState(() => _loadingCounts = true);
    final counts = await IntercityMatchingService.fetchDateCounts(
      pickupCity: widget.pickupCity,
      destinationCity: widget.destinationCity,
      dates: _dates,
    );
    if (mounted) {
      setState(() {
        _dateCounts = counts;
        _loadingCounts = false;
      });
    }
  }

  Future<void> _loadPartnersForSelectedDate() async {
    setState(() => _loadingPartners = true);
    final partners = await IntercityMatchingService.fetchAvailablePartnersForDate(
      pickupCity: widget.pickupCity,
      destinationCity: widget.destinationCity,
      date: _selectedDate,
    );
    // Issue 4 fix: guarantee the exact plan a match notification pointed at is shown even if the
    // generic search above (stricter exact-city-string + single-day filter) doesn't happen to
    // surface it -- the matching engine that produced the notification allows a wider date window
    // and route-corridor/coordinate matches. If the plan is genuinely gone/inactive/full,
    // fetchPartnerByPlanId returns null and the empty state below is still correctly shown.
    var merged = partners;
    final initialPlanId = widget.initialPlanId;
    if (initialPlanId != null && !partners.any((p) => p['id']?.toString() == initialPlanId)) {
      final specific = await IntercityMatchingService.fetchPartnerByPlanId(initialPlanId);
      if (specific != null) {
        merged = [specific, ...partners];
      }
    }
    final alreadySent = await IntercityMatchingService.fetchExistingRequestRiderIds(
      orderId: widget.orderId,
      riderIds: merged.map((p) => p['rider_id']?.toString()).whereType<String>().toList(),
    );
    // Feature 3: sort by Highest Rating -> Nearest Pickup -> Earliest Departure, using the
    // device's cached current position (already maintained app-wide by LocationCacheService, no
    // new location plumbing needed).
    final sorted = IntercityMatchingService.enrichWithDistanceAndSort(
      partners: merged,
      currentLat: LocationCacheService.currentLat,
      currentLng: LocationCacheService.currentLng,
    );
    if (mounted) {
      setState(() {
        _partners = sorted;
        _alreadySentRiderIds = alreadySent;
        _loadingPartners = false;
      });
    }
  }

  void _selectDate(DateTime date) {
    if (date.year == _selectedDate.year && date.month == _selectedDate.month && date.day == _selectedDate.day) {
      return;
    }
    setState(() => _selectedDate = date);
    _loadPartnersForSelectedDate();
  }

  Future<void> _travelTogether(Map<String, dynamic> partner) async {
    final planId = partner['id']?.toString();
    final riderId = partner['rider_id']?.toString();
    final currentUserId = Supabase.instance.client.auth.currentUser?.id;
    if (riderId == null || currentUserId == null) return;

    final travelDate = partner['travel_date'] != null
        ? DateTime.tryParse(partner['travel_date'].toString())?.toLocal()
        : null;
    final confirmed = await showTravelTogetherConfirmDialog(
      context,
      partnerName: (partner['full_name'] ?? 'Rider Partner').toString(),
      route: '${partner['pickup_city'] ?? ''} → ${partner['destination_city'] ?? ''}',
      travelDate: travelDate != null
          ? IntercityMatchingService.formatShortDate(travelDate)
          : 'Not specified',
    );
    if (confirmed != true) return;

    setState(() => _sendingPlanId = planId);
    try {
      // The proposed fare must always be the passenger's OWN order total (final_fare ?? current_fare
      // -- the same "payableFare" semantics used everywhere else: create-order, create-fare-qr,
      // update-order-status), never the traveller's plan-level price_per_seat. Those two numbers are
      // computed from two different distances (the passenger's own pickup->destination vs. the
      // traveller's full posted route) and showing/using whichever one happened to be on-screen is
      // exactly what produced two different displayed fares for the same booking.
      final orderRow = await Supabase.instance.client
          .from('orders')
          .select('current_fare, final_fare')
          .eq('id', widget.orderId)
          .maybeSingle();
      final proposedFare = double.tryParse(
            (orderRow?['final_fare'] ?? orderRow?['current_fare'] ?? 0).toString(),
          ) ??
          0;

      final created = await IntercityMatchingService.sendTravelTogetherRequest(
        orderId: widget.orderId,
        riderId: riderId,
        planId: planId,
        passengerUserId: currentUserId,
        initiatedBy: 'sender',
        proposedFare: proposedFare,
        isParcel: widget.isParcel,
        travelDateIso: partner['travel_date']?.toString(),
      );
      if (mounted) {
        setState(() => _alreadySentRiderIds = {..._alreadySentRiderIds, riderId});
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(created
                ? 'Request sent! Awaiting partner response.'
                : 'Request already sent to this partner.'),
            backgroundColor: const Color(0xFF7C3AED),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        final msg = e is TravelPlanFullyBookedException ? e.toString() : 'Failed to send request: $e';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(msg), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _sendingPlanId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final subTextColor = isDark ? const Color(0xFFA9B0BE) : const Color(0xFF6B7280);

    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF0F1115) : const Color(0xFFF9FAFB),
      appBar: AppBar(
        title: const Text('Available Partners'),
        backgroundColor: isDark ? const Color(0xFF171A21) : Colors.white,
        foregroundColor: isDark ? Colors.white : Colors.black,
        elevation: 0,
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Available Partners',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: isDark ? Colors.white : const Color(0xFF0F172A),
                ),
              ),
            ),
          ),
          SizedBox(
            height: 76,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              itemCount: _dates.length,
              itemBuilder: (context, index) {
                final date = _dates[index];
                final isSelected = date.year == _selectedDate.year &&
                    date.month == _selectedDate.month &&
                    date.day == _selectedDate.day;
                final count = _dateCounts[_dateKey(date)];

                return GestureDetector(
                  onTap: () => _selectDate(date),
                  child: Container(
                    width: 84,
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    decoration: BoxDecoration(
                      color: isSelected ? const Color(0xFFC5FF30) : (isDark ? const Color(0xFF171A21) : Colors.white),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: isSelected ? const Color(0xFFC5FF30) : (isDark ? Colors.white10 : const Color(0xFFE5E7EB)),
                      ),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          IntercityMatchingService.formatShortDate(date),
                          style: TextStyle(
                            color: isSelected ? Colors.black : (isDark ? Colors.white : Colors.black87),
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _loadingCounts ? '…' : '${count ?? 0} Partners',
                          style: TextStyle(
                            color: isSelected ? Colors.black87 : subTextColor,
                            fontSize: 10,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _loadingPartners
                ? const Center(child: CircularProgressIndicator())
                : _partners.isEmpty
                    ? Center(
                        child: Text(
                          'No partners available for this date yet.',
                          style: TextStyle(color: subTextColor),
                        ),
                      )
                    : RefreshIndicator(
                        onRefresh: _loadPartnersForSelectedDate,
                        child: ListView.builder(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          itemCount: _partners.length,
                          itemBuilder: (context, index) {
                            final partner = _partners[index];
                            return PartnerCard(
                              partner: partner,
                              isSending: _sendingPlanId == partner['id']?.toString(),
                              alreadySent: _alreadySentRiderIds.contains(partner['rider_id']?.toString()),
                              onTravelTogether: () => _travelTogether(partner),
                              yourFare: _yourFare,
                            );
                          },
                        ),
                      ),
          ),
        ],
      ),
    );
  }
}
