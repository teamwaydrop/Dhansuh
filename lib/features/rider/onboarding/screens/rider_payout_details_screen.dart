import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:waydrop/core/services/session/identity_operation_scope.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:waydrop/core/services/cache/qr_image_cache_manager.dart';
import 'package:waydrop/core/services/cache/qr_signed_url_cache.dart';
import 'package:waydrop/core/services/database/rider_payout_account_cache.dart';
import 'package:waydrop/features/rider/services/rider_status_service.dart';
import 'package:waydrop/shared/widgets/app_snackbar.dart';
import 'package:waydrop/features/rider/navigation/rider_main_navigation_screen.dart';
import 'package:waydrop/features/rider/onboarding/screens/service_mode_selection_screen.dart';

class RiderPayoutDetailsScreen extends StatefulWidget {
  const RiderPayoutDetailsScreen({super.key});

  @override
  State<RiderPayoutDetailsScreen> createState() => _RiderPayoutDetailsScreenState();
}

class _RiderPayoutDetailsScreenState extends State<RiderPayoutDetailsScreen> {
  late final _modeOperations = IdentityOperationScope.forWidget(() => mounted,
      onIdentityChanged: () => setState(() => loading = false));
  final _formKey = GlobalKey<FormState>();
  final supabase = Supabase.instance.client;

  // Reasonable UPI VPA format check -- "name@handle" -- no gateway verification involved.
  static final RegExp _upiVpaRegex = RegExp(r'^[a-zA-Z0-9.\-_]{2,256}@[a-zA-Z][a-zA-Z0-9]{1,64}$');

  final nameController = TextEditingController();
  final phoneController = TextEditingController();
  final emailController = TextEditingController();
  final accountNumberController = TextEditingController();
  final confirmAccountNumberController = TextEditingController();
  final ifscController = TextEditingController();
  final upiController = TextEditingController();

  bool loading = false;
  final String payoutMethod = 'bank_account'; // Always default to bank account

  // Driver's explicit ownership confirmation -- replaces Cashfree VPA Verification entirely as
  // the gate on whether personal_upi can ever be offered to passengers (see
  // rider_payout_accounts.upi_self_certified). Our merchant account doesn't have access to
  // Cashfree's Validate Payout capability (a separately-licensed "Verification Suite" feature), so
  // we never depend on it, and never fake a gateway verification we can't perform -- this
  // checkbox, enforced server-side by create-rider-payout, is the real source of truth instead.
  bool _upiSelfCertified = false;

  // Driver's uploaded receive-money QR (from GPay/PhonePe/Paytm/bank app) -- never generated from
  // the typed VPA. `_qrPickedFile` is a freshly-picked-but-not-yet-uploaded image; `_qrPreviewUrl`
  // is a short-lived signed URL for whatever is already on file (private bucket, so no public URL).
  String? _riderId;
  File? _qrPickedFile;
  String? _existingQrPath;
  String? _qrPreviewUrl;
  bool _uploadingQr = false;

  // True once we've confirmed a rider_payout_accounts row already exists for this user (i.e. this
  // screen is being reopened to edit, not filled out for the first time). set_personal_qr_path is
  // an UPDATE, not an UPSERT, so it can only succeed once this row exists.
  bool _hasPayoutAccount = false;
  // A QR that was uploaded to storage successfully but couldn't be pointed to yet because no
  // rider_payout_accounts row existed (first-time onboarding, QR picked before "Save & Link
  // Account"). Persisted automatically once _submitPayoutDetails creates that row.
  String? _pendingQrPath;

  static const primaryGreen = Color(0xFF10B981);
  static const darkSlate = Color(0xFF0F172A);

  @override
  void initState() {
    super.initState();
    _prefillUserInfo();
    // A changed VPA is not the one that was last self-certified -- require re-confirmation.
    upiController.addListener(() {
      if (mounted) {
        setState(() => _upiSelfCertified = false);
      }
    });
  }

  Future<void> _refreshQrPreview() async {
    final path = _existingQrPath;
    if (path == null || path.isEmpty) return;
    try {
      // Egress fix (Fix #10B): cached per storage path for its ~1hr validity instead of
      // re-signing on every call/screen-open.
      final url = await QrSignedUrlCache.get(
        path,
        () => supabase.storage.from('driver_personal_qr').createSignedUrl(path, 3600),
      );
      if (mounted) setState(() => _qrPreviewUrl = url);
    } catch (e) {
      debugPrint('QR PREVIEW SIGNED URL ERROR => $e');
    }
  }

  static const Set<String> _allowedQrExtensions = {'jpg', 'jpeg', 'png', 'webp'};

  Future<void> _pickAndUploadQr() async {
    try {
      final riderId = _riderId;
      if (riderId == null) {
        _showError('Complete your KYC / rider profile before uploading a QR.');
        return;
      }

      final picked = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 90);
      if (picked == null) return;

      final ext = picked.path.split('.').last.toLowerCase();
      if (!_allowedQrExtensions.contains(ext)) {
        _showError('Please choose a JPG, PNG, or WEBP image for your QR.');
        return;
      }

      final file = File(picked.path);
      final fileSize = await file.length();
      if (fileSize <= 0) {
        _showError('That image could not be read. Please pick a different file.');
        return;
      }

      setState(() {
        _qrPickedFile = file;
        _uploadingQr = true;
      });

      final path = '$riderId/personal_qr_${DateTime.now().millisecondsSinceEpoch}.$ext';

      // This upload succeeds regardless of whether rider_payout_accounts exists yet -- storage
      // RLS on driver_personal_qr only checks the (already-existing) riders row, not the payout
      // account. Confirming the upload itself before doing anything else means the image is safe
      // in the bucket even if the DB pointer below has to be deferred.
      await supabase.storage.from('driver_personal_qr').upload(
            path,
            file,
            fileOptions: FileOptions(upsert: true, contentType: 'image/$ext'),
          );

      if (!_hasPayoutAccount) {
        // No rider_payout_accounts row yet -- set_personal_qr_path (an UPDATE, not an UPSERT)
        // has nothing to point at until "Save & Link Account" creates that row below. The image
        // is already safely uploaded; just remember its path and finish the job on submit.
        if (!mounted) return;
        setState(() {
          _pendingQrPath = path;
          _uploadingQr = false;
        });
        _showSuccess('QR selected. It will be saved when you tap "Save & Link Account" below.');
        return;
      }

      final response = await supabase.rpc('set_personal_qr_path', params: {'p_path': path});
      final success = response is Map && response['success'] == true;

      if (!success) {
        final message = (response is Map ? response['message']?.toString() : null) ?? 'Failed to save QR.';
        throw Exception(message);
      }

      if (!mounted) return;
      RiderPayoutAccountCache.invalidate();
      setState(() {
        _existingQrPath = path;
        _pendingQrPath = null;
        _uploadingQr = false;
      });
      await _refreshQrPreview();
      if (!mounted) return;
      _showSuccess('Personal QR uploaded.');
    } catch (e) {
      debugPrint('QR UPLOAD ERROR => $e');
      if (mounted) {
        setState(() => _uploadingQr = false);
        _showError('Could not upload QR: ${_friendlyErrorMessage(e)}');
      }
    }
  }

  // Supabase Storage/Postgrest exceptions already carry a safe, user-facing `message` (no stack
  // traces, no secrets) -- surface that instead of a one-size-fits-all string, per the requirement
  // to log/report the real underlying issue instead of hiding it.
  String _friendlyErrorMessage(Object e) {
    final dynamic err = e;
    try {
      final msg = err.message;
      if (msg is String && msg.trim().isNotEmpty) return msg;
    } catch (_) {}
    final s = e.toString().replaceFirst('Exception: ', '');
    return s.length > 140 ? 'Please try again.' : s;
  }

  Future<void> _prefillUserInfo() async {
    try {
      final user = supabase.auth.currentUser;
      if (user != null) {
        // Safe pre-fill phone stripping +91 or 91 country codes
        if (user.phone != null && user.phone!.isNotEmpty) {
          final cleanPhone = user.phone!.replaceAll(RegExp(r'^\+91|^91'), '');
          phoneController.text = cleanPhone;
        }
        if (user.email != null) {
          emailController.text = user.email!;
        }

        // Fetch name from profile
        final profile = await supabase
            .from('users')
            .select('full_name')
            .eq('id', user.id)
            .maybeSingle();

        if (profile != null && profile['full_name'] != null) {
          nameController.text = profile['full_name'];
        }

        // Fetch existing payout account if any.
        // Egress fix (Fix #6 completion): shared via RiderPayoutAccountCache with the other
        // display/edit reads of this same row -- see that class's doc comment.
        final existingPayout = await RiderPayoutAccountCache.get(
          user.id,
          () => supabase
              .from('rider_payout_accounts')
              .select(
                'beneficiary_name, beneficiary_phone, beneficiary_email, upi_vpa, '
                'personal_qr_path, account_number, ifsc_code, beneficiary_id, '
                'cashfree_beneficiary_status, default_fare_payment_method, upi_self_certified',
              )
              .eq('user_id', user.id)
              .maybeSingle(),
        );

        _hasPayoutAccount = existingPayout != null;
        if (existingPayout != null) {
          if (existingPayout['beneficiary_name'] != null) {
            nameController.text = existingPayout['beneficiary_name'];
          }
          if (existingPayout['beneficiary_phone'] != null) {
            phoneController.text = existingPayout['beneficiary_phone'].toString().replaceAll(RegExp(r'^\+91|^91'), '');
          }
          if (existingPayout['beneficiary_email'] != null) {
            emailController.text = existingPayout['beneficiary_email'];
          }
          if (existingPayout['upi_vpa'] != null) {
            upiController.text = existingPayout['upi_vpa'].toString();
          }
          _existingQrPath = existingPayout['personal_qr_path']?.toString();
        }

        // Rider id is required to build the driver_personal_qr/{rider_id}/... upload path.
        final riderRow = await supabase
            .from('riders')
            .select('id')
            .eq('user_id', user.id)
            .maybeSingle();
        _riderId = riderRow?['id']?.toString();

        if (_existingQrPath != null && mounted) {
          await _refreshQrPreview();
        }
      }
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('Error pre-filling profile: $e');
    }
  }
  
  @override
  void dispose() {
    _modeOperations.dispose();
    nameController.dispose();
    phoneController.dispose();
    emailController.dispose();
    accountNumberController.dispose();
    confirmAccountNumberController.dispose();
    ifscController.dispose();
    upiController.dispose();
    super.dispose();
  }

  void _showError(String msg) {
    showAppSnackBar(context, msg, type: SnackBarType.error);
  }

  void _showSuccess(String msg) {
    showAppSnackBar(context, msg, type: SnackBarType.success);
  }

  Future<void> _submitPayoutDetails() async {
    if (!mounted) return;
    if (!_formKey.currentState!.validate()) return;

    if (accountNumberController.text != confirmAccountNumberController.text) {
      _showError('Bank Account Numbers do not match');
      return;
    }

    final hasUpi = upiController.text.trim().isNotEmpty;
    if (hasUpi && !_upiSelfCertified) {
      _showError('Please confirm the UPI ID belongs to you before saving.');
      return;
    }

    final operation = _modeOperations.begin();
    setState(() => loading = true);

    try {
      final user = supabase.auth.currentUser;
      if (user == null) {
        setState(() => loading = false);
        _showError('Session expired. Please log in again.');
        return;
      }

      // Payload matching table schema
      final Map<String, dynamic> requestBody = {
        'beneficiary_name': nameController.text.trim(),
        'beneficiary_phone': phoneController.text.trim(),
        'beneficiary_email': emailController.text.trim().isEmpty ? null : emailController.text.trim(),
        'payout_method': payoutMethod,
        'account_number': accountNumberController.text.trim(),
        'ifsc_code': ifscController.text.trim().toUpperCase(),
        'upi_vpa': hasUpi ? upiController.text.trim() : null,
        'upi_self_certified': hasUpi ? _upiSelfCertified : false,
      };

      // Invoke Edge Function
      final response = await supabase.functions.invoke(
        'create-rider-payout',
        body: requestBody,
      );
      if (!operation.isCurrent) return;

      debugPrint('CREATE RIDER PAYOUT RESPONSE => ${response.status}');
      debugPrint('CREATE RIDER PAYOUT DATA => ${response.data}');

      if (response.status != 200 || response.data == null || response.data['success'] != true) {
        setState(() => loading = false);
        _showError(response.data?['message'] ?? 'Failed to register payout details. Please verify your details.');
        return;
      }

      // Deliberately does not say "verified" -- this only confirms the bank/UPI payout details
      // were saved and linked with Cashfree's Payouts product. Personal UPI eligibility now comes
      // from the driver's own self-certification above, not any gateway verification.
      _showSuccess('Payout details saved and linked to Cashfree.');
      _hasPayoutAccount = true;
      RiderPayoutAccountCache.invalidate();

      // The rider_payout_accounts row now exists -- finish persisting a QR that was uploaded to
      // storage before this row existed (see _pickAndUploadQr). Non-fatal on failure: payout
      // details are already saved either way, and the driver can re-upload from Payment Settings.
      if (_pendingQrPath != null) {
        try {
          final qrResponse = await supabase.rpc('set_personal_qr_path', params: {'p_path': _pendingQrPath});
          if (!operation.isCurrent) return;
          if (qrResponse is Map && qrResponse['success'] == true) {
            _existingQrPath = _pendingQrPath;
            _pendingQrPath = null;
          } else {
            debugPrint('QR PERSIST AFTER PAYOUT SAVE FAILED => $qrResponse');
          }
        } catch (e) {
          if (!operation.isCurrent) return;
          debugPrint('QR PERSIST AFTER PAYOUT SAVE ERROR => $e');
        }
      }

      // Payout setup and Service Mode selection are two separate, independent steps -- payout
      // details are already fully saved above regardless of what happens next. switchToRiderMode()
      // re-validates KYC/activation/payout/service_mode as a group (see rider_status_service.dart)
      // and is what actually flips the account into "rider mode"; if the only thing missing is
      // Service Mode, send the partner to choose it as its own screen instead of surfacing that
      // re-validation exception as if payout setup itself had failed.
      try {
        if (!operation.isCurrent) return;
        await RiderStatusService.switchToRiderMode();
        if (!operation.isCurrent) return;
        setState(() => loading = false);

        if (Navigator.canPop(context)) {
          Navigator.pop(context, true);
        } else {
          Navigator.pushAndRemoveUntil(
            context,
            MaterialPageRoute(builder: (_) => const RiderMainNavigationScreen()),
            (_) => false,
          );
        }
      } catch (modeError) {
        if (!operation.isCurrent) return;
        setState(() => loading = false);

        if (modeError.toString().contains('Service Mode not chosen')) {
          Navigator.pushAndRemoveUntil(
            context,
            MaterialPageRoute(builder: (_) => const ServiceModeSelectionScreen()),
            (_) => false,
          );
        } else {
          _showError(modeError.toString().replaceFirst('Exception: ', ''));
        }
      }
    } catch (e) {
      if (operation.isCurrent) {
        setState(() => loading = false);
        String errorText = 'An unexpected error occurred: $e';
        
        if (e is FunctionException) {
          final details = e.details;
          if (details != null) {
            if (details is Map && details.containsKey('message')) {
              errorText = details['message'].toString();
            } else if (details is String) {
              try {
                final Map<String, dynamic> decoded = jsonDecode(details);
                if (decoded.containsKey('message')) {
                  errorText = decoded['message'].toString();
                }
              } catch (_) {
                errorText = details;
              }
            }
          } else {
            errorText = e.toString();
          }
        }
        
        _showError(errorText.replaceFirst('Exception: ', ''));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFB),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, color: darkSlate, size: 20),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text(
          'Payout Details',
          style: TextStyle(
            color: darkSlate,
            fontWeight: FontWeight.w900,
            fontSize: 18,
            letterSpacing: -0.4,
          ),
        ),
        centerTitle: true,
      ),
      body: SafeArea(
        child: GestureDetector(
          onTap: () => FocusScope.of(context).unfocus(),
          child: loading
              ? const Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      CircularProgressIndicator(
                        color: primaryGreen,
                        strokeWidth: 2.5,
                      ),
                      SizedBox(height: 16),
                      Text(
                        'Saving payout details...',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF64748B),
                        ),
                      ),
                    ],
                  ),
                )
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(24.0),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Card decoration
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(20),
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                              colors: [Color(0xFF0F172A), Color(0xFF1E293B)],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                            borderRadius: BorderRadius.circular(20),
                            boxShadow: [
                              BoxShadow(
                                color: const Color(0xFF0F172A).withValues(alpha: 0.1),
                                blurRadius: 10,
                                offset: const Offset(0, 4),
                              ),
                            ],
                          ),
                          child: Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: 0.1),
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(
                                  Icons.account_balance_rounded,
                                  color: primaryGreen,
                                  size: 24,
                                ),
                              ),
                              const SizedBox(width: 16),
                              const Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Setup Payout Account',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w900,
                                        fontSize: 16,
                                      ),
                                    ),
                                    SizedBox(height: 4),
                                    Text(
                                      'Link bank details to receive real-time rider earnings.',
                                      style: TextStyle(
                                        color: Color(0xFF94A3B8),
                                        fontSize: 12,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 24),

                        // Section 1: Beneficiary Contact
                        const Text(
                          'Beneficiary Details',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                            color: darkSlate,
                          ),
                        ),
                        const SizedBox(height: 12),

                        // Name field
                        _buildInputField(
                          controller: nameController,
                          label: 'Account Holder Name',
                          hint: 'Enter bank account holder full name',
                          icon: Icons.person_outline_rounded,
                          validator: (v) {
                            if (v == null || v.trim().isEmpty) return 'Account holder name is required';
                            if (v.trim().length < 3) return 'Name must be at least 3 characters';
                            return null;
                          },
                        ),
                        const SizedBox(height: 16),

                        // Phone field
                        _buildInputField(
                          controller: phoneController,
                          label: 'Phone Number',
                          hint: '10-digit mobile number (excluding +91)',
                          icon: Icons.phone_android_rounded,
                          keyboardType: TextInputType.phone,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                            LengthLimitingTextInputFormatter(10),
                          ],
                          validator: (v) {
                            if (v == null || v.trim().isEmpty) return 'Phone number is required';
                            if (v.trim().length != 10) return 'Enter exactly 10 digits (excluding +91)';
                            return null;
                          },
                        ),
                        const SizedBox(height: 16),

                        // Email field
                        _buildInputField(
                          controller: emailController,
                          label: 'Email Address (Optional)',
                          hint: 'Enter your email address',
                          icon: Icons.email_outlined,
                          keyboardType: TextInputType.emailAddress,
                          validator: (v) {
                            if (v != null && v.trim().isNotEmpty) {
                              final emailRegex = RegExp(r'^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$');
                              if (!emailRegex.hasMatch(v.trim())) return 'Enter a valid email address';
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 24),

                        // Section 2: Bank details
                        const Text(
                          'Bank Details',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                            color: darkSlate,
                          ),
                        ),
                        const SizedBox(height: 12),

                        // Account Number
                        _buildInputField(
                          controller: accountNumberController,
                          label: 'Bank Account Number',
                          hint: 'Enter your account number',
                          icon: Icons.numbers_rounded,
                          obscureText: true,
                          keyboardType: TextInputType.number,
                          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                          validator: (v) {
                            if (v == null || v.trim().isEmpty) return 'Account number is required';
                            if (v.trim().length < 8 || v.trim().length > 20) {
                              return 'Must be between 8 and 20 digits';
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 16),

                        // Confirm Account Number
                        _buildInputField(
                          controller: confirmAccountNumberController,
                          label: 'Confirm Bank Account Number',
                          hint: 'Re-enter your account number',
                          icon: Icons.numbers_rounded,
                          keyboardType: TextInputType.number,
                          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                          validator: (v) {
                            if (v == null || v.trim().isEmpty) return 'Please confirm your account number';
                            return null;
                          },
                        ),
                        const SizedBox(height: 16),

                        // IFSC Code
                        _buildInputField(
                          controller: ifscController,
                          label: 'IFSC Code',
                          hint: 'e.g. SBIN0001234',
                          icon: Icons.account_balance_rounded,
                          textCapitalization: TextCapitalization.characters,
                          validator: (v) {
                            if (v == null || v.trim().isEmpty) return 'IFSC code is required';
                            final ifscRegex = RegExp(r'^[A-Z]{4}0[A-Z0-9]{6}$');
                            if (!ifscRegex.hasMatch(v.trim().toUpperCase())) {
                              return 'Invalid IFSC format (e.g. HDFC0000123)';
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 24),

                        // Section 3: Personal UPI (fare collection + payout)
                        const Text(
                          'Personal UPI (Optional)',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                            color: darkSlate,
                          ),
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          'Passengers pay your uploaded QR directly -- no Cashfree fee. '
                          'The UPI ID below is for your own reference only; change your default '
                          'payment method anytime in Payment Settings.',
                          style: TextStyle(
                            fontSize: 11,
                            color: Color(0xFF64748B),
                            fontWeight: FontWeight.w500,
                            height: 1.4,
                          ),
                        ),
                        const SizedBox(height: 12),

                        // UPI VPA (reference only -- not used to generate a QR anymore)
                        _buildInputField(
                          controller: upiController,
                          label: 'UPI ID (VPA) -- reference only',
                          hint: 'e.g. mobile@upi (Optional)',
                          icon: Icons.badge_outlined,
                          validator: (v) {
                            if (v != null && v.trim().isNotEmpty) {
                              if (!_upiVpaRegex.hasMatch(v.trim())) {
                                return 'Invalid UPI VPA ID format (expected something like name@bank)';
                              }
                            }
                            return null;
                          },
                        ),
                        if (upiController.text.trim().contains('@') &&
                            upiController.text.trim().length >= 3) ...[
                          const SizedBox(height: 12),
                          // Server-enforced (create-rider-payout rejects the request without this)
                          // -- the only thing that replaces Cashfree VPA Verification. Never
                          // faked, never implied as a gateway "Verified" badge.
                          InkWell(
                            onTap: () => setState(() => _upiSelfCertified = !_upiSelfCertified),
                            borderRadius: BorderRadius.circular(12),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Checkbox(
                                  value: _upiSelfCertified,
                                  activeColor: primaryGreen,
                                  onChanged: (v) => setState(() => _upiSelfCertified = v ?? false),
                                ),
                                Expanded(
                                  child: Padding(
                                    padding: const EdgeInsets.only(top: 14),
                                    child: Text(
                                      'I confirm that this UPI ID belongs to me and that the '
                                      'payment details I provided are correct.',
                                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: darkSlate),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],

                        const SizedBox(height: 24),

                        // Section 4: Personal QR upload -- the actual receive-money QR image
                        // captured from GPay/PhonePe/Paytm/the driver's bank app. This, not any
                        // generated-from-VPA QR, is what passengers scan at trip end.
                        const Text(
                          'Personal QR',
                          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: darkSlate),
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          'Upload your real receive-money QR from Google Pay, PhonePe, Paytm, or '
                          'your bank app. This exact image is shown to passengers at the end of '
                          'every trip -- WayDrop never generates or modifies it.',
                          style: TextStyle(
                            fontSize: 11,
                            color: Color(0xFF64748B),
                            fontWeight: FontWeight.w500,
                            height: 1.4,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Center(
                          child: Column(
                            children: [
                              Container(
                                width: 160,
                                height: 160,
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(color: const Color(0xFFE2E8F0), width: 1.5),
                                ),
                                clipBehavior: Clip.antiAlias,
                                child: _uploadingQr
                                    ? const Center(child: CircularProgressIndicator(color: primaryGreen, strokeWidth: 2.5))
                                    : (_qrPickedFile != null
                                        ? Image.file(_qrPickedFile!, fit: BoxFit.contain)
                                        : (_qrPreviewUrl != null
                                            ? CachedNetworkImage(
                                                imageUrl: _qrPreviewUrl!,
                                                fit: BoxFit.contain,
                                                cacheManager: QrImageCacheManager.instance,
                                                memCacheWidth: (160 * MediaQuery.of(context).devicePixelRatio).round(),
                                                memCacheHeight: (160 * MediaQuery.of(context).devicePixelRatio).round(),
                                              )
                                            : const Center(
                                                child: Icon(Icons.qr_code_2_rounded, color: Color(0xFFCBD5E1), size: 56),
                                              ))),
                              ),
                              const SizedBox(height: 12),
                              OutlinedButton.icon(
                                onPressed: _uploadingQr ? null : _pickAndUploadQr,
                                icon: const Icon(Icons.upload_rounded, size: 18, color: primaryGreen),
                                label: Text(
                                  _existingQrPath != null ? 'Replace Personal QR' : 'Upload Personal QR',
                                  style: const TextStyle(color: primaryGreen, fontWeight: FontWeight.w800, fontSize: 13),
                                ),
                                style: OutlinedButton.styleFrom(
                                  side: const BorderSide(color: primaryGreen, width: 1.5),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                                ),
                              ),
                              if (_pendingQrPath != null) ...[
                                const SizedBox(height: 8),
                                const Text(
                                  'Selected -- will be saved when you tap "Save & Link Account".',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: Color(0xFF64748B),
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),

                        const SizedBox(height: 36),

                        // Submit Button
                        SizedBox(
                          width: double.infinity,
                          height: 54,
                          child: ElevatedButton(
                            onPressed: _submitPayoutDetails,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: darkSlate,
                              foregroundColor: Colors.white,
                              elevation: 0,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                              ),
                            ),
                            child: const Text(
                              'Save & Link Account',
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 24),
                      ],
                    ),
                  ),
                ),
        ),
      ),
    );
  }

  Widget _buildInputField({
    required TextEditingController controller,
    required String label,
    required String hint,
    required IconData icon,
    TextInputType keyboardType = TextInputType.text,
    List<TextInputFormatter>? inputFormatters,
    String? Function(String?)? validator,
    TextCapitalization textCapitalization = TextCapitalization.none,
    bool obscureText = false,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w800,
            color: Color(0xFF64748B),
          ),
        ),
        const SizedBox(height: 6),
        TextFormField(
          controller: controller,
          keyboardType: keyboardType,
          inputFormatters: inputFormatters,
          validator: validator,
          textCapitalization: textCapitalization,
          obscureText: obscureText,
          style: const TextStyle(
            color: darkSlate,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: const TextStyle(
              color: Color(0xFF94A3B8),
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
            prefixIcon: Icon(icon, color: const Color(0xFF94A3B8), size: 18),
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            filled: true,
            fillColor: Colors.white,
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: Color(0xFFE2E8F0), width: 1.5),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: primaryGreen, width: 2),
            ),
            errorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: Color(0xFFEF4444), width: 1.5),
            ),
            focusedErrorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: Color(0xFFEF4444), width: 2),
            ),
            errorStyle: const TextStyle(
              color: Color(0xFFEF4444),
              fontSize: 11,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
    );
  }
}
