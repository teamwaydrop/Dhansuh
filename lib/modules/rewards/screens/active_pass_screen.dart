import 'dart:async';

import 'package:flutter/material.dart';
import 'package:waydrop/design_system/waydrop_design_system.dart';
import 'package:waydrop/modules/rewards/services/reward_service.dart';

/// The live "WayDrop Rewards Pass" -- shown immediately after a successful activation.
/// The countdown is derived purely from the server-returned `expires_at` timestamp
/// (never a client-side "+5 minutes" computation), so it stays correct even if the app
/// was briefly suspended. There is no redeem/verify/scan control anywhere on this
/// screen and the coupon code is never displayed -- the pass itself is the proof.
///
/// The underlying reward cycle was already consumed atomically by activate_reward_offer
/// at activation time, so nothing here can "undo" that. Back navigation and
/// backgrounding still call close_active_pass (best-effort) so this specific pass is
/// never re-presented as live after the user leaves it, per the terminal-condition rule.
class ActivePassScreen extends StatefulWidget {
  final String ownerType;

  /// The activate_reward_offer RPC's success payload: reward_cycle_id, merchant_name,
  /// offer_title, discount_type, discount_value, activated_at, expires_at.
  final Map<String, dynamic> activation;

  const ActivePassScreen({super.key, required this.ownerType, required this.activation});

  @override
  State<ActivePassScreen> createState() => _ActivePassScreenState();
}

class _ActivePassScreenState extends State<ActivePassScreen> with WidgetsBindingObserver {
  late final DateTime _expiresAt;
  late final String _rewardCycleId;
  Timer? _tickTimer;
  Duration _remaining = Duration.zero;
  bool _closedOnce = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _rewardCycleId = widget.activation['reward_cycle_id'] as String;
    _expiresAt = DateTime.parse(widget.activation['expires_at'] as String).toLocal();
    _updateRemaining();
    // A once-a-second UI tick only -- purely local countdown math against the
    // authoritative _expiresAt, never a network call. No backend polling here.
    _tickTimer = Timer.periodic(const Duration(seconds: 1), (_) => _updateRemaining());
  }

  void _updateRemaining() {
    if (!mounted) return;
    final remaining = _expiresAt.difference(DateTime.now());
    setState(() => _remaining = remaining.isNegative ? Duration.zero : remaining);
    if (remaining.isNegative || remaining == Duration.zero) {
      _tickTimer?.cancel();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Backgrounding is a terminal condition for the pass per Phase 14 business rules --
    // close it the moment the app is no longer in the foreground, not only on the
    // 5-minute timeout. `paused` (not the transient `inactive`) is the correct signal
    // for "genuinely left the app", matching standard Flutter lifecycle handling.
    if (state == AppLifecycleState.paused) {
      _closePass();
    }
  }

  void _closePass() {
    if (_closedOnce) return;
    _closedOnce = true;
    // Fire-and-forget: the reward cycle is already permanently consumed regardless of
    // whether this call ever reaches the server; this only closes the pass record so it
    // is never re-shown as still-live.
    unawaited(RewardService.closeActivePass(ownerType: widget.ownerType, rewardCycleId: _rewardCycleId));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tickTimer?.cancel();
    super.dispose();
  }

  String _formatCountdown(Duration d) {
    final minutes = d.inMinutes.toString().padLeft(2, '0');
    final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final activation = widget.activation;
    final merchantName = activation['merchant_name'] as String? ?? '';
    final offerTitle = activation['offer_title'] as String? ?? '';
    final discountType = activation['discount_type'] as String? ?? 'percentage';
    final discountValue = (activation['discount_value'] as num?) ?? 0;
    final expired = _remaining == Duration.zero;

    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) _closePass();
      },
      child: Scaffold(
        backgroundColor: isDark ? const Color(0xFF0F1115) : WayDropColors.background,
        appBar: AppBar(
          title: const Text('WayDrop Rewards Pass'),
          backgroundColor: Colors.transparent,
          elevation: 0,
        ),
        body: ListView(
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            WayDropCard(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
              borderRadius: 28,
              border: Border.all(color: WayDropColors.goldAccent.withValues(alpha: 0.35), width: 1.5),
              child: Column(
                children: [
                  Text(
                    'WAYDROP REWARDS',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w900, letterSpacing: 3, color: isDark ? WayDropColors.goldAccent : WayDropColors.primaryEmerald),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    merchantName,
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900, letterSpacing: -0.5, color: isDark ? Colors.white : WayDropColors.primaryText),
                  ),
                  if (offerTitle.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(offerTitle, textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: isDark ? Colors.white60 : WayDropColors.secondaryText, fontWeight: FontWeight.w600)),
                  ],
                  const SizedBox(height: 28),
                  Text('SPECIAL DISCOUNT', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 2, color: isDark ? Colors.white38 : Colors.grey.shade500)),
                  const SizedBox(height: 8),
                  Text(
                    RewardService.formatDiscount(discountType, discountValue),
                    style: const TextStyle(fontSize: 48, fontWeight: FontWeight.w900, color: WayDropColors.primaryEmerald, letterSpacing: -1),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'SHOW THIS SCREEN AT\nRECEPTION / BILL PAYMENT',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, letterSpacing: 0.5, height: 1.4, color: isDark ? Colors.white70 : WayDropColors.primaryText),
                  ),
                  const SizedBox(height: 24),
                  Text('OFFER ACTIVE FOR', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 1.5, color: isDark ? Colors.white38 : Colors.grey.shade500)),
                  const SizedBox(height: 6),
                  Text(
                    expired ? 'EXPIRED' : _formatCountdown(_remaining),
                    style: TextStyle(
                      fontSize: 36,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1,
                      color: expired ? const Color(0xFFEF4444) : (isDark ? Colors.white : WayDropColors.primaryText),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    'Show this screen at the merchant to claim your WayDrop discount.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, height: 1.4, color: isDark ? Colors.white60 : WayDropColors.secondaryText),
                  ),
                ],
              ),
            ),
            if (expired)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: WayDropSecondaryButton(
                  text: 'DONE',
                  onPressed: () {
                    _closePass();
                    Navigator.pop(context);
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}
