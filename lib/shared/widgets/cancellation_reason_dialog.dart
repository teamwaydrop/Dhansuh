import 'package:flutter/material.dart';

/// Reusable "predefined reasons + Other free text" confirmation dialog for the intercity
/// traveller cancellation flows (individual accepted passenger, whole travel plan). Returns the
/// selected/typed reason string on confirm, or null if the user backed out without confirming.
class CancellationReasonDialog {
  static const Color _darkCard = Color(0xFF171A21);
  static const Color _textGray = Color(0xFFA9B0BE);
  static const Color _accent = Color(0xFF7C3AED);

  static Future<String?> show({
    required BuildContext context,
    required String title,
    required String description,
    required List<String> reasons,
    String confirmLabel = 'Confirm',
    Color confirmColor = Colors.redAccent,
  }) {
    String? selectedReason;
    final otherController = TextEditingController();

    return showDialog<String>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setState) {
            final isOtherSelected = selectedReason == 'Other';
            final canConfirm = selectedReason != null &&
                (!isOtherSelected || otherController.text.trim().isNotEmpty);

            return AlertDialog(
              backgroundColor: _darkCard,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
                side: BorderSide(color: Colors.white.withOpacity(0.08), width: 1),
              ),
              title: Text(
                title,
                style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      description,
                      style: const TextStyle(color: _textGray, fontSize: 13, height: 1.4),
                    ),
                    const SizedBox(height: 14),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: reasons.map((r) {
                        final isSelected = selectedReason == r;
                        return ChoiceChip(
                          label: Text(r),
                          selected: isSelected,
                          onSelected: (_) => setState(() => selectedReason = r),
                          selectedColor: _accent.withOpacity(0.28),
                          backgroundColor: Colors.white.withOpacity(0.06),
                          labelStyle: TextStyle(
                            color: isSelected ? Colors.white : _textGray,
                            fontSize: 12.5,
                            fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(20),
                            side: BorderSide(color: isSelected ? _accent : Colors.transparent),
                          ),
                        );
                      }).toList(),
                    ),
                    if (isOtherSelected) ...[
                      const SizedBox(height: 12),
                      TextField(
                        controller: otherController,
                        maxLines: 3,
                        autofocus: true,
                        style: const TextStyle(color: Colors.white, fontSize: 13),
                        onChanged: (_) => setState(() {}),
                        decoration: InputDecoration(
                          hintText: 'Please specify (required)',
                          hintStyle: const TextStyle(color: _textGray, fontSize: 13),
                          filled: true,
                          fillColor: Colors.white.withOpacity(0.06),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide.none,
                          ),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Back', style: TextStyle(color: _textGray)),
                ),
                TextButton(
                  onPressed: canConfirm
                      ? () {
                          final finalReason =
                              isOtherSelected ? otherController.text.trim() : selectedReason!;
                          Navigator.pop(ctx, finalReason);
                        }
                      : null,
                  child: Text(
                    confirmLabel,
                    style: TextStyle(
                      color: canConfirm ? confirmColor : _textGray.withOpacity(0.4),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}
