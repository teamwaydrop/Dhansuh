import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:waydrop/features/user/profile/services/passenger_photo_service.dart';
import 'package:waydrop/shared/widgets/kyc/kyc_upload_widgets.dart';
import 'package:waydrop/features/rider/navigation/rider_main_navigation_screen.dart';
import 'package:waydrop/modules/notifications/services/notification_service.dart';
import 'package:waydrop/core/services/cache/cache_cleanup_helper.dart';
import 'package:waydrop/core/services/session/user_session_service.dart';
import 'package:waydrop/shared/helpers/auth_session.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:waydrop/core/providers/app_mode_provider.dart';
import 'package:waydrop/features/rider/onboarding/screens/rider_entry_handler.dart';
import 'package:waydrop/features/rider/onboarding/screens/rider_payout_details_screen.dart';
import 'package:waydrop/features/rider/onboarding/screens/service_mode_selection_screen.dart';
import 'package:waydrop/shared/widgets/mode_switch_overlay.dart';
import 'package:waydrop/features/rider/services/rider_status_service.dart';
import 'package:waydrop/modules/support/screens/admin_support_chats_screen.dart';
import 'package:waydrop/features/user/settings/user_settings_screen.dart';
import 'package:waydrop/core/theme/responsive_layout.dart';
import 'package:waydrop/modules/support/screens/customer_support_screen.dart';
import 'package:waydrop/shared/helpers/insets.dart';
import 'package:waydrop/modules/rewards/services/reward_service.dart';
import 'package:waydrop/modules/rewards/screens/rewards_screen.dart';
import 'package:waydrop/modules/rewards/widgets/reward_profile_tile.dart';

class ProfileTab extends ConsumerStatefulWidget {
  const ProfileTab({super.key});

  @override
  ConsumerState<ProfileTab> createState() => _ProfileTabState();
}

class _ProfileTabState extends ConsumerState<ProfileTab> {
  bool _isSwitching = false;
  // [PERF] Issue #2: cached futures — created once, recreated only on explicit refresh.
  late Future<Map<String, dynamic>?> _userInfoFuture;
  late Future<Map<String, dynamic>?> _adminRoleFuture;
  late Future<Map<String, dynamic>> _rewardStatusFuture;

  @override
  void initState() {
    super.initState();
    // R9 perf fix: _loadUserInfo() and _loadAdminRole() used to each fire their own separate
    // `users` query against the exact same row (one for user_code/full_name/gender/
    // profile_photo_url, one for role) -- merged into a single query here so the initial mount
    // pays for one round trip instead of two. Both futures still resolve independently to a Map
    // shaped for their own FutureBuilder exactly as before (the merged row is a superset of both,
    // so every existing `data?['...']` read on either future keeps working unchanged); only how
    // many network calls it took to get there changed. _loadUserInfo() itself is untouched and
    // still used verbatim by every post-edit refresh call site below.
    final initialProfileFuture = _loadInitialProfileData();
    _userInfoFuture = initialProfileFuture;
    _adminRoleFuture = initialProfileFuture;
    _rewardStatusFuture = RewardService.fetchStatus('user');
  }

  Future<Map<String, dynamic>?> _loadInitialProfileData() {
    final userId = Supabase.instance.client.auth.currentUser?.id ?? '';
    return Supabase.instance.client
        .from('users')
        .select('user_code, full_name, gender, profile_photo_url, role')
        .eq('id', userId)
        .maybeSingle();
  }

  Future<Map<String, dynamic>?> _loadUserInfo() {
    final userId = Supabase.instance.client.auth.currentUser?.id ?? '';
    return Supabase.instance.client
        .from('users')
        .select('user_code, full_name, gender, profile_photo_url')
        .eq('id', userId)
        .maybeSingle();
  }

  Future<void> logout(BuildContext context) async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    
    final confirm = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: isDark ? const Color(0xFF1E222B) : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
      ),
      builder: (context) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 36),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox.shrink(),
            const SizedBox(height: 28),
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: const Color(0xFFEF4444).withValues(alpha: 0.12),
                shape: BoxShape.circle,
                border: Border.all(
                  color: const Color(0xFFEF4444).withValues(alpha: 0.2),
                  width: 1.5,
                ),
              ),
              child: const Center(
                child: Icon(Icons.logout_rounded, color: Color(0xFFEF4444), size: 34),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'Sign Out?',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w900,
                color: textColor,
                letterSpacing: -0.5,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Are you sure you want to sign out of your account on this device?',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: isDark ? const Color(0xFF94A3B8) : Colors.grey.shade600,
                height: 1.45,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 32),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context, false),
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(
                        color: isDark ? const Color(0xFF1E293B) : const Color(0xFFCBD5E1),
                        width: 1.5,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(18),
                      ),
                      minimumSize: const Size.fromHeight(54),
                    ),
                    child: Text(
                      'Cancel',
                      style: TextStyle(
                        color: textColor,
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () => Navigator.pop(context, true),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFEF4444),
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(18),
                      ),
                      minimumSize: const Size.fromHeight(54),
                    ),
                    child: const Text(
                      'Sign Out',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w900,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );

    if (confirm != true) return;

    try {
      await NotificationService().removeToken();
    } catch (_) {}
    await Supabase.instance.client.auth.signOut();
    await CacheCleanupHelper.clearAllCaches();
    AuthSession.clear();
    UserSessionService().stopListening();
    // BUG FIX (logout -> login -> OTP gets stuck until app restart): this used to
    // Navigator.pushAndRemoveUntil(...LoginScreen(), (_) => false) here, which -- with a
    // predicate that always returns false -- removes every route including the app's own
    // `home:` route (AppStartScreen itself), disposing its State and, with it, the
    // onAuthStateChange listener that OTP verification depends on to navigate (see
    // otp_screen.dart's comment: "AppStartScreen's listener is the sole source of truth for
    // post-login routing"). AppStartScreen was still alive and still subscribed at the moment
    // signOut() above resolved, so its own listener already reacts to the `signedOut` event
    // and swaps currentScreen to LoginScreen itself -- no manual navigation is needed here at
    // all, and doing it manually was actively harmful: it destroyed the one listener the next
    // login's post-OTP navigation relies on, so a second login-in-the-same-process would
    // verify the OTP successfully but never navigate anywhere (fixed only by a full app
    // restart, which recreates AppStartScreen fresh).
  }

  void _showEditNameSheet(BuildContext context, String currentName) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final cardBgColor = isDark ? const Color(0xFF171A21) : Colors.white;
    final controller = TextEditingController(text: currentName);
    bool isSaving = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) {
          return Container(
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF1E222B) : Colors.white,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
            ),
            padding: EdgeInsets.fromLTRB(24, 16, 24, MediaQuery.of(context).viewInsets.bottom + 36),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox.shrink(),
                const SizedBox(height: 24),
                Text(
                  'Update Full Name',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w900,
                    color: textColor,
                    letterSpacing: -0.5,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'This name will be visible to your riders and support agents.',
                  style: TextStyle(
                    fontSize: 13.5,
                    color: isDark ? const Color(0xFF94A3B8) : Colors.grey.shade600,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 24),
                TextField(
                  controller: controller,
                  style: TextStyle(color: textColor, fontWeight: FontWeight.w600),
                  decoration: InputDecoration(
                    labelText: 'Full Name',
                    labelStyle: const TextStyle(color: Color(0xFF10B981)),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: BorderSide(
                        color: isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0),
                        width: 1.5,
                      ),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: const BorderSide(color: Color(0xFF10B981), width: 2),
                    ),
                    filled: true,
                    fillColor: cardBgColor,
                  ),
                ),
                const SizedBox(height: 28),
                SizedBox(
                  width: double.infinity,
                  height: 54,
                  child: ElevatedButton(
                    onPressed: isSaving
                        ? null
                        : () async {
                            final newName = controller.text.trim();
                            if (newName.isEmpty) return;

                            setModalState(() => isSaving = true);
                            try {
                              final user = Supabase.instance.client.auth.currentUser;
                              if (user != null) {
                                await Supabase.instance.client
                                    .from('users')
                                    .update({'full_name': newName})
                                    .eq('id', user.id);
                              }
                              if (context.mounted) {
                                Navigator.pop(context);
                                setState(() {
                                  _userInfoFuture = _loadUserInfo();
                                });
                              }
                            } catch (e) {
                              setModalState(() => isSaving = false);
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text('Failed to update name: $e'),
                                    backgroundColor: const Color(0xFFEF4444),
                                  ),
                                );
                              }
                            }
                          },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF10B981),
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(18),
                      ),
                    ),
                    child: isSaving
                        ? const SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5),
                          )
                        : const Text(
                            'Save Changes',
                            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w900, color: Colors.white),
                          ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    ).then((_) => controller.dispose());
  }

  static const Map<String, String> _genderLabels = {
    'male': 'Male',
    'female': 'Female',
    'other': 'Other',
  };

  void _showEditGenderSheet(BuildContext context, String? currentGender) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final cardBgColor = isDark ? const Color(0xFF171A21) : const Color(0xFFF9FAFB);
    String? selected = currentGender;
    bool isSaving = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) {
          return Container(
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF1E222B) : Colors.white,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
            ),
            padding: EdgeInsets.fromLTRB(24, 16, 24, MediaQuery.of(context).viewInsets.bottom + 36),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox.shrink(),
                const SizedBox(height: 24),
                Text(
                  'Update Gender',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: textColor, letterSpacing: -0.5),
                ),
                const SizedBox(height: 8),
                Text(
                  'Shown to your rider/traveller so they can confirm they\'re serving the right passenger. Never shared with anyone else.',
                  style: TextStyle(
                    fontSize: 13.5,
                    color: isDark ? const Color(0xFF94A3B8) : Colors.grey.shade600,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 20),
                ..._genderLabels.entries.map((entry) {
                  final isSelected = selected == entry.key;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: GestureDetector(
                      onTap: () => setModalState(() => selected = entry.key),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                        decoration: BoxDecoration(
                          color: cardBgColor,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: isSelected ? const Color(0xFF10B981) : (isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0)),
                            width: isSelected ? 2 : 1.5,
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              isSelected ? Icons.radio_button_checked_rounded : Icons.radio_button_unchecked_rounded,
                              color: isSelected ? const Color(0xFF10B981) : (isDark ? Colors.white38 : Colors.grey.shade400),
                              size: 20,
                            ),
                            const SizedBox(width: 12),
                            Text(entry.value, style: TextStyle(color: textColor, fontWeight: FontWeight.w600, fontSize: 15)),
                          ],
                        ),
                      ),
                    ),
                  );
                }),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  height: 54,
                  child: ElevatedButton(
                    onPressed: isSaving || selected == null
                        ? null
                        : () async {
                            setModalState(() => isSaving = true);
                            try {
                              final user = Supabase.instance.client.auth.currentUser;
                              if (user != null) {
                                await Supabase.instance.client
                                    .from('users')
                                    .update({'gender': selected})
                                    .eq('id', user.id);
                              }
                              if (context.mounted) {
                                Navigator.pop(context);
                                setState(() {
                                  _userInfoFuture = _loadUserInfo();
                                });
                              }
                            } catch (e) {
                              setModalState(() => isSaving = false);
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text('Failed to update gender: $e'), backgroundColor: const Color(0xFFEF4444)),
                                );
                              }
                            }
                          },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF10B981),
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                    ),
                    child: isSaving
                        ? const SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5),
                          )
                        : const Text('Save Changes', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w900, color: Colors.white)),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  bool _uploadingPhoto = false;

  Future<void> _pickAndUploadProfilePhoto(BuildContext context) async {
    if (_uploadingPhoto) return;
    try {
      final image = await pickKycImage(context);
      if (image == null) return;
      if (!mounted) return;
      setState(() => _uploadingPhoto = true);
      await PassengerPhotoService.uploadProfilePhoto(image);
      if (mounted) {
        setState(() {
          _uploadingPhoto = false;
          _userInfoFuture = _loadUserInfo();
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _uploadingPhoto = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to upload photo: $e'), backgroundColor: const Color(0xFFEF4444)),
        );
      }
    }
  }

  Widget _buildGroupedCard({required List<Widget> children, required bool isDark}) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF171A21) : Colors.white,
        borderRadius: BorderRadius.circular(28),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.04),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        children: children,
      ),
    );
  }

  String _cleanPhoneCode(String rawPhone) {
    var clean = rawPhone.trim();
    if (clean.startsWith('+91')) {
      clean = clean.substring(3);
    } else if (clean.startsWith('91') && clean.length > 10) {
      clean = clean.substring(2);
    }
    return clean;
  }

  @override
  Widget build(BuildContext context) {
    final user = Supabase.instance.client.auth.currentUser;
    final phone = _cleanPhoneCode(user?.phone ?? '');
    final email = user?.email ?? '';
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final scaffoldBgColor = isDark ? const Color(0xFF0F1115) : const Color(0xFFF3F4F6);

    return Scaffold(
      backgroundColor: scaffoldBgColor,
      body: SafeArea(
        bottom: false,
        child: ListView(
          physics: const BouncingScrollPhysics(),
          padding: EdgeInsets.symmetric(
            horizontal: ResponsiveLayout.horizontalPadding(context),
          ),
          children: [
            const SizedBox(height: 24),
            // Header Row: Profile Title and Settings settings icon
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Profile',
                  style: TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -1.0,
                    color: textColor,
                  ),
                ),
                GestureDetector(
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const UserSettingsScreen()),
                    );
                  },
                  child: Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: isDark ? const Color(0xFF171A21) : Colors.white,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: isDark ? 0.15 : 0.04),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Icon(
                      Icons.more_horiz_rounded,
                      color: isDark ? Colors.white70 : const Color(0xFF64748B),
                      size: 22,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),

            // User Info Card with edit pencil
            FutureBuilder<Map<String, dynamic>?>(
              future: _userInfoFuture,
              builder: (context, snapshot) {
                final userCode = snapshot.data?['user_code']?.toString() ?? '...';
                final fullName = snapshot.data?['full_name']?.toString() ?? 'WayDrop User';
                final gender = snapshot.data?['gender']?.toString();
                final photoUrl = snapshot.data?['profile_photo_url']?.toString();
                final displaySubtitle = email.isNotEmpty ? email : (phone.isNotEmpty ? phone : 'Welcome to California');

                return Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: isDark ? const Color(0xFF171A21) : Colors.white,
                    borderRadius: BorderRadius.circular(28),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.04),
                        blurRadius: 16,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Row(
                    children: [
                      // User circular avatar -- tappable to add/change a profile photo, shown
                      // to the traveller/rider serving this passenger so they can confirm identity
                      // before OTP verification.
                      GestureDetector(
                        onTap: () => _pickAndUploadProfilePhoto(context),
                        child: Stack(
                          children: [
                            Container(
                              width: 60,
                              height: 60,
                              decoration: BoxDecoration(
                                color: isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0),
                                shape: BoxShape.circle,
                              ),
                              child: ClipOval(
                                child: (photoUrl != null && photoUrl.isNotEmpty)
                                    ? CachedNetworkImage(
                                        imageUrl: photoUrl,
                                        width: 60,
                                        height: 60,
                                        fit: BoxFit.cover,
                                        memCacheWidth: (60 * MediaQuery.of(context).devicePixelRatio).round(),
                                        memCacheHeight: (60 * MediaQuery.of(context).devicePixelRatio).round(),
                                        errorWidget: (_, _, _) => Icon(
                                          Icons.person_rounded,
                                          color: isDark ? Colors.white70 : const Color(0xFF64748B),
                                          size: 30,
                                        ),
                                      )
                                    : Icon(
                                        Icons.person_rounded,
                                        color: isDark ? Colors.white70 : const Color(0xFF64748B),
                                        size: 30,
                                      ),
                              ),
                            ),
                            if (_uploadingPhoto)
                              Positioned.fill(
                                child: Container(
                                  decoration: const BoxDecoration(color: Colors.black45, shape: BoxShape.circle),
                                  child: const Center(
                                    child: SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                    ),
                                  ),
                                ),
                              )
                            else
                              Positioned(
                                right: -2,
                                bottom: -2,
                                child: Container(
                                  padding: const EdgeInsets.all(4),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF10B981),
                                    shape: BoxShape.circle,
                                    border: Border.all(color: isDark ? const Color(0xFF171A21) : Colors.white, width: 2),
                                  ),
                                  child: const Icon(Icons.camera_alt_rounded, color: Colors.white, size: 11),
                                ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              fullName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w900,
                                color: textColor,
                                letterSpacing: -0.3,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              displaySubtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13,
                                color: isDark ? const Color(0xFF94A3B8) : Colors.grey.shade500,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'User ID: $userCode',
                              style: const TextStyle(
                                fontSize: 12,
                                color: Color(0xFF10B981),
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 6),
                            GestureDetector(
                              onTap: () => _showEditGenderSheet(context, gender),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.wc_rounded, size: 13, color: isDark ? const Color(0xFF94A3B8) : Colors.grey.shade500),
                                  const SizedBox(width: 4),
                                  Text(
                                    _genderLabels[gender] ?? 'Add gender',
                                    style: TextStyle(
                                      fontSize: 11.5,
                                      fontWeight: FontWeight.w600,
                                      color: isDark ? const Color(0xFF94A3B8) : Colors.grey.shade500,
                                      decoration: TextDecoration.underline,
                                      decorationColor: isDark ? const Color(0xFF94A3B8) : Colors.grey.shade500,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      // Edit pencil button
                      GestureDetector(
                        onTap: () => _showEditNameSheet(context, fullName),
                        child: Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: isDark ? const Color(0xFF1E293B) : Colors.white,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: isDark ? Colors.white.withValues(alpha: 0.1) : const Color(0xFFE2E8F0),
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.04),
                                blurRadius: 8,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                          child: Icon(
                            Icons.edit_outlined,
                            color: isDark ? Colors.white70 : const Color(0xFF0F172A),
                            size: 20,
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
            const SizedBox(height: 24),

            // Group 1 Card: Account & Mode Settings
            _buildGroupedCard(
              isDark: isDark,
              children: [
                _MenuTile(
                  icon: Icons.swap_horiz_rounded,
                  label: 'Switch to Drop Partner Mode',
                  subtitle: 'Accept parcel & transport jobs',
                  color: const Color(0xFF10B981),
                  trailing: _isSwitching
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF10B981)),
                        )
                      : null,
                  onTap: () async {
                    if (user == null) return;
                    setState(() => _isSwitching = true);

                    try {
                      final supabase = Supabase.instance.client;
                      // Egress fix: narrowed to the fields actually read below. The payout-active
                      // check intentionally stays a direct, uncached query -- see
                      // RiderPayoutAccountCache's doc comment for why this exact gating shape
                      // (cashfree_beneficiary_status='active') must never be served from a cache.
                      final kycResponse = await supabase
                          .from('rider_kyc')
                          .select('blocked_until, kyc_status, activation_status')
                          .eq('user_id', user.id)
                          .maybeSingle();
                      final riderResponse = await supabase.from('riders').select('id').eq('user_id', user.id).maybeSingle();
                      final payoutResponse = await supabase
                          .from('rider_payout_accounts')
                          .select('id')
                          .eq('user_id', user.id)
                          .eq('cashfree_beneficiary_status', 'active')
                          .maybeSingle();

                      if (!mounted) return;

                      bool isBlocked = false;
                      if (kycResponse != null) {
                        final String? blockedUntilStr = kycResponse['blocked_until'];
                        if (blockedUntilStr != null) {
                          final blockedUntil = DateTime.tryParse(blockedUntilStr);
                          if (blockedUntil != null && blockedUntil.isAfter(DateTime.now())) {
                            isBlocked = true;
                          }
                        }
                      }

                      final kycStatus = kycResponse?['kyc_status'] ?? 'none';
                      final activationStatus = kycResponse?['activation_status'] ?? 'inactive';
                      final bool riderExists = riderResponse != null;
                      final bool payoutActive = payoutResponse != null;

                      final bool isRiderReady = !isBlocked && kycStatus == 'approved' && activationStatus == 'active' && riderExists && payoutActive;

                      if (isRiderReady) {
                        final confirm = await showModalBottomSheet<bool>(
                          context: context,
                          backgroundColor: isDark ? const Color(0xFF1E222B) : Colors.white,
                          shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(32))),
                          builder: (_) => Padding(
                            padding: const EdgeInsets.fromLTRB(24, 16, 24, 36),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const SizedBox.shrink(),
                                const SizedBox(height: 28),
                                Container(
                                  width: 72,
                                  height: 72,
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF10B981).withValues(alpha: 0.12),
                                    shape: BoxShape.circle,
                                    border: Border.all(color: const Color(0xFF10B981).withValues(alpha: 0.2), width: 1.5),
                                  ),
                                  child: const Center(
                                    child: Icon(Icons.swap_horiz_rounded, color: Color(0xFF10B981), size: 34),
                                  ),
                                ),
                                const SizedBox(height: 20),
                                Text(
                                  'Switch to Drop Partner Mode?',
                                  style: TextStyle(
                                    fontSize: 24,
                                    fontWeight: FontWeight.w900,
                                    color: textColor,
                                    letterSpacing: -0.5,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  'You will switch to the rider view to accept jobs and start earning.',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 14,
                                    color: isDark ? const Color(0xFF94A3B8) : Colors.grey.shade600,
                                    height: 1.45,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                const SizedBox(height: 32),
                                Row(
                                  children: [
                                    Expanded(
                                      child: OutlinedButton(
                                        onPressed: () => Navigator.pop(context, false),
                                        style: OutlinedButton.styleFrom(
                                          side: BorderSide(color: isDark ? const Color(0xFF1E293B) : const Color(0xFFCBD5E1), width: 1.5),
                                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                                          minimumSize: const Size.fromHeight(54),
                                        ),
                                        child: Text('Cancel', style: TextStyle(color: textColor, fontSize: 15, fontWeight: FontWeight.w800)),
                                      ),
                                    ),
                                    const SizedBox(width: 14),
                                    Expanded(
                                      child: ElevatedButton(
                                        onPressed: () => Navigator.pop(context, true),
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: const Color(0xFF10B981),
                                          foregroundColor: Colors.white,
                                          elevation: 0,
                                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                                          minimumSize: const Size.fromHeight(54),
                                        ),
                                        child: const Text('Switch', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w900, color: Colors.white)),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        );

                        if (confirm == true && mounted) {
                          ref.read(modeSwitchOverlayProvider.notifier).trigger(
                            asyncAction: () async {
                              await RiderStatusService.switchToRiderMode();
                              ref.read(appModeProvider.notifier).switchToRider();
                            },
                            onMidpoint: () {
                              Navigator.pushAndRemoveUntil(
                                context,
                                PageRouteBuilder(
                                  pageBuilder: (context, animation, secondaryAnimation) => const RiderMainNavigationScreen(),
                                  transitionDuration: Duration.zero,
                                  reverseTransitionDuration: Duration.zero,
                                ),
                                (_) => false,
                              );
                            },
                            onError: (err) {
                              final errorMsg = err.toString();
                              if (errorMsg.contains('Payout details not registered')) {
                                Navigator.push(context, MaterialPageRoute(builder: (_) => const RiderPayoutDetailsScreen()));
                              } else if (errorMsg.contains('Service Mode not chosen')) {
                                Navigator.push(context, MaterialPageRoute(builder: (_) => const ServiceModeSelectionScreen()));
                              } else {
                                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(errorMsg.replaceFirst('Exception: ', '')), backgroundColor: const Color(0xFFEF4444)));
                              }
                            },
                          );
                        }
                      } else {
                        Navigator.push(context, MaterialPageRoute(builder: (_) => const RiderEntryHandler()));
                      }
                    } catch (e) {
                      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
                    } finally {
                      if (mounted) setState(() => _isSwitching = false);
                    }
                  },
                ),
                // Conditional Admin support panel tile
                FutureBuilder<Map<String, dynamic>?>(
                  future: _adminRoleFuture,
                  builder: (context, snapshot) {
                    if (snapshot.hasData && (snapshot.data?['role'] == 'admin' || snapshot.data?['role'] == 'support')) {
                      return Column(
                        children: [
                          const Divider(height: 1, indent: 64, color: Colors.black12),
                          _MenuTile(
                            icon: Icons.admin_panel_settings_rounded,
                            label: 'Admin Support Panel',
                            subtitle: 'Handle client help chats',
                            color: const Color(0xFFEF4444),
                            onTap: () {
                              Navigator.push(context, MaterialPageRoute(builder: (_) => const AdminSupportChatsScreen()));
                            },
                          ),
                        ],
                      );
                    }
                    return const SizedBox.shrink();
                  },
                ),
              ],
            ),
            const SizedBox(height: 20),

            // Group 2 Card: Support & General Options
            _buildGroupedCard(
              isDark: isDark,
              children: [
                FutureBuilder<Map<String, dynamic>>(
                  future: _rewardStatusFuture,
                  builder: (context, snapshot) {
                    final status = snapshot.data;
                    if (status == null || !RewardService.isFeatureEnabled(status)) {
                      return const SizedBox.shrink();
                    }
                    return Column(
                      children: [
                        RewardProfileTile(
                          status: status,
                          iconColor: const Color(0xFFD4AF37),
                          iconBgColor: const Color(0xFFD4AF37).withValues(alpha: 0.1),
                          titleColor: isDark ? Colors.white : const Color(0xFF0F172A),
                          subtitleColor: isDark ? const Color(0xFF94A3B8) : Colors.grey.shade500,
                          chevronColor: isDark ? const Color(0xFF475569) : const Color(0xFFCBD5E1),
                          progressTrackColor: isDark ? Colors.white.withValues(alpha: 0.08) : const Color(0xFFE2E8F0),
                          onTap: () {
                            if (RewardService.isUnlocked(status)) {
                              Navigator.push(context, MaterialPageRoute(builder: (_) => const RewardsScreen(ownerType: 'user')));
                            } else {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text(RewardService.subtitleFor(status))),
                              );
                            }
                          },
                        ),
                        const Divider(height: 1, indent: 64, color: Colors.black12),
                      ],
                    );
                  },
                ),
                _MenuTile(
                  icon: Icons.help_outline_rounded,
                  label: 'Help & Legal Policies',
                  subtitle: 'Get support or view compliance details',
                  color: const Color(0xFF2563EB),
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const CustomerSupportScreen(),
                      ),
                    );
                  },
                ),
                const Divider(height: 1, indent: 64, color: Colors.black12),
                _MenuTile(
                  icon: Icons.logout_rounded,
                  label: 'Sign Out',
                  subtitle: 'Log out from this device safely',
                  color: const Color(0xFFEF4444),
                  onTap: () => logout(context),
                ),
              ],
            ),
            const SizedBox(height: 36),

            // Version Label
            const Center(
              child: Text(
                'WayDrop v1.0.0',
                style: TextStyle(
                  color: Color(0xFF94A3B8),
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.5,
                ),
              ),
            ),
            SizedBox(height: 96 + Insets.bottom(context)), // Spacer for bottom navigation
          ],
        ),
      ),
    );
  }
}

// Grouped card tile helper widget
class _MenuTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? subtitle;
  final Color color;
  final VoidCallback onTap;
  final Widget? trailing;

  const _MenuTile({
    required this.icon,
    required this.label,
    this.subtitle,
    required this.color,
    required this.onTap,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final subColor = isDark ? const Color(0xFF94A3B8) : Colors.grey.shade500;

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: color, size: 20),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      color: textColor,
                    ),
                  ),
                  if (subtitle != null && subtitle!.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: subColor,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            trailing ?? Icon(
              Icons.chevron_right_rounded,
              color: isDark ? const Color(0xFF475569) : const Color(0xFFCBD5E1),
              size: 20,
            ),
          ],
        ),
      ),
    );
  }
}

// Public Notification Settings Preferences Sheet
class NotificationPreferencesSheet extends StatefulWidget {
  const NotificationPreferencesSheet({super.key});

  @override
  State<NotificationPreferencesSheet> createState() => NotificationPreferencesSheetState();
}

class NotificationPreferencesSheetState extends State<NotificationPreferencesSheet> {
  final _supabase = Supabase.instance.client;
  bool _loading = true;
  bool _prefOrder = true;
  bool _prefChat = true;
  bool _prefRating = true;
  bool _prefAdmin = true;
  String _orderNotificationMode = 'important_only';

  @override
  void initState() {
    super.initState();
    _loadPreferences();
  }

  Future<void> _loadPreferences() async {
    try {
      final user = _supabase.auth.currentUser;
      if (user == null) return;

      final data = await _supabase
          .from('users')
          .select('pref_order_notifications, pref_chat_notifications, pref_rating_notifications, pref_admin_notifications, order_notification_mode')
          .eq('id', user.id)
          .maybeSingle();

      if (data != null && mounted) {
        setState(() {
          _prefOrder = data['pref_order_notifications'] ?? true;
          _prefChat = data['pref_chat_notifications'] ?? true;
          _prefRating = data['pref_rating_notifications'] ?? true;
          _prefAdmin = data['pref_admin_notifications'] ?? true;
          _orderNotificationMode = data['order_notification_mode'] ?? 'important_only';
          _loading = false;
        });
      }
    } catch (e) {
      debugPrint('ERROR LOADING PREFERENCES => $e');
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _updatePreference(String column, dynamic value) async {
    try {
      final user = _supabase.auth.currentUser;
      if (user == null) return;

      await _supabase.from('users').update({column: value}).eq('id', user.id);
    } catch (e) {
      debugPrint('ERROR UPDATING PREFERENCE => $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);

    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E222B) : Colors.white,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
      ),
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 40),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox.shrink(),
          const SizedBox(height: 24),
          Text(
            'Notification Preferences',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w900,
              color: textColor,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Choose the notifications you wish to receive. Critical billing & system alerts cannot be disabled.',
            style: TextStyle(
              fontSize: 13.5,
              color: Color(0xFF64748B),
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 24),
          if (_loading)
            const Center(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 40.0),
                child: CircularProgressIndicator(color: Color(0xFF10B981)),
              ),
            )
          else ...[
            _buildPreferenceToggle(
              'Order Status Updates',
              'Alerts about rides, parcel pickups, and delivery updates',
              Icons.directions_car_rounded,
              const Color(0xFF10B981),
              _prefOrder,
              (val) {
                setState(() {
                  _prefOrder = val;
                  if (!val) {
                    _orderNotificationMode = 'tracking_silent';
                    _updatePreference('order_notification_mode', 'tracking_silent');
                  } else {
                    _orderNotificationMode = 'important_only';
                    _updatePreference('order_notification_mode', 'important_only');
                  }
                });
                _updatePreference('pref_order_notifications', val);
              },
            ),
            if (_prefOrder) ...[
              const SizedBox(height: 10),
              Padding(
                padding: const EdgeInsets.only(left: 12.0, right: 12.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Alert Level',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w800,
                        color: textColor.withValues(alpha: 0.75),
                      ),
                    ),
                    const SizedBox(height: 8),
                    _buildModeSelector(textColor, isDark),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 16),
            _buildPreferenceToggle(
              'Chat Messages',
              'Messages from Drop Partners, clients, and order threads',
              Icons.chat_bubble_rounded,
              const Color(0xFF3B82F6),
              _prefChat,
              (val) {
                setState(() => _prefChat = val);
                _updatePreference('pref_chat_notifications', val);
              },
            ),
            const SizedBox(height: 12),
            _buildPreferenceToggle(
              'Ratings & Reviews',
              'Alerts when a user or rider rates your trip',
              Icons.star_rounded,
              const Color(0xFFFBBF24),
              _prefRating,
              (val) {
                setState(() => _prefRating = val);
                _updatePreference('pref_rating_notifications', val);
              },
            ),
            const SizedBox(height: 12),
            _buildPreferenceToggle(
              'Announcements & Promotions',
              'General news, special offers, and platform updates',
              Icons.campaign_rounded,
              const Color(0xFF7C3AED),
              _prefAdmin,
              (val) {
                setState(() => _prefAdmin = val);
                _updatePreference('pref_admin_notifications', val);
              },
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildModeSelector(Color textColor, bool isDark) {
    final modes = [
      {'value': 'all', 'label': 'All Updates', 'desc': 'Notify all changes'},
      {'value': 'important_only', 'label': 'Important Only', 'desc': 'Milestones only'},
      {'value': 'tracking_silent', 'label': 'Minimal', 'desc': 'Critical & chats only'},
    ];

    return Row(
      children: modes.map((mode) {
        final isSelected = _orderNotificationMode == mode['value'];
        final chipBgColor = isSelected
            ? const Color(0xFF10B981)
            : (isDark ? const Color(0xFF171A21) : Colors.white);
        final chipBorderColor = isSelected
            ? const Color(0xFF10B981)
            : (isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0));
        final chipTextColor = isSelected
            ? Colors.white
            : (isDark ? Colors.white70 : const Color(0xFF475569));

        return Expanded(
          child: GestureDetector(
            onTap: () {
              setState(() => _orderNotificationMode = mode['value']!);
              _updatePreference('order_notification_mode', mode['value']!);
            },
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 4),
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 2),
              decoration: BoxDecoration(
                color: chipBgColor,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: chipBorderColor, width: 1.5),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    mode['label']!,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.bold,
                      color: chipTextColor,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    mode['desc']!,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 9,
                      color: isSelected ? Colors.white70 : const Color(0xFF64748B),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildPreferenceToggle(
    String title,
    String description,
    IconData icon,
    Color color,
    bool value,
    ValueChanged<bool> onChanged,
  ) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardBgColor = isDark ? const Color(0xFF171A21) : Colors.white;
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: cardBgColor,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0),
          width: 1.5,
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.bold,
                    color: textColor,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  description,
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFF64748B),
                    height: 1.25,
                  ),
                ),
              ],
            ),
          ),
          Switch.adaptive(
            value: value,
            activeColor: const Color(0xFF10B981),
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}