import 'dart:io';
import 'dart:math';
import 'package:shared_preferences/shared_preferences.dart';

class DeviceInfoHelper {
  static const String _keyDeviceId = 'waydrop_device_uuid';

  /// Returns a persistent, unique device fingerprint (true UUID) cached in SharedPreferences.
  static Future<String> getDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    String? deviceId = prefs.getString(_keyDeviceId);
    if (deviceId == null) {
      deviceId = _generateUuid();
      await prefs.setString(_keyDeviceId, deviceId);
    }
    return deviceId;
  }

  /// Generates a compliant random version 4 UUID.
  static String _generateUuid() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    
    // Set version (4) and variant (8, 9, a, or b)
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20, 32)}';
  }

  /// Retrives a package map of device metadata.
  static Future<Map<String, String>> getDeviceMetadata() async {
    final deviceId = await getDeviceId();
    String model = 'Generic Mobile';
    String brand = 'Generic';
    
    if (Platform.isAndroid) {
      model = 'Android Device';
      brand = 'Google/Android';
    } else if (Platform.isIOS) {
      model = 'iOS Device';
      brand = 'Apple';
    } else if (Platform.isMacOS) {
      model = 'Mac';
      brand = 'Apple';
    } else if (Platform.isWindows) {
      model = 'PC';
      brand = 'Windows';
    } else if (Platform.isLinux) {
      model = 'PC';
      brand = 'Linux';
    }

    return {
      'device_id': deviceId,
      'device_model': model,
      'device_brand': brand,
      'os_version': Platform.operatingSystemVersion,
      'app_version': '1.0.0',
    };
  }
}
