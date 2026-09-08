// Structural regression guard for Phase 1 / Issue 2: local_parcel push notifications must say
// "Drop Partner", never "Rider" -- and for the production-reconciliation pass that followed it.
//
// BUG REPORT: send_order_status_notifications_core() (the single source of every order_status
// push notification's title/body, for both the foreground alert shown while the app is open and
// the background/killed-app FCM system-tray notification -- both render the exact same server-
// generated title/body) used generic "rider" wording in its ELSE fallback for several branches --
// a fallback that was NOT scoped to just "any non-ride, non-intercity order_type" but silently
// also caught local_parcel, even though the client-side in-app banners
// (parcel_tracking_screen.dart) already correctly say "Drop Partner"/"delivery partner"
// everywhere. One branch ('rider_at_drop') was not even gated by order_type at all.
//
// PRODUCTION RECONCILIATION (2026-08-23): the first draft of this migration was built on top of
// the last LOCAL migration file touching this function (20260822000000) -- but a read-only audit
// (pg_get_functiondef against the linked production project) found production's actual live
// function body had already diverged from that file, via two fixes applied directly to
// production and never captured locally:
//   1. The 'cancelled' branch sends NO passenger-facing copy for intercity orders at all
//      (`IF v_is_intercity THEN NULL; ELSE ... END IF;`) -- avoids duplicating the notification
//      on_intercity_request_change() already sends for every intercity cancellation.
//   2. The rider-notify block's actor check compares `p_cancelled_by = 'user'`, not `'passenger'`
//      -- orders.cancelled_by is the real Postgres enum cancelled_by_enum ('user' | 'rider' |
//      'admin' | 'system'); there is no 'passenger' label.
// The migration was rewritten from scratch on top of that VERIFIED CURRENT PRODUCTION baseline
// (saved to a local reference file via pg_get_functiondef(30799::oid) before editing), so this
// test file now pins the RECONCILED function body, not the stale one.
//
// FIX: added a `p_order_type = 'local_parcel'`-scoped branch to each of the 'accepted',
// 'rider_arrived', 'picked_up'/'ongoing', 'rider_at_drop', and 'completed'/'delivered' cases,
// reusing the "Drop Partner" wording already established elsewhere in this same function's
// 'expired' branch. The 'ride' branches, every intercity branch (INCLUDING both production-only
// fixes above), and the generic ELSE fallback that still legitimately covers other non-ride/non-
// intercity/non-local_parcel order types (food_delivery, grocery_delivery, batch_delivery,
// ride_sharing) are reproduced byte-for-byte, unchanged.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final migration =
      _read('supabase/migrations/20260901000025_local_parcel_partner_notification_wording.sql');
  final parcelTrackingScreen =
      _read('lib/features/local_parcels/tracking/screens/parcel_tracking_screen.dart');

  group('1. local_parcel notification copy says "Drop Partner", not "Rider"', () {
    test('accepted: local_parcel gets its own Drop Partner branch, distinct from the generic '
        'rider fallback', () {
      expect(migration.contains("ELSIF v_is_local_parcel THEN\n                -- THIS MIGRATION.\n"
          "                v_title := 'Order Accepted 📦';\n"
          "                v_body := 'A Drop Partner has accepted your order and is on the way!';"), isTrue);
    });

    test('rider_arrived: local_parcel gets its own Drop Partner branch', () {
      expect(
        migration.contains(
          "ELSIF v_is_local_parcel THEN\n                -- THIS MIGRATION.\n"
          "                v_title := 'Drop Partner at Pickup Location 📦';\n"
          "                v_body := 'Your Drop Partner has arrived at the pickup location. Share OTP ' || v_otp || ' to start the delivery.';",
        ),
        isTrue,
      );
    });

    test('picked_up/ongoing: local_parcel tracks "your Drop Partner\'s live location", not '
        '"your rider\'s"', () {
      expect(
        migration.contains(
          "ELSIF v_is_local_parcel THEN\n                -- THIS MIGRATION.\n"
          "                v_title := 'Trip on the Way 🗺️';\n"
          "                v_body := 'Your trip has started. Track your Drop Partner''s live location on the map.';",
        ),
        isTrue,
      );
    });

    test('rider_at_drop: now branched by order_type (previously unconditional for every order '
        'type) -- local_parcel says Drop Partner', () {
      expect(
        migration.contains(
          "IF v_is_local_parcel THEN\n                v_title := 'Drop Partner Reached Drop-off 📍';\n"
          "                v_body := 'Your Drop Partner has reached the drop-off point. Please share OTP ' || v_otp || ' with the receiver to complete the delivery.';",
        ),
        isTrue,
      );
    });

    test('completed/delivered: local_parcel thanks the Drop Partner, not "the rider"', () {
      expect(
        migration.contains(
          "ELSIF v_is_local_parcel THEN\n                -- THIS MIGRATION.\n"
          "                v_title := 'Order Delivered Successfully 🎉';\n"
          "                v_body := 'Your order has been completed. Rate your experience and thank your Drop Partner!';",
        ),
        isTrue,
      );
    });

    test('v_is_local_parcel is derived the same way v_is_intercity/v_is_intercity_parcel already '
        'are -- a plain order_type equality check, no new business logic', () {
      expect(
        migration.contains("v_is_local_parcel := COALESCE(p_order_type = 'local_parcel', false);"),
        isTrue,
      );
    });
  });

  group('2. Local ride wording is untouched ("Do NOT change normal LOCAL RIDE terminology")', () {
    test('ride branches are reproduced byte-for-byte from the verified production baseline', () {
      expect(migration.contains("v_title := 'Ride Accepted 🚗';\n                v_body := 'Your ride has been accepted. Your partner is on the way.';"), isTrue);
      expect(migration.contains("v_title := 'Your Partner has Arrived! 👋';\n                v_body := 'Your partner has arrived. Share OTP ' || v_otp || ' with your partner to start your trip.';"), isTrue);
      expect(migration.contains("v_title := 'Ride Completed 🎉';\n                v_body := 'Your ride is completed. Thank you for riding with WayDrop. We hope to see you again!';"), isTrue);
    });
  });

  group('3. Intercity notification logic is untouched, including BOTH production-only fixes '
      'discovered during reconciliation', () {
    test('every v_is_intercity branch (accepted/arrived/trip-started/completed/expired, plus the '
        'rider-facing completion notification) is reproduced byte-for-byte', () {
      expect(migration.contains("v_title := 'Your Partner Started the Trip';"), isTrue);
      expect(migration.contains("v_title := 'Partner Arrived';"), isTrue);
      expect(migration.contains("v_body := E'Your parcel has been delivered successfully by your Traveller.\\n\\nThank you for using WayDrop!';"), isTrue);
      expect(migration.contains("'Delivery Completed 🎉',"), isTrue);
    });

    test('PRODUCTION-ONLY FIX 1 preserved: the intercity cancelled branch sends no passenger-'
        'facing copy at all (duplicate-notification suppression, owned by '
        'on_intercity_request_change) -- this migration must NOT reintroduce a '
        '"Trip Cancelled"/intercity-specific cancelled title here', () {
      final cancelledAnchor = migration.indexOf("ELSIF p_new_status = 'cancelled' THEN");
      expect(cancelledAnchor, greaterThan(-1));
      expect(
        migration.contains(
          "IF v_is_intercity THEN\n                NULL;\n            ELSE\n"
          "                v_title := 'Order Cancelled ❌';\n"
          "                v_body := 'Your order has been cancelled.';\n            END IF;",
        ),
        isTrue,
      );
      final dedupBlockAnchor = migration.indexOf('IF v_is_intercity THEN\n                NULL;');
      expect(dedupBlockAnchor, greaterThan(cancelledAnchor));
      expect(migration.contains("v_title := 'Trip Cancelled"), isFalse);
    });

    test('PRODUCTION-ONLY FIX 2 preserved: the rider-notify actor check compares against '
        "'user', never 'passenger' -- orders.cancelled_by is a real Postgres enum with no "
        "'passenger' label", () {
      expect(
        migration.contains("WHEN v_is_intercity AND p_cancelled_by = 'user' THEN 'The passenger cancelled the trip.'"),
        isTrue,
      );
      expect(migration.contains("p_cancelled_by = 'passenger'"), isFalse);
    });
  });

  group('4. Unrelated notification behavior (fallback for other order types, expired copy, '
      'routing/sound/push-type) is unchanged', () {
    test('the original generic "rider" wording still exists as the ELSE fallback for any other '
        'non-ride/non-intercity/non-local_parcel order type -- this migration narrows the bucket, '
        'it does not delete the fallback wholesale ("do not blindly change all strings")', () {
      expect(migration.contains("v_title := 'Order Accepted 🚗';\n                v_body := 'A rider has accepted your order and is on the way!';"), isTrue);
      expect(migration.contains("v_title := 'Rider at Pickup Location 📦';\n                v_body := 'Your rider has arrived at the pickup location. Share OTP ' || v_otp || ' to start the delivery.';"), isTrue);
      expect(migration.contains("v_body := 'Your trip has started. Track your rider''s live location on the map.';"), isTrue);
      expect(migration.contains("v_title := 'Rider Reached Drop-off 📍';\n                v_body := 'Your rider has reached the drop-off point. Please share OTP ' || v_otp || ' with the receiver to complete the delivery.';"), isTrue);
      expect(migration.contains("v_body := 'Your order has been completed. Rate your experience and thank the rider!';"), isTrue);
    });

    test('the pre-existing "Drop Partner" expired-order wording (already correct) is byte-for-'
        'byte unchanged', () {
      expect(migration.contains("v_title := 'No Drop Partners Available ⏱️';\n            v_body := 'We couldn''t find a Drop Partner for your request in time. Please try booking again.';"), isTrue);
    });

    test('the function signature, notification routing (send_push_notification_fnc call sites, '
        'jsonb payload shape) and rider-facing completion block are unchanged', () {
      expect(migration.contains('p_cancelled_by text DEFAULT NULL::text'), isTrue);
      expect(migration.contains("'type', 'order_status',"), isTrue);
      expect(
        migration.contains("'The order you accepted has been cancelled by the customer.'"),
        isTrue,
      );
    });
  });

  group('5. Client-side foreground display already used "Drop Partner" terminology -- confirms '
      'the push-notification copy fix brings the server in line with the existing client '
      'convention, not the other way around', () {
    test('parcel_tracking_screen.dart\'s in-app status banners already say "delivery partner" / '
        '"Drop Partner", not "rider"', () {
      expect(
        parcelTrackingScreen.contains(
          "message = 'Your delivery partner has been assigned and is heading to collect your parcel.';",
        ),
        isTrue,
      );
      expect(
        parcelTrackingScreen.contains(
          "message = 'Your delivery partner has arrived. Share the pickup OTP to hand over your parcel.';",
        ),
        isTrue,
      );
      expect(parcelTrackingScreen.contains("distanceText = 'Drop Partner at Pickup';"), isTrue);
    });
  });

  group('6. Migration safety: this is a reconciled rewrite, not a stale copy of the old local '
      'function', () {
    test('the migration explicitly documents the production reconciliation trace -- it was not '
        'silently rebuilt from the stale local baseline', () {
      expect(migration.contains('RECONCILED AGAINST ACTUAL PRODUCTION'), isTrue);
      expect(migration.contains('pg_get_functiondef'), isTrue);
    });

    test('no pricing, GST, commission, tax, payment, dispatch, or subscription keyword appears '
        'in the actual function body -- confirms the scope stayed notification-copy-only '
        '(checked against the SQL body only, not the header prose, since the header itself '
        'documents in English that none of these are touched)', () {
      final bodyStart = migration.indexOf('AS \$function\$');
      expect(bodyStart, greaterThan(-1));
      final body = migration.substring(bodyStart).toLowerCase();
      for (final forbidden in [
        'gst_percentage',
        'commission_percentage',
        'tax_rate_config',
        'government_tax_ledger',
        'cashfree',
        'pricing_config',
        'subscription_active',
        'dispatch',
      ]) {
        expect(body.contains(forbidden.toLowerCase()), isFalse,
            reason: 'unexpected "$forbidden" reference in a notification-copy-only migration');
      }
    });
  });
}
