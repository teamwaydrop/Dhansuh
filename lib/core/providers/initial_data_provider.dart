import 'package:flutter_riverpod/flutter_riverpod.dart';

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
  final Map<String, dynamic>? rider;
  final double todayEarnings;

  InitialRiderData({
    this.rider,
    required this.todayEarnings,
  });
}

final initialUserDataProvider = StateProvider<InitialUserData?>((ref) => null);
final initialRiderDataProvider = StateProvider<InitialRiderData?>((ref) => null);
final activeAssignmentsCountProvider = StateProvider<int>((ref) => 0);
