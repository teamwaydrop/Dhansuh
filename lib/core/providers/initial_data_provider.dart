import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:waydrop/core/models/today_earnings_seed.dart';

class InitialUserData {
  final Map<String, dynamic>? userProfile;
  final Map<String, dynamic>? riderProfile;
  final Map<String, dynamic>? kycProfile;
  final List<Map<String, dynamic>> recentOrders;

  InitialUserData({
    this.userProfile,
    this.riderProfile,
    this.kycProfile,
    required this.recentOrders,
  });
}

class InitialRiderData {
  final String? userId;
  final Map<String, dynamic>? rider;
  /// Legacy, unscoped value. Never interpret it as a gross or partner seed.
  final double? todayEarnings;
  final TodayEarningsSeed? earningsSeed;

  InitialRiderData({
    this.userId,
    this.rider,
    this.todayEarnings,
    this.earningsSeed,
  });
  bool belongsTo(String? currentUserId) => currentUserId != null && userId == currentUserId;
}

final initialUserDataProvider = StateProvider<InitialUserData?>((ref) => null);
final initialRiderDataProvider = StateProvider<InitialRiderData?>((ref) => null);
final activeAssignmentsCountProvider = StateProvider<int>((ref) => 0);
