/// Reserved test-only phone number used to bypass real OTP delivery for
/// Cashfree/Play Store reviewer access and internal dummy-payment testing.
/// This must stay an EXACT match everywhere it is used — never widen it to
/// a prefix/substring match, since that turns it into a public auth bypass.
const String kReviewerBypassPhone = '9999999999';

class AuthSession {
  static String? activePhone;

  static DateTime? lastOtpTime;

  static int resendAttempts = 0;

  static DateTime? blockedUntil;

  static bool get isBlocked {
    if (blockedUntil == null) return false;

    return DateTime.now().isBefore(
      blockedUntil!,
    );
  }

  static Duration? get remainingBlock {
    if (blockedUntil == null) return null;

    final diff = blockedUntil!.difference(DateTime.now());
    return diff.isNegative ? Duration.zero : diff;
  }

  static int getCooldownDuration(int attempts) {
    if (attempts <= 1) return 30;
    if (attempts == 2) return 60;
    if (attempts == 3) return 300;
    if (attempts == 4) return 600;
    return 1800; // 30 minutes block handled separately
  }

  static int get remainingCooldownSeconds {
    if (lastOtpTime == null) return 0;
    final cooldown = getCooldownDuration(resendAttempts);
    final elapsed = DateTime.now().difference(lastOtpTime!).inSeconds;
    final remaining = cooldown - elapsed;
    return remaining > 0 ? remaining : 0;
  }

  static void clear() {
    activePhone = null;
    lastOtpTime = null;
    resendAttempts = 0;
    blockedUntil = null;
  }
}