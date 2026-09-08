// Structural regression guard for "app restarts after the rider selfie is captured" (KYC step 5).
//
// ROOT CAUSE (confirmed by code inspection, not reproduction -- this cannot be exercised inside
// `flutter test`, see the pattern already used by nearby_partner_count_regression_test.dart):
// pickSelfieImage() awaits `picker.pickImage(source: ImageSource.camera, ...)`, which hands control
// to Android's native Camera activity. While that activity is in the foreground, WayDrop's own
// process is backgrounded and is a common target for Android's low-memory killer, especially on
// mid/low-RAM devices -- a camera activity is itself memory-heavy, and the OS reclaims backgrounded
// app processes first under pressure. If the process is killed while the user is still in the
// Camera app, `picker.pickImage()`'s Future never resolves (the isolate awaiting it no longer
// exists). When the user then presses OK, Android has nothing to deliver the captured photo to and
// must cold-start a fresh WayDrop process -- visible to the user as the splash screen appearing,
// indistinguishable from "the app restarted". The existing SharedPreferences-backed KYC state
// restore (_loadKycState) correctly repopulates every text field and the current step, which is why
// "previously entered KYC details are restored" -- but the in-flight selfie pick was never recorded
// anywhere (that only happens once _uploadDoc runs, which never got a chance to start), so it is
// silently lost and the user must redo the capture.
//
// FIX: `image_picker` exposes exactly this recovery path on Android --
// `ImagePicker.retrieveLostData()` returns the file from the most recent pick that was in flight
// when the process died, once, on the next cold start. It does not identify which on-screen picker
// call it came from, so a small SharedPreferences marker (set immediately before the camera
// launches, cleared the instant pickImage() returns by any path) is what lets the recovery method
// know a recovered file belongs to the selfie step specifically. On recovery, the file is routed
// through the exact same _uploadDoc(KycDocSlot.riderSelfie, file) call the normal capture path
// already uses -- no new upload/business logic, no change to validation, storage structure, or the
// KYC flow itself.
//
// This does not run the app or call Supabase (see the pattern already used by
// travel_plan_mode_switch_regression_test.dart) -- it inspects the actual source file.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final riderKycScreen = _read('lib/features/rider/onboarding/screens/rider_kyc_screen.dart');

  group('A pending-pick marker brackets the vulnerable picker.pickImage(camera) await', () {
    test('the marker is set to true immediately before pickImage(camera) is called', () {
      final pickStart = riderKycScreen.indexOf('Future<void> pickSelfieImage() async {');
      final pickImageCall = riderKycScreen.indexOf(
        "picker.pickImage(source: ImageSource.camera",
        pickStart,
      );
      expect(pickStart, greaterThan(-1));
      expect(pickImageCall, greaterThan(pickStart));
      final section = riderKycScreen.substring(pickStart, pickImageCall);
      expect(section.contains("prefs.setBool(_selfiePickPendingPrefsKey, true)"), isTrue);
    });

    test('the marker is cleared in a finally block, guaranteed to run whether the pick '
        'succeeds, is cancelled, or throws', () {
      final pickStart = riderKycScreen.indexOf('Future<void> pickSelfieImage() async {');
      final nextMethod = riderKycScreen.indexOf(
        'Future<void> _recoverLostSelfieCapture()',
      );
      expect(pickStart, greaterThan(-1));
      expect(nextMethod, greaterThan(pickStart));
      final section = riderKycScreen.substring(pickStart, nextMethod);
      final finallyIndex = section.indexOf('} finally {');
      expect(finallyIndex, greaterThan(-1));
      final finallySection = section.substring(finallyIndex);
      expect(finallySection.contains('prefs.setBool(_selfiePickPendingPrefsKey, false)'), isTrue);
    });
  });

  group('Recovery on the next cold start', () {
    test('_recoverLostSelfieCapture is defined and called during KYC state restore, after the '
        'upload session is initialized (so _uploadDoc has somewhere to write the recovered file)', () {
      expect(riderKycScreen.contains('Future<void> _recoverLostSelfieCapture() async {'), isTrue);
      final initCall = riderKycScreen.indexOf('await _initializeUploadSession();');
      final recoverCall = riderKycScreen.indexOf('await _recoverLostSelfieCapture();');
      expect(initCall, greaterThan(-1));
      expect(recoverCall, greaterThan(initCall));
    });

    test('recovery only acts when the pending marker says a selfie pick was actually in flight', () {
      final start = riderKycScreen.indexOf('Future<void> _recoverLostSelfieCapture() async {');
      final end = riderKycScreen.indexOf('} catch (e) {', start);
      expect(start, greaterThan(-1));
      expect(end, greaterThan(start));
      final section = riderKycScreen.substring(start, end);
      expect(section.contains('prefs.getBool(_selfiePickPendingPrefsKey)'), isTrue);
      expect(section.contains('if (!wasPending) return;'), isTrue);
    });

    test('recovery clears the marker before doing anything else, so a later unrelated cold '
        'start can never misattribute a lost pick to the selfie step', () {
      final start = riderKycScreen.indexOf('Future<void> _recoverLostSelfieCapture() async {');
      final retrieveCall = riderKycScreen.indexOf('picker.retrieveLostData()', start);
      expect(start, greaterThan(-1));
      expect(retrieveCall, greaterThan(start));
      final section = riderKycScreen.substring(start, retrieveCall);
      expect(section.contains('prefs.setBool(_selfiePickPendingPrefsKey, false)'), isTrue);
    });

    test('a recovered file is routed through the SAME upload call the normal capture path uses '
        '-- no separate/duplicate upload logic', () {
      final start = riderKycScreen.indexOf('Future<void> _recoverLostSelfieCapture() async {');
      final end = riderKycScreen.indexOf('} catch (e) {', start);
      expect(start, greaterThan(-1));
      final section = riderKycScreen.substring(start, end);
      expect(section.contains('setState(() => riderSelfie = recovered)'), isTrue);
      expect(section.contains('_uploadDoc(KycDocSlot.riderSelfie, recovered)'), isTrue);
    });

    test('exactly two call sites invoke _uploadDoc for the riderSelfie slot -- the happy path '
        'and the recovery path, and nothing else', () {
      final matches = '_uploadDoc(KycDocSlot.riderSelfie,'.allMatches(riderKycScreen).length;
      expect(matches, 2);
    });
  });
}
