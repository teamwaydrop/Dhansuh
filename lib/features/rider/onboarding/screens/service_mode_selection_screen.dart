import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:waydrop/features/rider/models/partner_service_mode.dart';
import 'package:waydrop/features/rider/navigation/rider_main_navigation_screen.dart';
import 'package:waydrop/shared/widgets/app_snackbar.dart';

/// Mandatory one-time Service Mode picker. Shown by RiderEntryHandler
/// whenever `riders.service_mode` is NULL — i.e. a partner (new or
/// pre-existing) who hasn't yet chosen between Local City Partner and
/// Intercity Traveller. No auto-classification, no admin approval: the
/// partner picks for themselves, exactly as they can later change it from
/// the Service Mode card on the Home screen (see rider_home_tab.dart, which
/// reuses the same picker UI via [showServiceModeChangeSheet]).
class ServiceModeSelectionScreen extends StatefulWidget {
  const ServiceModeSelectionScreen({super.key});

  @override
  State<ServiceModeSelectionScreen> createState() => _ServiceModeSelectionScreenState();
}

class _ServiceModeSelectionScreenState extends State<ServiceModeSelectionScreen> {
  PartnerServiceMode? _selected;
  bool _saving = false;

  Future<void> _submit() async {
    if (_selected == null || _saving) return;
    setState(() => _saving = true);

    try {
      final supabase = Supabase.instance.client;
      final user = supabase.auth.currentUser;
      if (user == null) throw Exception('Not signed in');

      await supabase
          .from('riders')
          .update({'service_mode': _selected!.dbValue}).eq('user_id', user.id);

      if (!mounted) return;
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (_) => const RiderMainNavigationScreen()),
        (_) => false,
      );
    } catch (e) {
      if (mounted) {
        showAppSnackBar(context, e.toString().replaceFirst('Exception: ', ''), type: SnackBarType.error);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFB),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 40),
              Container(
                width: 88,
                height: 88,
                decoration: BoxDecoration(
                  color: const Color(0xFFF0FDF4),
                  borderRadius: BorderRadius.circular(28),
                  border: Border.all(color: const Color(0xFF10B981).withValues(alpha: 0.3), width: 1.5),
                ),
                child: const Center(
                  child: Icon(Icons.tune_rounded, size: 40, color: Color(0xFF10B981)),
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                'Choose your Service Mode',
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w900,
                  color: Color(0xFF0F172A),
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                'This decides which jobs you receive. You can change it anytime from the Service Mode card on your Home screen.',
                style: TextStyle(fontSize: 14, color: Color(0xFF64748B), height: 1.5),
              ),
              const SizedBox(height: 28),
              _ModeOptionCard(
                mode: PartnerServiceMode.local,
                selected: _selected == PartnerServiceMode.local,
                onTap: () => setState(() => _selected = PartnerServiceMode.local),
              ),
              const SizedBox(height: 14),
              _ModeOptionCard(
                mode: PartnerServiceMode.intercity,
                selected: _selected == PartnerServiceMode.intercity,
                onTap: () => setState(() => _selected = PartnerServiceMode.intercity),
              ),
              const Spacer(),
              SizedBox(
                width: double.infinity,
                height: 54,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF10B981),
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: const Color(0xFFA7F3D0),
                    elevation: 0,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                  onPressed: _selected == null || _saving ? null : _submit,
                  child: _saving
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                        )
                      : const Text('Continue', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
                ),
              ),
              const SizedBox(height: 28),
            ],
          ),
        ),
      ),
    );
  }
}

/// Bottom sheet used by the Home screen's Service Mode card (see
/// rider_home_tab.dart) to let a partner change an already-set Service Mode.
/// Reuses the same [_ModeOptionCard] visuals as the mandatory picker above.
/// Returns `true` if the mode was changed. Surfaces the DB guard from
/// 20260718000013 (mode switch blocked while an order is active) as a clear
/// inline message rather than a raw error.
Future<bool> showServiceModeChangeSheet(
  BuildContext context, {
  required PartnerServiceMode currentMode,
}) async {
  final result = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _ServiceModeChangeSheet(currentMode: currentMode),
  );
  return result ?? false;
}

class _ServiceModeChangeSheet extends StatefulWidget {
  final PartnerServiceMode currentMode;
  const _ServiceModeChangeSheet({required this.currentMode});

  @override
  State<_ServiceModeChangeSheet> createState() => _ServiceModeChangeSheetState();
}

class _ServiceModeChangeSheetState extends State<_ServiceModeChangeSheet> {
  late PartnerServiceMode _selected = widget.currentMode;
  bool _saving = false;

  Future<void> _save() async {
    if (_selected == widget.currentMode || _saving) return;
    setState(() => _saving = true);

    try {
      final supabase = Supabase.instance.client;
      final user = supabase.auth.currentUser;
      if (user == null) throw Exception('Not signed in');

      await supabase
          .from('riders')
          .update({'service_mode': _selected.dbValue}).eq('user_id', user.id);

      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      final raw = e.toString();
      // Matches the RAISE EXCEPTION text from prevent_service_mode_switch_during_active_order()
      // (supabase/migrations/20260726000001_fix_service_mode_lock_on_scheduled_travel_plan.sql):
      // "Cannot switch Service Mode while a trip is active. ...". Only a trip that has actually
      // been STARTED (Start Trip pressed) trips this guard -- a merely created/scheduled Travel
      // Plan never does -- so this friendly copy is accurate whenever it fires.
      final message = raw.contains('trip is active')
          ? 'Complete or end your active trip before switching to Local Service.'
          : raw.replaceFirst('Exception: ', '');
      if (mounted) {
        showAppSnackBar(context, message, type: SnackBarType.error);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    const darkCard = Color(0xFF131926);
    const primaryLime = Color(0xFFC5FF30);
    const textGray = Color(0xFF94A3B8);

    return SafeArea(
      child: Container(
        margin: const EdgeInsets.all(12),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: darkCard,
          borderRadius: BorderRadius.circular(24),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Service Mode',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: Colors.white),
            ),
            const SizedBox(height: 6),
            const Text(
              'Switching takes effect immediately and is blocked while you have an active order.',
              style: TextStyle(fontSize: 12.5, color: textGray, height: 1.4),
            ),
            const SizedBox(height: 18),
            _ModeOptionCard(
              mode: PartnerServiceMode.local,
              selected: _selected == PartnerServiceMode.local,
              dark: true,
              onTap: () => setState(() => _selected = PartnerServiceMode.local),
            ),
            const SizedBox(height: 12),
            _ModeOptionCard(
              mode: PartnerServiceMode.intercity,
              selected: _selected == PartnerServiceMode.intercity,
              dark: true,
              onTap: () => setState(() => _selected = PartnerServiceMode.intercity),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: primaryLime,
                  foregroundColor: Colors.black,
                  disabledBackgroundColor: primaryLime.withValues(alpha: 0.3),
                  elevation: 0,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                onPressed: (_selected == widget.currentMode || _saving) ? null : _save,
                child: _saving
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(color: Colors.black, strokeWidth: 2),
                      )
                    : const Text('Save', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ModeOptionCard extends StatelessWidget {
  final PartnerServiceMode mode;
  final bool selected;
  final VoidCallback onTap;
  final bool dark;

  const _ModeOptionCard({
    required this.mode,
    required this.selected,
    required this.onTap,
    this.dark = false,
  });

  @override
  Widget build(BuildContext context) {
    final accent = dark ? const Color(0xFFC5FF30) : const Color(0xFF10B981);
    final cardColor = dark ? const Color(0xFF1B2333) : Colors.white;
    final borderColor = dark ? const Color(0xFF2A3447) : const Color(0xFFE2E8F0);
    final titleColor = dark ? Colors.white : const Color(0xFF0F172A);
    final subtitleColor = dark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);
    final radioOffColor = dark ? const Color(0xFF475569) : const Color(0xFFCBD5E1);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: cardColor,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: selected ? accent : borderColor,
            width: selected ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            Icon(
              selected ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
              color: selected ? accent : radioOffColor,
              size: 24,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    mode.label,
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: titleColor),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    mode.description,
                    style: TextStyle(fontSize: 12.5, color: subtitleColor, height: 1.4),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
