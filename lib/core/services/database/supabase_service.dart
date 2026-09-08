/// ============================================================================
/// File: supabase_service.dart
///
/// Module:
/// Core → Services → Database
///
/// Purpose:
/// Initializer and client provider for Supabase.
///
/// Responsibilities:
/// • Expose Supabase client instance.
/// • Initialize database dependencies on application startup.
///
/// Related:
/// main.dart
/// ============================================================================

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class SupabaseService {
  final SupabaseClient client = Supabase.instance.client;

  Future<void> sendOtp(String phone) async {
    final formattedPhone = formatPhone(phone);

    await client.auth.signInWithOtp(
      phone: formattedPhone,
    );
  }

  Future<AuthResponse> verifyOtp({
    required String phone,
    required String token,
  }) async {
    final formattedPhone = formatPhone(phone);

    final response = await client.auth.verifyOTP(
      phone: formattedPhone,
      token: token.trim(),
      type: OtpType.sms,
    );

    final user = response.user;

    if (user != null) {
      try {
  await client.from('users').upsert({
    'id': user.id,
    'phone': user.phone,
  });
} catch (e) {
  debugPrint('Failed to upsert user record after OTP verification: $e');
}
    }

    return response;
  }

  String formatPhone(String phone) {
    phone = phone.trim().replaceAll(' ', '');

    if (!phone.startsWith('+91')) {
      phone = '+91${phone.replaceAll('+91', '')}';
    }

    return phone;
  }
}