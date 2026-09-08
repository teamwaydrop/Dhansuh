import 'dart:async';
import 'package:flutter/material.dart';

/// Feature 6/7/8: shown on both the traveller's (RiderActiveOrderScreen) and the passenger's
/// (IntercityTrackingScreen) screens once a booking is Accepted but the travel date hasn't
/// arrived yet. Replaces the immediate "navigate now" UI that used to appear right after
/// acceptance — navigation/trip-start must never be implied before the travel date, regardless of
/// how long ago the booking was accepted.
///
/// [onStartTrip] is only ever provided on the traveller side, and the button only renders once
/// [travelDate] is within 1 hour of arriving (server-side enforcement lives in the
/// start_intercity_trip RPC; this is just the matching UI gate so the button isn't even shown
/// before then).
class WaitingForTravelDayCard extends StatefulWidget {
  final DateTime? travelDate;
  final bool isTraveller;
  final Future<void> Function()? onStartTrip;

  const WaitingForTravelDayCard({
    super.key,
    required this.travelDate,
    required this.isTraveller,
    this.onStartTrip,
  });

  @override
  State<WaitingForTravelDayCard> createState() => _WaitingForTravelDayCardState();
}

class _WaitingForTravelDayCardState extends State<WaitingForTravelDayCard> {
  Timer? _timer;
  bool _starting = false;

  @override
  void initState() {
    super.initState();
    // UI-only clock tick to keep the countdown fresh — no network calls, so this is not polling
    // the server (Feature 9: event-driven, not client polling).
    _timer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  // Matches the server-side gate in start_intercity_trip(): the traveller may press Start Trip
  // any time from 1 hour before the scheduled departure onward, not only on the literal travel
  // date/time. Comparing instants directly (not calendar days) so this stays correct across a day
  // boundary too, e.g. a 12:30 AM departure unlocks at 11:30 PM the previous day.
  static const _earlyStartWindow = Duration(hours: 1);

  bool get _canStartTrip {
    final date = widget.travelDate;
    if (date == null) return false;
    return !DateTime.now().isBefore(date.toLocal().subtract(_earlyStartWindow));
  }

  Future<void> _handleStartTrip() async {
    if (widget.onStartTrip == null || _starting) return;
    setState(() => _starting = true);
    try {
      await widget.onStartTrip!();
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardColor = isDark ? const Color(0xFF171A21) : Colors.white;
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final subTextColor = isDark ? const Color(0xFFA9B0BE) : const Color(0xFF6B7280);
    const accent = Color(0xFF7C3AED);

    final travelDate = widget.travelDate;
    final canStart = _canStartTrip;

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: accent.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.event_available_rounded, color: accent, size: 20),
              const SizedBox(width: 8),
              Text(
                'Accepted',
                style: TextStyle(color: textColor, fontWeight: FontWeight.bold, fontSize: 15),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Waiting for Travel Day',
            style: TextStyle(color: subTextColor, fontSize: 13),
          ),
          const SizedBox(height: 14),
          if (!canStart && travelDate != null) ...[
            Text(
              'Travel starts in:',
              style: TextStyle(color: subTextColor, fontSize: 12),
            ),
            const SizedBox(height: 6),
            Text(
              _formatCountdown(travelDate),
              style: const TextStyle(color: accent, fontWeight: FontWeight.bold, fontSize: 18),
            ),
          ] else if (widget.isTraveller) ...[
            Text(
              'You can start the trip now — up to 1 hour early is fine if you are leaving ahead of schedule.',
              style: TextStyle(color: subTextColor, fontSize: 12, height: 1.4),
            ),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _starting ? null : _handleStartTrip,
                icon: _starting
                    ? const SizedBox(
                        height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                    : const Icon(Icons.play_arrow_rounded, color: Colors.black),
                label: Text(
                  _starting ? 'STARTING TRIP...' : 'START TRIP',
                  style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.black, letterSpacing: 0.5),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFC5FF30),
                  minimumSize: const Size(double.infinity, 50),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  elevation: 0,
                ),
              ),
            ),
          ] else ...[
            Text(
              'Your travel partner can start the trip now.',
              style: TextStyle(color: subTextColor, fontSize: 12, height: 1.4),
            ),
          ],
        ],
      ),
    );
  }

  String _formatCountdown(DateTime travelDate) {
    final diff = travelDate.toLocal().difference(DateTime.now());
    if (diff.isNegative) return 'Today';
    final days = diff.inDays;
    final hours = diff.inHours % 24;
    if (days > 0) {
      return '$days Day${days == 1 ? '' : 's'} $hours Hour${hours == 1 ? '' : 's'}';
    }
    final minutes = diff.inMinutes % 60;
    return '$hours Hour${hours == 1 ? '' : 's'} $minutes Min${minutes == 1 ? '' : 's'}';
  }
}
