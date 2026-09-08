// Regression guard for PHASE 2, Issue 6:
//  A) Chat before Traveller acceptance must show a normal info message, never a red error.
//  B) Traveller-rates-Passenger must show passenger-appropriate suggestion chips, not
//     vehicle/driving categories.
//
// ISSUE 6A ROOT CAUSE: order_chat_screen.dart already disabled the TextField (decorative) while
// intercity_requests.status == 'request_sent', but _sendMessage() itself had no such guard --
// any send attempted while _intercityRequest hadn't loaded yet (e.g. this screen opened from a
// notification tap without riderId) could still be tried, and its failure surfaced via a raw red
// ScaffoldMessenger SnackBar dumping the exception text verbatim. Fix: guard _sendMessage()
// itself and show an info-style message via the existing showAppSnackBar helper instead.
//
// ISSUE 6B ROOT CAUSE: rider_rating_screen.dart's _positiveTags/_negativeTags were two plain
// hardcoded maps shared unconditionally by every rating direction -- "Clean Vehicle"/"Safe
// Driving" make no sense when a Traveller rates a Passenger (widget.ratedByRider == true). Fix:
// convert to getters branching on ratedByRider; the false (passenger-rates-driver) direction --
// every existing local + intercity call site -- is byte-for-byte unchanged.
//
// Structural guard (reads the real source), matching the pattern used throughout this suite.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  group('order_chat_screen.dart -- pre-acceptance send is blocked with an info message, not a '
      'red error', () {
    final source = _read('lib/modules/chat/screens/order_chat_screen.dart');
    final sendMethodStart = source.indexOf('Future<void> _sendMessage() async {');
    final sendMethodGuardEnd = source.indexOf(
      'final text = _messageController.text.trim();',
      sendMethodStart,
    );
    final sendMethodGuardArea = source.substring(sendMethodStart, sendMethodGuardEnd);

    test('_sendMessage() guards on intercity_requests.status == request_sent before attempting '
        'the insert', () {
      expect(
        sendMethodGuardArea.contains("_intercityRequest!['status'] == 'request_sent'"),
        isTrue,
      );
    });

    test('the guard uses the shared info-style snackbar helper, not a raw red SnackBar', () {
      expect(sendMethodGuardArea.contains('showAppSnackBar('), isTrue);
      expect(sendMethodGuardArea.contains('type: SnackBarType.info'), isTrue);
    });

    test('the guard wording is role-aware (traveller vs passenger see different, correct '
        'instructions)', () {
      expect(sendMethodGuardArea.contains("_senderType == 'rider'"), isTrue);
      expect(
        sendMethodGuardArea.contains('Accept the request to start chatting with the passenger.'),
        isTrue,
      );
      expect(
        sendMethodGuardArea.contains('You can chat once the traveller responds to your request.'),
        isTrue,
      );
    });

    test('app_snackbar.dart is imported', () {
      expect(
        source.contains("import 'package:waydrop/shared/widgets/app_snackbar.dart';"),
        isTrue,
      );
    });

    test('the pre-existing red-error path for genuine send failures is untouched (still red, '
        'still shown for real failures -- only the pre-acceptance case is redirected away from it)', () {
      expect(source.contains("'Failed to send message: \$e'"), isTrue);
      expect(source.contains('backgroundColor: Colors.red'), isTrue);
    });
  });

  group('RiderRatingScreen -- role-aware suggestion chips', () {
    final source = _read('lib/features/local_rides/rating/screens/rider_rating_screen.dart');

    test('_positiveTags/_negativeTags are getters branching on widget.ratedByRider (not plain '
        'shared fields)', () {
      expect(source.contains('Map<String, String> get _positiveTags => widget.ratedByRider'), isTrue);
      expect(source.contains('Map<String, String> get _negativeTags => widget.ratedByRider'), isTrue);
    });

    test('passenger-rates-driver direction (ratedByRider == false) keeps the exact original '
        'vehicle/driving categories, unchanged for every existing local + intercity call site', () {
      expect(source.contains("'Clean Vehicle': 'clean_vehicle',"), isTrue);
      expect(source.contains("'Safe Driving': 'safe_driving',"), isTrue);
      expect(source.contains("'Dirty Vehicle': 'dirty_vehicle',"), isTrue);
      expect(source.contains("'Unsafe Driving': 'unsafe_driving',"), isTrue);
    });

    test('traveller-rates-passenger direction (ratedByRider == true) uses passenger-appropriate '
        'categories, never vehicle/driving ones', () {
      expect(source.contains("'Ready at Pickup': 'ready_at_pickup',"), isTrue);
      expect(source.contains("'Easy to Communicate With': 'easy_to_communicate',"), isTrue);
      expect(source.contains("'No-show': 'no_show',"), isTrue);
      expect(source.contains("'Changed Plans Unexpectedly': 'changed_plans',"), isTrue);
    });

    test('every rating direction still ends with an "Other" tag, and tag-mapping/submission logic '
        'is untouched', () {
      expect(
        source.contains(
          'final activeTagMap = _selectedRating >= 4 ? _positiveTags : _negativeTags;',
        ),
        isTrue,
      );
    });
  });
}
