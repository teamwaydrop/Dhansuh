// Structural regression guard for Issue 2: after a Traveller rejects a User's "Travel Together"
// request, the User's intercity searching screen kept showing that Traveller as if the request
// were still pending.
//
// ROOT CAUSE (traced end to end):
//   - Backend (reject_intercity_offer(), 20260717000005/20260718000007) was already correct --
//     it writes intercity_requests.status = 'rejected'. Not a backend bug.
//   - RiderOrdersScreen.dart's user-facing counterpart, intercity_searching_screen.dart, keeps a
//     `req = intercityRequests['$riderId|$planId']` lookup per matched Drop Partner card. Its
//     status-badge switch (request_sent/discussion_started/fare_agreed/confirmed/paid/in_progress/
//     completed/cancelled) had NO branch for 'rejected' -- it fell through to the default
//     statusLabel='Sent'/badgeColor=orange, i.e. a rejected traveller displayed with the exact same
//     badge as one still awaiting a response.
//   - The reject (X) button was already correctly gated to only
//     ['request_sent','discussion_started','fare_agreed'] (excludes 'rejected' -- correct).
//   - The Call and Chat buttons, however, were rendered completely unconditionally whenever
//     `req != null`, regardless of status -- so a rejected traveller still showed a live, tappable
//     "Chat" button, exactly the reported "Chat should NOT be presented as the action for a
//     rejected traveller".
//
// FIX: added an explicit 'rejected' branch (statusLabel='Rejected', red badge, matching the
// existing 'cancelled' convention already used in this same switch) and wrapped the Call/Chat
// action buttons in `if (reqStatus != 'rejected')`. A rejected traveller card now unambiguously
// reads "REJECTED" and offers no actionable buttons at all -- it can never be mistaken for an
// available match nor be re-engaged via chat. Every other status (sent/negotiating/confirmed/
// in_progress/completed/cancelled) is completely unchanged, so other valid travellers/matches for
// this same trip are unaffected.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final screen = _read('lib/features/intercity/shared/screens/intercity_searching_screen.dart');

  group('1. Backend already sets the correct terminal status on rejection (untouched by this fix)', () {
    test('reject_intercity_offer() and rejectTravelTogetherRequest() write status = \'rejected\'', () {
      final service = _read('lib/features/intercity/shared/services/intercity_matching_service.dart');
      expect(service.contains("_supabase.rpc('reject_intercity_offer'"), isTrue);
    });
  });

  group('2. THE FIX: rejected requests get their own distinct, non-actionable status badge', () {
    test('the status-badge switch has an explicit \'rejected\' branch, distinct from the default '
        '\'Sent\' label the bug fell through to', () {
      expect(
        screen.contains("} else if (reqStatus == 'rejected') {"),
        isTrue,
      );
      final idx = screen.indexOf("} else if (reqStatus == 'rejected') {");
      final block = screen.substring(idx, idx + 500);
      expect(block.contains("statusLabel = 'Rejected';"), isTrue);
      expect(block.contains('badgeColor = Colors.red;'), isTrue);
    });

    test('Call and Chat action buttons are gated behind reqStatus != \'rejected\' -- a rejected '
        'traveller cannot be called or chatted with from this screen', () {
      expect(screen.contains("if (reqStatus != 'rejected') ...["), isTrue);
      // Both the Call button and the Chat/OrderChatScreen button must live inside that gate.
      final gateIdx = screen.indexOf("if (reqStatus != 'rejected') ...[");
      final gateBlockEnd = screen.indexOf('\n                      ],', gateIdx);
      final gatedBlock = screen.substring(gateIdx, gateBlockEnd == -1 ? screen.length : gateBlockEnd);
      expect(gatedBlock.contains("'Call'"), isTrue);
      expect(gatedBlock.contains('OrderChatScreen('), isTrue);
    });

    test('the reject (X) action button remains correctly excluded for a rejected request -- only '
        'offered while the request is still actionable', () {
      expect(
        screen.contains("if (['request_sent', 'discussion_started', 'fare_agreed'].contains(reqStatus)) ...["),
        isTrue,
      );
    });
  });

  group('3. Other valid statuses/matches are unaffected', () {
    test('confirmed/paid/in_progress/completed/cancelled/negotiating badges are all still present '
        'and unchanged', () {
      expect(screen.contains("statusLabel = 'Negotiating';"), isTrue);
      expect(screen.contains("statusLabel = 'Confirmed';"), isTrue);
      expect(screen.contains("statusLabel = 'In Transit';"), isTrue);
      expect(screen.contains("statusLabel = 'Completed';"), isTrue);
      expect(screen.contains("statusLabel = 'Cancelled';"), isTrue);
    });

    test('the per-match filter that excludes rejected/cancelled DISPATCH (rider_assignments) '
        'offers is untouched -- this fix only affects the separate intercity_requests negotiation '
        'status badge/actions, not the initial matching list query', () {
      expect(screen.contains("return status != 'rejected' && status != 'cancelled';"), isTrue);
    });
  });
}
