import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:waydrop/features/rider/onboarding/services/rider_kyc_upload_service.dart';

/// Uploads the passenger's own optional profile photo to the 'user_profile_photos' bucket
/// (added alongside the `users.profile_photo_url` column so travellers can identify which
/// passenger they're serving before OTP verification). Mirrors RiderKycUploadService's
/// compress-then-upload pattern, reusing its compression step directly since that method is
/// generic over any XFile and not tied to the rider_kyc bucket.
class PassengerPhotoService {
  PassengerPhotoService._();

  static SupabaseClient get _supabase => Supabase.instance.client;

  static Future<String> uploadProfilePhoto(XFile image) async {
    final user = _supabase.auth.currentUser;
    if (user == null) {
      throw Exception('User not logged in');
    }

    await RiderKycUploadService.validateImage(image);
    final compressed = await RiderKycUploadService.compressImageSmart(image);

    final path = '${user.id}/profile_${DateTime.now().millisecondsSinceEpoch}.jpg';
    final publicUrl = _supabase.storage.from('user_profile_photos').getPublicUrl(path);

    await _supabase.storage
        .from('user_profile_photos')
        .upload(path, compressed, fileOptions: const FileOptions(upsert: true));

    try {
      await _supabase.from('users').update({'profile_photo_url': publicUrl}).eq('id', user.id);
    } catch (e) {
      debugPrint('PassengerPhotoService: failed to persist profile_photo_url: $e');
      rethrow;
    }

    return publicUrl;
  }
}
