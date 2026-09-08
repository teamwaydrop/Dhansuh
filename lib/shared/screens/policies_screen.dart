import 'package:flutter/material.dart';

class PoliciesScreen extends StatelessWidget {
  const PoliciesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        backgroundColor: const Color(0xFF1E222B),
        appBar: AppBar(
          backgroundColor: const Color(0xFF171A21),
          title: const Text(
            'POLICIES & LEGAL',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
          ),
          bottom: const TabBar(
            indicatorColor: Color(0xFF10B981),
            labelColor: Color(0xFF10B981),
            unselectedLabelColor: Colors.grey,
            tabs: [
              Tab(text: 'Privacy'),
              Tab(text: 'Terms'),
              Tab(text: 'Refunds'),
            ],
          ),
        ),
        body: const TabBarView(
          children: [
            _PolicyTextTab(
              title: 'PRIVACY POLICY',
              content: 'Last Updated: June 16, 2026\n\n'
                  'WayDrop ("we", "us", or "our") values your privacy. This Privacy Policy describes how we collect, use, and share your personal data when you use the WayDrop mobile application and platforms.\n\n'
                  '1. DATA WE COLLECT\n'
                  '- Account Information: Name, phone number, email address, profile picture.\n'
                  '- Location Data: Precise GPS coordinates from Drop Partners (background location for tracking) and users (for pickup/dropoff).\n'
                  '- Financial Records: Wallet transactions, ledger logs, and payout credentials.\n'
                  '- Compliance Records: Identification proofs and verification pictures.\n\n'
                  '2. HOW WE USE YOUR DATA\n'
                  '- To connect users with nearby transport partners.\n'
                  '- To process secure cash/wallet settlements and payments.\n'
                  '- To track live rides for user safety and order transparency.\n'
                  '- To prevent fraud and abuse on our network.\n\n'
                  '3. DATA SHARING & RETENTION\n'
                  '- We do not sell your personal data.\n'
                  '- Location telemetry is shared only during active orders and deleted or anonymized within 90 days.\n'
                  '- Financial transactions are stored securely and retained for accounting compliance.',
            ),
            _PolicyTextTab(
              title: 'TERMS OF SERVICE',
              content: 'Last Updated: June 16, 2026\n\n'
                  'By accessing or using WayDrop, you agree to comply with and be bound by these Terms of Service.\n\n'
                  '1. PLATFORM USAGE\n'
                  '- You must be at least 18 years old to register an account.\n'
                  '- You agree to provide accurate registration details (name, phone, vehicle records).\n'
                  '- Any fraud, self-matching, or account spoofing will result in immediate permanent suspension.\n\n'
                  '2. FARES AND PAYMENT TERMS\n'
                  '- Fares are calculated dynamically based on distance, time, and service zones.\n'
                  '- Payment can be made in Cash directly to the Drop Partner or via Wallet top-ups.\n'
                  '- Double-entry wallet transactions are immutable. Ledger corrections are processed as adjustment transactions.\n\n'
                  '3. DROP PARTNER OBLIGATIONS\n'
                  '- Drop Partners must maintain valid transport licenses and verify pickups using OTP sheets.\n'
                  '- High cancellation rates or failing to upload package proofs can lead to platform lockout.',
            ),
            _PolicyTextTab(
              title: 'REFUND POLICY',
              content: 'Last Updated: June 16, 2026\n\n'
                  'We strive to maintain a transparent charging structure for our users and Drop Partners.\n\n'
                  '1. TRIP CANCELLATION CHARGES\n'
                  '- If a user cancels a ride 5 minutes after a Drop Partner is assigned, a cancellation fee of ₹50 may apply to cover the Drop Partner\'s travel cost.\n'
                  '- If a Drop Partner cancels the ride, no cancellation fee applies to the user.\n\n'
                  '2. WALLET REFUNDS\n'
                  '- Wallet balances topped up by card payments can be refunded back to the source bank account upon request. Contact support through the support chat to raise a refund request -- our team will process eligible refunds manually.\n'
                  '- Promotional bonuses or referral credits are non-refundable and cannot be settled in cash.\n\n'
                  '3. DISPUTE RESOLUTION\n'
                  '- Fare disputes must be raised within 48 hours of order completion through the support chat.',
            ),
          ],
        ),
      ),
    );
  }
}

class _PolicyTextTab extends StatelessWidget {
  final String title;
  final String content;

  const _PolicyTextTab({
    required this.title,
    required this.content,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.0,
            ),
          ),
          const SizedBox(height: 15),
          Text(
            content,
            style: const TextStyle(
              color: Color(0xFF94A3B8),
              fontSize: 13,
              height: 1.6,
            ),
          ),
        ],
      ),
    );
  }
}
