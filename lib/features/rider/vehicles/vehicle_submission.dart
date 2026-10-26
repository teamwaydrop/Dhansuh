import 'dart:io';
import 'package:image_picker/image_picker.dart';

class VehicleSubmissionWriteUnconfirmed implements Exception {
  const VehicleSubmissionWriteUnconfirmed();
}

class RetiredVehicleSubmission implements Exception {
  const RetiredVehicleSubmission();
}

/// Side-effect boundary used by the actual screen. Inputs are captured once;
/// every asynchronous stage and each upload retry must check the owner revision.
class VehicleSubmission {
  const VehicleSubmission({required this.ownsRider, required this.validate,
    required this.compress, required this.upload, required this.insert});
  final Future<bool> Function(String account, String rider) ownsRider;
  final Future<void> Function(XFile file) validate;
  final Future<File> Function(XFile file) compress;
  final Future<String> Function(File file, String name, String folder, bool Function() current) upload;
  final Future<void> Function(Map<String, dynamic> row) insert;

  Future<void> run({required String account, required String rider,
    required String type, required String number, required List<XFile> files,
    required String folder, required bool Function() isCurrent}) async {
    void check() { if (!isCurrent()) throw const RetiredVehicleSubmission(); }
    check();
    final owned = await ownsRider(account, rider);
    check();
    if (!owned) throw StateError('Vehicle owner could not be verified');
    await Future.wait(files.map(validate));
    check();
    final compressed = await Future.wait(files.map(compress));
    check();
    const names = ['rc_front', 'rc_back', 'vehicle_image'];
    final paths = await Future.wait(List.generate(3, (i) =>
        upload(compressed[i], names[i], folder, isCurrent)));
    check();
    // No automatic delete: upsert paths may be shared, and failed acknowledgement
    // does not prove this insert rolled back. Reclamation needs confirmed evidence.
    try {
      await insert({'rider_id': rider, 'vehicle_type': type, 'vehicle_number': number,
        'rc_front_image': paths[0], 'rc_back_image': paths[1], 'vehicle_image': paths[2]});
    } catch (_) {
      throw const VehicleSubmissionWriteUnconfirmed();
    }
    check();
  }
}
