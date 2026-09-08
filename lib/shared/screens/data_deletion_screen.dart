import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:waydrop/shared/widgets/app_snackbar.dart';
import 'package:waydrop/core/services/cache/cache_cleanup_helper.dart';
import 'package:waydrop/core/services/session/user_session_service.dart';
import 'package:waydrop/shared/helpers/auth_session.dart';
import 'package:waydrop/features/auth/screens/login_screen.dart';

class DataDeletionScreen extends StatefulWidget {
  const DataDeletionScreen({super.key});

  @override
  State<DataDeletionScreen> createState() => _DataDeletionScreenState();
}

class _DataDeletionScreenState extends State<DataDeletionScreen> {
  final supabase = Supabase.instance.client;
  bool isSubmitting = false;
  bool agreeToTerms = false;

  Future<void> _confirmAndDelete() async {
    final confirmed = await _showLegalRetentionDialog();
    if (confirmed != true) return;
    await _deleteAccount();
  }

  Future<bool?> _showLegalRetentionDialog() {
    return showDialog<bool>(
      context: context,
      barrierDismissible: !isSubmitting,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF171A21),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text(
          'Delete your account permanently?',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 17),
        ),
        content: const Text(
          'This immediately signs you out everywhere and permanently disables sign-in with this phone '
          'number on this account. Your name, phone, email and photo are erased and cannot be recovered.\n\n'
          'By Indian law, some records (orders, payments, chats, delivery/verification photos, and rider '
          'KYC/financial records) must still be retained for fraud, tax and law-enforcement purposes -- '
          'these are securely archived and are never visible to you, other users, or through the app '
          'again. You can register a brand-new account with the same phone number afterwards; it will '
          'not be linked to this one.\n\n'
          'This action cannot be undone.',
          style: TextStyle(color: Color(0xFF94A3B8), fontSize: 13, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: isSubmitting ? null : () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel', style: TextStyle(color: Color(0xFF94A3B8))),
          ),
          TextButton(
            onPressed: isSubmitting ? null : () => Navigator.pop(dialogContext, true),
            child: const Text(
              'Delete permanently',
              style: TextStyle(color: Color(0xFFEF4444), fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteAccount() async {
    if (isSubmitting) return;
    setState(() => isSubmitting = true);

    try {
      await supabase.functions.invoke('delete-account', method: HttpMethod.post);

      // Server-side deletion succeeded (including server-side push-token cleanup for every
      // device -- see delete-account/index.ts) -- sign this device out immediately, mirroring
      // the sign-out sequence used by the normal "Sign Out" action elsewhere (profile_tab.dart /
      // rider_profile_tab.dart) so local state and realtime listeners are torn down consistently.
      // Every other signed-in device for this account is force-logged-out separately by
      // UserSessionService's real-time listener reacting to users.deleted_at, which the edge
      // function's Postgres step just set.
      await supabase.auth.signOut();
      await CacheCleanupHelper.clearAllCaches();
      AuthSession.clear();
      UserSessionService().stopListening();

      if (!mounted) return;
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (_) => const LoginScreen()),
        (_) => false,
      );
      showAppSnackBar(
        context,
        'Your account has been deleted.',
        type: SnackBarType.success,
      );
    } catch (e) {
      if (mounted) {
        showAppSnackBar(
          context,
          'Deletion failed: ${_extractErrorMessage(e)}',
          type: SnackBarType.error,
        );
      }
    } finally {
      if (mounted) {
        setState(() => isSubmitting = false);
      }
    }
  }

  String _extractErrorMessage(Object e) {
    if (e is FunctionException) {
      final details = e.details;
      // BUG FIX: delete-account returns {success:false, message: "..."} (see delete-account/
      // index.ts), not {error: "..."} -- this previously only checked the latter, so every
      // deletion failure (including the new "active trip" block) fell through to the generic
      // e.toString() below instead of showing the server's clear, user-facing message.
      if (details is Map) {
        final msg = details['message'] ?? details['error'];
        if (msg != null) return msg.toString();
      }
    }
    return e.toString();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1E222B),
      appBar: AppBar(
        backgroundColor: const Color(0xFF171A21),
        title: const Text(
          'DELETE ACCOUNT',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'ACCOUNT ERASURE & ANONYMIZATION',
              style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 15),
            const Text(
              'Deleting your account permanently signs you out and erases your personal details from '
              'WayDrop immediately. This cannot be undone, and the same phone number can only be used '
              'to create a brand-new, unrelated account afterwards.',
              style: TextStyle(color: Color(0xFF94A3B8), fontSize: 13, height: 1.5),
            ),
            const SizedBox(height: 24),

            _buildComplianceCard(
              title: 'Erased immediately',
              color: const Color(0xFFEF4444),
              items: [
                'Your name, phone number, email and profile photo.',
                'Sign-in access for this account -- permanently disabled.',
                'Active sessions on every device -- you are signed out everywhere.',
              ],
            ),
            const SizedBox(height: 16),

            _buildComplianceCard(
              title: 'What we are legally required to retain',
              color: const Color(0xFFF59E0B),
              items: [
                'Orders, ride/parcel history, payments, wallet transactions and GST records.',
                'Chat messages, pickup/delivery/verification photos, and parcel declarations.',
                'Rider KYC evidence (Aadhaar/PAN/DL/RC/insurance), earnings and ratings, where applicable.',
                'These are moved to a secure legal archive accessible only to authorized WayDrop staff '
                    'for fraud investigation, tax audits, and law-enforcement or court requests -- never '
                    'visible to any user or through the app.',
              ],
            ),
            const SizedBox(height: 30),

            Row(
              children: [
                Checkbox(
                  value: agreeToTerms,
                  activeColor: const Color(0xFF10B981),
                  onChanged: isSubmitting ? null : (val) => setState(() => agreeToTerms = val ?? false),
                ),
                const Expanded(
                  child: Text(
                    'I understand this action is immediate, irreversible, and my account cannot be recovered.',
                    style: TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),

            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: agreeToTerms ? const Color(0xFFEF4444) : Colors.grey.withValues(alpha: 0.3),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: (agreeToTerms && !isSubmitting) ? _confirmAndDelete : null,
                child: isSubmitting
                    ? const SizedBox(
                        height: 22,
                        width: 22,
                        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5),
                      )
                    : const Text(
                        'DELETE MY ACCOUNT',
                        style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, letterSpacing: 1.1),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildComplianceCard({
    required String title,
    required Color color,
    required List<String> items,
  }) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: const Color(0xFF171A21),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF1E293B)),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(width: 4, height: 16, color: color),
              const SizedBox(width: 8),
              Text(
                title,
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Column(
            children: items.map((item) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 4.0),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('• ', style: TextStyle(color: Color(0xFF94A3B8), fontSize: 13)),
                    Expanded(
                      child: Text(
                        item,
                        style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12, height: 1.4),
                      ),
                    ),
                  ],
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }
}
