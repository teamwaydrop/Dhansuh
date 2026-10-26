// Structural regression guard for the P0 "Submitting KYC..." infinite-loader
// fix. Root cause: submitKyc() invoked validate-rider-kyc, uploaded 10
// documents, and invoked create-rider-kyc with zero client-side timeouts, so
// a stalled connection left `isSubmitting`/`loading` true forever with no way
// to recover short of force-closing the app. A second, independent bug made
// the very next launch worse: AppStartScreen's catch-all error handling built
// ConnectionErrorScreen without an explicit errorType, which defaults to
// ErrorType.offline ("No Internet Connection"), so ANY exception on startup
// -- not just real connectivity failures -- was misreported to the user as
// their internet being down. A third bug allowed two rider_kyc rows per user
// if a client retry raced the original create-rider-kyc call (no DB-level
// uniqueness on user_id existed before this fix).
//
// A fourth, separately-reported bug: both edge functions trusted
// body.user_id outright (they run with the service_role key, bypassing RLS)
// with no check that it matched the caller's own JWT, so any authenticated
// user could submit/overwrite KYC for someone else's user_id. Both functions
// now extract the bearer token, resolve it via supabase.auth.getUser(), and
// reject any request whose body.user_id doesn't match the authenticated
// user -- the same pattern already used by create-order/index.ts.
//
// Like the other *_regression_test.dart files in this repo, this inspects
// the fixed source files as text rather than driving the real widgets/DB,
// since exercising the actual network hang / process-kill / DB race isn't
// practical inside `flutter test`.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final kycScreen = _read('lib/features/rider/onboarding/screens/rider_kyc_screen.dart');
  final uploadService = _read('lib/features/rider/onboarding/services/rider_kyc_upload_service.dart');
  final appStart = _read('lib/app_start_screen.dart');
  final createKycFn = _read('supabase/functions/create-rider-kyc/index.ts');
  final validateKycFn = _read('supabase/functions/validate-rider-kyc/index.ts');

  group('submitKyc() never hangs forever', () {
    test('validate-rider-kyc invoke has a client-side timeout', () {
      expect(
        kycScreen.contains("supabase.functions.invoke('validate-rider-kyc'"),
        isTrue,
      );
      expect(kycScreen.contains('.timeout(_validateTimeout)'), isTrue);
    });

    test('create-rider-kyc invoke has a client-side timeout', () {
      expect(
        kycScreen.contains("supabase.functions.invoke('create-rider-kyc'"),
        isTrue,
      );
      expect(kycScreen.contains('.timeout(_createTimeout)'), isTrue);
    });

    test('the storage upload call in uploadCompressedFile has a timeout', () {
      final methodStart = uploadService.indexOf('static Future<String> uploadCompressedFile(');
      final methodEnd = uploadService.indexOf('// =====================================================', methodStart + 1);
      final method = uploadService.substring(methodStart, methodEnd);
      expect(method.contains('.upload(path, file, fileOptions: const FileOptions(upsert: true))'), isTrue);
      expect(
        method.contains('.timeout(const Duration(seconds: 30))'),
        isTrue,
        reason: 'a stalled upload connection must fail and retry, not hang indefinitely',
      );
    });

    test('a TimeoutException is caught distinctly and resets the loading state', () {
      expect(kycScreen.contains('on TimeoutException catch (e) {'), isTrue);
      // The timeout branch must always clear isSubmitting/loading so the
      // spinner cannot get stuck, and must never blindly delete just-uploaded
      // files (the request may have actually reached the server).
      final timeoutBranchIndex = kycScreen.indexOf('on TimeoutException catch (e) {');
      final nextCatchIndex = kycScreen.indexOf('} catch (e) {', timeoutBranchIndex);
      final timeoutBranch = kycScreen.substring(timeoutBranchIndex, nextCatchIndex);
      expect(timeoutBranch.contains('isSubmitting = false'), isTrue);
      expect(
        timeoutBranch.contains('rollbackFiles'),
        isFalse,
        reason: 'rolling back on an ambiguous timeout could orphan a KYC row that the server actually committed',
      );
    });
  });

  group('duplicate-submit and duplicate-record protection', () {
    test('submitKyc() guards against re-entrant/duplicate invocation', () {
      expect(kycScreen.contains('if (isSubmitting) return;'), isTrue);
    });

    test('an "already submitted/under review/approved" response routes to the pending screen, not a raw error', () {
      expect(kycScreen.contains('_isAlreadyPendingMessage'), isTrue);
      expect(kycScreen.contains('const RiderKycPendingScreen()'), isTrue);
    });

    test('rider_kyc has a database-level unique constraint on user_id', () {
      final migration = _read('supabase/migrations/20260731000003_prevent_duplicate_rider_kyc_rows.sql');
      expect(
        migration.contains('CREATE UNIQUE INDEX') && migration.contains('"rider_kyc"') && migration.contains('"user_id"'),
        isTrue,
      );
    });

    test('create-rider-kyc treats a unique-violation race as "already submitted", not a raw DB error', () {
      expect(createKycFn.contains('insertError.code === "23505"'), isTrue);
    });
  });

  group('AppStartScreen never mislabels an arbitrary error as "no internet"', () {
    test('the generic catch-all only uses ErrorType.offline for an actual connectivity exception', () {
      expect(appStart.contains('isConnectivityError'), isTrue);
      expect(
        appStart.contains('errorType: isConnectivityError ? ErrorType.offline : ErrorType.general'),
        isTrue,
        reason: 'ConnectionErrorScreen defaults errorType to ErrorType.offline, so every catch block here must '
            'set it explicitly instead of letting an unrelated bug/exception render as "No Internet Connection"',
      );
    });

    test('a TimeoutException on startup is shown as a backend/timeout error, not "No Internet Connection"', () {
      final timeoutBranchIndex = RegExp(r'on TimeoutException catch\s*\([^)]*\)\s*\{').firstMatch(appStart)?.start ?? -1;
      expect(timeoutBranchIndex, greaterThanOrEqualTo(0));
      final branchEnd = appStart.indexOf('} catch (', timeoutBranchIndex);
      expect(branchEnd, greaterThan(timeoutBranchIndex));
      final timeoutBranch = appStart.substring(timeoutBranchIndex, branchEnd);
      expect(timeoutBranch.contains('errorType: ErrorType.backend'), isTrue);
    });

    test('the riders/kyc/orders batch fetch has a timeout, matching the profile query above it', () {
      final batchIndex = appStart.indexOf('final results = await Future.wait([');
      final batchEnd = appStart.indexOf(';', batchIndex);
      final batch = appStart.substring(batchIndex, batchEnd);
      expect(batch.contains('riderFuture'), isTrue);
      expect(batch.contains('kycFuture'), isTrue);
      expect(batch.contains('ordersFuture'), isTrue);
      expect(batch.contains('.timeout('), isTrue);
    });
  });

  group('create-rider-kyc and validate-rider-kyc never trust body.user_id on its own', () {
    for (final entry in {
      'create-rider-kyc': createKycFn,
      'validate-rider-kyc': validateKycFn,
    }.entries) {
      final name = entry.key;
      final source = entry.value;

      test('$name rejects requests with no Authorization header', () {
        expect(source.contains('req.headers.get("Authorization")'), isTrue);
        expect(source.contains('Missing auth token'), isTrue);
      });

      test('$name resolves the caller via supabase.auth.getUser(), not the request body', () {
        expect(source.contains('supabase.auth.getUser(authToken)'), isTrue);
      });

      test('$name rejects a body.user_id that does not match the authenticated user', () {
        expect(source.contains('body.user_id !== authData.user.id'), isTrue);
        final guardStart = source.indexOf('if (!body.user_id || body.user_id !== authData.user.id)');
        expect(guardStart, greaterThanOrEqualTo(0));
        final guard = source.substring(guardStart, source.indexOf('\n    }', guardStart));
        expect(guard.contains('return Response.json('), isTrue);
        expect(guard.contains('success: false'), isTrue);
        expect(guard.contains('status: 403'), isTrue);
      });

      test('$name performs the auth check before any KYC-record read/write', () {
        final authCheckIndex = source.indexOf('body.user_id !== authData.user.id');
        final firstKycTableAccess = source.indexOf('.from("rider_kyc")');
        expect(authCheckIndex, greaterThan(-1));
        expect(firstKycTableAccess, greaterThan(-1));
        expect(
          authCheckIndex < firstKycTableAccess,
          isTrue,
          reason: 'the identity check must happen before touching any rider_kyc row',
        );
      });
    }
  });
}
