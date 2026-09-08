// Structural regression guard for two rounds of fixes to rider-facing completed-ride /
// earnings screens, plus one unrelated dispatch-race fix (kept from the first round, section
// D below).
//
// ROUND 2 (this file's primary coverage) -- four issues reported from a real device after round
// 1 shipped, diagnosed and approved before implementation:
//
// ISSUE 1 -- Earnings tab's "Recent Completed Rides" section showed an empty-state card
// ("No Completed Trips Yet") for a partner who had genuinely completed a ride. Requirement: the
// empty-state card must be removed entirely -- if completed rides exist, show the latest 3; if
// none exist, render nothing (no card at all). Fixed in rider_earnings_tab.dart by changing the
// `if (recentCompletedRides.isEmpty) _buildEmptyState() else [...]` branch to a single
// `if (recentCompletedRides.isNotEmpty) [...]` with no else, and deleting `_buildEmptyState()`.
//
// ISSUE 2 -- "Ride Fare" and "Your Trip Earnings" showed the identical number whenever
// commission was 0% (free trial/MAX). Root cause: calculate_fare_breakdown() only ever computes
// rider_earning = base_fare - commission_amount; it has zero awareness of government tax (a
// completely separate mechanism -- government_tax_ledger / apply_order_government_tax()). So
// whenever commission = 0%, rider_earning is mathematically identical to base_fare by
// construction, even though a real government tax deduction applies. Originally fixed by
// computing "YOUR TRIP EARNINGS" client-side as `fareBeforeGst - governmentTaxAmount` -- see
// ROUND 3 below for why that formula was ALSO wrong, and the actual final fix.
//
// ROUND 3 (2026-08-20 real-device report, after Round 2 shipped) -- "Ride Fare" itself was wrong:
// a ₹51.49 fare (correctly shown on the active-ride screen before completion) became ₹49.04 on
// the Ride Completed screen. Root cause: every Round-2 fix used `breakdown.fareBeforeGst` as
// "Ride Fare", but fareBeforeGst is calculate_fare_breakdown()'s internal "base_fare" --
// `customerPaid - gstAmount`, i.e. the total fare with "Platform GST" (orders.gst_amount, a
// completely separate, partner-facing-hidden concept from Government Tax) already netted out.
// Displaying fareBeforeGst as "Ride Fare" silently subtracted Platform GST from the partner-
// visible total. The same bug doubly affected "Your Trip Earnings", which also never subtracted
// commission at all when using fareBeforeGst as its base (base_fare has no commission subtracted
// -- rider_earning = base_fare - commission does).
//
// FIXED (final): "Ride Fare" now reads `breakdown.customerPaid` (final_fare/current_fare) --
// the exact total already shown to the partner pre-completion, in every one of the 4 screens.
// "YOUR TRIP EARNINGS" is now `riderEarning + breakdown.gstAmount - governmentTaxAmount` in every
// screen -- algebraically identical to `customerPaid - commissionAmount - governmentTaxAmount`
// (riderEarning is already base_fare - commission; adding back gstAmount recovers customerPaid's
// basis before subtracting governmentTax), reusing the backend's own already-correct commission/
// subscription-waiver handling rather than reconstructing it in Flutter. See
// fare_presentation_regression_test.dart for an executable worked-example proof of this formula
// against the exact reported numbers (₹51.49 / ₹2.57 / ₹48.92). No backend/business-logic change
// -- Platform GST, commission, and government tax are all still computed exactly as before; only
// the client-side DISPLAY combination of those existing values was wrong.
//
// ISSUE 3 -- The old "Platform GST (X%)" row (orders.gst_amount) was shown alongside the new
// "Government Tax" row, which was confusing (two GST-looking numbers for one order). Requirement:
// remove "Platform GST" from partner-facing completed-ride UI entirely; show only Government Tax.
// Fixed by deleting the `if (breakdown.gstAmount > 0) [...Platform GST row...]` block from every
// affected screen -- gstAmount/gstPercentage are no longer referenced anywhere in these files.
// orders.gst_amount itself is untouched server-side; this is a UI-only removal.
//
// ISSUE 4 -- Order History's detail sheet showed "Government Tax ₹0.00" for an order that showed
// a real non-zero government tax elsewhere (e.g. the completion screen right after the ride).
// Root cause: loadHistoryData()'s `.select(...)` for `orders` was missing the `id` column
// entirely, so the detail sheet's government_tax_ledger lookup (keyed on order_id) always ran
// with a null id and matched nothing -- silently falling back to ₹0.00. Fixed by adding `id` (and
// every other FareBreakdown.fromOrder()/direct-collection input column the restructured detail
// sheet now needs) to that select. The completed-ride screen and Order History for the same order
// now read the exact same government_tax_ledger row -- no independently-computed tax value
// anywhere.
//
// Across all four affected screens (rider_earnings_tab.dart's _ExpandableOrderCard,
// rider_activity_tab.dart, rider_order_history_screen.dart, rider_active_order_screen.dart's
// buildCompletionScreen()), the government tax lookup is fetched ONCE per card/sheet/screen (not
// re-fetched inconsistently), and both the headline earnings figure and the expanded breakdown's
// "YOUR TRIP EARNINGS" row read from that same cached/single-fetch value, so they can never
// disagree with each other.
//
// ROUND 1 (sections A-D below, unchanged by round 2) -- see each group's own comment.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final earningsTab = _read('lib/features/rider/earnings/rider_earnings_tab.dart');
  final activityTab = _read('lib/features/rider/activity/rider_activity_tab.dart');
  final homeTab = _read('lib/features/rider/home/rider_home_tab.dart');
  final activeOrderScreen = _read('lib/features/rider/orders/screens/rider_active_order_screen.dart');
  final orderHistoryScreen = _read('lib/features/rider/orders/screens/rider_order_history_screen.dart');

  group('Issue 1: Earnings tab empty-state card is removed entirely, not just re-gated', () {
    test('rider_earnings_tab.dart no longer defines or calls _buildEmptyState()', () {
      // _buildEmptyState() was the sole renderer of the "No Completed Trips Yet" card; its
      // complete removal (not just a call-site removal) is proof the card can no longer render.
      // (The phrase itself may still appear inside an explanatory code comment.)
      expect(earningsTab.contains('_buildEmptyState'), isFalse);
    });

    test('the Recent Completed Rides section renders only when the list is non-empty, with no '
        'else branch (nothing at all is shown when there are zero completed rides)', () {
      final guardIdx = earningsTab.indexOf('if (recentCompletedRides.isNotEmpty) ...[');
      expect(guardIdx, greaterThan(-1));
      final nearby = earningsTab.substring(guardIdx, guardIdx + 400);
      expect(nearby.contains('Recent Completed Rides'), isTrue);
      expect(nearby.contains('recentCompletedRides.map'), isTrue);
    });

    test('the dedicated, server-limited "latest 3 completed rides ever" query is unchanged: no '
        '30-day window, ordered newest-first, capped to 3 rows', () {
      final queryStart = earningsTab.indexOf('final recentCompletedRidesFuture');
      expect(queryStart, greaterThan(-1));
      final queryEnd = earningsTab.indexOf('List<Map<String, dynamic>> activityData', queryStart);
      final queryBody = earningsTab.substring(queryStart, queryEnd > queryStart ? queryEnd : queryStart + 900);
      expect(queryBody.contains("inFilter('order_status', ['completed', 'delivered'])"), isTrue);
      expect(queryBody.contains(".order('completed_at', ascending: false)"), isTrue);
      expect(queryBody.contains('.limit(3)'), isTrue);
      expect(queryBody.contains('thirtyDaysAgo'), isFalse);
    });

    test('the analytics section (totals/averages/chart) is still gated on the original 30-day '
        '`recentOrders` list, unchanged -- existing earnings totals are not broken by this fix', () {
      final analyticsGuardIdx = earningsTab.indexOf('if (recentOrders.isNotEmpty)');
      expect(analyticsGuardIdx, greaterThan(-1));
      final nearby = earningsTab.substring(analyticsGuardIdx, analyticsGuardIdx + 300);
      expect(nearby.contains('Earnings Analytics'), isTrue);
    });
  });

  group('Issues 2 & 3: YOUR TRIP EARNINGS = Ride Fare - Government Tax (never raw rider_earning), '
      'Platform GST removed -- across every rider-facing completed-ride screen', () {
    // UPDATED (ROUND 3): breakdown.gstAmount ("Platform GST") is now legitimately READ by all
    // four screens -- it's an input to the YOUR TRIP EARNINGS formula (added back to riderEarning
    // to recover the true total-fare basis before subtracting government tax). What must still be
    // true is that it is never DISPLAYED as its own "Platform GST" row/label, and gst_percentage
    // (only ever used for that removed label's "(X%)" suffix) is never referenced at all.
    test('gst_percentage is never referenced (it only ever fed the removed "Platform GST (X%)" '
        'label) -- and no screen renders a "Platform GST" row, even though gstAmount is now a '
        'legitimate input to the YOUR TRIP EARNINGS formula', () {
      for (final src in [earningsTab, activityTab, activeOrderScreen, orderHistoryScreen]) {
        expect(src.contains('gstPercentage'), isFalse);
        // The phrase may still appear inside an explanatory code comment (double-quoted, for
        // readability) documenting the removal -- only a real Dart string literal (single-quoted,
        // the form an actual UI row/label would use) proves the row itself is gone.
        expect(src.contains("'Platform GST"), isFalse);
      }
    });

    test('rider_earnings_tab.dart\'s _ExpandableOrderCard fetches government_tax_ledger once in '
        'initState(), Ride Fare reads breakdown.customerPaid (never fareBeforeGst), and '
        'YOUR TRIP EARNINGS = riderEarning + gstAmount - govTax (never fareBeforeGst - govTax, '
        'which silently netted out Platform GST -- the ₹51.49-becomes-₹49.04 bug)', () {
      final start = earningsTab.indexOf('class _ExpandableOrderCardState');
      expect(start, greaterThan(-1));
      final body = earningsTab.substring(start);
      expect(body.contains("from('government_tax_ledger')"), isTrue);
      expect(body.contains("eq('entry_type', 'ORDER_TAX')"), isTrue);
      expect(body.contains('Future<void> _loadGovernmentTax() async'), isTrue);
      // Non-eligible path unchanged; eligible 2%-PG ride shows riderEarning directly (already final).
      final netIdx = body.indexOf(
        'final netEarnings = breakdown.isPgChargeRide\n'
        '        ? riderEarning\n'
        '        : (_taxLoading ? riderEarning : (riderEarning + breakdown.gstAmount - govTaxAmount));',
      );
      expect(netIdx, greaterThan(-1));
      // The old, buggy formula must be gone, not merely superseded alongside it.
      expect(body.contains('breakdown.fareBeforeGst - govTaxAmount'), isFalse);
      // Both the collapsed "+₹..." headline and the expanded row must read netEarnings, not
      // riderEarning/breakdown.partnerEarning directly.
      expect(body.contains(r"'+₹${netEarnings.toStringAsFixed(2)}'"), isTrue);
      expect(body.contains("_buildOrderBreakdownSectionHeader('RIDE FARE')"), isTrue);
      expect(body.contains("_buildOrderBreakdownSectionHeader('DEDUCTIONS')"), isTrue);
      // Ride Fare is the full original total (breakdown.customerPaid), never fareBeforeGst.
      expect(
        body.contains("_buildOrderBreakdownRow('Ride Fare', '₹\${breakdown.customerPaid.toStringAsFixed(2)}')"),
        isTrue,
      );
      expect(body.contains("_buildOrderBreakdownRow('Ride Fare', '₹\${breakdown.fareBeforeGst"), isFalse);
    });

    test('rider_activity_tab.dart\'s detail sheet: Ride Fare/Customer Paid reads '
        'breakdown.customerPaid, and YOUR TRIP EARNINGS = riderEarning + gstAmount - taxAmount '
        '(never fareBeforeGst - taxAmount)', () {
      final anchor = activityTab.indexOf("from('government_tax_ledger')");
      expect(anchor, greaterThan(-1));
      final nearby = activityTab.substring(anchor, anchor + 600);
      expect(nearby.contains("eq('entry_type', 'ORDER_TAX')"), isTrue);
      expect(
        activityTab.contains(
          'final netEarnings = breakdown.isPgChargeRide\n'
          '                            ? breakdown.partnerEarning\n'
          '                            : (taxLoading\n'
          '                                ? breakdown.partnerEarning\n'
          '                                : (breakdown.partnerEarning + breakdown.gstAmount - taxAmount));',
        ),
        isTrue,
      );
      expect(activityTab.contains('breakdown.fareBeforeGst - taxAmount'), isFalse);
      expect(activityTab.contains("buildSectionHeader('RIDE FARE')"), isTrue);
      expect(activityTab.contains("buildSectionHeader('DEDUCTIONS')"), isTrue);
      expect(
        activityTab.contains(
          r"buildBreakdownRow('YOUR TRIP EARNINGS', '₹${netEarnings.toStringAsFixed(2)}', color: primaryLime)",
        ),
        isTrue,
      );
      // Ride Fare (or Customer Paid, for a genuine gateway settlement) is the full original
      // total -- breakdown.customerPaid, never breakdown.fareBeforeGst.
      expect(
        activityTab.contains(
          "buildBreakdownRow(\n"
          "                              isDirectCollection ? 'Ride Fare' : 'Customer Paid',\n"
          "                              '₹\${breakdown.customerPaid.toStringAsFixed(2)}',",
        ),
        isTrue,
      );
      expect(activityTab.contains("'₹\${breakdown.fareBeforeGst.toStringAsFixed(2)}'"), isFalse);
      expect(activityTab.contains('hasRealCustomerPaidFigure'), isFalse);
    });

    test('rider_order_history_screen.dart\'s detail sheet matches the same fix as '
        'rider_activity_tab.dart -- same government_tax_ledger lookup, same netEarnings formula, '
        'same Ride Fare = customerPaid value, same RIDE FARE / DEDUCTIONS section structure', () {
      expect(orderHistoryScreen.contains("from('government_tax_ledger')"), isTrue);
      expect(orderHistoryScreen.contains("eq('entry_type', 'ORDER_TAX')"), isTrue);
      expect(
        orderHistoryScreen.contains(
          'final netEarnings = breakdown.isPgChargeRide\n'
          '                            ? breakdown.partnerEarning\n'
          '                            : (taxLoading\n'
          '                                ? breakdown.partnerEarning\n'
          '                                : (breakdown.partnerEarning + breakdown.gstAmount - taxAmount));',
        ),
        isTrue,
      );
      expect(orderHistoryScreen.contains('breakdown.fareBeforeGst - taxAmount'), isFalse);
      expect(orderHistoryScreen.contains("buildSectionHeader('RIDE FARE')"), isTrue);
      expect(orderHistoryScreen.contains("buildSectionHeader('DEDUCTIONS')"), isTrue);
      expect(
        orderHistoryScreen.contains(
          r"buildBreakdownRow('YOUR TRIP EARNINGS', '₹${netEarnings.toStringAsFixed(2)}', color: primaryLime)",
        ),
        isTrue,
      );
      expect(
        orderHistoryScreen.contains(
          "buildBreakdownRow(\n"
          "                              isDirectCollection ? 'Ride Fare' : 'Customer Paid',\n"
          "                              '₹\${breakdown.customerPaid.toStringAsFixed(2)}',",
        ),
        isTrue,
      );
      expect(orderHistoryScreen.contains("'₹\${breakdown.fareBeforeGst.toStringAsFixed(2)}'"), isFalse);
      expect(orderHistoryScreen.contains('hasRealCustomerPaidFigure'), isFalse);
    });

    test('rider_active_order_screen.dart fetches government tax ONCE per order at State level '
        '(not per-section), so the hero "YOUR TRIP EARNINGS" figure at the very top of the '
        'completion screen and the DEDUCTIONS row further down can never disagree -- both read '
        'the same completionNetEarnings = riderEarning + gstAmount - govTax, and every "Ride '
        'Fare"/"Customer Paid" value on this screen is the plain `fare` local (customerPaid), '
        'never the old, buggy `baseFare` (fareBeforeGst)', () {
      expect(activeOrderScreen.contains('Future<void> _loadCompletionGovernmentTax(String orderId) async'), isTrue);
      expect(activeOrderScreen.contains("from('government_tax_ledger')"), isTrue);
      expect(activeOrderScreen.contains("eq('entry_type', 'ORDER_TAX')"), isTrue);
      expect(
        activeOrderScreen.contains(
          'final completionNetEarnings = breakdown.isPgChargeRide\n'
          '        ? riderEarning\n'
          '        : (_completionTaxLoading ? riderEarning : (riderEarning + breakdown.gstAmount - _completionGovTaxAmount));',
        ),
        isTrue,
      );
      // The `baseFare` variable (fareBeforeGst) that caused the reported bug must be gone
      // entirely from this screen, not merely unused alongside a correct replacement.
      expect(activeOrderScreen.contains('baseFare'), isFalse);
      final start = activeOrderScreen.indexOf('Widget buildCompletionScreen()');
      expect(start, greaterThan(-1));
      final body = activeOrderScreen.substring(start);
      // The hero card's headline figure (shown immediately, in the largest font on the screen)
      // must read the shared, tax-adjusted value -- never the raw partner-earning identity that
      // caused the original "Ride Fare == Your Trip Earnings" bug.
      expect(body.contains(r"'₹${completionNetEarnings.toStringAsFixed(2)}'"), isTrue);
      expect(body.contains(r"'₹${riderEarning.toStringAsFixed(2)}'"), isFalse);
      // Ride Fare (both the top summary row and the RIDE FARE section) is `fare`
      // (breakdown.customerPaid basis), the exact figure already shown pre-completion.
      expect(body.contains("_buildStatRow('Ride Fare', '₹\${fare.toStringAsFixed(2)}')"), isTrue);
      expect(body.contains(r"'₹${fare.toStringAsFixed(2)}'"), isTrue);
      // The hero card is the first "Card 1" container in buildCompletionScreen -- confirm the
      // tax-adjusted value literal appears inside that specific card, not merely somewhere later
      // in the (very long) method.
      final heroCardStart = body.indexOf('Card 1: Trip Earnings Card');
      final heroCardEnd = body.indexOf('Card 2: Route Details Card');
      expect(heroCardStart, greaterThan(-1));
      expect(heroCardEnd, greaterThan(heroCardStart));
      final heroCard = body.substring(heroCardStart, heroCardEnd);
      expect(heroCard.contains("'YOUR TRIP EARNINGS'"), isTrue);
      expect(heroCard.contains(r"'₹${completionNetEarnings.toStringAsFixed(2)}'"), isTrue);
    });

    test('WayDrop Commission is labeled "(0%)" during a free trial/subscription waiver on every '
        'screen -- never implies government tax is also waived', () {
      bool waiverLabelPresent(String src, String waiverFlagExpr) {
        final labelIdx = src.indexOf("'WayDrop Commission (0%)'");
        if (labelIdx == -1) return false;
        final precedingStart = (labelIdx - 150).clamp(0, src.length);
        final nearby = src.substring(precedingStart, labelIdx);
        return nearby.contains(waiverFlagExpr);
      }

      expect(waiverLabelPresent(earningsTab, 'breakdown.subscriptionCommissionWaived'), isTrue);
      expect(waiverLabelPresent(activityTab, 'breakdown.subscriptionCommissionWaived'), isTrue);
      expect(waiverLabelPresent(activeOrderScreen, 'subscriptionWaived'), isTrue);
      for (final src in [activityTab, activeOrderScreen, orderHistoryScreen]) {
        expect(src.contains('Government tax is separate from company commission'), isTrue);
      }
    });
  });

  group('Issue 4: Order History and Earnings tab read the real government_tax_ledger row for '
      'the same order -- no hard-coded ₹0.00, no independently-computed tax value', () {
    test('rider_order_history_screen.dart\'s orders select() includes `id` plus every '
        'FareBreakdown/direct-collection column the detail sheet needs', () {
      final start = orderHistoryScreen.indexOf('Future<void> loadHistoryData() async {');
      expect(start, greaterThan(-1));
      final end = orderHistoryScreen.indexOf('.limit(50)', start);
      final body = orderHistoryScreen.substring(start, end > start ? end : start + 1200);
      expect(body.contains("'id, order_type, order_code"), isTrue);
      expect(body.contains('final_fare, current_fare, gst_amount, gst_percentage'), isTrue);
      expect(body.contains('commission_amount, commission_percentage, subscription_commission_waived'), isTrue);
      expect(body.contains('fare_payment_method, payment_mode, payment_status'), isTrue);
    });

    test('rider_earnings_tab.dart\'s orders/recentCompletedRides selects both include `id` plus '
        'the same tax/commission columns, so the same order reads identically in both places', () {
      expect(
        earningsTab.contains(
          "'id, order_code, order_type, completed_at, created_at, picked_up_at, accepted_at, "
          'rider_earning, boost_amount, distance_km, time_taken_seconds, '
          'vehicle_type, final_fare, current_fare, gst_amount, gst_percentage, pg_charge_amount, commission_amount, '
          "commission_percentage, subscription_commission_waived, fare_payment_method, payment_mode, payment_status'",
        ),
        isTrue,
      );
    });

    test('rider_earnings_tab.dart\'s orders .select() lists contain ONLY real orders columns -- no '
        'surge_fee / rain_fee (those columns do not exist on public.orders; selecting them made '
        'PostgREST reject the whole query with 42703, which surfaced as "Unable to load")', () {
      // Guard the SELECT column lists specifically (a `o['surge_fee']` map read elsewhere is a
      // harmless null->0 and out of scope here).
      for (final m in RegExp(r"\.select\(\s*'([^']*)'\s*\)").allMatches(earningsTab)) {
        final cols = m.group(1)!;
        expect(cols.contains('surge_fee'), isFalse, reason: '.select() must not request surge_fee');
        expect(cols.contains('rain_fee'), isFalse, reason: '.select() must not request rain_fee');
      }
    });

    test('every government_tax_ledger lookup across all four screens filters on the real order id '
        'and entry_type ORDER_TAX -- never a hard-coded/omitted order_id', () {
      for (final src in [earningsTab, activityTab, activeOrderScreen, orderHistoryScreen]) {
        expect(src.contains("eq('order_id',"), isTrue);
        expect(src.contains("eq('entry_type', 'ORDER_TAX')"), isTrue);
      }
    });
  });

  group('A. Completed ride detail: honest fare labeling, no fabricated "Customer Paid ₹0.00"', () {
    // UPDATED (ROUND 3): "Customer Fare" + "• Ride Fare" sub-line split (hasRealCustomerPaidFigure)
    // is gone -- both used to show the SAME concept (the total fare), so the split was redundant
    // once "Ride Fare" itself was fixed to mean the full total. Now there is a single row whose
    // VALUE is always breakdown.customerPaid and whose LABEL alone depends on collection method.
    test('"Customer Paid" is shown only for a genuine gateway settlement; "Ride Fare" is the '
        'label for a direct-collection (cash/personal-UPI) ride -- but the underlying VALUE '
        '(breakdown.customerPaid) is identical either way, never a fabricated ₹0.00', () {
      expect(activityTab.contains("'Customer Paid'"), isTrue);
      expect(activityTab.contains("'Ride Fare'"), isTrue);
      expect(activityTab.contains('isDirectCollection'), isTrue);
      expect(activityTab.contains('hasRealCustomerPaidFigure'), isFalse);
      expect(activityTab.contains("'Customer Fare'"), isFalse);
    });

    test('the direct-collection determination mirrors the server\'s own rule '
        '(complete_order_and_settle) rather than inventing a new one', () {
      final anchor = activityTab.indexOf('final isDirectCollection');
      expect(anchor, greaterThan(-1));
      final nearby = activityTab.substring(anchor, anchor + 300);
      expect(nearby.contains("fareMethod == 'personal_upi' || fareMethod == 'cash'"), isTrue);
    });
  });

  group('B. Pending order after active-ride completion: race fixed via existing realtime '
      'reconciliation, no polling added', () {
    test('subscribeActiveOrder\'s completion handler awaits loadActiveOrder() before any '
        'pending-assignment reconciliation runs', () {
      final start = homeTab.indexOf('void subscribeActiveOrder(String riderId) {');
      final end = homeTab.indexOf('void subscribeTravelPlans(String riderId) {');
      expect(start, greaterThan(-1));
      expect(end, greaterThan(start));
      final body = homeTab.substring(start, end);
      expect(body.contains('callback: (payload) async {'), isTrue);
      final awaitIdx = body.indexOf('await loadActiveOrder(riderId);');
      expect(awaitIdx, greaterThan(-1));
      final loadRiderIdx = body.indexOf('loadRider(skipActiveOrderReload: true)');
      final reconcileFallbackIdx = body.indexOf('_reconcilePendingAssignments(riderId)');
      expect(loadRiderIdx, greaterThan(awaitIdx));
      expect(reconcileFallbackIdx, greaterThan(awaitIdx));
    });

    test('the fix does not introduce a new Timer/polling loop -- it only sequences two existing, '
        'already-triggered calls correctly', () {
      final start = homeTab.indexOf('void subscribeActiveOrder(String riderId) {');
      final end = homeTab.indexOf('void subscribeTravelPlans(String riderId) {');
      final body = homeTab.substring(start, end);
      expect(body.contains('Timer.periodic'), isFalse);
      expect(body.contains('Timer('), isFalse);
    });

    test('_showIncomingOrder()\'s busy-guard (never announce while the rider has an active order) '
        'is unchanged -- the fix only ensures it sees fresh state, never removes the guard itself', () {
      expect(homeTab.contains('if (activeOrders.isNotEmpty) {'), isTrue);
      // Signature gained an optional `{String? orderType}` param (WayDrop bug-fix pass: gates the
      // local incoming-ride sound to local order types, see
      // intercity_match_no_local_sound_regression_test.dart) -- match on the stable prefix only.
      final idx = homeTab.indexOf('void _showIncomingOrder(Map<String, dynamic> assignment');
      expect(idx, greaterThan(-1));
    });

    test('the existing pending-assignment reconciliation mechanism (not a new one) is what '
        'surfaces the order -- _reconcilePendingAssignments already calls _showIncomingOrder for '
        'every unannounced "sent" assignment', () {
      final idx = homeTab.indexOf('Future<void> _reconcilePendingAssignments(String riderId) async {');
      expect(idx, greaterThan(-1));
      final end = homeTab.indexOf('Future<void> loadActiveOrder(String riderId) async {');
      final body = homeTab.substring(idx, end > idx ? end : idx + 1500);
      expect(body.contains('_showIncomingOrder(row)'), isTrue);
    });
  });

  group('C. Existing active-ride and paid-subscriber behavior is unchanged', () {
    test('loadActiveOrder()\'s busy-order status filter is unchanged by this fix', () {
      expect(
        homeTab.contains(
          "inFilter('order_status', ['accepted', 'rider_arrived', 'picked_up', 'rider_at_drop', 'ongoing', 'payment_pending']);",
        ),
        isTrue,
      );
    });

    test('the paid-subscription commission-waiver flag read in the ride-detail breakdown is the '
        'same pre-existing field this feature has always used -- no new/duplicate waiver state', () {
      expect(activityTab.contains("order['subscription_commission_waived'] == true"), isFalse);
      final helper = _read('lib/shared/helpers/fare_presentation_helper.dart');
      expect(helper.contains("order['subscription_commission_waived'] == true"), isTrue);
    });
  });
}
