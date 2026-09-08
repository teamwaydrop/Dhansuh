import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

class CacheService {
  static final CacheService instance = CacheService._internal();
  CacheService._internal();

  static const int currentSchemaVersion = 1;
  static const int currentKeyVersion = 1;

  static const _secureStorage = FlutterSecureStorage();

  Box? _cacheBox;
  bool _isInitialized = false;

  Future<void> init() async {
    if (_isInitialized) return;
    try {
      await Hive.initFlutter();

      String? keyBase64 = await _secureStorage.read(key: 'hive_encryption_key');

      if (keyBase64 == null) {
        // Migrate a key from the old (plaintext SharedPreferences) location so
        // upgrading users don't lose access to their existing encrypted cache.
        final prefs = await SharedPreferences.getInstance();
        final legacyKeyBase64 = prefs.getString('hive_encryption_key');

        keyBase64 = legacyKeyBase64 ?? base64Encode(Hive.generateSecureKey());
        await _secureStorage.write(key: 'hive_encryption_key', value: keyBase64);
        await prefs.setInt('hive_key_version', currentKeyVersion);
        if (legacyKeyBase64 != null) {
          await prefs.remove('hive_encryption_key');
        }
      }

      final keyBytes = base64Decode(keyBase64);

      _cacheBox = await Hive.openBox(
        'waydrop_secure_cache',
        encryptionCipher: HiveAesCipher(keyBytes),
      );

      _isInitialized = true;
    } catch (e) {
      debugPrint('CacheService initialization failed, attempting fallback recovery: $e');
      // In case of corruption, key changes, or encryption failures, purge and rebuild the store
      try {
        final prefs = await SharedPreferences.getInstance();
        await _secureStorage.delete(key: 'hive_encryption_key');
        await prefs.remove('hive_encryption_key');
        await Hive.deleteBoxFromDisk('waydrop_secure_cache');

        final newKey = Hive.generateSecureKey();
        await _secureStorage.write(key: 'hive_encryption_key', value: base64Encode(newKey));
        await prefs.setInt('hive_key_version', currentKeyVersion);

        _cacheBox = await Hive.openBox(
          'waydrop_secure_cache',
          encryptionCipher: HiveAesCipher(newKey),
        );
        _isInitialized = true;
      } catch (recoveryError) {
        debugPrint('CacheService fallback recovery also failed: $recoveryError');
      }
    }
  }

  /// Write item to the cache with optional TTL.
  Future<void> put(String key, dynamic value, {Duration? ttl}) async {
    if (!_isInitialized || _cacheBox == null) {
      await init();
    }
    if (_cacheBox == null) return;

    final entry = {
      'version': currentSchemaVersion,
      'key_version': currentKeyVersion,
      'createdAt': DateTime.now().toIso8601String(),
      'ttl_seconds': ttl?.inSeconds ?? -1, // -1 means no TTL/immortal
      'data': value,
    };

    try {
      await _cacheBox!.put(key, jsonEncode(entry));
    } catch (e) {
      debugPrint('Cache write error: $e');
    }
  }

  /// Get item from the cache. Returns null if expired or invalid.
  dynamic get(String key) {
    if (!_isInitialized || _cacheBox == null) {
      return null;
    }

    final raw = _cacheBox!.get(key);
    if (raw == null) return null;

    try {
      final entry = jsonDecode(raw.toString());
      if (entry is! Map) return null;

      final version = entry['version'] as int?;
      final keyVersion = entry['key_version'] as int?;
      if (version != currentSchemaVersion || keyVersion != currentKeyVersion) {
        // Version mismatch, invalidate
        _cacheBox!.delete(key);
        return null;
      }

      final createdAtStr = entry['createdAt'] as String?;
      final ttlSeconds = entry['ttl_seconds'] as int?;
      if (createdAtStr != null && ttlSeconds != null && ttlSeconds > 0) {
        final createdAt = DateTime.tryParse(createdAtStr);
        if (createdAt != null) {
          final expiry = createdAt.add(Duration(seconds: ttlSeconds));
          if (DateTime.now().isAfter(expiry)) {
            // Expired, invalidate
            _cacheBox!.delete(key);
            return null;
          }
        }
      }

      return entry['data'];
    } catch (e) {
      debugPrint('Cache read/decode error: $e');
      _cacheBox!.delete(key);
      return null;
    }
  }

  Future<void> delete(String key) async {
    if (!_isInitialized || _cacheBox == null) return;
    try {
      await _cacheBox!.delete(key);
    } catch (e) {
      debugPrint('Cache delete error: $e');
    }
  }

  Future<void> clear() async {
    if (!_isInitialized || _cacheBox == null) return;
    try {
      await _cacheBox!.clear();
    } catch (e) {
      debugPrint('Cache clear error: $e');
    }
  }
}
