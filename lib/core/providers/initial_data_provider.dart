import 'package:flutter_riverpod/flutter_riverpod.dart';

class InitialUserData {
  final Map<String, dynamic>? userProfile;
  final Map<String, dynamic>? riderProfile;
  final Map<String, dynamic>? kycProfile;
  final List<Map<String, dynamic>> recentOrders;
  final bool secondaryDataLoaded;

  InitialUserData({
    this.userProfile,
    this.riderProfile,
    this.kycProfile,
    required this.recentOrders,
    this.secondaryDataLoaded = true,
  });
}

class InitialRiderData {
  final Map<String, dynamic>? rider;
  final double? todayEarnings;
  final DateTime fetchedAt;
  final Set<String> _consumedBy = {};

  InitialRiderData({
    this.rider,
    required this.todayEarnings,
    DateTime? fetchedAt,
  }) : fetchedAt = fetchedAt ?? DateTime.now();

  bool isUsableFor(String? userId, {DateTime? now}) {
    final age = (now ?? DateTime.now()).difference(fetchedAt);
    return userId != null && rider?['user_id'] == userId &&
        !age.isNegative && age < const Duration(seconds: 5);
  }

  // Each successful entry check publishes a new seed. Reuse it once per
  // consumer, while refusing to reuse an old seed on another screen recreation.
  // This is display-read reuse, never an alternative to RiderAccessService.
  bool consumeFor(String consumer, String? userId, {DateTime? now}) {
    if (!isUsableFor(userId, now: now)) return false;
    return _consumedBy.add(consumer);
  }
}

final initialUserDataProvider = StateProvider<InitialUserData?>((ref) => null);
final initialRiderDataProvider = StateProvider<InitialRiderData?>((ref) => null);
final activeAssignmentsCountProvider = StateProvider<int>((ref) => 0);
