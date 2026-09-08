import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class AnalyticsService {
  static final AnalyticsService instance = AnalyticsService._internal();
  AnalyticsService._internal();

  final _supabase = Supabase.instance.client;

  /// Logs a custom analytics event.
  Future<void> logEvent(String eventName, Map<String, dynamic> properties) async {
    final user = _supabase.auth.currentUser;
    debugPrint('=== ANALYTICS EVENT => $eventName | User: ${user?.id} | Properties: $properties');
    
    try {
      await _supabase.from('analytics_events').insert({
        'event_name': eventName,
        'user_id': user?.id,
        'properties': properties,
        'timestamp': DateTime.now().toIso8601String(),
      });
    } catch (e) {
      // Silently catch database write errors during load tests / local runs
      debugPrint('Analytics logging to DB ignored: $e');
    }
  }

  // =====================================================
  // ANALYTICS CONVERSION FUNNELS
  // =====================================================

  Future<void> logRideRequested({required String orderId, required double estimatedFare, required String orderType}) async {
    await logEvent('Ride Requested', {
      'order_id': orderId,
      'estimated_fare': estimatedFare,
      'order_type': orderType,
    });
  }

  Future<void> logDispatchStarted({required String orderId}) async {
    await logEvent('Dispatch Started', {
      'order_id': orderId,
    });
  }

  Future<void> logRiderAssigned({required String orderId, required String riderId}) async {
    await logEvent('Rider Assigned', {
      'order_id': orderId,
      'rider_id': riderId,
    });
  }

  Future<void> logRideAccepted({required String orderId, required String riderId}) async {
    await logEvent('Ride Accepted', {
      'order_id': orderId,
      'rider_id': riderId,
    });
  }

  Future<void> logRideStarted({required String orderId}) async {
    await logEvent('Ride Started', {
      'order_id': orderId,
    });
  }

  Future<void> logRideCompleted({required String orderId}) async {
    await logEvent('Ride Completed', {
      'order_id': orderId,
    });
  }

  Future<void> logPaymentCompleted({
    required String orderId,
    required double amount,
    required String paymentMethod,
  }) async {
    await logEvent('Payment Completed', {
      'order_id': orderId,
      'amount': amount,
      'payment_method': paymentMethod,
    });
  }

  Future<void> logParcelCreated({required String orderId, required double fare}) async {
    await logEvent('Parcel Created', {
      'order_id': orderId,
      'fare': fare,
    });
  }

  Future<void> logParcelDelivered({required String orderId}) async {
    await logEvent('Parcel Delivered', {
      'order_id': orderId,
    });
  }

  Future<void> logOtpVerified({required String orderId, required String otpType}) async {
    await logEvent('OTP Verified', {
      'order_id': orderId,
      'otp_type': otpType,
    });
  }
}
