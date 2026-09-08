import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:waydrop/features/rider/onboarding/screens/rider_kyc_pending_screen.dart';
import 'package:waydrop/features/rider/onboarding/screens/rider_entry_handler.dart';
import 'package:waydrop/features/rider/onboarding/services/rider_kyc_upload_service.dart';
import 'package:waydrop/features/rider/onboarding/models/kyc_upload_state.dart';
import 'package:waydrop/shared/widgets/app_snackbar.dart';
import 'package:waydrop/shared/widgets/kyc/kyc_upload_widgets.dart';

class RiderKycScreen extends StatefulWidget {
  const RiderKycScreen({super.key});

  @override
  State<RiderKycScreen> createState() => _RiderKycScreenState();
}

class _RiderKycScreenState extends State<RiderKycScreen> {
  final PageController pageController = PageController();
  final picker = ImagePicker();
  int currentStep = 0;
  bool loading = false;
  bool isSubmitting = false;
  bool consent = false;

  final fullNameController = TextEditingController();
  final fatherNameController = TextEditingController();
  final ageController = TextEditingController();
  final vehicleNumberController = TextEditingController();
  String? vehicleType;
  DateTime? dateOfBirth;
  int rejectionCount = 0;

  final aadhaarController = TextEditingController();
  final panController = TextEditingController();
  final dlController = TextEditingController();

  final beneficiaryNameController = TextEditingController();
  final beneficiaryPhoneController = TextEditingController();
  final accountNumberController = TextEditingController();
  final confirmAccountNumberController = TextEditingController();
  final ifscController = TextEditingController();
  final upiController = TextEditingController();

  XFile? aadhaarFront, aadhaarBack;
  XFile? panFront, panBack;
  XFile? licenseFront, licenseBack;
  XFile? riderSelfie, vehicleImage;
  XFile? vehicleRcFront, vehicleRcBack;

  // Upload-session state: replaces the old "batch upload everything at Submit" flow. Each
  // document uploads immediately on pick (see _uploadDoc) and this tracks per-document
  // status/remote-path, persisted to SharedPreferences so it survives an app kill (see
  // _initializeUploadSession / _persistUploadSession).
  KycUploadSession? _uploadSession;

  bool _isRestoring = false;

  static const primary = Color(0xFF2563EB);

  @override
  void initState() {
    super.initState();
    _loadKycState().then((_) {
      fullNameController.addListener(_saveKycState);
      fatherNameController.addListener(_saveKycState);
      vehicleNumberController.addListener(_saveKycState);
      aadhaarController.addListener(_saveKycState);
      panController.addListener(_saveKycState);
      dlController.addListener(_saveKycState);
      beneficiaryNameController.addListener(_saveKycState);
      beneficiaryPhoneController.addListener(_saveKycState);
      accountNumberController.addListener(_saveKycState);
      confirmAccountNumberController.addListener(_saveKycState);
      ifscController.addListener(_saveKycState);
      upiController.addListener(_saveKycState);
    });
  }

  Future<void> _saveKycState() async {
    if (_isRestoring) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('kyc_current_step', currentStep);
      await prefs.setBool('kyc_consent', consent);
      
      await prefs.setString('kyc_full_name', fullNameController.text);
      await prefs.setString('kyc_father_name', fatherNameController.text);
      await prefs.setString('kyc_date_of_birth', dateOfBirth?.toIso8601String() ?? '');
      await prefs.setString('kyc_vehicle_type', vehicleType ?? '');
      await prefs.setString('kyc_vehicle_number', vehicleNumberController.text);
      await prefs.setString('kyc_aadhaar_number', aadhaarController.text);
      await prefs.setString('kyc_pan_number', panController.text);
      await prefs.setString('kyc_dl_number', dlController.text);
      await prefs.setString('kyc_beneficiary_name', beneficiaryNameController.text);
      await prefs.setString('kyc_beneficiary_phone', beneficiaryPhoneController.text);
      await prefs.setString('kyc_account_number', accountNumberController.text);
      await prefs.setString('kyc_confirm_account_number', confirmAccountNumberController.text);
      await prefs.setString('kyc_ifsc_code', ifscController.text);
      await prefs.setString('kyc_upi_vpa', upiController.text);
      // Document local paths + upload status now live in _uploadSession (see
      // _persistUploadSession) -- not duplicated here.
    } catch (e) {
      debugPrint('Error saving KYC state: $e');
    }
  }

  Future<void> _loadKycState() async {
    setState(() { _isRestoring = true; });
    try {
      final supabase = Supabase.instance.client;
      final user = supabase.auth.currentUser;
      if (user != null) {
        // Egress fix: narrowed to the fields read directly below plus the 2 fields
        // KycBlockedScreen(kyc: kycResponse) reads from this same map (blocked_until,
        // rejection_reason -- already audited when that widget's own file, rider_entry_handler.dart,
        // was narrowed in a previous pass).
        final kycResponse = await supabase
            .from('rider_kyc')
            .select('rejection_count, kyc_status, blocked_until, rejection_reason')
            .eq('user_id', user.id)
            .maybeSingle()
            .timeout(const Duration(seconds: 15));

        if (kycResponse != null) {
          rejectionCount = kycResponse['rejection_count'] ?? 0;
          final String kycStatus = kycResponse['kyc_status'] ?? 'pending';
          final String? blockedUntilStr = kycResponse['blocked_until'];

          if (blockedUntilStr != null) {
            final blockedUntil = DateTime.tryParse(blockedUntilStr);
            if (blockedUntil != null && blockedUntil.isAfter(DateTime.now())) {
              if (mounted) {
                Navigator.pushReplacement(context, MaterialPageRoute(
                  builder: (_) => KycBlockedScreen(kyc: kycResponse),
                ));
                return;
              }
            }
          }

          if (kycStatus == 'pending' || kycStatus == 'under_review' || kycStatus == 'resubmitted') {
            if (mounted) {
              Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const RiderKycPendingScreen()));
              return;
            }
          } else if (kycStatus == 'approved') {
            // Egress fix: existence-only check below.
            final riderResponse = await supabase
                .from('riders')
                .select('id')
                .eq('user_id', user.id)
                .maybeSingle()
                .timeout(const Duration(seconds: 15));
            final bool riderExists = riderResponse != null;
            if (mounted) {
              if (riderExists) {
                Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const WelcomeRiderScreen()));
              } else {
                Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const KycVerifiedWaitingScreen()));
              }
              return;
            }
          }
        }
      }

      // Reached only when no rider_kyc row exists yet, or one exists as 'rejected' with its
      // cooldown already expired (see the redirects above) -- exactly the two cases where the
      // document pickers below are reachable. Resolves fresh-vs-resume for the upload session
      // before restoring anything else.
      await _initializeUploadSession();
      await _recoverLostSelfieCapture();

      final prefs = await SharedPreferences.getInstance();
      if (prefs.containsKey('kyc_current_step')) {
        currentStep = prefs.getInt('kyc_current_step') ?? 0;
        consent = prefs.getBool('kyc_consent') ?? false;
        
        fullNameController.text = prefs.getString('kyc_full_name') ?? '';
        fatherNameController.text = prefs.getString('kyc_father_name') ?? '';
        final dobStr = prefs.getString('kyc_date_of_birth') ?? '';
        if (dobStr.isNotEmpty) {
          dateOfBirth = DateTime.tryParse(dobStr);
        }
        final vt = prefs.getString('kyc_vehicle_type') ?? '';
        vehicleType = vt.isEmpty ? null : vt;
        vehicleNumberController.text = prefs.getString('kyc_vehicle_number') ?? '';
        aadhaarController.text = prefs.getString('kyc_aadhaar_number') ?? '';
        panController.text = prefs.getString('kyc_pan_number') ?? '';
        dlController.text = prefs.getString('kyc_dl_number') ?? '';
        beneficiaryNameController.text = prefs.getString('kyc_beneficiary_name') ?? '';
        beneficiaryPhoneController.text = prefs.getString('kyc_beneficiary_phone') ?? '';
        accountNumberController.text = prefs.getString('kyc_account_number') ?? '';
        confirmAccountNumberController.text = prefs.getString('kyc_confirm_account_number') ?? '';
        ifscController.text = prefs.getString('kyc_ifsc_code') ?? '';
        upiController.text = prefs.getString('kyc_upi_vpa') ?? '';
        // Document local paths/status are restored by _initializeUploadSession above, not here.

        if (!mounted) return;
        setState(() {});

        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (pageController.hasClients) {
            pageController.jumpToPage(currentStep);
          }
        });
      }
    } catch (e) {
      debugPrint('Error loading KYC state: $e');
    } finally {
      if (mounted) {
        setState(() { _isRestoring = false; });
      }
    }
  }

  // ─────────────────────── Upload Session ───────────────────────
  // Replaces the old batch-upload-at-Submit flow: each document uploads immediately on pick
  // (see _uploadDoc) and the session below tracks per-document status, persisted across app
  // restarts and reconciled against real storage contents on resume.

  static const _uploadSessionPrefsKey = 'kyc_upload_session_v1';

  Future<void> _initializeUploadSession() async {
    try {
      final info = await RiderKycUploadService.resolveAttemptInfo();
      final prefs = await SharedPreferences.getInstance();
      final existing = KycUploadSession.tryDecode(prefs.getString(_uploadSessionPrefsKey));

      KycUploadSession session;
      if (existing != null && existing.attemptNumber == info.attemptNumber) {
        // Same attempt as last time this screen was open -- resume it. Reconcile every slot
        // against a single batched storage listing rather than trusting local state blindly:
        // this catches both an upload interrupted mid-flight by an app kill, and a long-abandoned
        // draft whose files the cleanup job may have since reclaimed.
        session = existing;
        final present = await RiderKycUploadService.listSessionFolder(session.sessionFolder);
        // `present == null` means the listing call itself failed (e.g. no network right now) --
        // inconclusive, not proof of absence.
        for (final slot in KycDocSlot.values) {
          final doc = session.docs[slot]!;
          // Every upload writes to a path suffixed with its own pickGeneration (see
          // RiderKycUploadService.uploadSingleDocument), so what "this slot's file" means on
          // resume is always the object matching the LOCALLY-persisted generation -- never a
          // fixed name every generation could collide on. Local state already forgets older
          // generations the instant a re-pick happens (one status/remotePath per slot, not a
          // history), so there is nothing else to reconcile against.
          final expectedName = '${slot.storageFileName}_g${doc.pickGeneration}.jpg';
          if (doc.status == KycUploadStatus.uploading) {
            // No active upload is actually running after a cold start, and this state has no
            // retry action in the UI -- it must always resolve to something concrete, using the
            // listing when available and falling back to failed (which the user CAN retry) when
            // the listing itself is inconclusive, rather than stranding it in "uploading" forever.
            final actuallyPresent = present?.contains(expectedName) ?? false;
            session = session.copyWithDoc(
              slot,
              doc.copyWith(status: actuallyPresent ? KycUploadStatus.uploaded : KycUploadStatus.failed),
            );
          } else if (doc.status == KycUploadStatus.uploaded &&
              present != null &&
              !present.contains(expectedName)) {
            // Only demote an already-confirmed upload when the listing definitively shows it's
            // gone (e.g. reclaimed by the abandoned-upload cleanup job) -- never merely because the
            // listing call itself failed, which is inconclusive and previously forced a pointless
            // re-upload of an already-durable document whenever resume happened to run offline.
            session = session.copyWithDoc(slot, doc.copyWith(status: KycUploadStatus.failed));
          }
        }
      } else {
        // First time, or a new rejection cycle started since the last local session -- start
        // fresh. The random suffix keeps this folder distinct even if another device/process
        // resolves the same attempt number concurrently.
        final folder = RiderKycUploadService.buildFreshSessionFolder(
          userId: info.userId,
          phone: info.phone,
          attemptNumber: info.attemptNumber,
        );
        session = KycUploadSession.fresh(sessionFolder: folder, attemptNumber: info.attemptNumber);
      }

      _uploadSession = session;
      await _persistUploadSession();

      // Restore local file references (for thumbnails / possible re-upload) for slots that still
      // have a usable local file. Never applied to an 'uploaded' slot -- once bytes are durably
      // in storage, local temp-file eviction (common on iOS between launches) is irrelevant.
      for (final slot in KycDocSlot.values) {
        final doc = session.docs[slot]!;
        if (doc.status == KycUploadStatus.uploaded) continue;
        final path = doc.localPath;
        if (path == null || path.isEmpty || !await File(path).exists()) continue;
        _assignLocalXFile(slot, XFile(path));
      }
    } catch (e) {
      debugPrint('Error initializing KYC upload session: $e');
    }
  }

  Future<void> _persistUploadSession() async {
    final session = _uploadSession;
    if (session == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_uploadSessionPrefsKey, session.encode());
    } catch (e) {
      debugPrint('Error persisting KYC upload session: $e');
    }
  }

  void _assignLocalXFile(KycDocSlot slot, XFile file) {
    switch (slot) {
      case KycDocSlot.riderSelfie: riderSelfie = file; break;
      case KycDocSlot.aadhaarFront: aadhaarFront = file; break;
      case KycDocSlot.aadhaarBack: aadhaarBack = file; break;
      case KycDocSlot.panFront: panFront = file; break;
      case KycDocSlot.panBack: panBack = file; break;
      case KycDocSlot.licenseFront: licenseFront = file; break;
      case KycDocSlot.licenseBack: licenseBack = file; break;
      case KycDocSlot.vehicleImage: vehicleImage = file; break;
      case KycDocSlot.vehicleRcFront: vehicleRcFront = file; break;
      case KycDocSlot.vehicleRcBack: vehicleRcBack = file; break;
    }
  }

  /// Uploads one document immediately. Never batched with any other document's upload (no
  /// `Future.wait()` here or anywhere in this flow) -- each call is independent so one document's
  /// failure/retry never blocks or restarts the others. Duplicate-tap-proof: a re-pick of the
  /// same slot bumps its generation, and both this function's own stale-check and the service's
  /// internal `isStale` callback discard a superseded attempt's result instead of clobbering a
  /// newer pick.
  Future<void> _uploadDoc(KycDocSlot slot, XFile file) async {
    final session = _uploadSession;
    if (session == null) return;
    final current = session.docs[slot]!;
    final generation = current.pickGeneration + 1;

    setState(() {
      _uploadSession = session.copyWithDoc(
        slot,
        current.copyWith(
          status: KycUploadStatus.uploading,
          localPath: file.path,
          pickGeneration: generation,
          clearLastError: true,
        ),
      );
    });
    await _persistUploadSession();

    bool isCurrentGeneration() => _uploadSession?.docs[slot]?.pickGeneration == generation;

    try {
      final remotePath = await RiderKycUploadService.uploadSingleDocument(
        slot: slot,
        file: file,
        sessionFolder: session.sessionFolder,
        pickGeneration: generation,
        isStale: () => !isCurrentGeneration(),
      );
      if (!mounted || !isCurrentGeneration()) return; // superseded meanwhile -- discard silently
      setState(() {
        final latest = _uploadSession!;
        _uploadSession = latest.copyWithDoc(
          slot,
          latest.docs[slot]!.copyWith(status: KycUploadStatus.uploaded, remotePath: remotePath, clearLastError: true),
        );
      });
      await _persistUploadSession();
    } on StaleUploadException {
      // A newer pick already superseded this attempt -- nothing to show the user.
    } on KycUploadAuthException catch (e) {
      if (!mounted || !isCurrentGeneration()) return;
      setState(() {
        final latest = _uploadSession!;
        _uploadSession = latest.copyWithDoc(slot, latest.docs[slot]!.copyWith(status: KycUploadStatus.failed, lastError: e.message));
      });
      await _persistUploadSession();
      showError(e.message);
    } catch (e) {
      if (!mounted || !isCurrentGeneration()) return; // superseded -- don't surface a stale error
      setState(() {
        final latest = _uploadSession!;
        _uploadSession = latest.copyWithDoc(
          slot,
          latest.docs[slot]!.copyWith(
            status: KycUploadStatus.failed,
            attempts: latest.docs[slot]!.attempts + 1,
            lastError: e.toString(),
          ),
        );
      });
      await _persistUploadSession();
    }
  }

  /// Retries a failed document upload using its already-picked local file (re-picking is only
  /// needed if that local file no longer exists, e.g. iOS evicted the temp path).
  Future<void> _retryDoc(KycDocSlot slot) async {
    final doc = _uploadSession?.docs[slot];
    final path = doc?.localPath;
    if (path == null || path.isEmpty || !await File(path).exists()) {
      showError('That file is no longer available -- please pick it again.');
      return;
    }
    unawaited(_uploadDoc(slot, XFile(path)));
  }

  DocUploadStatus? _statusFor(KycDocSlot slot) {
    switch (_uploadSession?.docs[slot]?.status) {
      case KycUploadStatus.uploading:
        return DocUploadStatus.uploading;
      case KycUploadStatus.uploaded:
        return DocUploadStatus.uploaded;
      case KycUploadStatus.failed:
        return DocUploadStatus.failed;
      case KycUploadStatus.idle:
      case KycUploadStatus.picked:
      case null:
        return null;
    }
  }

  /// Returns an error message if [slot] isn't uploaded yet, or null if it's ready. Used by both
  /// the per-step "Continue" gate and the Final Submit gate so a user can never advance past (or
  /// submit with) a document that's still uploading, failed, or never picked.
  String? _uploadIssueMessage(KycDocSlot slot, String label) {
    switch (_uploadSession?.docs[slot]?.status) {
      case KycUploadStatus.uploaded:
        return null;
      case KycUploadStatus.uploading:
        return '$label is still uploading -- please wait a moment';
      case KycUploadStatus.failed:
        return '$label upload failed -- tap Retry';
      case KycUploadStatus.idle:
      case KycUploadStatus.picked:
      case null:
        return 'Upload $label';
    }
  }

  Future<void> _clearSavedState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('kyc_current_step');
      await prefs.remove('kyc_consent');
      await prefs.remove('kyc_full_name');
      await prefs.remove('kyc_father_name');
      await prefs.remove('kyc_date_of_birth');
      await prefs.remove('kyc_vehicle_type');
      await prefs.remove('kyc_vehicle_number');
      await prefs.remove('kyc_aadhaar_number');
      await prefs.remove('kyc_pan_number');
      await prefs.remove('kyc_dl_number');
      await prefs.remove('kyc_beneficiary_name');
      await prefs.remove('kyc_beneficiary_phone');
      await prefs.remove('kyc_account_number');
      await prefs.remove('kyc_confirm_account_number');
      await prefs.remove('kyc_ifsc_code');
      await prefs.remove('kyc_upi_vpa');
      await prefs.remove(_uploadSessionPrefsKey);
    } catch (e) {
      debugPrint('Error clearing saved state: $e');
    }
  }

  // ─────────────────────── Navigation ───────────────────────
  void nextStep() {
    FocusScope.of(context).unfocus();
    pageController.nextPage(duration: const Duration(milliseconds: 260), curve: Curves.easeInOut);
  }

  void previousStep() {
    FocusScope.of(context).unfocus();
    pageController.previousPage(duration: const Duration(milliseconds: 260), curve: Curves.easeInOut);
  }

  // ─────────────────────── Image Picker ───────────────────────
  Future<XFile?> pickImage() => pickKycImage(context);

  // ─────────────────────── Snackbars ───────────────────────
  void showError(String message) {
    showAppSnackBar(context, message, type: SnackBarType.error);
  }

  // ─────────────────────── Validation ───────────────────────
  bool validateCurrentStep() {
    if (currentStep == 1) {
      final name = fullNameController.text.trim();
      if (name.length < 3) { showError('Invalid full name (minimum 3 characters required)'); return false; }
      final fName = fatherNameController.text.trim();
      if (fName.length < 3) { showError('Invalid father name (minimum 3 characters required)'); return false; }
      if (dateOfBirth == null) { showError('Select your Date of Birth'); return false; }
      final today = DateTime.now();
      int age = today.year - dateOfBirth!.year;
      final monthDiff = today.month - dateOfBirth!.month;
      if (monthDiff < 0 || (monthDiff == 0 && today.day < dateOfBirth!.day)) {
        age--;
      }
      if (age < 18) { showError('You must be at least 18 years old'); return false; }
      if (vehicleType == null) { showError('Please select a vehicle type'); return false; }
      if (vehicleNumberController.text.trim().isEmpty) { showError('Enter vehicle number'); return false; }
    }
    if (currentStep == 2) {
      final aadhaar = aadhaarController.text.replaceAll(' ', '');
      if (aadhaar.length != 12) { showError('Enter valid 12-digit Aadhaar'); return false; }
      final frontIssue = _uploadIssueMessage(KycDocSlot.aadhaarFront, 'Aadhaar front');
      if (frontIssue != null) { showError(frontIssue); return false; }
      final backIssue = _uploadIssueMessage(KycDocSlot.aadhaarBack, 'Aadhaar back');
      if (backIssue != null) { showError(backIssue); return false; }
    }
    if (currentStep == 3) {
      final panRegex = RegExp(r'^[A-Z]{5}[0-9]{4}[A-Z]{1}$');
      if (!panRegex.hasMatch(panController.text.trim().toUpperCase())) { showError('PAN Card format must be ABCDE1234F (5 letters, 4 digits, 1 letter)'); return false; }
      final panFrontIssue = _uploadIssueMessage(KycDocSlot.panFront, 'PAN front');
      if (panFrontIssue != null) { showError(panFrontIssue); return false; }
      final panBackIssue = _uploadIssueMessage(KycDocSlot.panBack, 'PAN back');
      if (panBackIssue != null) { showError(panBackIssue); return false; }
      if (dlController.text.trim().isEmpty) { showError('Enter driving license number'); return false; }
      final licenseFrontIssue = _uploadIssueMessage(KycDocSlot.licenseFront, 'License front');
      if (licenseFrontIssue != null) { showError(licenseFrontIssue); return false; }
      final licenseBackIssue = _uploadIssueMessage(KycDocSlot.licenseBack, 'License back');
      if (licenseBackIssue != null) { showError(licenseBackIssue); return false; }
    }
    if (currentStep == 4) {
      final selfieIssue = _uploadIssueMessage(KycDocSlot.riderSelfie, 'Rider selfie');
      if (selfieIssue != null) { showError(selfieIssue); return false; }
      final vehicleIssue = _uploadIssueMessage(KycDocSlot.vehicleImage, 'Vehicle photo');
      if (vehicleIssue != null) { showError(vehicleIssue); return false; }
      final rcFrontIssue = _uploadIssueMessage(KycDocSlot.vehicleRcFront, 'RC front');
      if (rcFrontIssue != null) { showError(rcFrontIssue); return false; }
      final rcBackIssue = _uploadIssueMessage(KycDocSlot.vehicleRcBack, 'RC back');
      if (rcBackIssue != null) { showError(rcBackIssue); return false; }
    }

    return true;
  }

  // ─────────────────────── Submit ───────────────────────
  static const _validateTimeout = Duration(seconds: 20);
  static const _createTimeout = Duration(seconds: 20);

  /// Messages returned by validate-rider-kyc / create-rider-kyc that mean
  /// "a KYC record already exists and is pending/under review" — this must
  /// route straight to the pending screen instead of being shown as a
  /// generic submission error, otherwise a client retry after a lost
  /// response (e.g. the create call succeeded server-side but the reply
  /// never reached the app) looks like a failure when it was actually a
  /// success.
  bool _isAlreadyPendingMessage(String? message) {
    if (message == null) return false;
    final m = message.toLowerCase();
    return m.contains('already submitted') ||
        m.contains('already under review') ||
        m.contains('already approved');
  }

  /// Submit no longer uploads anything -- every document was already uploaded the instant it was
  /// picked (see _uploadDoc). This only validates that every required upload has already
  /// completed, then calls validate-rider-kyc -> create-rider-kyc exactly as before. On failure,
  /// uploaded files are NOT rolled back (a deliberate change from the old batch flow) -- they're
  /// durable and independent of submit outcome, so the user can just tap Submit again.
  Future<void> submitKyc() async {
    if (isSubmitting) return; // guard against duplicate/rapid double-taps
    FocusScope.of(context).unfocus();

    final session = _uploadSession;
    if (session == null || !session.allUploaded) {
      showError('Please wait for all documents to finish uploading before submitting.');
      return;
    }

    final aadhaar = aadhaarController.text.replaceAll(' ', '');
    final pan = panController.text.trim().toUpperCase();
    final dl = dlController.text.trim().toUpperCase();
    final dobFormatted = dateOfBirth != null
        ? "${dateOfBirth!.year.toString().padLeft(4, '0')}-${dateOfBirth!.month.toString().padLeft(2, '0')}-${dateOfBirth!.day.toString().padLeft(2, '0')}"
        : "";

    if (!mounted) return;
    setState(() { loading = true; isSubmitting = true; });

    final supabase = Supabase.instance.client;
    final user = supabase.auth.currentUser;
    if (user == null) { setState(() { loading = false; isSubmitting = false; }); showError('Session expired'); return; }

    try {
      final validateResponse = await supabase.functions.invoke('validate-rider-kyc', body: {
        'user_id': user.id,
        'full_name': fullNameController.text.trim(),
        'father_name': fatherNameController.text.trim(),
        'date_of_birth': dobFormatted,
        'vehicle_type': vehicleType,
        'vehicle_number': vehicleNumberController.text.trim(),
        'aadhaar_number': aadhaar,
        'pan_number': pan,
        'driving_license_number': dl,
      }).timeout(_validateTimeout);

      if (validateResponse.status != 200 || validateResponse.data == null || validateResponse.data['success'] != true) {
        setState(() { loading = false; isSubmitting = false; });
        final message = validateResponse.data?['message'] as String?;
        if (_isAlreadyPendingMessage(message)) {
          _clearForm();
          if (!mounted) return;
          Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const RiderKycPendingScreen()));
          return;
        }
        showError(message ?? 'Validation failed');
        return;
      }

      // Defensive: every remote path about to be sent must actually belong to THIS session's
      // folder -- cheap insurance against a resume/reconciliation bug silently sending a path
      // from a stale or foreign session.
      final uploads = <String, String>{};
      for (final slot in KycDocSlot.values) {
        final path = session.docs[slot]!.remotePath;
        if (path == null || !path.startsWith('${session.sessionFolder}/')) {
          setState(() { loading = false; isSubmitting = false; });
          showError('Upload state looks out of date -- please retry the affected document.');
          return;
        }
        uploads[slot.createRiderKycField] = path;
      }

      final response = await supabase.functions.invoke('create-rider-kyc', body: {
        'user_id': user.id,
        'full_name': fullNameController.text.trim(),
        'father_name': fatherNameController.text.trim(),
        'date_of_birth': dobFormatted,
        'vehicle_type': vehicleType,
        'vehicle_number': vehicleNumberController.text.trim(),
        'aadhaar_number': aadhaar,
        'pan_number': pan,
        'driving_license_number': dl,
        ...uploads,
      }).timeout(_createTimeout);

      if (response.status != 200 || response.data == null || response.data['success'] != true) {
        final message = response.data?['message'] as String?;
        if (_isAlreadyPendingMessage(message)) {
          // The record already exists server-side (e.g. a previous attempt's response was lost
          // but the insert/update actually went through) -- a success outcome, not a failure.
          _clearForm();
          if (!mounted) return;
          setState(() { loading = false; isSubmitting = false; });
          Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const RiderKycPendingScreen()));
          return;
        }
        // No rollback: the uploaded files stay exactly as they are, so retrying Submit is instant.
        throw Exception(message ?? 'KYC submission failed');
      }

      _clearForm();
      if (!mounted) return;
      setState(() { loading = false; isSubmitting = false; });
      showAppSnackBar(context, 'KYC Submitted Successfully', type: SnackBarType.success);
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const RiderKycPendingScreen()));
    } on TimeoutException catch (e) {
      // A timeout only means the client gave up waiting, not that the request never reached the
      // server -- create-rider-kyc is idempotent for an existing pending record, and no files
      // were ever at risk here (nothing uploads during Submit anymore), so just let the user retry.
      if (!mounted) return;
      setState(() { loading = false; isSubmitting = false; });
      showError('Request timed out. Please check your connection and tap Submit to retry.');
    } catch (e) {
      if (!mounted) return;
      setState(() { loading = false; isSubmitting = false; });
      String errMsg = e.toString();
      if (e is FunctionException) {
        String detailsMsg = '';
        if (e.details is Map && (e.details as Map).containsKey('message')) {
          detailsMsg = (e.details as Map)['message']?.toString() ?? '';
        } else if (e.details != null) {
          detailsMsg = e.details.toString();
        }
        if (detailsMsg.isEmpty) {
          detailsMsg = e.reasonPhrase ?? 'Unknown function error';
        }
        errMsg = 'Error (${e.status}): $detailsMsg';
      }
      showError(errMsg);
    }
  }

  // Persisted before the camera Intent launches, cleared once picker.pickImage() returns by any
  // path (success, cancel, or error). Its only job is answering "was a selfie capture in flight
  // when this process last ran" on the NEXT cold start -- see _recoverLostSelfieCapture below for
  // why that question matters.
  static const _selfiePickPendingPrefsKey = 'kyc_selfie_pick_pending';

  Future<void> pickSelfieImage() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_selfiePickPendingPrefsKey, true);
    try {
      debugPrint('[TRACE_KYC_SELFIE] picker.pickImage(camera) START epoch=${DateTime.now().millisecondsSinceEpoch}');
      final picked = await picker.pickImage(source: ImageSource.camera, preferredCameraDevice: CameraDevice.front, imageQuality: 90);
      debugPrint('[TRACE_KYC_SELFIE] picker.pickImage(camera) DONE epoch=${DateTime.now().millisecondsSinceEpoch} path=${picked?.path}');
      if (picked == null) return;
      if (!mounted) return;
      setState(() => riderSelfie = picked);
      // Uploads immediately -- _uploadDoc's first step (before any compression/network work) is
      // itself a synchronous setState + persist of the picked local path, so the memory-pressure
      // window right after the camera intent is already covered without needing to await the
      // full upload here.
      unawaited(_uploadDoc(KycDocSlot.riderSelfie, picked));
    } catch (e) {
      if (!mounted) return;
      showError('Failed to capture selfie');
    } finally {
      // picker.pickImage() returned (by any path), so the process survived -- nothing to recover
      // on the next launch. Left set ONLY if the process was killed mid-await, which is exactly
      // the signal _recoverLostSelfieCapture() looks for.
      await prefs.setBool(_selfiePickPendingPrefsKey, false);
    }
  }

  /// Recovers a selfie capture that completed in the native Camera app but never made it back
  /// into this screen because Android reclaimed this app's process while the Camera activity was
  /// in the foreground -- common on mid/low-RAM devices, since a camera activity is memory-heavy
  /// and backgrounded apps are the OS's first target. When that happens, `picker.pickImage()`'s
  /// Future simply never resolves (the isolate that was awaiting it no longer exists), so from the
  /// app's perspective the selfie is silently lost even though the file exists and Android already
  /// has it queued for delivery -- the user sees WayDrop cold-start back to its splash screen
  /// (indistinguishable from "the app restarted"), and has to redo the capture.
  ///
  /// `image_picker` exposes exactly this recovery path for Android:
  /// `ImagePicker.retrieveLostData()` returns the file from the most recent pick that was in
  /// flight when the process died, the first time it's called after the new process starts. It
  /// does not identify which on-screen picker call it came from, so `_selfiePickPendingPrefsKey`
  /// (set immediately before the camera launches, cleared the instant `pickImage()` returns by any
  /// path) is what tells this method the recovered file -- if any -- belongs to the selfie step
  /// and not some other flow. On iOS this plugin call is a documented no-op (iOS does not lose
  /// picker results this way), so this is unconditionally safe to run on every cold start.
  Future<void> _recoverLostSelfieCapture() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final wasPending = prefs.getBool(_selfiePickPendingPrefsKey) ?? false;
      if (!wasPending) return;
      await prefs.setBool(_selfiePickPendingPrefsKey, false);

      final response = await picker.retrieveLostData();
      if (response.isEmpty || response.file == null) return;

      final recovered = response.file!;
      if (!mounted) return;
      setState(() => riderSelfie = recovered);
      unawaited(_uploadDoc(KycDocSlot.riderSelfie, recovered));
    } catch (e) {
      debugPrint('Error recovering lost selfie capture: $e');
    }
  }

  void _clearForm() {
    _clearSavedState();
    fullNameController.clear(); fatherNameController.clear();
    aadhaarController.clear(); panController.clear(); dlController.clear(); vehicleNumberController.clear();
    beneficiaryNameController.clear(); beneficiaryPhoneController.clear();
    accountNumberController.clear(); confirmAccountNumberController.clear();
    ifscController.clear(); upiController.clear();
    riderSelfie = aadhaarFront = aadhaarBack = panFront = panBack = licenseFront = licenseBack = vehicleImage = null;
    vehicleRcFront = vehicleRcBack = null;
    vehicleType = null;
    dateOfBirth = null;
    _uploadSession = null;
  }

  @override
  void dispose() {
    pageController.dispose();
    fullNameController.dispose(); fatherNameController.dispose(); ageController.dispose();
    aadhaarController.dispose(); panController.dispose(); dlController.dispose(); vehicleNumberController.dispose();
    beneficiaryNameController.dispose(); beneficiaryPhoneController.dispose();
    accountNumberController.dispose(); confirmAccountNumberController.dispose();
    ifscController.dispose(); upiController.dispose();
    super.dispose();
  }

  // ─────────────────────── Build ───────────────────────
  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: currentStep == 0 && !isSubmitting,
      onPopInvokedWithResult: (didPop, result) {
        if (isSubmitting) return;
        if (!didPop && currentStep > 0) previousStep();
      },
      child: Scaffold(
        backgroundColor: const Color(0xFFF8FAFB),
        body: Stack(
          children: [
            SafeArea(
              child: Column(
                children: [
                  _buildHeader(),
                  Expanded(
                    child: PageView(
                      controller: pageController,
                      physics: const NeverScrollableScrollPhysics(),
                      onPageChanged: (v) {
                        setState(() => currentStep = v);
                        _saveKycState();
                      },
                      children: [_introStep(), _personalStep(), _aadhaarStep(), _panDlStep(), _selfieStep(), _reviewStep()],
                    ),
                  ),
                ],
              ),
            ),
            if (isSubmitting)
              Container(
                color: Colors.black.withValues(alpha: 0.5),
                child: const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(color: primary, strokeWidth: 3),
                      SizedBox(height: 16),
                      Text('Submitting KYC...', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 15)),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ─────────────────────── Header ───────────────────────
  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Column(
        children: [
          Row(
            children: [
              if (currentStep != 0)
                GestureDetector(
                  onTap: previousStep,
                  child: Container(
                    width: 40, height: 40,
                    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: const Color(0xFFE2E8F0))),
                    child: const Icon(Icons.arrow_back_ios_new_rounded, size: 16, color: Color(0xFF0F172A)),
                  ),
                ),
              const Spacer(),
              Text('Step ${currentStep + 1} of 6',
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF94A3B8))),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: List.generate(6, (i) => Expanded(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                margin: const EdgeInsets.symmetric(horizontal: 2),
                height: 5,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(99),
                  color: i <= currentStep ? primary : const Color(0xFFE2E8F0),
                ),
              ),
            )),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  // ─────────────────────── INTRO ───────────────────────
  Widget _introStep() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Column(
              children: [
                const Text(
                  'BECOME A WAYDROP RIDER',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: Color(0xFF0F172A), letterSpacing: -0.5),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Follow this 7-step guide to complete your profile verification',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: Color(0xFF64748B), height: 1.4),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          
          // Guidelines Card
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFFE2E8F0)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.camera_enhance_rounded, color: primary, size: 18),
                    const SizedBox(width: 8),
                    const Text(
                      'DOCUMENT UPLOAD MANUAL',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w900, color: primary, letterSpacing: 0.5),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _manualItem(
                  icon: Icons.aspect_ratio_rounded,
                  title: 'Original Documents Only',
                  desc: 'Photos of photocopies, scans, or computer screens will be rejected automatically.',
                ),
                _manualItem(
                  icon: Icons.lightbulb_outline_rounded,
                  title: 'Avoid Reflections & Glare',
                  desc: 'Capture photos under bright, natural light. Ensure no text is obscured by reflections.',
                ),
                _manualItem(
                  icon: Icons.crop_free_rounded,
                  title: 'Keep All Corners Visible',
                  desc: 'Ensure all four edges and corners of the ID cards are captured completely within the photo.',
                ),
                _manualItem(
                  icon: Icons.face_rounded,
                  title: 'Clear Face Selfie',
                  desc: 'Take selfie in a well-lit space. No hats, sunglasses, or blurred background.',
                ),
              ],
            ),
          ),
          
          const SizedBox(height: 20),
          
          // Steps Outline Card
          const Text(
            'ONBOARDING WORKFLOW',
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w900, color: Color(0xFF94A3B8), letterSpacing: 0.5),
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFFE2E8F0)),
            ),
            child: Column(
              children: [
                _workflowStep(1, 'Personal Details & Vehicle Type Selection'),
                _workflowStep(2, 'Aadhaar ID Card Front & Back Capture'),
                _workflowStep(3, 'PAN Card & Driving Permit Uploads'),
                _workflowStep(4, 'Clear Drop Partner Portrait & Transport Photo'),
              ],
            ),
          ),
          const SizedBox(height: 28),
          _nextButton('GET STARTED', nextStep),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _manualItem({required IconData icon, required String title, required String desc}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(color: const Color(0xFFEFF6FF), borderRadius: BorderRadius.circular(8)),
            child: Icon(icon, color: primary, size: 16),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title.toUpperCase(), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: Color(0xFF0F172A))),
                const SizedBox(height: 2),
                Text(desc, style: const TextStyle(fontSize: 11, color: Color(0xFF64748B), height: 1.4)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _workflowStep(int num, String label) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          CircleAvatar(
            radius: 9,
            backgroundColor: const Color(0xFFEFF6FF),
            child: Text(
              num.toString(),
              style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: primary),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF334155)),
            ),
          ),
        ],
      ),
    );
  }

  // ─────────────────────── PERSONAL ───────────────────────
  Widget _personalStep() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (rejectionCount >= 1) ...[
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFFFEF2F2),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFFFCA5A5)),
              ),
              child: const Row(
                children: [
                  Icon(Icons.warning_amber_rounded, color: Color(0xFFEF4444), size: 22),
                  SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'ATTENTION: This is your final resubmission attempt. Any further rejection will lock your profile for 7 days.',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF991B1B),
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],
          const Text('PERSONAL INFO', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: Color(0xFF0F172A))),
          const SizedBox(height: 4),
          const Text('Enter details exactly as on your documents', style: TextStyle(fontSize: 13, color: Color(0xFF94A3B8))),
          const SizedBox(height: 24),
          KycTextField(ctrl: fullNameController, hint: 'Full Name', icon: Icons.person_outline_rounded, textCapitalization: TextCapitalization.characters),
          const SizedBox(height: 12),
          KycTextField(ctrl: fatherNameController, hint: "Father's Name", icon: Icons.person_2_outlined, textCapitalization: TextCapitalization.characters),
          const SizedBox(height: 12),
          _DateOfBirthSelector(
            selectedDate: dateOfBirth,
            onSelect: (date) {
              final today = DateTime.now();
              int age = today.year - date.year;
              final monthDiff = today.month - date.month;
              if (monthDiff < 0 || (monthDiff == 0 && today.day < date.day)) {
                age--;
              }
              if (age < 18) {
                showError('You must be at least 18 years old to apply');
                return;
              }
              setState(() => dateOfBirth = date);
              _saveKycState();
            },
          ),
          const SizedBox(height: 20),
          const Text('VEHICLE TYPE', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w900, color: Color(0xFF0F172A))),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: VehicleTypeChip(
                value: 'bike',
                imagePath: 'assets/images/bike.jpg',
                label: 'Bike',
                selected: vehicleType == 'bike',
                onTap: () { setState(() => vehicleType = 'bike'); _saveKycState(); },
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: VehicleTypeChip(
                value: 'auto',
                imagePath: 'assets/images/auto.jpg',
                label: 'Auto',
                selected: vehicleType == 'auto',
                onTap: () { setState(() => vehicleType = 'auto'); _saveKycState(); },
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: VehicleTypeChip(
                value: 'cab',
                imagePath: 'assets/images/cab.jpg',
                label: 'Cab',
                selected: vehicleType == 'cab',
                onTap: () { setState(() => vehicleType = 'cab'); _saveKycState(); },
              ),
            ),
          ]),
          const SizedBox(height: 12),
          KycTextField(ctrl: vehicleNumberController, hint: 'Vehicle Number (e.g. KA01XX1234)', icon: Icons.text_fields_rounded, textCapitalization: TextCapitalization.characters),
          const SizedBox(height: 36),
          _nextButton('CONTINUE', () { if (validateCurrentStep()) nextStep(); }),
        ],
      ),
    );
  }

  // ─────────────────────── AADHAAR ───────────────────────
  Widget _aadhaarStep() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('AADHAAR VERIFICATION', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: Color(0xFF0F172A))),
          const SizedBox(height: 4),
          const Text('Verify your identity using Aadhaar', style: TextStyle(fontSize: 13, color: Color(0xFF94A3B8))),
          const SizedBox(height: 24),
          KycTextField(ctrl: aadhaarController, hint: '12-digit Aadhaar Number', icon: Icons.credit_card_rounded, numeric: true, maxLen: 12),
          const SizedBox(height: 24),
          const Text('AADHAAR DOCUMENTS', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w900, color: Color(0xFF0F172A))),
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
                  title: 'AADHAAR FRONT',
                  description: 'Front side of your Aadhaar card with clear photo and name',
                  image: aadhaarFront,
                  status: _statusFor(KycDocSlot.aadhaarFront),
                  onRetry: () => _retryDoc(KycDocSlot.aadhaarFront),
                  onTap: () async { final img = await pickImage(); if (!mounted) return; if (img != null) { setState(() => aadhaarFront = img); unawaited(_uploadDoc(KycDocSlot.aadhaarFront, img)); } },
                ),
                DocUploadRow(
                  title: 'AADHAAR BACK',
                  description: 'Back side of your Aadhaar card displaying your residential address',
                  image: aadhaarBack,
                  status: _statusFor(KycDocSlot.aadhaarBack),
                  onRetry: () => _retryDoc(KycDocSlot.aadhaarBack),
                  onTap: () async { final img = await pickImage(); if (!mounted) return; if (img != null) { setState(() => aadhaarBack = img); unawaited(_uploadDoc(KycDocSlot.aadhaarBack, img)); } },
                  last: true,
                ),
              ],
            ),
          ),
          const SizedBox(height: 36),
          _nextButton('CONTINUE', () { if (validateCurrentStep()) nextStep(); }),
        ],
      ),
    );
  }

  // ─────────────────────── PAN & DL ───────────────────────
  Widget _panDlStep() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('PAN & LICENSE', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: Color(0xFF0F172A))),
          const SizedBox(height: 4),
          const Text('Income verification and driving permit', style: TextStyle(fontSize: 13, color: Color(0xFF94A3B8))),
          const SizedBox(height: 24),
          KycTextField(ctrl: panController, hint: 'PAN Number (ABCDE1234F)', icon: Icons.badge_rounded, textCapitalization: TextCapitalization.characters, maxLen: 10),
          const SizedBox(height: 14),
          const Text('PAN CARD DOCUMENTS', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w900, color: Color(0xFF0F172A))),
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
                  title: 'PAN FRONT',
                  description: 'Front side of your PAN card showing clear photo and details',
                  image: panFront,
                  status: _statusFor(KycDocSlot.panFront),
                  onRetry: () => _retryDoc(KycDocSlot.panFront),
                  onTap: () async { final img = await pickImage(); if (!mounted) return; if (img != null) { setState(() => panFront = img); unawaited(_uploadDoc(KycDocSlot.panFront, img)); } },
                ),
                DocUploadRow(
                  title: 'PAN BACK',
                  description: 'Back side of your PAN card',
                  image: panBack,
                  status: _statusFor(KycDocSlot.panBack),
                  onRetry: () => _retryDoc(KycDocSlot.panBack),
                  onTap: () async { final img = await pickImage(); if (!mounted) return; if (img != null) { setState(() => panBack = img); unawaited(_uploadDoc(KycDocSlot.panBack, img)); } },
                  last: true,
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          KycTextField(ctrl: dlController, hint: 'Driving License Number', icon: Icons.drive_eta_rounded, textCapitalization: TextCapitalization.characters),
          const SizedBox(height: 14),
          const Text('DRIVING LICENSE DOCUMENTS', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w900, color: Color(0xFF0F172A))),
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
                  title: 'LICENSE FRONT',
                  description: 'Front side of your driving license showing permit and details',
                  image: licenseFront,
                  status: _statusFor(KycDocSlot.licenseFront),
                  onRetry: () => _retryDoc(KycDocSlot.licenseFront),
                  onTap: () async { final img = await pickImage(); if (!mounted) return; if (img != null) { setState(() => licenseFront = img); unawaited(_uploadDoc(KycDocSlot.licenseFront, img)); } },
                ),
                DocUploadRow(
                  title: 'LICENSE BACK',
                  description: 'Back side of your driving license displaying validity details',
                  image: licenseBack,
                  status: _statusFor(KycDocSlot.licenseBack),
                  onRetry: () => _retryDoc(KycDocSlot.licenseBack),
                  onTap: () async { final img = await pickImage(); if (!mounted) return; if (img != null) { setState(() => licenseBack = img); unawaited(_uploadDoc(KycDocSlot.licenseBack, img)); } },
                  last: true,
                ),
              ],
            ),
          ),
          const SizedBox(height: 36),
          _nextButton('CONTINUE', () { if (validateCurrentStep()) nextStep(); }),
        ],
      ),
    );
  }

  // ─────────────────────── SELFIE ───────────────────────
  Widget _selfieStep() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('SELFIE & VEHICLE', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: Color(0xFF0F172A))),
          const SizedBox(height: 4),
          const Text('Clear selfie and vehicle photo required', style: TextStyle(fontSize: 13, color: Color(0xFF94A3B8))),
          const SizedBox(height: 24),
          const Text('PROFILE & TRANSPORT DOCUMENTS', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w900, color: Color(0xFF0F172A))),
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
                  title: 'RIDER SELFIE',
                  description: 'Clear, front-facing selfie portrait with no cap or glasses',
                  image: riderSelfie,
                  status: _statusFor(KycDocSlot.riderSelfie),
                  onRetry: () => _retryDoc(KycDocSlot.riderSelfie),
                  onTap: pickSelfieImage,
                ),
                DocUploadRow(
                  title: 'VEHICLE PHOTO',
                  description: 'Full photo of your vehicle showing the registration plate clearly',
                  image: vehicleImage,
                  status: _statusFor(KycDocSlot.vehicleImage),
                  onRetry: () => _retryDoc(KycDocSlot.vehicleImage),
                  onTap: () async { final img = await pickImage(); if (!mounted) return; if (img != null) { setState(() => vehicleImage = img); unawaited(_uploadDoc(KycDocSlot.vehicleImage, img)); } },
                  last: true,
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          const Text('VEHICLE RC DOCUMENTS', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w900, color: Color(0xFF0F172A))),
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
                  description: 'Front side of your Vehicle Registration Certificate (RC)',
                  image: vehicleRcFront,
                  status: _statusFor(KycDocSlot.vehicleRcFront),
                  onRetry: () => _retryDoc(KycDocSlot.vehicleRcFront),
                  onTap: () async { final img = await pickImage(); if (!mounted) return; if (img != null) { setState(() => vehicleRcFront = img); unawaited(_uploadDoc(KycDocSlot.vehicleRcFront, img)); } },
                ),
                DocUploadRow(
                  title: 'RC BACK',
                  description: 'Back side of your Vehicle Registration Certificate (RC)',
                  image: vehicleRcBack,
                  status: _statusFor(KycDocSlot.vehicleRcBack),
                  onRetry: () => _retryDoc(KycDocSlot.vehicleRcBack),
                  onTap: () async { final img = await pickImage(); if (!mounted) return; if (img != null) { setState(() => vehicleRcBack = img); unawaited(_uploadDoc(KycDocSlot.vehicleRcBack, img)); } },
                  last: true,
                ),
              ],
            ),
          ),
          const SizedBox(height: 36),
          _nextButton('CONTINUE', () { if (validateCurrentStep()) nextStep(); }),
        ],
      ),
    );
  }

  // ─────────────────────── REVIEW ───────────────────────


  Widget _reviewStep() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('REVIEW & SUBMIT', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: Color(0xFF0F172A))),
          const SizedBox(height: 4),
          const Text('Check all details before submitting', style: TextStyle(fontSize: 13, color: Color(0xFF94A3B8))),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18), border: Border.all(color: const Color(0xFFE2E8F0))),
            child: Column(
              children: [
                _ReviewRow('FULL NAME', fullNameController.text),
                _ReviewRow("FATHER'S NAME", fatherNameController.text),
                _ReviewRow('DATE OF BIRTH', dateOfBirth != null ? "${dateOfBirth!.year.toString().padLeft(4, '0')}-${dateOfBirth!.month.toString().padLeft(2, '0')}-${dateOfBirth!.day.toString().padLeft(2, '0')}" : ""),
                _ReviewRow('VEHICLE TYPE', (vehicleType ?? '').toUpperCase()),
                _ReviewRow('VEHICLE NUMBER', vehicleNumberController.text),
                _ReviewRow('AADHAAR', aadhaarController.text),
                _ReviewRow('PAN', panController.text.toUpperCase()),
                _ReviewRow('DRIVING LICENSE', dlController.text.toUpperCase(), last: true),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Checkbox(
                value: consent,
                activeColor: primary,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
                onChanged: (v) { setState(() => consent = v ?? false); _saveKycState(); },
              ),
              const Expanded(
                child: Padding(
                  padding: EdgeInsets.only(top: 10),
                  child: Text.rich(
                    TextSpan(
                      text: 'By continuing, I confirm that I have read & agree to the ',
                      style: TextStyle(fontSize: 12, color: Color(0xFF64748B), height: 1.4),
                      children: [
                        TextSpan(
                          text: 'TERMS & CONDITIONS',
                          style: TextStyle(fontWeight: FontWeight.w900, color: Color(0xFF2563EB)),
                        ),
                        TextSpan(text: ' and '),
                        TextSpan(
                          text: 'PRIVACY POLICY',
                          style: TextStyle(fontWeight: FontWeight.w900, color: Color(0xFF2563EB)),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          _nextButton('SUBMIT VERIFICATION', (consent && (_uploadSession?.allUploaded ?? false)) ? submitKyc : null),
          const SizedBox(height: 20),
        ],
      ),
    );
  }

  // ─────────────────────── Shared Widgets ───────────────────────
  Widget _nextButton(String label, VoidCallback? onPressed) {
    return SizedBox(
      width: double.infinity, height: 54,
      child: ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: onPressed != null ? primary : const Color(0xFFE2E8F0),
          foregroundColor: onPressed != null ? Colors.white : const Color(0xFF94A3B8),
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
        child: Text(label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
      ),
    );
  }
}

// ─────────────────────── Helper Widgets ───────────────────────
// KycTextField, DocUploadRow, VehicleTypeChip and UpperCaseTextFormatter now
// live in shared/widgets/kyc/kyc_upload_widgets.dart so the Add Vehicle
// screen can reuse them without duplicating this UI.

class _ReviewRow extends StatelessWidget {
  final String label, value;
  final bool last;
  const _ReviewRow(this.label, this.value, {this.last = false});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(label, style: const TextStyle(fontSize: 13, color: Color(0xFF94A3B8), fontWeight: FontWeight.w600)),
              const SizedBox(width: 12),
              Flexible(child: Text(value, textAlign: TextAlign.right, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: Color(0xFF0F172A)))),
            ],
          ),
        ),
        if (!last) const Divider(height: 1, color: Color(0xFFF1F5F9)),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────
// DATE OF BIRTH SELECTOR WIDGET
// ─────────────────────────────────────────────────────────────

class _DateOfBirthSelector extends StatelessWidget {
  final DateTime? selectedDate;
  final Function(DateTime) onSelect;

  const _DateOfBirthSelector({
    required this.selectedDate,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final displayStr = selectedDate != null
        ? "${_monthName(selectedDate!.month)} ${selectedDate!.day.toString().padLeft(2, '0')}, ${selectedDate!.year}"
        : 'Select Date of Birth';

    return GestureDetector(
      onTap: () {
        final now = DateTime.now();
        final initialDate = selectedDate ?? now.subtract(const Duration(days: 365 * 18 + 5));
        final firstDate = now.subtract(const Duration(days: 365 * 100)); // Up to 100 years ago
        final lastDate = now.subtract(const Duration(days: 365 * 18 + 4)); // Must be at least 18 years old

        showModalBottomSheet(
          context: context,
          backgroundColor: Colors.white,
          elevation: 0,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
          ),
          builder: (context) {
            DateTime tempPickedDate = initialDate.isAfter(lastDate) ? lastDate : initialDate;
            return Container(
              height: 390,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              child: Column(
                children: [
                  // Premium Grab Handle
                  const SizedBox.shrink(),
                  const SizedBox.shrink(),
                  const Text(
                    'Select Date of Birth',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w900,
                      color: Color(0xFF0F172A),
                      letterSpacing: -0.3,
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'You must be at least 18 years old to apply',
                    style: TextStyle(
                      fontSize: 12.5,
                      color: Color(0xFF94A3B8),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 16),
                  // Cupertino Wheel Selector
                  Expanded(
                    child: CupertinoTheme(
                      data: const CupertinoThemeData(
                        textTheme: CupertinoTextThemeData(
                          dateTimePickerTextStyle: TextStyle(
                            fontSize: 19,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFF0F172A),
                          ),
                        ),
                      ),
                      child: CupertinoDatePicker(
                        mode: CupertinoDatePickerMode.date,
                        initialDateTime: tempPickedDate,
                        minimumDate: firstDate,
                        maximumDate: lastDate,
                        onDateTimeChanged: (DateTime date) {
                          tempPickedDate = date;
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  // Confirm Button
                  SizedBox(
                    width: double.infinity,
                    height: 54,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.black,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(27),
                        ),
                      ),
                      onPressed: () {
                        onSelect(tempPickedDate);
                        Navigator.pop(context);
                      },
                      child: const Text(
                        'Confirm Date',
                        style: TextStyle(
                          fontSize: 15.5,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.2,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            );
          },
        );
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFFE2E8F0)),
        ),
        child: Row(
          children: [
            const Icon(Icons.calendar_month_rounded, color: Color(0xFF94A3B8), size: 18),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                displayStr,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: selectedDate != null ? const Color(0xFF0F172A) : const Color(0xFFCBD5E1),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _monthName(int m) {
    const names = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    if (m >= 1 && m <= 12) return names[m - 1];
    return '';
  }
}