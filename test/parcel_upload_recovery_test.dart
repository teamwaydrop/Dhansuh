import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:waydrop/features/local_parcels/services/parcel_upload_service.dart';

class _MemoryPhoto extends Fake implements File {
  final Uint8List bytes;
  _MemoryPhoto(this.bytes);
  @override
  Future<Uint8List> readAsBytes() async => bytes;
}

void main() {
  const uid = '00000000-0000-4000-8000-000000000211';
  late SupabaseClient client;
  late Directory dir;
  late File first;
  late File second;
  final objects = <String, Uint8List>{};
  final writes = <String>[];
  var reads = 0;
  var response = 200;
  var commit = true;
  var readStatus = 0;
  Uint8List? wrongContent;
  Completer<void>? readGate;
  Completer<void>? writeGate;
  late Completer<void> firstReadStarted;
  late Completer<void> firstWriteStarted;
  late Completer<void> secondWriteStarted;
  int? failWriteNumber;
  final upsertHeaders = <String?>[];
  String encode(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');

  setUp(() async {
    objects.clear();
    writes.clear();
    upsertHeaders.clear();
    reads = 0;
    response = 200;
    commit = true;
    readStatus = 0;
    readGate = null;
    writeGate = null;
    wrongContent = null;
    failWriteNumber = null;
    firstReadStarted = Completer<void>();
    firstWriteStarted = Completer<void>();
    secondWriteStarted = Completer<void>();
    dir = await Directory.systemTemp.createTemp('waydrop-synthetic-photo-');
    first = await File(
      '${dir.path}/one.jpg',
    ).writeAsBytes([255, 216, 255, 1, 2, 3]);
    second = await File(
      '${dir.path}/two.jpg',
    ).writeAsBytes([255, 216, 255, 4, 5, 6]);
    client = SupabaseClient(
      'https://example.supabase.co',
      'synthetic-public',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((request) async {
        if (request.url.path.endsWith('/token')) {
          return http.Response(
            jsonEncode({
              'access_token':
                  '${encode({'alg': 'HS256', 'typ': 'JWT'})}.${encode({'sub': uid, 'role': 'authenticated', 'exp': DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000})}.synthetic',
              'refresh_token': 'synthetic',
              'token_type': 'bearer',
              'expires_in': 3600,
              'user': {
                'id': uid,
                'aud': 'authenticated',
                'created_at': '2026-01-01T00:00:00Z',
                'app_metadata': {},
                'user_metadata': {},
              },
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        final path = request.url.path;
        if (!path.contains('/object/parcel_images/')) {
          return http.Response('{}', 200);
        }
        if (request.method == 'GET') {
          reads++;
          if (reads == 1) firstReadStarted.complete();
          await readGate?.future;
          if (readStatus != 0) {
            return http.Response('synthetic read failure', readStatus);
          }
          final content = wrongContent ?? objects[path];
          return content == null
              ? http.Response('Not found', 404)
              : http.Response.bytes(content, 200);
        }
        expect(
          request.method,
          'POST',
          reason: 'Never update/delete uncertain objects',
        );
        writes.add(path);
        if (writes.length == 1) firstWriteStarted.complete();
        if (writes.length == 2) secondWriteStarted.complete();
        upsertHeaders.add(request.headers['x-upsert']);
        await writeGate?.future;
        if (objects.containsKey(path)) {
          return http.Response('already exists', 409);
        }
        final fails = failWriteNumber == writes.length;
        // The pinned SDK sends multipart/form-data even for uploadBinary.
        // Emulate Storage extracting the file part, not the multipart envelope.
        final raw = latin1.decode(request.bodyBytes);
        final header = raw.indexOf('filename=');
        final start = raw.indexOf('\r\n\r\n', header) + 4;
        final boundary = request.headers['content-type']!
            .split('boundary=')
            .last;
        final end = raw.indexOf('\r\n--$boundary', start);
        expect(header, greaterThanOrEqualTo(0));
        expect(end, greaterThan(start));
        if (commit && !fails) {
          objects[path] = Uint8List.fromList(
            latin1.encode(raw.substring(start, end)),
          );
        }
        final status = fails ? 504 : response;
        return http.Response(
          status == 200
              ? jsonEncode({'Key': path})
              : '<html>synthetic gateway failure</html>',
          status,
        );
      }),
    );
    await client.auth.setSession('synthetic');
  });
  tearDown(() async {
    if (readGate != null && !readGate!.isCompleted) readGate!.complete();
    if (writeGate != null && !writeGate!.isCompleted) writeGate!.complete();
    await client.dispose();
    await dir.delete(recursive: true);
  });

  test(
    'healthy upload is immutable and returns its actual stored bytes',
    () async {
      final urls = await ParcelPhotoUploader(client).uploadImages([first]);
      expect(urls.length, 1);
      expect(writes.length, 1);
      expect(reads, 1);
      expect(upsertHeaders.single, 'false');
      expect(objects.values.single, await first.readAsBytes());
      expect(writes.single, contains('/parcels/$uid/'));
      expect(writes.single, isNot(contains('one.jpg')));
    },
  );
  test(
    'proof bytes use immutable order/type/account scope and reconcile replay',
    () async {
      final uploader = ParcelPhotoUploader(client);
      final bytes = await first.readAsBytes();
      final a = await uploader.uploadVerificationBytes(
        bytes,
        orderId: 'order-a',
        photoType: 'pickup',
      );
      final b = await uploader.uploadVerificationBytes(
        bytes,
        orderId: 'order-a',
        photoType: 'pickup',
      );
      expect(a, b);
      expect(writes, hasLength(1));
      expect(upsertHeaders.single, 'false');
      expect(
        writes.single,
        contains('/orders/order-a/verifications/pickup/$uid/'),
      );
      expect(objects.values.single, bytes);
    },
  );
  test('five concurrent proof uploads share one POST', () async {
    final uploader = ParcelPhotoUploader(client);
    final bytes = await first.readAsBytes();
    writeGate = Completer<void>();
    final work = List.generate(
      5,
      (_) => uploader.uploadVerificationBytes(
        bytes,
        orderId: 'order-a',
        photoType: 'pickup',
      ),
    );
    await firstWriteStarted.future;
    writeGate!.complete();
    final urls = await Future.wait(work);
    expect(urls.toSet(), hasLength(1));
    expect(writes, hasLength(1));
  });
  test(
    'proof timeout retains pending upload ownership until raw completion',
    () async {
      final uploader = ParcelPhotoUploader(
        client,
        responseTimeout: const Duration(milliseconds: 20),
      );
      final bytes = await first.readAsBytes();
      writeGate = Completer<void>();
      final firstWork = uploader.uploadVerificationBytes(
        bytes,
        orderId: 'order-a',
        photoType: 'pickup',
      );
      final observed = expectLater(
        firstWork,
        throwsA(isA<ParcelUploadUnconfirmed>()),
      );
      await firstWriteStarted.future;
      await observed;
      final retry = uploader.uploadVerificationBytes(
        bytes,
        orderId: 'order-a',
        photoType: 'pickup',
      );
      writeGate!.complete();
      await retry;
      expect(writes, hasLength(1));
    },
  );
  test('proof scope separates orders and pickup/dropoff', () async {
    final uploader = ParcelPhotoUploader(client);
    final bytes = await first.readAsBytes();
    final urls = await Future.wait([
      uploader.uploadVerificationBytes(
        bytes,
        orderId: 'order-a',
        photoType: 'pickup',
      ),
      uploader.uploadVerificationBytes(
        bytes,
        orderId: 'order-a',
        photoType: 'dropoff',
      ),
      uploader.uploadVerificationBytes(
        bytes,
        orderId: 'order-b',
        photoType: 'pickup',
      ),
    ]);
    expect(urls.toSet(), hasLength(3));
    expect(writes, hasLength(3));
  });
  test('sign-out during proof object lookup prevents later POST', () async {
    final uploader = ParcelPhotoUploader(client);
    readGate = Completer<void>();
    final work = uploader.uploadVerificationBytes(
      await first.readAsBytes(),
      orderId: 'order-a',
      photoType: 'pickup',
    );
    final observed = expectLater(work, throwsA(isA<AuthException>()));
    await firstReadStarted.future;
    await client.auth.signOut(scope: SignOutScope.local);
    readGate!.complete();
    await observed;
    expect(writes, isEmpty);
  });
  test('504 after commit reconciles content without a second write', () async {
    response = 504;
    expect(
      await ParcelPhotoUploader(client).uploadImages([first]),
      hasLength(1),
    );
    expect(writes, hasLength(1));
    expect(reads, 2);
  });
  test(
    '504 before commit stays unconfirmed until explicit same-path retry',
    () async {
      final uploader = ParcelPhotoUploader(client);
      response = 504;
      commit = false;
      await expectLater(
        uploader.uploadImages([first]),
        throwsA(isA<ParcelUploadUnconfirmed>()),
      );
      expect(writes.length, 1);
      response = 200;
      commit = true;
      expect(await uploader.uploadImages([first]), hasLength(1));
      expect(writes.length, 2);
      expect(writes.toSet(), hasLength(1));
    },
  );
  for (final status in [400, 401, 403, 503]) {
    test('lookup $status is not absence and cannot trigger a write', () async {
      readStatus = status;
      await expectLater(
        ParcelPhotoUploader(client).uploadImages([first]),
        throwsA(isA<StorageException>()),
      );
      expect(writes, isEmpty);
    });
  }
  test('five concurrent handlers share one actual GET/POST', () async {
    readGate = Completer<void>();
    final uploader = ParcelPhotoUploader(client);
    final photo = _MemoryPhoto(await first.readAsBytes());
    final work = List.generate(5, (_) => uploader.uploadImages([photo]));
    await firstReadStarted.future.timeout(const Duration(seconds: 5));
    expect(reads, 1);
    readGate!.complete();
    expect((await Future.wait(work)).expand((v) => v).toSet(), hasLength(1));
    expect(writes.length, 1);
  });
  test(
    'process recreation and renamed copy reuse verified immutable content',
    () async {
      await ParcelPhotoUploader(client).uploadImages([first]);
      final copy = await first.copy('${dir.path}/renamed.jpg');
      expect(
        await ParcelPhotoUploader(client).uploadImages([copy]),
        hasLength(1),
      );
      expect(writes.length, 1);
    },
  );
  test('existing different bytes are never overwritten or accepted', () async {
    wrongContent = Uint8List.fromList([9, 8, 7]);
    await expectLater(
      ParcelPhotoUploader(client).uploadImages([first]),
      throwsA(isA<ParcelUploadUnconfirmed>()),
    );
    expect(writes, isEmpty);
  });
  test('409 concurrent commit is reconciled with exact content', () async {
    response = 409;
    expect(
      await ParcelPhotoUploader(client).uploadImages([first]),
      hasLength(1),
    );
    expect(writes.length, 1);
    expect(reads, 2);
  });
  test(
    'independent upload owners racing for one key never overwrite content',
    () async {
      writeGate = Completer<void>();
      final one = ParcelPhotoUploader(client).uploadImages([first]);
      final two = ParcelPhotoUploader(client).uploadImages([first]);
      await secondWriteStarted.future.timeout(const Duration(seconds: 5));
      expect(writes.length, 2);
      expect(writes.toSet(), hasLength(1));
      writeGate!.complete();
      final urls = await Future.wait([one, two]);
      expect(urls[0], urls[1]);
      expect(objects, hasLength(1));
      expect(objects.values.single, await first.readAsBytes());
      expect(upsertHeaders.every((value) => value == 'false'), isTrue);
    },
  );
  test(
    'partial batch retry preserves completed object and selection ordering',
    () async {
      failWriteNumber = 2;
      final uploader = ParcelPhotoUploader(client);
      await expectLater(
        uploader.uploadImages([first, second]),
        throwsA(isA<ParcelUploadUnconfirmed>()),
      );
      expect(writes.length, 2);
      expect(objects.length, 1);
      failWriteNumber = null;
      final urls = await uploader.uploadImages([first, second]);
      expect(urls.length, 2);
      expect(writes.length, 3);
      expect(objects.length, 2);
      expect(urls[0], endsWith(writes[0].split('/parcel_images/').last));
      expect(writes[1], writes[2]);
    },
  );
  test(
    'UI timeouts retain raw write ownership and late success is discoverable',
    () async {
      writeGate = Completer<void>();
      final uploader = ParcelPhotoUploader(
        client,
        responseTimeout: const Duration(milliseconds: 20),
      );
      await expectLater(
        uploader.uploadImages([first]),
        throwsA(isA<ParcelUploadUnconfirmed>()),
      );
      await expectLater(
        uploader.uploadImages([first]),
        throwsA(isA<ParcelUploadUnconfirmed>()),
      );
      expect(writes.length, 1);
      writeGate!.complete();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(await uploader.uploadImages([first]), hasLength(1));
      expect(writes.length, 1);
    },
  );
  test('sign-out while lookup is pending prevents a later POST', () async {
    readGate = Completer<void>();
    final work = ParcelPhotoUploader(client).uploadImages([first]);
    final observed = expectLater(work, throwsA(isA<AuthException>()));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await client.auth.signOut(scope: SignOutScope.local);
    readGate!.complete();
    await observed;
    expect(writes, isEmpty);
  });
  test(
    'upload authorization failure is not converted to recovery success',
    () async {
      response = 403;
      commit = false;
      await expectLater(
        ParcelPhotoUploader(client).uploadImages([first]),
        throwsA(isA<StorageException>()),
      );
      expect(writes.length, 1);
      expect(reads, 1);
    },
  );
}
