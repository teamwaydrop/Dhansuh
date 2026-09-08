// Regression guard for PHASE 13A, Condition 4 (KYC/vehicle image storage against a private bucket).
//
// ROOT CAUSE: the rider_kyc storage bucket was made private in
// 20260731000004_rider_kyc_bucket_private.sql. create-rider-kyc/index.ts (the person-KYC path) was
// updated at the same time to store bare storage paths instead of public URLs (its own comment:
// "Storing the bare path decouples the DB row from the bucket's public/private state entirely --
// every read site resolves a fresh signed URL on demand"). add_vehicle_screen.dart (the
// vehicle-specific add flow, rider_vehicles table) was never updated to match -- it still called
// getPublicUrl() and stored the resulting (dead, since the bucket is private) URL in
// rider_vehicles.rc_front_image / rc_back_image / vehicle_image.
//
// NOT CURRENTLY VISIBLE AS A BROKEN IMAGE: no screen in lib/ reads rc_front_image, rc_back_image,
// or vehicle_image from rider_vehicles today (my_vehicles_screen.dart only selects vehicle_type,
// vehicle_number, status, rejection_reason) -- so nothing currently attempts to render the dead
// URL. This is a latent data-correctness bug, not a currently-reproduced UI failure.
//
// FIX: store the bare storage path (matching create-rider-kyc/index.ts's already-approved
// pattern), not a public URL. No storage policy, RLS, upload/compression, or KYC-review workflow
// change.
//
// Structural guard (reads the real source as text), consistent with this repo's other regression
// tests.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final addVehicleScreen =
      _read('lib/features/rider/vehicles/screens/add_vehicle_screen.dart');

  group('add_vehicle_screen.dart stores bare storage paths for rider_vehicles image columns', () {
    test('no longer calls .getPublicUrl() against the private rider_kyc bucket', () {
      // Checks for an actual method call (leading dot), not the explanatory comment mentioning
      // getPublicUrl() by name.
      expect(addVehicleScreen.contains('.getPublicUrl('), isFalse);
    });

    test('inserts the bare uploaded paths directly for rc_front_image/rc_back_image/vehicle_image', () {
      final start = addVehicleScreen.indexOf("await supabase.from('rider_vehicles').insert({");
      final end = addVehicleScreen.indexOf('});', start);
      final body = addVehicleScreen.substring(start, end);
      expect(body.contains("'rc_front_image': paths[0],"), isTrue);
      expect(body.contains("'rc_back_image': paths[1],"), isTrue);
      expect(body.contains("'vehicle_image': paths[2],"), isTrue);
    });

    test('upload path is still scoped under the uploading rider\'s own auth uid folder (storage '
        'RLS ownership unchanged)', () {
      expect(
        addVehicleScreen.contains("final folder = '\${user.id}/vehicles/\${DateTime.now().millisecondsSinceEpoch}';"),
        isTrue,
      );
    });

    test('upload/compress/validate pipeline and rollback-on-failure are untouched', () {
      expect(addVehicleScreen.contains('RiderKycUploadService.validateImage'), isTrue);
      expect(addVehicleScreen.contains('RiderKycUploadService.compressImageSmart'), isTrue);
      expect(addVehicleScreen.contains('RiderKycUploadService.uploadCompressedFile'), isTrue);
      expect(addVehicleScreen.contains('RiderKycUploadService.rollbackFiles(uploadedPaths)'), isTrue);
    });
  });

  group('my_vehicles_screen.dart does not currently render these columns (documents why this bug '
      'was latent, not user-visible)', () {
    final myVehiclesScreen = _read('lib/features/rider/vehicles/screens/my_vehicles_screen.dart');

    test('only selects vehicle_type/vehicle_number/status/rejection_reason -- no image columns', () {
      expect(
        myVehiclesScreen.contains("select('vehicle_type, vehicle_number, status, rejection_reason')"),
        isTrue,
      );
      expect(myVehiclesScreen.contains('rc_front_image'), isFalse);
      expect(myVehiclesScreen.contains('rc_back_image'), isFalse);
    });
  });
}
