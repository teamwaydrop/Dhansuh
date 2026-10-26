import 'package:waydrop/shared/widgets/ride_diagnostic_export_tile.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:waydrop/features/rider/settings/rider_payment_settings_screen.dart';
import 'package:waydrop/shared/widgets/skeleton_loader.dart';
import 'package:waydrop/shared/screens/data_deletion_screen.dart';

class RiderSettingsScreen extends StatefulWidget {
  final Map<String, dynamic>? kycData;
  final Map<String, dynamic>? riderData;

  const RiderSettingsScreen({
    super.key,
    this.kycData,
    this.riderData,
  });

  @override
  State<RiderSettingsScreen> createState() => _RiderSettingsScreenState();
}

class _RiderSettingsScreenState extends State<RiderSettingsScreen> {
  static const Color primaryLime = Color(0xFFC5FF30);
  static const Color darkBg = Color(0xFF0B0F19);
  static const Color darkCard = Color(0xFF131926);
  static const Color textGray = Color(0xFF94A3B8);

  bool _soundEnabled = true;
  bool _notificationsEnabled = true;
  bool _screenAlwaysOn = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (mounted) {
        setState(() {
          _soundEnabled = prefs.getBool('rider_sound_enabled') ?? true;
          _notificationsEnabled = prefs.getBool('rider_notifications_enabled') ?? true;
          _screenAlwaysOn = prefs.getBool('rider_keep_screen_on') ?? false;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _saveSetting(String key, bool value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(key, value);
    } catch (_) {}
  }

  String _capitalize(String text) {
    if (text.isEmpty) return '';
    return text[0].toUpperCase() + text.substring(1);
  }

  @override
  Widget build(BuildContext context) {
    final vehicleNumber = widget.kycData?['vehicle_number'] ?? '';
    final vehicleType = widget.kycData?['vehicle_type'] ?? 'bike';

    return Scaffold(
      backgroundColor: darkBg,
      appBar: AppBar(
        backgroundColor: darkBg,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white, size: 20),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text(
          'Settings',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 20),
        ),
        centerTitle: true,
      ),
      body: SafeArea(
        child: _loading
            ? const SkeletonLoader()
            : ListView(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                children: [
                  const RideDiagnosticExportTile(),
                  _buildSectionHeader('Notifications'),
                  _buildToggleTile(
                    icon: Icons.volume_up_rounded,
                    title: 'Sound Alerts',
                    subtitle: 'Play ringtone for incoming requests',
                    value: _soundEnabled,
                    onChanged: (val) {
                      setState(() => _soundEnabled = val);
                      _saveSetting('rider_sound_enabled', val);
                    },
                  ),
                  const SizedBox(height: 12),
                  _buildToggleTile(
                    icon: Icons.notifications_rounded,
                    title: 'Push Notifications',
                    subtitle: 'Order updates when app is minimised',
                    value: _notificationsEnabled,
                    onChanged: (val) {
                      setState(() => _notificationsEnabled = val);
                      _saveSetting('rider_notifications_enabled', val);
                    },
                  ),
                  const SizedBox(height: 24),

                  _buildSectionHeader('Payments'),
                  _buildNavTile(
                    icon: Icons.qr_code_rounded,
                    title: 'Payment Settings',
                    subtitle: 'Choose how passengers pay you -- Personal UPI or Cashfree',
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const RiderPaymentSettingsScreen()),
                      );
                    },
                  ),
                  const SizedBox(height: 24),

                  _buildSectionHeader('Display'),
                  _buildToggleTile(
                    icon: Icons.screen_lock_portrait_rounded,
                    title: 'Keep Screen On',
                    subtitle: 'Prevent screen sleep while riding',
                    value: _screenAlwaysOn,
                    onChanged: (val) {
                      setState(() => _screenAlwaysOn = val);
                      _saveSetting('rider_keep_screen_on', val);
                    },
                  ),

                  if (vehicleNumber.isNotEmpty) ...[
                    const SizedBox(height: 24),
                    _buildSectionHeader('Vehicle'),
                    _buildInfoRow('Type', _capitalize(vehicleType)),
                    const SizedBox(height: 12),
                    _buildInfoRow('Number', vehicleNumber),
                  ],

                  const SizedBox(height: 24),
                  _buildSectionHeader('Account'),
                  // COMPLIANCE FIX: DataDeletionScreen was a fully-built, working
                  // account/data-deletion request screen with no navigation entry anywhere in
                  // the app (Google Play requires an accessible account-deletion path for any
                  // app supporting account creation).
                  _buildNavTile(
                    icon: Icons.delete_forever_rounded,
                    title: 'Delete My Account',
                    subtitle: 'Request permanent data deletion',
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const DataDeletionScreen()),
                      );
                    },
                  ),

                  const SizedBox(height: 40),
                ],
              ),
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 12),
      child: Text(
        title.toUpperCase(),
        style: const TextStyle(
          color: primaryLime,
          fontSize: 11,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.2,
        ),
      ),
    );
  }

  Widget _buildToggleTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: darkCard,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05), width: 1.5),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: value ? primaryLime.withValues(alpha: 0.1) : Colors.white.withValues(alpha: 0.04),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: value ? primaryLime : textGray, size: 20),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.bold, color: Colors.white)),
                const SizedBox(height: 2),
                Text(subtitle,
                    style: const TextStyle(fontSize: 11, color: textGray)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Switch(
            value: value,
            onChanged: onChanged,
            activeColor: Colors.black,
            activeTrackColor: primaryLime,
            inactiveThumbColor: Colors.white54,
            inactiveTrackColor: Colors.white10,
          ),
        ],
      ),
    );
  }

  Widget _buildNavTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: darkCard,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white.withValues(alpha: 0.05), width: 1.5),
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.04),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: primaryLime, size: 20),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.bold, color: Colors.white)),
                  const SizedBox(height: 2),
                  Text(subtitle,
                      style: const TextStyle(fontSize: 11, color: textGray)),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded, color: textGray, size: 22),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: darkCard,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05), width: 1.5),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: const TextStyle(
                  fontSize: 14, fontWeight: FontWeight.w600, color: textGray)),
          Flexible(
            child: Text(
              value,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
              style: const TextStyle(
                  fontSize: 14, fontWeight: FontWeight.bold, color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }
}
