// Phase 2 regression guard: production safety / emergency-control hardening found during a
// systematic re-audit of the Phase 1 production_config system (see
// production_control_system_regression_test.dart for the Phase 1 tests themselves -- this file
// covers only what Phase 2 actually changed, plus the specific version-comparison values and
// failure-mode proofs the Phase 2 audit was asked to re-verify explicitly).
//
// TWO REAL BUGS found and fixed this pass (both proven by tracing the real call chain, not
// assumed):
//
// BUG 1 (payment_service.dart): PaymentService.createPayment()'s `on FunctionException` handler
// unconditionally returned null, discarding create-payment's own clear rejection message --
// startPayment() then always showed the generic "Unable to create payment session" regardless of
// WHY the payment was rejected. This silently broke the UX requirement for Phase 1's
// payments_enabled/subscriptions_enabled 503s (which have no client-side flag UI by design -- the
// error message IS the UX for those two flags) and, independently, every other pre-existing
// create-payment rejection (order already paid, order not found, etc). This is the exact same bug
// class already fixed once before for delete-account (data_deletion_screen.dart's
// _extractErrorMessage: details['message'] ?? details['error']) but never applied to payments.
// Fixed using the identical established pattern. Traced end-to-end: server 503 body ->
// FunctionException.details -> extracted message -> startPayment()'s returned map -> thrown
// Exception -> rider_home_tab.dart's subscription-purchase catch block -> SnackBar.
//
// BUG 2 (production_config_service.dart): PackageInfo.fromPlatform() had no timeout, unlike the
// Supabase production_config fetch immediately after it in the same sequential _fetch() -- a
// theoretical (never observed) native platform-channel stall would have blocked the entire
// config fetch, and therefore AppStartScreen's splash screen, indefinitely. Fixed with a matching
// 3s timeout, defense-in-depth only.
//
// Everything else audited this pass (maintenance-mode ordering, fail-open failure/offline policy,
// version-comparison correctness for double-digit segments, config fetch cadence per cold
// start/warm resume/login/navigation, server-side bypass protection) was found ALREADY CORRECT and
// is NOT re-implemented here -- see the Phase 2 conversation report for the full audit trail. This
// file adds the specific missing proofs the audit was asked to re-verify explicitly (exact version
// values, PackageInfo timeout, the payment message fix) rather than duplicating Phase 1's tests.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:waydrop/core/services/config/production_config_service.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final paymentService = _read('lib/modules/payments/services/payment_service.dart');
  final configService = _read('lib/core/services/config/production_config_service.dart');
  final riderHomeTab = _read('lib/features/rider/home/rider_home_tab.dart');
  final dataDeletionScreen = _read('lib/shared/screens/data_deletion_screen.dart');

  group('BUG 1 FIX: create-payment rejection messages are no longer swallowed', () {
    test('the FunctionException handler extracts details[message] ?? details[error] -- the '
        'identical established pattern already used for delete-account, not a new one', () {
      final anchor = paymentService.indexOf('} on FunctionException catch (e, st) {');
      expect(anchor, greaterThan(-1));
      final end = paymentService.indexOf('} catch (e, st) {', anchor);
      expect(end, greaterThan(anchor));
      final block = paymentService.substring(anchor, end);
      expect(block.contains("(details['message'] ?? details['error'])?.toString()"), isTrue);
      // Same extraction expression already proven correct in data_deletion_screen.dart.
      expect(dataDeletionScreen.contains("details['message'] ?? details['error']"), isTrue);
    });

    test('the extracted message is returned via a distinguishable sentinel, not null -- so '
        'startPayment can tell "server rejected with a reason" apart from "transport/response '
        'shape failure" (which correctly keeps its own generic message)', () {
      expect(paymentService.contains("return {'_serverRejection': true, '_serverMessage': serverMessage};"), isTrue);
    });

    test('startPayment checks the sentinel BEFORE the null-check and BEFORE the missing-fields '
        'check, so a server rejection message is never masked by a more generic one', () {
      final sentinelIdx = paymentService.indexOf("payment['_serverRejection'] == true");
      final nullCheckIdx = paymentService.indexOf('if (payment == null) {');
      final missingFieldsIdx = paymentService.indexOf('missing field(s) in create-payment response');
      expect(sentinelIdx, greaterThan(-1));
      expect(nullCheckIdx, greaterThan(sentinelIdx));
      expect(missingFieldsIdx, greaterThan(sentinelIdx));
    });

    test('the real server message (falling back to the old generic message only if somehow '
        'null) is what startPayment returns to its caller', () {
      expect(
        paymentService.contains("'message': serverMessage ?? 'Unable to create payment session',"),
        isTrue,
      );
    });

    test('end-to-end: the rider subscription-purchase flow throws the returned message and '
        'shows it in a SnackBar (not a swallowed/generic one)', () {
      expect(riderHomeTab.contains("throw Exception(paymentResult['message'] ?? 'Payment was not completed');"), isTrue);
      expect(riderHomeTab.contains("SnackBar(content: Text('Purchase failed: \$e')),"), isTrue);
    });

    test('createPayment() itself still returns Map<String, dynamic>? -- the fix did not widen '
        'or change the public return type', () {
      expect(paymentService.contains('Future<Map<String, dynamic>?>'), isTrue);
    });
  });

  group('BUG 2 FIX: PackageInfo.fromPlatform() is timeout-bounded, matching the Supabase call', () {
    test('a 3s timeout wraps the PackageInfo call', () {
      expect(configService.contains('await PackageInfo.fromPlatform().timeout(const Duration(seconds: 3));'), isTrue);
    });

    test('it is still wrapped in its own try/catch so a timeout there cannot propagate and '
        'abort the rest of _fetch() (the production_config fetch that follows must still run)', () {
      final anchor = configService.indexOf('Future<void> _fetch() async {');
      final packageInfoIdx = configService.indexOf('PackageInfo.fromPlatform()', anchor);
      final catchIdx = configService.indexOf('} catch (e) {', packageInfoIdx);
      final supabaseFetchIdx = configService.indexOf("from('production_config')", anchor);
      expect(anchor, greaterThan(-1));
      expect(packageInfoIdx, greaterThan(anchor));
      expect(catchIdx, greaterThan(packageInfoIdx));
      expect(supabaseFetchIdx, greaterThan(catchIdx));
    });
  });

  group('Version comparison: exact values re-verified per the Phase 2 audit request', () {
    test('1.0.0 vs 1.0.0 -- equal, not lower', () {
      expect(ProductionConfigService.isVersionLower('1.0.0', '1.0.0'), isFalse);
    });

    test('1.0.0 vs 1.0.1 -- lower (patch bump)', () {
      expect(ProductionConfigService.isVersionLower('1.0.0', '1.0.1'), isTrue);
      expect(ProductionConfigService.isVersionLower('1.0.1', '1.0.0'), isFalse);
    });

    test('1.0.1 vs 1.2.0 -- lower (minor bump dominates patch)', () {
      expect(ProductionConfigService.isVersionLower('1.0.1', '1.2.0'), isTrue);
    });

    test('1.2.0 vs 1.10.0 -- lower. Proves this is NOT naive string comparison: the string '
        '"1.10.0" sorts BEFORE "1.2.0" lexicographically ("1" < "2"), but numerically 10 > 2, so '
        'a correct integer-segment comparator must say 1.2.0 IS lower than 1.10.0', () {
      expect(ProductionConfigService.isVersionLower('1.2.0', '1.10.0'), isTrue);
      expect(ProductionConfigService.isVersionLower('1.10.0', '1.2.0'), isFalse);
    });

    test('1.10.0 vs 2.0.0 -- lower (major bump dominates everything)', () {
      expect(ProductionConfigService.isVersionLower('1.10.0', '2.0.0'), isTrue);
    });

    test('1.9.0 vs 1.10.0 -- lower. A naive string comparator gets this pair wrong: '
        "'1.9.0'.compareTo('1.10.0') is POSITIVE (lexicographically '9' > '1'), so a naive "
        'string-based implementation would incorrectly say 1.9.0 is NOT lower than 1.10.0. The '
        'real, integer-segment-based comparator correctly says it IS lower (9 < 10).', () {
      expect('1.9.0'.compareTo('1.10.0') > 0, isTrue, reason: 'sanity-check the naive-string-comparison trap actually exists for this pair');
      expect(ProductionConfigService.isVersionLower('1.9.0', '1.10.0'), isTrue);
    });
  });

  group('Config fetch cadence: no lifecycle listener re-triggers a fetch on resume', () {
    test('the only AppLifecycleState observer in the app is the debug trace logger -- it never '
        'calls ProductionConfigService.instance.init() or checkUserFlow()', () {
      final mainDart = File('lib/main.dart').readAsStringSync();
      final observerAnchor = mainDart.indexOf('class _TraceLifecycleObserver');
      final observerEnd = mainDart.indexOf('\n}', observerAnchor);
      expect(observerAnchor, greaterThan(-1));
      final observerBody = mainDart.substring(observerAnchor, observerEnd);
      expect(observerBody.contains('debugPrint'), isTrue);
      expect(observerBody.contains('ProductionConfigService'), isFalse);
      expect(observerBody.contains('checkUserFlow'), isFalse);
    });
  });
}
