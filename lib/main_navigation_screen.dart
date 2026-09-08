import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:waydrop/core/theme/app_colors.dart';

import 'package:waydrop/features/user/home/home_tab.dart';
import 'package:waydrop/features/user/services/services_tab.dart';
import 'package:waydrop/features/user/activity/activity_tab.dart';
import 'package:waydrop/features/user/profile/profile_tab.dart';
import 'package:waydrop/shared/widgets/custom_curved_navigation_bar.dart';

class MainNavigationScreen extends StatefulWidget {
  const MainNavigationScreen({
    super.key,
  });

  @override
  State<MainNavigationScreen> createState() =>
      MainNavigationScreenState();
}

class MainNavigationScreenState
    extends State<MainNavigationScreen> {
  int currentIndex = 0;
  int _navBuildCount = 0;
  final GlobalKey<ActivityTabState> activityTabKey = GlobalKey<ActivityTabState>();

  void setIndex(int index) {
    setState(() {
      currentIndex = index;
    });
    if (index == 2) {
      activityTabKey.currentState?.loadOrders(showLoading: false);
    }
  }

  late final List<Widget> screens;

  @override
  void initState() {
    super.initState();
    screens = [
      const HomeTab(),
      const ServicesTab(),
      ActivityTab(key: activityTabKey),
      const ProfileTab(),
    ];
  }

  @override
  Widget build(BuildContext context) {
    _navBuildCount++;
    debugPrint('[PERF_NAV] MainNavigationScreen.build #$_navBuildCount epoch=${DateTime.now().millisecondsSinceEpoch}');
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final navBarBgColor = isDark ? AppColors.surface : Colors.white;

    SystemChrome.setSystemUIOverlayStyle(
      SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
        statusBarBrightness: isDark ? Brightness.dark : Brightness.light,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
        systemNavigationBarDividerColor: Colors.transparent,
        systemNavigationBarContrastEnforced: false,
      ),
    );

    final bottomPadding = MediaQuery.of(context).padding.bottom;

    return Scaffold(
      body: Stack(
        children: [
          IndexedStack(
            index: currentIndex,
            children: screens,
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: CustomCurvedNavigationBar(
              currentIndex: currentIndex,
              onTap: setIndex,
              activeIconColor: const Color(0xFF1B7A44), // Emerald active icon
              backgroundColor: isDark ? AppColors.background : Colors.white,
              items: const [
                CustomNavBarItem(
                  iconActive: Icons.home_rounded,
                  iconInactive: Icons.home_outlined,
                  label: 'Home',
                ),
                CustomNavBarItem(
                  iconActive: Icons.inventory_2_rounded,
                  iconInactive: Icons.inventory_2_outlined,
                  label: 'Services',
                ),
                CustomNavBarItem(
                  iconActive: Icons.local_activity_rounded,
                  iconInactive: Icons.local_activity_outlined,
                  label: 'Activity',
                ),
                CustomNavBarItem(
                  iconActive: Icons.person_rounded,
                  iconInactive: Icons.person_outline_rounded,
                  label: 'Profile',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}