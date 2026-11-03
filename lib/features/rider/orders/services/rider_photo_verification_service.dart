import 'dart:async';
import 'dart:convert';
import 'package:supabase_flutter/supabase_flutter.dart';

class RiderProofUnconfirmed implements Exception {
  const RiderProofUnconfirmed();
  @override
  String toString() =>
      'Photo verification is unconfirmed. Check proof status before retrying.';
}

/// Screen-scoped transport ownership, not a replacement for server idempotency.
/// Keep completed/failed outcomes so the same proof is never automatically POSTed
/// again by this owner after a lost response or partial server-side write.
class RiderPhotoVerificationService {
  final SupabaseClient client;
  final Duration responseTimeout;
  final _requests = <String, Future<FunctionResponse>>{};
  RiderPhotoVerificationService(
    this.client, {
    this.responseTimeout = const Duration(seconds: 20),
  });

  Future<FunctionResponse> verify({
    required String owner,
    required String orderId,
    required String riderId,
    required String photoType,
    required String photoUrl,
    required bool Function() isActive,
    double? latitude,
    double? longitude,
    String? deviceId,
  }) async {
    void checkOwner() {
      if (client.auth.currentUser?.id != owner) {
        throw const AuthException('Account changed during verification.');
      }
      if (!isActive()) {
        throw StateError('Verification screen is no longer active.');
      }
    }

    checkOwner();
    final key = jsonEncode([owner, orderId, riderId, photoType, photoUrl]);
    final request = _requests.putIfAbsent(
      key,
      () => client.functions.invoke(
        'process-verification-photo',
        body: {
          'order_id': orderId,
          'rider_id': riderId,
          'photo_type': photoType,
          'photo_url': photoUrl,
          'latitude': latitude,
          'longitude': longitude,
          'device_id': deviceId,
        },
      ),
    );
    try {
      final response = await request.timeout(responseTimeout);
      checkOwner();
      return response;
    } on TimeoutException {
      throw const RiderProofUnconfirmed();
    } on FunctionException catch (error) {
      checkOwner();
      if (error.status >= 500) throw const RiderProofUnconfirmed();
      rethrow;
    } catch (_) {
      checkOwner();
      throw const RiderProofUnconfirmed();
    }
  }
}
