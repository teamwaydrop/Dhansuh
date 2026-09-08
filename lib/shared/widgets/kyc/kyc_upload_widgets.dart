import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

/// Shared document-verification building blocks used by both the one-time
/// Rider/Drop Partner person KYC flow (Aadhaar/PAN/Driving License/Selfie)
/// and the independent per-vehicle verification flow (RC Front/Back,
/// Vehicle Photo) — kept here so neither flow duplicates the other's
/// upload UI.

const kKycPrimaryColor = Color(0xFF2563EB);

/// Shows the camera/gallery picker sheet and returns the picked image, or
/// null if the user dismissed it without picking anything.
Future<XFile?> pickKycImage(BuildContext context) async {
  final source = await showModalBottomSheet<ImageSource>(
    context: context,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    builder: (_) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox.shrink(),
            const SizedBox(height: 16),
            ListTile(
              leading: Container(width: 40, height: 40, decoration: BoxDecoration(color: const Color(0xFFF0FDF4), borderRadius: BorderRadius.circular(12)), child: const Icon(Icons.camera_alt_rounded, color: kKycPrimaryColor, size: 20)),
              title: const Text('Take Photo', style: TextStyle(fontWeight: FontWeight.w700, color: Color(0xFF0F172A))),
              onTap: () => Navigator.pop(context, ImageSource.camera),
            ),
            ListTile(
              leading: Container(width: 40, height: 40, decoration: BoxDecoration(color: const Color(0xFFEFF6FF), borderRadius: BorderRadius.circular(12)), child: const Icon(Icons.photo_rounded, color: Color(0xFF2563EB), size: 20)),
              title: const Text('Choose from Gallery', style: TextStyle(fontWeight: FontWeight.w700, color: Color(0xFF0F172A))),
              onTap: () => Navigator.pop(context, ImageSource.gallery),
            ),
          ],
        ),
      ),
    ),
  );
  if (source == null) return null;
  final picker = ImagePicker();
  return await picker.pickImage(source: source, imageQuality: 90);
}

class UpperCaseTextFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    return TextEditingValue(
      text: newValue.text.toUpperCase(),
      selection: newValue.selection,
    );
  }
}

class KycTextField extends StatelessWidget {
  final TextEditingController ctrl;
  final String hint;
  final IconData icon;
  final bool numeric;
  final int? maxLen;
  final TextCapitalization textCapitalization;

  const KycTextField({
    super.key,
    required this.ctrl,
    required this.hint,
    required this.icon,
    this.numeric = false,
    this.maxLen,
    this.textCapitalization = TextCapitalization.none,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: TextField(
        controller: ctrl,
        keyboardType: numeric ? TextInputType.number : TextInputType.text,
        inputFormatters: numeric
            ? [FilteringTextInputFormatter.digitsOnly]
            : (textCapitalization == TextCapitalization.characters
                ? [UpperCaseTextFormatter()]
                : null),
        maxLength: maxLen,
        textCapitalization: textCapitalization,
        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Color(0xFF0F172A)),
        decoration: InputDecoration(
          icon: Icon(icon, color: const Color(0xFF94A3B8), size: 18),
          border: InputBorder.none,
          hintText: hint,
          hintStyle: const TextStyle(color: Color(0xFFCBD5E1), fontSize: 14, fontWeight: FontWeight.w500),
          counterText: '',
        ),
      ),
    );
  }
}

/// Upload progress/result state for a [DocUploadRow]. Left as `null` (the default) for callers
/// that only track local pick state, not remote upload state -- e.g. add_vehicle_screen.dart,
/// which still batch-uploads at its own submit time and is out of scope for the incremental-
/// upload redesign the Rider KYC screen now uses.
enum DocUploadStatus { uploading, uploaded, failed }

/// A single "document upload" row: title + description on the left, a
/// thumbnail/checkmark once uploaded or an "UPLOAD" pill otherwise. Used
/// for Aadhaar/PAN/License/Selfie/Vehicle Photo and RC Front/Back.
class DocUploadRow extends StatelessWidget {
  final String title;
  final String description;
  final XFile? image;
  final VoidCallback onTap;
  final bool last;
  final DocUploadStatus? status;
  final VoidCallback? onRetry;

  const DocUploadRow({
    super.key,
    required this.title,
    required this.description,
    required this.image,
    required this.onTap,
    this.last = false,
    this.status,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            title.toUpperCase(),
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w900,
                              color: Color(0xFF0F172A),
                              letterSpacing: 0.3,
                            ),
                          ),
                          const SizedBox(width: 6),
                          const Icon(
                            Icons.info_outline_rounded,
                            size: 13,
                            color: Color(0xFF3B82F6),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        description,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFF64748B),
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                _buildActionState(),
              ],
            ),
          ),
        ),
        if (!last) const Divider(height: 1, color: Color(0xFFF1F5F9)),
      ],
    );
  }

  Widget _buildActionState() {
    Widget? thumbnail;
    if (image != null) {
      thumbnail = ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Image.file(
          File(image!.path),
          width: 38,
          height: 38,
          fit: BoxFit.cover,
        ),
      );
    }

    switch (status) {
      case DocUploadStatus.uploading:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (thumbnail != null) ...[thumbnail, const SizedBox(width: 8)],
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF2563EB)),
            ),
          ],
        );
      case DocUploadStatus.uploaded:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (thumbnail != null) ...[thumbnail, const SizedBox(width: 8)],
            const CircleAvatar(
              backgroundColor: Color(0xFF2563EB),
              radius: 10,
              child: Icon(Icons.check_rounded, size: 12, color: Colors.white),
            ),
          ],
        );
      case DocUploadStatus.failed:
        return InkWell(
          onTap: onRetry,
          borderRadius: BorderRadius.circular(20),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
            decoration: BoxDecoration(
              color: const Color(0xFFFEF2F2),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: const Color(0xFFFECACA)),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.refresh_rounded, size: 13, color: Color(0xFFDC2626)),
                SizedBox(width: 4),
                Text(
                  'RETRY',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w900,
                    color: Color(0xFFDC2626),
                    letterSpacing: 0.5,
                  ),
                ),
              ],
            ),
          ),
        );
      case null:
        if (image != null) {
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              thumbnail!,
              const SizedBox(width: 8),
              const CircleAvatar(
                backgroundColor: Color(0xFF2563EB),
                radius: 10,
                child: Icon(Icons.check_rounded, size: 12, color: Colors.white),
              ),
            ],
          );
        }
        return Container(
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
          decoration: BoxDecoration(
            color: const Color(0xFFEFF6FF),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0xFFDBEAFE)),
          ),
          child: const Text(
            'UPLOAD',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w900,
              color: Color(0xFF2563EB),
              letterSpacing: 0.5,
            ),
          ),
        );
    }
  }
}

/// Selectable vehicle-type tile with a thumbnail image (bike/auto/cab),
/// used both at KYC time and when adding an additional vehicle.
class VehicleTypeChip extends StatelessWidget {
  final String value, label;
  final String imagePath;
  final bool selected;
  final VoidCallback onTap;

  const VehicleTypeChip({
    super.key,
    required this.value,
    required this.imagePath,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFFEFF6FF) : Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected ? const Color(0xFF2563EB) : const Color(0xFFE2E8F0),
            width: selected ? 2 : 1,
          ),
          boxShadow: selected
              ? [BoxShadow(color: const Color(0xFF2563EB).withValues(alpha: 0.15), blurRadius: 8, offset: const Offset(0, 4))]
              : null,
        ),
        child: Column(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.asset(
                imagePath,
                height: 64,
                width: double.infinity,
                fit: BoxFit.cover,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              label.toUpperCase(),
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w900,
                color: selected ? const Color(0xFF2563EB) : const Color(0xFF64748B),
                letterSpacing: 0.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
