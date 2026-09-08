import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class RiderKycPendingScreen extends StatefulWidget {
  const RiderKycPendingScreen({super.key});

  @override
  State<RiderKycPendingScreen> createState() => _RiderKycPendingScreenState();
}

class _RiderKycPendingScreenState extends State<RiderKycPendingScreen> {
  final supabase = Supabase.instance.client;
  String currentStatus = 'pending';
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _loadStatus();
  }

  Future<void> _loadStatus() async {
    try {
      final user = supabase.auth.currentUser;
      if (user != null) {
        final res = await supabase
            .from('rider_kyc')
            .select('kyc_status')
            .eq('user_id', user.id)
            .maybeSingle();
        if (res != null && mounted) {
          setState(() {
            currentStatus = res['kyc_status'] ?? 'pending';
            loading = false;
          });
        } else {
          if (mounted) setState(() => loading = false);
        }
      } else {
        if (mounted) setState(() => loading = false);
      }
    } catch (e) {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    String title = 'KYC Completed';
    String description = 'Thanks for submitting your document we’ll verify it\nand complete your KYC as soon as possible';
    
    if (currentStatus == 'under_review') {
      title = 'Under Admin Review';
      description = 'Your documents are currently under review by our administration team.\nWe will notify you once approved.';
    } else if (currentStatus == 'resubmitted') {
      title = 'KYC Resubmitted';
      description = 'Thanks for resubmitting your details. Our team is actively\nreviewing your updated documents.';
    }

    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: loading
              ? const Center(
                  child: CircularProgressIndicator(
                    color: Colors.black,
                    strokeWidth: 2.5,
                  ),
                )
              : Column(
                  children: [
                    const Spacer(flex: 3),

                    // Large wavy checkmark badge
                    const Icon(
                      Icons.verified,
                      size: 115,
                      color: Colors.black,
                    ),
                    const SizedBox(height: 16),

                    // Title
                    Text(
                      title,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        color: Colors.black,
                        letterSpacing: -0.4,
                      ),
                    ),

                    const Spacer(flex: 4),

                    // Description
                    Text(
                      description,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 13.5,
                        color: Color(0xFF333333),
                        height: 1.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 36),

                    // Pill Button
                    SizedBox(
                      width: double.infinity,
                      height: 56,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.black,
                          foregroundColor: Colors.white,
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(28),
                          ),
                        ),
                        onPressed: () => Navigator.pop(context),
                        child: const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.chevron_left_rounded,
                              color: Colors.white,
                              size: 24,
                            ),
                            SizedBox(width: 6),
                            Text(
                              'Back to home',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                letterSpacing: -0.2,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                    const Spacer(flex: 2),
                  ],
                ),
        ),
      ),
    );
  }
}