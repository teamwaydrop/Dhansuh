import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:waydrop/features/rider/onboarding/services/rider_kyc_upload_service.dart';
import 'package:waydrop/shared/widgets/app_snackbar.dart';
import 'package:waydrop/shared/widgets/kyc/kyc_upload_widgets.dart';

/// Adds an additional vehicle for an already-verified Drop Partner, without
/// repeating person KYC (Aadhaar/PAN/Driving License/Selfie/Bank Details).
/// Collects Vehicle Type, Vehicle Number, RC Front, RC Back and Vehicle
/// Photo, and stores the new vehicle in `rider_vehicles` with status
/// 'pending' until it is reviewed the same way rider_kyc is reviewed today.
///
/// Reuses KycTextField / DocUploadRow / VehicleTypeChip / pickKycImage
/// (shared/widgets/kyc/kyc_upload_widgets.dart) and RiderKycUploadService's
/// validate/compress/upload pipeline — no new upload widgets or storage
/// bucket were created for this screen.
class AddVehicleScreen extends StatefulWidget {
  final String riderId;

  const AddVehicleScreen({super.key, required this.riderId});

  @override
  State<AddVehicleScreen> createState() => _AddVehicleScreenState();
}

class _AddVehicleScreenState extends State<AddVehicleScreen> {
  final supabase = Supabase.instance.client;
  final vehicleNumberController = TextEditingController();

  String? vehicleType;
  XFile? rcFront, rcBack, vehiclePhoto;
  bool submitting = false;

  static const primary = kKycPrimaryColor;

  @override
  void dispose() {
    vehicleNumberController.dispose();
    super.dispose();
  }

  void showError(String message) {
    showAppSnackBar(context, message, type: SnackBarType.error);
  }

  bool _validate() {
    if (vehicleType == null) { showError('Please select a vehicle type'); return false; }
    if (vehicleNumberController.text.trim().isEmpty) { showError('Enter vehicle number'); return false; }
    if (rcFront == null) { showError('Upload RC front'); return false; }
    if (rcBack == null) { showError('Upload RC back'); return false; }
    if (vehiclePhoto == null) { showError('Upload vehicle photo'); return false; }
    return true;
  }

  Future<void> _submit() async {
    if (!_validate()) return;

    final user = supabase.auth.currentUser;
    if (user == null) { showError('Session expired'); return; }

    setState(() => submitting = true);

    final folder = '${user.id}/vehicles/${DateTime.now().millisecondsSinceEpoch}';
    final uploadedPaths = <String>[];

    try {
      await Future.wait([
        RiderKycUploadService.validateImage(rcFront!),
        RiderKycUploadService.validateImage(rcBack!),
        RiderKycUploadService.validateImage(vehiclePhoto!),
      ]);

      final compressed = await Future.wait([
        RiderKycUploadService.compressImageSmart(rcFront!),
        RiderKycUploadService.compressImageSmart(rcBack!),
        RiderKycUploadService.compressImageSmart(vehiclePhoto!),
      ]);

      final paths = await Future.wait([
        RiderKycUploadService.uploadCompressedFile(file: compressed[0], fileName: 'rc_front', folderName: folder),
        RiderKycUploadService.uploadCompressedFile(file: compressed[1], fileName: 'rc_back', folderName: folder),
        RiderKycUploadService.uploadCompressedFile(file: compressed[2], fileName: 'vehicle_image', folderName: folder),
      ]);
      uploadedPaths.addAll(paths);

      // Store the bare storage path, not a public URL: the rider_kyc bucket is private
      // (20260731000004_rider_kyc_bucket_private.sql), so a getPublicUrl() value is dead on
      // arrival. This matches the already-fixed pattern in create-rider-kyc/index.ts -- any
      // future read site resolves a fresh signed URL from the path on demand.
      await supabase.from('rider_vehicles').insert({
        'rider_id': widget.riderId,
        'vehicle_type': vehicleType,
        'vehicle_number': vehicleNumberController.text.trim().toUpperCase(),
        'rc_front_image': paths[0],
        'rc_back_image': paths[1],
        'vehicle_image': paths[2],
      });

      if (!mounted) return;
      showAppSnackBar(context, 'Vehicle submitted for verification', type: SnackBarType.success);
      Navigator.pop(context, true);
    } catch (e) {
      debugPrint('ADD VEHICLE ERROR => $e');
      await RiderKycUploadService.rollbackFiles(uploadedPaths);
      if (!mounted) return;
      final detail = e is PostgrestException ? e.message : e.toString();
      showError('Failed to add vehicle: $detail');
    } finally {
      if (mounted) setState(() => submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !submitting,
      child: Scaffold(
        backgroundColor: const Color(0xFFF8FAFB),
        appBar: AppBar(
          backgroundColor: Colors.white,
          elevation: 0,
          centerTitle: true,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 18, color: Color(0xFF0F172A)),
            onPressed: submitting ? null : () => Navigator.pop(context),
          ),
          title: const Text(
            'Add Vehicle',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: Color(0xFF0F172A)),
          ),
        ),
        body: Stack(
          children: [
            SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('VEHICLE DETAILS', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: Color(0xFF0F172A))),
                  const SizedBox(height: 4),
                  const Text('Verify an additional vehicle without redoing your KYC', style: TextStyle(fontSize: 13, color: Color(0xFF94A3B8))),
                  const SizedBox(height: 24),

                  const Text('VEHICLE TYPE', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w900, color: Color(0xFF0F172A))),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: VehicleTypeChip(
                          value: 'bike',
                          imagePath: 'assets/images/bike.jpg',
                          label: 'Bike',
                          selected: vehicleType == 'bike',
                          onTap: () => setState(() => vehicleType = 'bike'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: VehicleTypeChip(
                          value: 'auto',
                          imagePath: 'assets/images/auto.jpg',
                          label: 'Auto',
                          selected: vehicleType == 'auto',
                          onTap: () => setState(() => vehicleType = 'auto'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: VehicleTypeChip(
                          value: 'cab',
                          imagePath: 'assets/images/cab.jpg',
                          label: 'Cab',
                          selected: vehicleType == 'cab',
                          onTap: () => setState(() => vehicleType = 'cab'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  KycTextField(
                    ctrl: vehicleNumberController,
                    hint: 'Vehicle Number (e.g. KA01XX1234)',
                    icon: Icons.text_fields_rounded,
                    textCapitalization: TextCapitalization.characters,
                  ),
                  const SizedBox(height: 24),

                  const Text('RC & VEHICLE DOCUMENTS', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w900, color: Color(0xFF0F172A))),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: const Color(0xFFE2E8F0)),
                    ),
                    child: Column(
                      children: [
                        DocUploadRow(
                          title: 'RC FRONT',
                          description: 'Front side of the Vehicle Registration Certificate (RC)',
                          image: rcFront,
                          onTap: () async {
                            final img = await pickKycImage(context);
                            if (img != null) setState(() => rcFront = img);
                          },
                        ),
                        DocUploadRow(
                          title: 'RC BACK',
                          description: 'Back side of the Vehicle Registration Certificate (RC)',
                          image: rcBack,
                          onTap: () async {
                            final img = await pickKycImage(context);
                            if (img != null) setState(() => rcBack = img);
                          },
                        ),
                        DocUploadRow(
                          title: 'VEHICLE PHOTO',
                          description: 'Full photo of the vehicle showing the registration plate clearly',
                          image: vehiclePhoto,
                          onTap: () async {
                            final img = await pickKycImage(context);
                            if (img != null) setState(() => vehiclePhoto = img);
                          },
                          last: true,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 36),
                  SizedBox(
                    width: double.infinity,
                    height: 54,
                    child: ElevatedButton(
                      onPressed: submitting ? null : _submit,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: primary,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      ),
                      child: submitting
                          ? const SizedBox(height: 22, width: 22, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5))
                          : const Text('SUBMIT FOR VERIFICATION', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
