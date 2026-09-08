import 'package:flutter/material.dart';

/// Shared "Send Travel Request?" confirmation dialog (Bug 4) — shown before any
/// [IntercityMatchingService.sendTravelTogetherRequest] call, from either side (User browsing
/// Available Partners, or Partner browsing Available Travelers), so the request is never sent
/// without the user confirming who/where/when first.
///
/// Styled to match the existing dialog pattern in travel_plan_details_screen.dart's
/// `_confirmDeletePlan` (dark card, rounded border, muted Cancel + solid primary action).
Future<bool?> showTravelTogetherConfirmDialog(
  BuildContext context, {
  required String partnerName,
  required String route,
  required String travelDate,
}) {
  debugPrint('[RUNTIME_TRACE] Confirmation dialog opens (travel_together_confirm_dialog.dart) partnerName=$partnerName route=$route');
  final isDark = Theme.of(context).brightness == Brightness.dark;
  final cardColor = isDark ? const Color(0xFF171A21) : Colors.white;
  final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
  final subTextColor = isDark ? const Color(0xFFA9B0BE) : const Color(0xFF6B7280);

  return showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: cardColor,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: (isDark ? Colors.white : Colors.black).withOpacity(0.08), width: 1),
      ),
      title: Text(
        'Send Travel Request',
        style: TextStyle(color: textColor, fontSize: 16, fontWeight: FontWeight.bold),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Your request will be sent to the traveller. The traveller can accept or decline it.',
            style: TextStyle(color: subTextColor, fontSize: 13, height: 1.4),
          ),
          const SizedBox(height: 16),
          _DialogRow(label: 'Partner', value: partnerName, subTextColor: subTextColor, textColor: textColor),
          const SizedBox(height: 10),
          _DialogRow(label: 'Route', value: route, subTextColor: subTextColor, textColor: textColor),
          const SizedBox(height: 10),
          _DialogRow(label: 'Travel Date', value: travelDate, subTextColor: subTextColor, textColor: textColor),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text('Cancel', style: TextStyle(color: subTextColor, fontSize: 12, fontWeight: FontWeight.bold)),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFFC5FF30),
            foregroundColor: Colors.black,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            elevation: 0,
          ),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Send Request', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
        ),
      ],
    ),
  );
}

class _DialogRow extends StatelessWidget {
  final String label;
  final String value;
  final Color subTextColor;
  final Color textColor;

  const _DialogRow({
    required this.label,
    required this.value,
    required this.subTextColor,
    required this.textColor,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 82,
          child: Text(label, style: TextStyle(color: subTextColor, fontSize: 12)),
        ),
        Expanded(
          child: Text(
            value,
            style: TextStyle(color: textColor, fontSize: 13, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }
}
