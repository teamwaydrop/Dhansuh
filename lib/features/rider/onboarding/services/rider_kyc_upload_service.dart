import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:waydrop/features/rider/onboarding/models/kyc_upload_state.dart';

/// Thrown by [RiderKycUploadService.uploadSingleDocument] when the upload's own generation is no
/// longer current -- the caller re-picked this document slot while the upload was still in
/// flight. The caller should discard the result silently (never surface as a user-facing error).
class StaleUploadException implements Exception {
  const StaleUploadException();
}

/// Thrown when the storage call fails with an auth error (expired/invalid session). Never worth
/// auto-retrying -- the caller should prompt re-authentication instead of burning the backoff
/// budget on a request that can't succeed.
class KycUploadAuthException implements Exception {
  final String message;
  const KycUploadAuthException(this.message);
  @override
  String toString() => message;
}

class KycAttemptInfo {
  final String userId;
  final String phone;
  final int attemptNumber;
  const KycAttemptInfo({required this.userId, required this.phone, required this.attemptNumber});
}

class RiderKycUploadService {
  static final supabase = Supabase.instance.client;

  // =====================================================
  // MAX FILE SIZE
  // =====================================================

  static const int maxSizeBytes = 2 * 1024 * 1024;

  // =====================================================
  // RESOLVE ATTEMPT INFO (server round-trip: phone + rejection_count)
  //
  // Called once at KYC screen init to decide fresh-vs-resume for the local upload session --
  // NOT at Submit time anymore. `rejection_count` already drives create-rider-kyc's own
  // resubmission logic server-side; this reuses that same number client-side purely to detect
  // "a new rejection cycle started since the last locally-persisted session" (see
  // buildFreshSessionFolder below).
  // =====================================================

  static Future<KycAttemptInfo> resolveAttemptInfo() async {
    final user = supabase.auth.currentUser;
    if (user == null) {
      throw Exception('User not logged in');
    }

    final response = await supabase
        .from('users')
        .select('phone')
        .eq('id', user.id)
        .single()
        .timeout(const Duration(seconds: 15));

    final rawPhone = response['phone'] ?? '';
    final phone = rawPhone.toString().replaceAll('+91', '').replaceAll(' ', '');

    final existing = await supabase
        .from('rider_kyc')
        .select('rejection_count')
        .eq('user_id', user.id)
        .maybeSingle()
        .timeout(const Duration(seconds: 15));

    int attempt = 1;
    if (existing != null) {
      final int rejections = existing['rejection_count'] ?? 0;
      attempt = rejections + 1;
    }

    return KycAttemptInfo(userId: user.id, phone: phone, attemptNumber: attempt);
  }

  /// Builds a brand-new session folder for a fresh attempt. Pure/local -- no DB call. The random
  /// suffix (not present in the old batch-upload folder scheme) makes the folder collision-proof
  /// across two devices/processes that independently resolve the same attempt number: each
  /// starting a fresh session gets its own folder, so `upsert:true` writes from one device can
  /// never silently overwrite another device's upload for what the fixed-filename scheme would
  /// otherwise treat as "the same" document.
  static String buildFreshSessionFolder({
    required String userId,
    required String phone,
    required int attemptNumber,
  }) {
    return '$userId/${phone}_attempt_${attemptNumber}_${_randomSuffix(8)}';
  }

  static String _randomSuffix(int length) {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final rnd = Random.secure();
    return List.generate(length, (_) => chars[rnd.nextInt(chars.length)]).join();
  }

  // =====================================================
  // LIST SESSION FOLDER (resume reconciliation)
  // =====================================================

  /// Lists every object already present under [sessionFolder], returning just the bare
  /// filenames (no extension check needed -- every doc is uploaded as `<fileName>.jpg`). Used
  /// once per resume to reconcile every locally-persisted slot in a single round trip rather
  /// than a per-file existence check.
  ///
  /// Returns `null` -- not an empty set -- when the listing call itself failed (e.g. no network
  /// at exactly the moment the app resumes). Collapsing that into an empty set previously made an
  /// inconclusive "we couldn't check" indistinguishable from a confirmed "nothing is there", which
  /// caused every already-durably-uploaded document to be wrongly demoted to failed (forcing a
  /// pointless re-upload) whenever resume happened to run while offline. Callers must treat `null`
  /// as "unknown" and leave already-`uploaded` slots alone rather than trusting an empty set.
  static Future<Set<String>?> listSessionFolder(String sessionFolder) async {
    try {
      final objects = await supabase.storage
          .from('rider_kyc')
          .list(path: sessionFolder)
          .timeout(const Duration(seconds: 15));
      return objects.map((o) => o.name).toSet();
    } catch (e) {
      debugPrint('listSessionFolder failed for $sessionFolder => $e');
      return null;
    }
  }

  // =====================================================
  // COMPRESS IMAGE SMARTLY
  // =====================================================

  static Future<File> compressImageSmart(XFile image) async {
    final original = File(image.path);

    final originalSize = await original.length();

    debugPrint(
      'ORIGINAL SIZE => ${(originalSize / 1024 / 1024).toStringAsFixed(2)} MB',
    );

    // =========================================
    // IF ALREADY UNDER 2MB
    // =========================================

    if (originalSize <= maxSizeBytes) {
      debugPrint('NO COMPRESSION NEEDED');

      return original;
    }

    // =========================================
    // COMPRESS UNTIL <= 2MB
    // =========================================

    final tempDir = await getTemporaryDirectory();

    int quality = 95;

    File? compressedFile;

    while (quality >= 20) {
      final targetPath =
          '${tempDir.path}/${DateTime.now().millisecondsSinceEpoch}_$quality.jpg';

      final result = await FlutterImageCompress.compressAndGetFile(
        image.path,
        targetPath,
        quality: quality,
        minWidth: 1280,
        minHeight: 1280,
      );

      if (result == null) {
        throw Exception('Compression failed');
      }

      compressedFile = File(result.path);

      final size = await compressedFile.length();

      debugPrint(
        'QUALITY $quality => ${(size / 1024 / 1024).toStringAsFixed(2)} MB',
      );

      if (size <= maxSizeBytes) {
        debugPrint(
          'FINAL SIZE => ${(size / 1024 / 1024).toStringAsFixed(2)} MB',
        );

        return compressedFile;
      }

      quality -= 10;
    }

    // =========================================
    // FINAL CHECK
    // =========================================

    if (compressedFile == null) {
      throw Exception('Compression failed');
    }

    final finalSize = await compressedFile.length();

    if (finalSize > maxSizeBytes) {
      throw Exception('Unable to compress under 2MB');
    }

    return compressedFile;
  }

  // =====================================================
  // VALIDATE IMAGE BEFORE UPLOAD
  // =====================================================

  static Future<void> validateImage(XFile image) async {
    final file = File(image.path);

    final size = await file.length();

    if (size <= 0) {
      throw Exception('Invalid image file');
    }
  }

  // =====================================================
  // UPLOAD SINGLE FILE (flat retry -- kept for add_vehicle_screen.dart, unchanged)
  // =====================================================

  static Future<String> uploadCompressedFile({
    required File file,
    required String fileName,
    required String folderName,
  }) async {
    final path = '$folderName/$fileName.jpg';
    final size = await file.length();

    int attempt = 1;
    const int maxAttempts = 3;
    const Duration delay = Duration(milliseconds: 1500);

    while (attempt <= maxAttempts) {
      try {
        debugPrint('UPLOADING (Attempt $attempt/$maxAttempts) => rider_kyc/$path');
        debugPrint('FINAL SIZE => ${(size / 1024 / 1024).toStringAsFixed(2)} MB');

        await supabase.storage
            .from('rider_kyc')
            .upload(path, file, fileOptions: const FileOptions(upsert: true))
            .timeout(const Duration(seconds: 30));

        debugPrint('UPLOAD SUCCESS => $path');
        return path;
      } on TimeoutException catch (e) {
        debugPrint('UPLOAD ATTEMPT $attempt TIMED OUT => $e');
        if (attempt >= maxAttempts) {
          throw Exception('Upload timed out. Please check your connection and try again.');
        }
        attempt++;
        await Future.delayed(delay);
      } catch (e) {
        debugPrint('UPLOAD ATTEMPT $attempt FAILED => $e');
        if (attempt >= maxAttempts) {
          rethrow;
        }
        attempt++;
        await Future.delayed(delay);
      }
    }
    throw Exception('Failed to upload file after $maxAttempts attempts');
  }

  // =====================================================
  // UPLOAD ONE KYC DOCUMENT -- immediate-on-pick, exponential backoff + jitter, stale-generation
  // aware. This is the entry point the redesigned KYC screen calls from each picker's onTap,
  // replacing the old batch uploadAllDocuments() (removed -- its only caller was the KYC
  // Submit button, which no longer uploads anything).
  // =====================================================

  static Future<String> uploadSingleDocument({
    required KycDocSlot slot,
    required XFile file,
    required String sessionFolder,
    required int pickGeneration,
    required bool Function() isStale,
    int maxAttempts = 4, // 1 initial attempt + 3 backoff retries
  }) async {
    await validateImage(file);
    if (isStale()) throw const StaleUploadException();

    final compressed = await compressImageSmart(file);
    if (isStale()) throw const StaleUploadException();

    // The generation is baked into the object path itself (not just tracked locally). This is
    // what makes the same-slot race structurally impossible rather than merely discouraged: a
    // stale (superseded) upload and a newer re-pick of the same slot used to share one fixed path
    // with upsert:true, so whichever's write landed on the server LAST won -- regardless of which
    // one was actually current -- since "discard the stale result locally" never stopped that
    // write from reaching storage. With a distinct path per generation, two different generations
    // can no longer collide at all; there is nothing left for a stale write to overwrite.
    final path = '$sessionFolder/${slot.storageFileName}_g$pickGeneration.jpg';
    const backoffSecondsTable = [1, 2, 4];

    int attempt = 0;
    while (true) {
      attempt++;
      // Re-checked before every attempt (not just once up front) purely to avoid burning the
      // retry/backoff budget on an upload nobody wants anymore -- correctness no longer depends on
      // this check now that generations can't collide, but there's no reason to keep retrying work
      // whose result will just be discarded.
      if (isStale()) throw const StaleUploadException();
      try {
        await supabase.storage
            .from('rider_kyc')
            .upload(path, compressed, fileOptions: const FileOptions(upsert: true))
            .timeout(const Duration(seconds: 30));

        if (isStale()) throw const StaleUploadException();
        return path;
      } on StaleUploadException {
        rethrow;
      } on StorageException catch (e) {
        if (_isAuthError(e)) {
          throw KycUploadAuthException('Your session has expired. Please sign in again.');
        }
        if (attempt >= maxAttempts) rethrow;
        await Future.delayed(_backoffDelay(backoffSecondsTable, attempt));
      } catch (e) {
        if (attempt >= maxAttempts) rethrow;
        await Future.delayed(_backoffDelay(backoffSecondsTable, attempt));
      }
    }
  }

  static bool _isAuthError(StorageException e) {
    final status = e.statusCode?.toString() ?? '';
    final msg = e.message.toLowerCase();
    return status == '401' ||
        msg.contains('jwt') ||
        msg.contains('unauthorized') ||
        msg.contains('invalid token') ||
        msg.contains('expired');
  }

  static Duration _backoffDelay(List<int> table, int attempt) {
    final index = (attempt - 1).clamp(0, table.length - 1);
    final base = table[index];
    // Same jitter shape as RealtimeManager's reconnect backoff (0.85x-1.15x of base).
    final jitter = 0.85 + 0.30 * (DateTime.now().millisecond / 1000.0);
    return Duration(milliseconds: (base * 1000 * jitter).toInt());
  }

  // =====================================================
  // ROLLBACK FILES -- kept for explicit user-initiated "start over" only. No longer called
  // automatically on create-rider-kyc failure (uploads are now durable/independent of submit
  // outcome -- see rider_kyc_screen.dart submitKyc()).
  // =====================================================

  static Future<void> rollbackFiles(List<String> paths) async {
    try {
      if (paths.isEmpty) {
        return;
      }

      await supabase.storage.from('rider_kyc').remove(paths);

      debugPrint('ROLLBACK SUCCESS');
    } catch (e) {
      debugPrint('ROLLBACK ERROR => $e');
    }
  }
}
