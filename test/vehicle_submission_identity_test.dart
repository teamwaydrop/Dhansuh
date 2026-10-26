import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:waydrop/features/rider/vehicles/vehicle_submission.dart';

void main() {
  for (final stage in ['owner', 'validate', 'compress', 'upload', 'insert']) {
    test('retirement at $stage fences every following stage', () async {
      final paused = Completer<void>();
      final reached = Completer<void>();
      var current = true;
      var writes = 0;
      var uploads = 0;
      Future<void> wait(String name) async {
        if (stage == name) { if (!reached.isCompleted) reached.complete(); await paused.future; }
      }
      final pipeline = VehicleSubmission(
        ownsRider: (account, rider) async { await wait('owner'); return true; },
        validate: (_) => wait('validate'),
        compress: (_) async { await wait('compress'); return File('synthetic'); },
        upload: (_, name, folder, current) async { uploads++; await wait('upload'); return '$folder/$name.jpg'; },
        insert: (row) async { writes++; await wait('insert'); },
      );
      final run = pipeline.run(account: 'A', rider: 'RA', type: 'bike', number: 'SYNTHETIC',
        files: List.generate(3, (_) => XFile('synthetic')), folder: 'A/vehicles/synthetic', isCurrent: () => current);
      final rejected = expectLater(run, throwsA(isA<RetiredVehicleSubmission>()));
      await reached.future;
      current = false; paused.complete(); await rejected;
      expect(writes, stage == 'insert' ? 1 : 0);
      expect(uploads, ['upload', 'insert'].contains(stage) ? 3 : 0);
    });
  }
  test('unverified rider ownership prevents validation, uploads and insert', () async {
    var steps = 0;
    final pipeline = VehicleSubmission(
      ownsRider: (account, rider) async => false,
      validate: (_) async { steps++; }, compress: (_) async { steps++; return File('synthetic'); },
      upload: (_, name, folder, current) async { steps++; return 'synthetic'; },
      insert: (_) async { steps++; });
    await expectLater(pipeline.run(account: 'A', rider: 'RA', type: 'bike', number: 'SYNTHETIC',
      files: List.generate(3, (_) => XFile('synthetic')), folder: 'A/vehicles/synthetic', isCurrent: () => true), throwsStateError);
    expect(steps, 0);
  });
  test('partial upload failure never submits or deletes; payload uses captured bare paths', () async {
    var writes = 0;
    var fail = true;
    Map<String, dynamic>? payload;
    final pipeline = VehicleSubmission(
      ownsRider: (account, rider) async => true, validate: (_) async {}, compress: (_) async => File('synthetic'),
      upload: (_, name, folder, current) async {
        if (fail && name == 'rc_back') throw StateError('synthetic upload failure');
        return '$folder/$name.jpg';
      }, insert: (row) async { writes++; payload = row; });
    Future<void> run() => pipeline.run(account: 'A', rider: 'RA', type: 'bike', number: 'SYNTHETIC',
      files: List.generate(3, (_) => XFile('synthetic')), folder: 'A/vehicles/synthetic', isCurrent: () => true);
    await expectLater(run(), throwsStateError); expect(writes, 0);
    fail = false; await run(); expect(writes, 1);
    expect(payload, {'rider_id': 'RA', 'vehicle_type': 'bike', 'vehicle_number': 'SYNTHETIC',
      'rc_front_image': 'A/vehicles/synthetic/rc_front.jpg', 'rc_back_image': 'A/vehicles/synthetic/rc_back.jpg',
      'vehicle_image': 'A/vehicles/synthetic/vehicle_image.jpg'});
  });
  test('uncertain insert outcome propagates without deleting uploaded paths', () async {
    var committed = false;
    final pipeline = VehicleSubmission(
      ownsRider: (account, rider) async => true, validate: (_) async {}, compress: (_) async => File('synthetic'),
      upload: (_, name, folder, current) async => '$folder/$name.jpg',
      insert: (_) async { committed = true; throw StateError('synthetic lost acknowledgement'); });
    await expectLater(pipeline.run(account: 'A', rider: 'RA', type: 'bike', number: 'SYNTHETIC',
      files: List.generate(3, (_) => XFile('synthetic')), folder: 'A/vehicles/synthetic', isCurrent: () => true), throwsA(isA<VehicleSubmissionWriteUnconfirmed>()));
    expect(committed, isTrue); // No deletion API is exposed to this pipeline.
  });
}
