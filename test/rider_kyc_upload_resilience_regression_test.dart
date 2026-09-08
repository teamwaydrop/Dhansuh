// Structural regression guard for a 2026-08-03 production audit of the incremental rider-KYC
// upload architecture (each document uploads to storage the instant it's picked, not batched at
// Final Submit -- see rider_kyc_screen.dart / kyc_upload_state.dart / rider_kyc_upload_service.dart).
//
// Root causes fixed by this audit:
//
// 1. cleanup-abandoned-kyc-uploads gated deletion of an ENTIRE session folder on the OLDEST
//    object's age. A rider who resumes an in-progress, still-unclaimed session after more than 7
//    calendar days (a scenario the client's resume flow explicitly supports indefinitely) would
//    have every file in that folder deleted by the next daily cron run -- including documents
//    uploaded minutes earlier -- because the session's first-ever file crossed the grace period.
//    Fixed to gate on the NEWEST object's age instead, so a folder is only reaped once nothing has
//    been added to it for a full grace period.
//
// 2. cleanup-abandoned-kyc-uploads had no caller authentication. Supabase's platform verify_jwt
//    gate accepts any authenticated end user's own session JWT, not just the service-role key, so
//    without an explicit check any signed-in rider/passenger could invoke this privileged,
//    bucket-wide sweep directly. Fixed to require the service-role key, matching the
//    isTrustedServerCaller pattern already used by send-push-notification/index.ts.
//
// 3. cleanup-abandoned-kyc-uploads listed the bucket root (and each user's session folders) with a
//    single un-paginated `limit: 1000` call, silently truncating past the first page -- guaranteed
//    well before 100,000 users -- and never scanning or cleaning folders beyond it. Fixed via a
//    paginating helper.
//
// 4. RiderKycUploadService.listSessionFolder collapsed "the listing call itself failed" (e.g. no
//    network exactly when the app resumes) into the same empty Set<String> as "the folder is
//    confirmed empty". The caller then treated an inconclusive check as proof of absence and
//    demoted every already-durably-uploaded document back to failed, forcing a pointless re-upload
//    purely because resume happened to run while offline. Fixed by returning null (distinct from
//    an empty set) on failure, and by only demoting an 'uploaded' slot when the listing positively
//    confirms the file is gone.
//
// 5. (2026-08-03 follow-up) The same-slot race was only mitigated above, not eliminated: a stale
//    (superseded) upload and a fresh re-pick of the same slot both wrote to the exact same storage
//    path (upsert:true), so whichever's write landed on the server LAST won, regardless of which
//    pick was actually current -- discarding the stale call's result on the Dart side never
//    stopped its network write from reaching storage. Fixed by suffixing every upload's path with
//    its own pickGeneration, making two different generations of the same slot write to distinct
//    objects that can never collide. This in turn requires two follow-on changes: resume
//    reconciliation must check presence of the GENERATION-suffixed name, not a fixed one, and the
//    cleanup job must prune now-orphaned older-generation objects that a claimed (submitted)
//    folder can accumulate, since it never deletes a claimed folder wholesale.
//
// Like the other *_regression_test.dart files in this repo, this inspects the fixed source files
// as text rather than driving real storage/network/cron, since exercising an actual multi-day
// abandoned session, an offline resume, a concurrent same-slot upload race, or an unauthenticated
// cron invocation isn't practical inside `flutter test`.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final cleanupFn = _read('supabase/functions/cleanup-abandoned-kyc-uploads/index.ts');
  final uploadService = _read('lib/features/rider/onboarding/services/rider_kyc_upload_service.dart');
  final kycScreen = _read('lib/features/rider/onboarding/screens/rider_kyc_screen.dart');

  group('cleanup-abandoned-kyc-uploads never deletes a still-active session', () {
    test('the grace-period check uses the newest object, not the oldest', () {
      expect(cleanupFn.contains('newestMs'), isTrue);
      expect(
        cleanupFn.contains('const oldestMs ='),
        isFalse,
        reason: 'gating whole-folder deletion on the OLDEST object deletes freshly-added files '
            'the moment the session\'s very first upload crosses the grace period',
      );
    });

    test('newestMs is computed via a max reduction, not min', () {
      final idx = cleanupFn.indexOf('const newestMs =');
      expect(idx, greaterThan(-1));
      final snippet = cleanupFn.substring(idx, idx + 200);
      expect(snippet.contains('t > max'), isTrue);
    });
  });

  group('cleanup-abandoned-kyc-uploads requires the service-role key', () {
    test('the function rejects any caller that is not the service role', () {
      expect(cleanupFn.contains('SUPABASE_SERVICE_ROLE_KEY'), isTrue);
      expect(cleanupFn.contains('status: 403'), isTrue);
    });

    test('the auth check runs before any storage listing', () {
      final authCheckIndex = cleanupFn.indexOf('SUPABASE_SERVICE_ROLE_KEY');
      final firstListCall = cleanupFn.indexOf('listAllPages(');
      expect(authCheckIndex, greaterThan(-1));
      expect(firstListCall, greaterThan(-1));
      expect(authCheckIndex < firstListCall, isTrue);
    });
  });

  group('cleanup-abandoned-kyc-uploads scans the full bucket, not just the first page', () {
    test('a paginating helper is used for both the bucket-root and per-user listings', () {
      expect(cleanupFn.contains('listAllPages'), isTrue);
      expect(cleanupFn.contains('offset'), isTrue);
      expect(
        cleanupFn.contains('.list("", { limit: 1000 })'),
        isFalse,
        reason: 'an un-paginated single-page listing silently stops scanning past 1000 top-level '
            'user folders, well below a 100,000-user target',
      );
    });
  });

  group('resume never discards an already-uploaded document because of a transient listing failure', () {
    test('listSessionFolder returns a nullable set, distinguishing "unknown" from "confirmed empty"', () {
      expect(uploadService.contains('Future<Set<String>?> listSessionFolder'), isTrue);
    });

    test('an uploaded slot is only demoted to failed when the listing positively confirms absence', () {
      final idx = kycScreen.indexOf("doc.status == KycUploadStatus.uploaded &&");
      expect(idx, greaterThan(-1));
      final snippet = kycScreen.substring(idx, idx + 200);
      expect(
        snippet.contains('present != null'),
        isTrue,
        reason: 'a null (failed/unknown) listing result must never be treated as proof the file is gone',
      );
    });
  });

  group('a superseded upload cannot keep retrying past the point it was superseded', () {
    test('isStale() is re-checked before every retry attempt, not just once before the loop', () {
      final whileIndex = uploadService.indexOf('while (true) {');
      final attemptIncrementIndex = uploadService.indexOf('attempt++;', whileIndex);
      final uploadCallIndex = uploadService.indexOf('.upload(path, compressed', attemptIncrementIndex);
      final staleCheckBetween = uploadService.substring(attemptIncrementIndex, uploadCallIndex);
      expect(
        staleCheckBetween.contains('if (isStale()) throw const StaleUploadException();'),
        isTrue,
        reason: 'without this, a superseded (stale) upload keeps retrying through its full backoff '
            'budget and remains eligible to overwrite a newer pick\'s upload to the same storage path',
      );
    });
  });

  group('two generations of the same document slot can never collide in storage', () {
    test('the upload path is suffixed with the pickGeneration, not a fixed per-slot name', () {
      expect(
        uploadService.contains(
          r"final path = '$sessionFolder/${slot.storageFileName}_g$pickGeneration.jpg';",
        ),
        isTrue,
        reason: 'a fixed path shared by every generation of a slot is what let a stale (superseded) '
            'upload\'s write silently overwrite a newer pick\'s upload if it landed on the server last',
      );
    });

    test(
      'resume reconciliation checks presence of the generation-suffixed name, not a fixed one',
      () {
        expect(
          kycScreen.contains(
            r"final expectedName = '${slot.storageFileName}_g${doc.pickGeneration}.jpg';",
          ),
          isTrue,
        );
        expect(
          kycScreen.contains("present?.contains('\${slot.storageFileName}.jpg')"),
          isFalse,
          reason: 'checking a fixed filename can no longer tell two generations of the same slot apart',
        );
      },
    );
  });

  group('cleanup-abandoned-kyc-uploads prunes obsolete generation objects from a claimed folder '
      'without ever deleting the folder wholesale', () {
    test('a claimed folder is never removed via the whole-folder remove() call', () {
      final claimedIdx = cleanupFn.indexOf('if (claimed) {');
      expect(claimedIdx, greaterThan(-1));
      final unclaimedSectionIdx = cleanupFn.indexOf('still within the grace period', claimedIdx);
      final claimedBranch = cleanupFn.substring(claimedIdx, unclaimedSectionIdx);
      expect(
        claimedBranch.contains('continue;'),
        isTrue,
        reason: 'the claimed branch must always continue past the whole-folder deletion below it',
      );
    });

    test('obsolete-object detection checks every image column, not just rider_image', () {
      expect(cleanupFn.contains('IMAGE_FIELDS'), isTrue);
      expect(cleanupFn.contains('"aadhaar_front_image"'), isTrue);
      expect(cleanupFn.contains('"VECHILE_RC_back_image"'), isTrue);
      expect(
        cleanupFn.contains('.select("rider_image")'),
        isFalse,
        reason: 'checking only rider_image would treat every other slot\'s obsolete objects as '
            'unreferenced-and-safe-to-delete even when they are actually still the active document '
            '-- or vice versa, never pruning a truly obsolete object because an unrelated field matched',
      );
    });

    test('an object referenced by the row is never pruned as obsolete', () {
      final idx = cleanupFn.indexOf('const obsolete = objects.filter');
      expect(idx, greaterThan(-1));
      final snippet = cleanupFn.substring(idx, idx + 300);
      expect(snippet.contains('referencedValues.some((v) => v.includes(objectPath))'), isTrue);
    });
  });
}
