import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class ParcelUploadUnconfirmed implements Exception {
  const ParcelUploadUnconfirmed();
  @override
  String toString() =>
      'Photo upload could not be confirmed. Check / retry the same photo.';
}

class ParcelUploadService {
  static final _shared = ParcelPhotoUploader(Supabase.instance.client);
  static Future<List<String>> uploadImages(List<dynamic> images) =>
      _shared.uploadImages(images);
  static Future<String> uploadVerificationBytes(
    Uint8List bytes, {
    required String orderId,
    required String photoType,
  }) => _shared.uploadVerificationBytes(
    bytes,
    orderId: orderId,
    photoType: photoType,
  );
}

/// Immutable account-scoped addresses survive screen/process recreation.
/// Timeouts never replace an outstanding write. No automatic write retry.
class ParcelPhotoUploader {
  final SupabaseClient client;
  final Duration responseTimeout;
  final _inFlight = <String, Future<String>>{};
  ParcelPhotoUploader(
    this.client, {
    this.responseTimeout = const Duration(seconds: 20),
  });

  Future<String> uploadVerificationBytes(
    Uint8List bytes, {
    required String orderId,
    required String photoType,
  }) async {
    final owner = client.auth.currentUser?.id;
    if (owner == null) throw const AuthException('Sign in to upload a photo.');
    if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(orderId) ||
        !['pickup', 'dropoff'].contains(photoType)) {
      throw ArgumentError('Invalid verification scope.');
    }
    final snapshot = Uint8List.fromList(bytes);
    final digest = sha256.convert(snapshot).toString();
    final suffix = _suffix(snapshot);
    final path =
        'orders/$orderId/verifications/$photoType/$owner/$digest.$suffix';
    var work = _inFlight[path];
    if (work == null) {
      late final Future<String> owned;
      owned = _upload(owner, path, snapshot, digest, suffix).whenComplete(() {
        if (identical(_inFlight[path], owned)) _inFlight.remove(path);
      });
      _inFlight[path] = work = owned;
    }
    try {
      final url = await work.timeout(responseTimeout);
      _checkOwner(owner);
      return url;
    } on TimeoutException {
      throw const ParcelUploadUnconfirmed();
    }
  }

  Future<List<String>> uploadImages(List<dynamic> images) async {
    final owner = client.auth.currentUser?.id;
    if (owner == null) throw const AuthException('Sign in to upload a photo.');
    final urls = <String>[];
    // Bound write concurrency, preserving selection order and partial success.
    for (final image in List<dynamic>.of(images)) {
      _checkOwner(owner);
      if (image is String) {
        urls.add(image);
      } else if (image is File) {
        final bytes = await image.readAsBytes();
        _checkOwner(owner);
        final digest = sha256.convert(bytes).toString();
        final suffix = _suffix(bytes);
        final path = 'parcels/$owner/$digest.$suffix';
        var work = _inFlight[path];
        if (work == null) {
          late final Future<String> owned;
          owned = _upload(owner, path, bytes, digest, suffix).whenComplete(() {
            if (identical(_inFlight[path], owned)) _inFlight.remove(path);
          });
          _inFlight[path] = work = owned;
        }
        try {
          urls.add(await work.timeout(responseTimeout));
        } on TimeoutException {
          throw const ParcelUploadUnconfirmed();
        }
        _checkOwner(owner);
      }
    }
    return urls;
  }

  void _checkOwner(String owner) {
    if (client.auth.currentUser?.id != owner) {
      throw const AuthException('Account changed during photo upload.');
    }
  }

  Future<bool> _verified(String owner, String path, String digest) async {
    _checkOwner(owner);
    Uint8List remote;
    try {
      // Exact-object read, never a broad listing or an existence-only claim.
      remote = await client.storage.from('parcel_images').download(path);
    } on StorageException catch (e) {
      _checkOwner(owner);
      if (e.statusCode == '404') return false;
      if (e.statusCode == '400') {
        try {
          final body = jsonDecode(e.message);
          if (body is Map && ['NoSuchKey', 'NotFound'].contains(body['code'])) {
            return false;
          }
        } on FormatException {
          /* A generic 400 is not proof of absence. */
        }
      }
      rethrow;
    }
    _checkOwner(owner);
    if (sha256.convert(remote).toString() != digest) {
      throw const ParcelUploadUnconfirmed(); // Never overwrite different content.
    }
    return true;
  }

  Future<String> _upload(
    String owner,
    String path,
    Uint8List bytes,
    String digest,
    String suffix,
  ) async {
    final bucket = client.storage.from('parcel_images');
    if (await _verified(owner, path, digest)) return bucket.getPublicUrl(path);
    _checkOwner(owner);
    try {
      await bucket.uploadBinary(
        path,
        bytes,
        fileOptions: FileOptions(
          upsert: false,
          contentType: switch (suffix) {
            'jpg' => 'image/jpeg',
            'png' => 'image/png',
            'webp' => 'image/webp',
            'heic' => 'image/heic',
            _ => 'application/octet-stream',
          },
        ),
        retryAttempts: 0,
      );
    } catch (failure) {
      _checkOwner(owner);
      if (failure is StorageException &&
          ['401', '403', '413', '415', '422'].contains(failure.statusCode)) {
        rethrow;
      }
      // 504, abort and duplicate responses have uncertain commit outcomes.
      // One read-only reconciliation: no second POST, PUT, deletion or upsert.
      try {
        if (await _verified(owner, path, digest)) {
          return bucket.getPublicUrl(path);
        }
      } catch (_) {
        _checkOwner(owner);
        throw const ParcelUploadUnconfirmed();
      }
      throw const ParcelUploadUnconfirmed();
    }
    _checkOwner(owner);
    return bucket.getPublicUrl(path);
  }

  static String _suffix(Uint8List bytes) {
    if (bytes.length >= 3 &&
        bytes[0] == 255 &&
        bytes[1] == 216 &&
        bytes[2] == 255) {
      return 'jpg';
    }
    if (bytes.length >= 8 &&
        bytes[0] == 137 &&
        bytes[1] == 80 &&
        bytes[2] == 78 &&
        bytes[3] == 71) {
      return 'png';
    }
    if (bytes.length >= 12 &&
        ascii.decode(bytes.sublist(0, 4), allowInvalid: true) == 'RIFF' &&
        ascii.decode(bytes.sublist(8, 12), allowInvalid: true) == 'WEBP') {
      return 'webp';
    }
    if (bytes.length >= 12 &&
        [
          'heic',
          'heix',
          'hevc',
          'hevx',
        ].contains(ascii.decode(bytes.sublist(8, 12), allowInvalid: true))) {
      return 'heic';
    }
    return 'bin';
  }
}
