import 'package:flutter/material.dart';

/// Small green checkmark shown next to a Partner/User's name once their KYC is approved.
/// Extracted from the inline pattern previously duplicated only in
/// intercity_searching_screen.dart (`Icons.verified_rounded`, size 14, #10B981, driven by
/// `kyc_status == 'approved'`) so the new Partner/User cards can reuse it instead of a third copy.
class VerifiedBadge extends StatelessWidget {
  final bool isVerified;
  final double size;

  const VerifiedBadge({super.key, required this.isVerified, this.size = 14});

  @override
  Widget build(BuildContext context) {
    if (!isVerified) return const SizedBox.shrink();
    return Icon(Icons.verified_rounded, size: size, color: const Color(0xFF10B981));
  }
}
