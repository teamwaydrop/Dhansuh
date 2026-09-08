import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Feature 1 ("Notification Badge: YES"): app-wide unread-notification count, shown as a red
/// badge on the bell icon in both the User and Rider home tabs. Kept in a single provider (mirrors
/// the existing activeAssignmentsCountProvider pattern) so both bell icons stay in sync
/// automatically regardless of which one triggered the last refresh.
final unreadNotificationCountProvider = StateProvider<int>((ref) => 0);
