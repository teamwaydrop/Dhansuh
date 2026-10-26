import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:waydrop/core/services/session/identity_operation_scope.dart';
import 'package:waydrop/features/rider/vehicles/vehicle_submission.dart';
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
final vehicleSubmissionProvider = Provider<VehicleSubmission>((ref) => VehicleSubmission(
  ownsRider: (account, rider) async => await Supabase.instance.client.from('riders')
      .select('id').eq('id', rider).eq('user_id', account).maybeSingle() != null,
  validate: RiderKycUploadService.validateImage,
  compress: RiderKycUploadService.compressImageSmart,
  upload: (file, name, folder, current) => RiderKycUploadService.uploadCompressedFile(
      file: file, fileName: name, folderName: folder, isCurrent: current),
  insert: (row) async { await Supabase.instance.client.from('rider_vehicles').insert(row); },
));

class AddVehicleScreen extends ConsumerStatefulWidget {
  final String riderId;

  const AddVehicleScreen({super.key, required this.riderId});

  @override
  ConsumerState<AddVehicleScreen> createState() => _AddVehicleScreenState();
}

class _AddVehicleScreenState extends ConsumerState<AddVehicleScreen> {
  final supabase = Supabase.instance.client;
  final vehicleNumberController = TextEditingController();

  String? vehicleType;
  XFile? rcFront, rcBack, vehiclePhoto;
  bool submitting = false;
  bool _retired = false;
  bool _writeUnconfirmed = false;
  int _routeGeneration = 0;
  late final IdentityOperationScope _operations;

  @override
  void initState() {
    super.initState();
    _operations = IdentityOperationScope.forWidget(() => mounted,
      onIdentityChanged: () {
        setState(() {
          ++_routeGeneration;
          _retired = true; submitting = false;
          vehicleType = null; rcFront = null; rcBack = null; vehiclePhoto = null;
          vehicleNumberController.clear();
        });
      });
  }

  @override
  void didUpdateWidget(covariant AddVehicleScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.riderId != widget.riderId) {
      ++_routeGeneration;
      _operations.begin(); // Retire the previous rider's in-flight operation.
      _retired = false; _writeUnconfirmed = false; submitting = false;
      vehicleType = null; rcFront = null; rcBack = null; vehiclePhoto = null;
      vehicleNumberController.clear();
    }
  }

  static const primary = kKycPrimaryColor;

  @override
  void dispose() {
    ++_routeGeneration;
    _operations.dispose();
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
    if (!mounted || submitting || _retired || _writeUnconfirmed || !_validate()) return;
    final user = supabase.auth.currentUser;
    if (user == null) { showError('Session expired'); return; }
    final operation = _operations.begin();
    final rider = widget.riderId;
    final generation = _routeGeneration;
    final type = vehicleType!;
    final number = vehicleNumberController.text.trim().toUpperCase();
    final files = [rcFront!, rcBack!, vehiclePhoto!];
    bool current() => !_retired && operation.isCurrent && widget.riderId == rider &&
        generation == _routeGeneration;
    setState(() => submitting = true);
    final folder = '${user.id}/vehicles/${DateTime.now().millisecondsSinceEpoch}';
    try {
      await ref.read(vehicleSubmissionProvider).run(account: user.id, rider: rider,
        type: type, number: number, files: files, folder: folder, isCurrent: current);
      if (!mounted || !current()) return;
      showAppSnackBar(context, 'Vehicle submitted for verification', type: SnackBarType.success);
      Navigator.pop(context, true);
    } on RetiredVehicleSubmission {
      // Retired operations never navigate or give feedback to a replacement account.
    } on VehicleSubmissionWriteUnconfirmed {
      if (!mounted || !current()) return;
      setState(() => _writeUnconfirmed = true);
      showError('Confirmation unavailable. Refresh My Vehicles before retrying.');
    } catch (e) {
      if (!current()) return;
      debugPrint('ADD_VEHICLE outcome=submission_failure');
      final detail = e is PostgrestException ? e.message : e.toString();
      showError('Failed to confirm vehicle submission: $detail');
    } finally {
      if (current()) setState(() => submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_retired) {
      return Scaffold(appBar: AppBar(title: const Text('Add Vehicle')),
        body: const Center(child: Text('Account changed. Return to My Vehicles to continue.')));
    }
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
                            final account = supabase.auth.currentUser?.id;
                            final rider = widget.riderId;
                            final generation = _routeGeneration;
                            final img = await pickKycImage(context);
                            if (!mounted || _retired || account != supabase.auth.currentUser?.id || rider != widget.riderId || generation != _routeGeneration) return;
                            if (img != null) setState(() => rcFront = img);
                          },
                        ),
                        DocUploadRow(
                          title: 'RC BACK',
                          description: 'Back side of the Vehicle Registration Certificate (RC)',
                          image: rcBack,
                          onTap: () async {
                            final account = supabase.auth.currentUser?.id;
                            final rider = widget.riderId;
                            final generation = _routeGeneration;
                            final img = await pickKycImage(context);
                            if (!mounted || _retired || account != supabase.auth.currentUser?.id || rider != widget.riderId || generation != _routeGeneration) return;
                            if (img != null) setState(() => rcBack = img);
                          },
                        ),
                        DocUploadRow(
                          title: 'VEHICLE PHOTO',
                          description: 'Full photo of the vehicle showing the registration plate clearly',
                          image: vehiclePhoto,
                          onTap: () async {
                            final account = supabase.auth.currentUser?.id;
                            final rider = widget.riderId;
                            final generation = _routeGeneration;
                            final img = await pickKycImage(context);
                            if (!mounted || _retired || account != supabase.auth.currentUser?.id || rider != widget.riderId || generation != _routeGeneration) return;
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
                      onPressed: submitting || _writeUnconfirmed ? null : _submit,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: primary,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      ),
                      child: submitting
                          ? const SizedBox(height: 22, width: 22, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5))
                          : Text(_writeUnconfirmed ? 'REFRESH MY VEHICLES BEFORE RETRYING' : 'SUBMIT FOR VERIFICATION', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
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
