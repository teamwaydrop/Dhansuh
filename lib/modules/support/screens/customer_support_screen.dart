import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:waydrop/modules/chat/screens/order_chat_screen.dart';

class CustomerSupportScreen extends StatefulWidget {
  const CustomerSupportScreen({super.key});

  @override
  State<CustomerSupportScreen> createState() => _CustomerSupportScreenState();
}

class _CustomerSupportScreenState extends State<CustomerSupportScreen> {
  Future<void> _launchEmail(String email, {String subject = 'WayDrop Support Query'}) async {
    final Uri emailLaunchUri = Uri(
      scheme: 'mailto',
      path: email,
      queryParameters: {
        'subject': subject,
      },
    );
    try {
      await launchUrl(emailLaunchUri);
    } catch (e) {
      debugPrint('Could not launch email: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    // Forcing a clean and professional white background style
    const Color scaffoldBgColor = Colors.white;
    const Color textColor = Color(0xFF0F172A);
    const Color textGrayColor = Color(0xFF64748B);
    const Color dividerColor = Color(0xFFE2E8F0);
    const Color primaryLime = Color(0xFF10B981);

    return Theme(
      data: ThemeData.light().copyWith(
        scaffoldBackgroundColor: scaffoldBgColor,
        appBarTheme: const AppBarTheme(
          backgroundColor: scaffoldBgColor,
          elevation: 0,
          iconTheme: IconThemeData(color: textColor),
          titleTextStyle: TextStyle(
            color: textColor,
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
      child: Scaffold(
        backgroundColor: scaffoldBgColor,
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
            onPressed: () => Navigator.pop(context),
          ),
          title: const Text('Help & Legal Policies'),
          centerTitle: true,
          shape: const Border(
            bottom: BorderSide(color: dividerColor, width: 1),
          ),
        ),
        body: SafeArea(
          child: SingleChildScrollView(
            physics: const ClampingScrollPhysics(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 1. Professional support SLA message banner
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.all(16),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF8FAFC),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: dividerColor),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Usually problems with order or anyother will resolve in 24 hours ,if it has not been solved , please free to react out us on our mail:',
                        style: TextStyle(
                          fontSize: 13.5,
                          height: 1.5,
                          color: Color(0xFF334155),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 8),
                      GestureDetector(
                        onTap: () => _launchEmail('waydroptech@gmail.com', subject: 'WayDrop Support Query'),
                        child: const Text(
                          'waydroptech@gmail.com',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF10B981),
                            decoration: TextDecoration.underline,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'Live chat support will be added soon.',
                        style: TextStyle(
                          fontSize: 12,
                          color: Color(0xFF64748B),
                          fontStyle: FontStyle.italic,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 8),

                // 2. Help & FAQs Section
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    'HELP & FAQS',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: textGrayColor,
                      letterSpacing: 0.8,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                _buildMenuRow(
                  title: 'Frequently Asked Questions (FAQs)',
                  icon: Icons.help_outline_rounded,
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const FaqScreen(),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 20),

                // 3. Legal and policies list view (Flipkart style)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    'LEGAL & COMPLIANCE',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: textGrayColor,
                      letterSpacing: 0.8,
                    ),
                  ),
                ),
                const SizedBox(height: 8),

                _buildMenuRow(
                  title: 'Terms of Use & Conditions',
                  icon: Icons.gavel_rounded,
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => LegalReaderScreen(
                          title: 'Terms & Conditions',
                          lastUpdated: 'May 22, 2026',
                          paragraphs: termsAndConditionsContent,
                        ),
                      ),
                    );
                  },
                ),
                _buildMenuRow(
                  title: 'Privacy Policy',
                  icon: Icons.privacy_tip_outlined,
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => LegalReaderScreen(
                          title: 'Privacy Policy',
                          lastUpdated: 'May 22, 2026',
                          paragraphs: privacyPolicyContent,
                        ),
                      ),
                    );
                  },
                ),
                _buildMenuRow(
                  title: 'Refund & Cancellation Policy',
                  icon: Icons.receipt_long_rounded,
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => LegalReaderScreen(
                          title: 'Refund & Cancellation Policy',
                          lastUpdated: 'June 2026',
                          paragraphs: refundPolicyContent,
                        ),
                      ),
                    );
                  },
                ),
                _buildMenuRow(
                  title: 'Grievance Officer Redressal Details',
                  icon: Icons.badge_outlined,
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const GrievanceDetailsScreen(),
                      ),
                    );
                  },
                ),

                const SizedBox(height: 24),

                // Corporate details at bottom
                const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24.0),
                    child: Text(
                      'WAY DROP TECH PRIVATE LIMITED\n© 2026. All rights reserved.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 12,
                        color: textGrayColor,
                        height: 1.4,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMenuRow({
    required String title,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    const Color textColor = Color(0xFF0F172A);
    const Color dividerColor = Color(0xFFE2E8F0);

    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        decoration: const BoxDecoration(
          border: Border(
            bottom: BorderSide(color: dividerColor, width: 0.5),
          ),
        ),
        child: Row(
          children: [
            Icon(icon, size: 20, color: const Color(0xFF475569)),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w600,
                  color: textColor,
                ),
              ),
            ),
            const Icon(Icons.chevron_right_rounded, size: 20, color: Color(0xFF94A3B8)),
          ],
        ),
      ),
    );
  }
}

// ── REUSABLE LEGAL POLICY READER SCREEN ─────────────────────────────────────
class LegalReaderScreen extends StatelessWidget {
  final String title;
  final String lastUpdated;
  final List<Map<String, String>> paragraphs;

  const LegalReaderScreen({
    super.key,
    required this.title,
    required this.lastUpdated,
    required this.paragraphs,
  });

  @override
  Widget build(BuildContext context) {
    const Color scaffoldBgColor = Colors.white;
    const Color textColor = Color(0xFF0F172A);
    const Color dividerColor = Color(0xFFE2E8F0);

    return Theme(
      data: ThemeData.light().copyWith(scaffoldBackgroundColor: scaffoldBgColor),
      child: Scaffold(
        backgroundColor: scaffoldBgColor,
        appBar: AppBar(
          backgroundColor: scaffoldBgColor,
          elevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20, color: textColor),
            onPressed: () => Navigator.pop(context),
          ),
          title: Text(
            title,
            style: const TextStyle(color: textColor, fontSize: 16, fontWeight: FontWeight.bold),
          ),
          centerTitle: true,
          shape: const Border(
            bottom: BorderSide(color: dividerColor, width: 1),
          ),
        ),
        body: SafeArea(
          child: SingleChildScrollView(
            physics: const ClampingScrollPhysics(),
            padding: const EdgeInsets.all(20.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Last updated / Effective: $lastUpdated',
                  style: const TextStyle(
                    fontSize: 12.5,
                    color: Color(0xFF64748B),
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 16),
                ...paragraphs.map((sec) {
                  final String heading = sec['heading'] ?? '';
                  final String body = sec['body'] ?? '';
                  final bool isBoldHeading = sec['style'] == 'title';

                  return Padding(
                    padding: const EdgeInsets.only(bottom: 20.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (heading.isNotEmpty) ...[
                          Text(
                            heading,
                            style: TextStyle(
                              fontSize: isBoldHeading ? 17 : 14.5,
                              fontWeight: FontWeight.bold,
                              color: textColor,
                              height: 1.35,
                            ),
                          ),
                          const SizedBox(height: 6),
                        ],
                        if (body.isNotEmpty)
                          Text(
                            body,
                            style: const TextStyle(
                              fontSize: 13.5,
                              color: Color(0xFF334155),
                              height: 1.55,
                            ),
                          ),
                      ],
                    ),
                  );
                }),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── GRIEVANCE REDRESSAL COMPLIANCE DETAILS SCREEN ───────────────────────────
class GrievanceDetailsScreen extends StatelessWidget {
  const GrievanceDetailsScreen({super.key});

  Future<void> _launchEmail(String email) async {
    final Uri emailLaunchUri = Uri(
      scheme: 'mailto',
      path: email,
      queryParameters: {
        'subject': 'Grievance Query - WayDrop Compliance',
      },
    );
    try {
      await launchUrl(emailLaunchUri);
    } catch (e) {
      debugPrint('Could not launch email: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    const Color scaffoldBgColor = Colors.white;
    const Color textColor = Color(0xFF0F172A);
    const Color textGrayColor = Color(0xFF64748B);
    const Color dividerColor = Color(0xFFE2E8F0);
    const Color primaryLime = Color(0xFF10B981);

    return Theme(
      data: ThemeData.light().copyWith(scaffoldBackgroundColor: scaffoldBgColor),
      child: Scaffold(
        backgroundColor: scaffoldBgColor,
        appBar: AppBar(
          backgroundColor: scaffoldBgColor,
          elevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20, color: textColor),
            onPressed: () => Navigator.pop(context),
          ),
          title: const Text('Grievance Redressal', style: TextStyle(color: textColor, fontSize: 16, fontWeight: FontWeight.bold)),
          centerTitle: true,
          shape: const Border(
            bottom: BorderSide(color: dividerColor, width: 1),
          ),
        ),
        body: SafeArea(
          child: SingleChildScrollView(
            physics: const ClampingScrollPhysics(),
            padding: const EdgeInsets.all(20.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Grievance Redressal Mechanism',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: textColor,
                    letterSpacing: -0.4,
                  ),
                ),
                const SizedBox(height: 10),
                const Text(
                  'In accordance with the Information Technology Act and Consumer Protection Rules, the details of the Grievance Officer for the Platform are provided below:',
                  style: TextStyle(
                    fontSize: 13.5,
                    color: textGrayColor,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 24),

                // Officer Profile Row Card
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF8FAFC),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: dividerColor),
                  ),
                  child: Column(
                    children: [
                      _buildDetailRow('Name', 'Dhanush Kumar Minnakanti / Vishal Mummadi', textColor, textGrayColor),
                      const Divider(height: 24, color: dividerColor),
                      _buildDetailRow('Designation', 'Grievance Officer, Way Drop Tech Private Limited', textColor, textGrayColor),
                      const Divider(height: 24, color: dividerColor),
                      _buildDetailRow(
                        'Email',
                        'waydroptech@gmail.com',
                        primaryLime,
                        textGrayColor,
                        isLink: true,
                        onTap: () => _launchEmail('waydroptech@gmail.com'),
                      ),
                      const Divider(height: 24, color: dividerColor),
                      _buildDetailRow(
                        'Address',
                        'H. No. 6-50, Ramalayam Back Side, Nagineniprolu, Burgampahad, Khammam, Telangana - 507114, India.',
                        textColor,
                        textGrayColor,
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 28),
                const Text(
                  'Escalation & Resolution Timelines',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: textColor,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  '• Upon receipt of a Consumer Grievance, the Consumer shall receive an acknowledgment for their grievance within 48 (Forty-Eight) hours through email, phone call, or SMS.\n\n• The Company is committed to resolving any complaints or queries regarding order issues or safety within a maximum timeline of 24 hours. General disputes or compliance issues will be resolved in a structured manner within 15 days.',
                  style: TextStyle(
                    fontSize: 13.5,
                    color: textGrayColor,
                    height: 1.55,
                  ),
                ),
                const SizedBox(height: 28),
                const Text(
                  'Corporate Headquarters Contact',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: textColor,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'WAY DROP TECH PRIVATE LIMITED\nEmail: contact@waydrop.in\nSupport Hours: Monday to Saturday, 9:00 AM to 6:00 PM IST',
                  style: TextStyle(
                    fontSize: 13.5,
                    color: textGrayColor,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDetailRow(String label, String value, Color valueColor, Color labelColor, {bool isLink = false, VoidCallback? onTap}) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 90,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: labelColor,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: InkWell(
            onTap: onTap,
            child: Text(
              value,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: valueColor,
                decoration: isLink ? TextDecoration.underline : TextDecoration.none,
                height: 1.4,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ── VERBATIM POLICY CONTENTS ────────────────────────────────────────────────
final List<Map<String, String>> termsAndConditionsContent = [
  {
    'heading': 'Interpretation and Definitions',
    'body': '',
    'style': 'title',
  },
  {
    'heading': 'Interpretation',
    'body': 'The words whose initial letters are capitalized have meanings defined under the following conditions. The following definitions shall have the same meaning regardless of whether they appear in singular or plural.',
  },
  {
    'heading': 'Definitions',
    'body': 'For the purposes of these Terms and Conditions:\n\n'
        '• Application means the software program provided by the Company downloaded by You on any electronic device, named Way Drop.\n\n'
        '• Application Store means the digital distribution service operated and developed by Apple Inc. (Apple App Store) or Google LLC (Google Play Store) in which the Application has been downloaded.\n\n'
        '• Affiliate means an entity that controls, is controlled by, or is under common control with a party.\n\n'
        '• Country refers to: India\n\n'
        '• Company (referred to as either "the Company", "We", "Us" or "Our" in these Terms and Conditions) refers to WAY DROP TECH PRIVATE LIMITED, H. No. 6-50, Ramalayam Back Side, Nagineniprolu, Burgampahad, Khammam, Telangana - 507114, India.\n\n'
        '• Device means any device that can access the Service such as a computer, a cell phone or a digital tablet.\n\n'
        '• Service refers to the Application, the Website or both.\n\n'
        '• Terms and Conditions (also referred to as "Terms") means these Terms and Conditions.\n\n'
        '• Website refers to Way Drop, accessible from https://waydroptechs.netlify.app\n\n'
        '• You means the individual accessing or using the Service, or the company, or other legal entity on behalf of which such individual is accessing or using the Service, as applicable.',
  },
  {
    'heading': 'Acknowledgment',
    'body': 'These are the Terms and Conditions governing the use of this Service and the agreement between You and the Company. These Terms and Conditions set out the rights and obligations of all users regarding the use of the Service.\n\n'
        'Your access to and use of the Service is conditioned on Your acceptance of and compliance with these Terms and Conditions.\n\n'
        'By accessing or using the Service You agree to be bound by these Terms and Conditions. If You disagree with any part of these Terms and Conditions then You may not access the Service.\n\n'
        'You represent that You are over the age of 18. The Company does not permit those under 18 to use the Service.\n\n'
        'Your access to and use of the Service is also subject to Our Privacy Policy, which describes how We collect, use and disclose personal information. Please read Our Privacy Policy carefully before using Our Service.',
  },
  {
    'heading': 'Account Registration',
    'body': 'Accounts are generated directly using your mobile phone number and verified through OTP authentication. You are responsible for maintaining the confidentiality of your account credentials and access to your device.',
  },
  {
    'heading': 'Services and Payments',
    'body': 'Way Drop facilitates city rides, parcel deliveries and community-based logistics services. Users are responsible for paying all applicable fares, delivery fees, taxes and charges associated with the Service. Payments may be processed through trusted third-party payment gateways integrated within the Platform.\n\n'
        'Refund processing timelines may vary depending on payment providers, banks and applicable financial systems.',
  },
  {
    'heading': 'Platform Role Disclaimer',
    'body': 'Way Drop acts as a technology platform connecting users, Drop Partners and delivery partners. The Company does not guarantee the conduct, quality, safety, legality or availability of individual users, Drop Partners or third-party partners.\n\n'
        'Independent Contractor Relationship: Drop Partners registered on the Platform are independent third-party contractors and NOT employees, agents, or partners of WAY DROP TECH PRIVATE LIMITED. Drop Partners retain the absolute right to log in, log out, accept, or decline service requests at their own sole discretion.',
  },
  {
    'heading': 'Prohibited Activities',
    'body': 'Users agree not to misuse the Platform or engage in illegal, fraudulent, abusive, harmful or unsafe activities while using the Service.\n\n'
        'Prohibited Items & Activities: Users are strictly prohibited from utilizing the Service to transport, move, or deliver the following items:\n'
        '• Cash, currency notes, coins, gold, silver, diamonds, precious stones, or high-value jewelry.\n'
        '• Alcohol, liquor, illegal drugs, narcotics, psychotropic substances, or any government-banned materials.\n'
        '• Weapons, firearms, ammunition, firecrackers, hazardous chemicals, or explosive liquids.\n\n'
        'Any violation will result in immediate account termination, and the Company will cooperate fully with law enforcement agencies.',
  },
  {
    'heading': 'Intellectual Property',
    'body': 'The Service, its original content, logos, brand names, designs and related materials are the exclusive property of Way Drop Tech Private Limited.',
  },
  {
    'heading': 'Links to Other Websites',
    'body': 'Our Service may contain links to third-party websites or services that are not owned or controlled by the Company.\n\n'
        'The Company has no control over, and assumes no responsibility for, the content, privacy policies or practices of any third-party websites or services. You further acknowledge and agree that the Company shall not be responsible or liable, directly or indirectly, for any damage or loss caused or alleged to be caused by or in connection with the use of or reliance on any such content, goods or services available on or through any such websites or services.',
  },
  {
    'heading': 'Termination',
    'body': 'We may terminate or suspend Your access immediately, without prior notice or liability, for any reason whatsoever, including without limitation if You breach these Terms and Conditions.\n\n'
        'Upon termination, Your right to use the Service will cease immediately.',
  },
  {
    'heading': 'Limitation of Liability',
    'body': 'Limitation of Liability & Parcel Loss Cap: To the maximum extent permitted by applicable law, the total structural value of any parcel sent through Way Drop must not exceed ₹5,000. In the event of parcel loss, damage, or theft during transit, the maximum aggregate liability of the Company to any user shall be strictly capped at ₹2,000 or the actual value of the parcel (whichever is lower), subject to verification of genuine purchase invoices.\n\n'
        'To the maximum extent permitted by applicable law, in no event shall the Company or its suppliers be liable for any special, incidental, indirect or consequential damages whatsoever.',
  },
  {
    'heading': '"AS IS" and "AS AVAILABLE" Disclaimer',
    'body': 'The Service is provided to You "AS IS" and "AS AVAILABLE" and with all faults and defects without warranty of any kind.\n\n'
        'Without limiting the foregoing, neither the Company nor any of the Company\'s providers makes any representation or warranty of any kind, express or implied:\n'
        '• As to the operation or availability of the Service\n'
        '• That the Service will be uninterrupted or error-free\n'
        '• As to the accuracy, reliability or currency of information provided\n'
        '• That the Service, servers, content or emails sent from the Company are free of viruses or harmful components',
  },
  {
    'heading': 'Governing Law',
    'body': 'The laws of India, excluding its conflicts of law rules, shall govern these Terms and Your use of the Service. Your use of the Application may also be subject to other local, state, national or international laws. These Terms shall be under the exclusive jurisdiction of the courts located in Telangana, India.',
  },
  {
    'heading': 'Disputes Resolution',
    'body': 'If You have any concern or dispute about the Service, You agree to first try to resolve the dispute informally by contacting the Company.',
  },
  {
    'heading': 'Severability and Waiver',
    'body': '',
    'style': 'title',
  },
  {
    'heading': 'Severability',
    'body': 'If any provision of these Terms is held to be unenforceable or invalid, such provision will be changed and interpreted to accomplish the objectives of such provision to the greatest extent possible under applicable law and the remaining provisions will continue in full force and effect.',
  },
  {
    'heading': 'Waiver',
    'body': 'Except as provided herein, the failure to exercise a right or to require performance of an obligation under these Terms shall not affect a party\'s ability to exercise such right or require such performance at any time thereafter, nor shall the waiver of a breach constitute a waiver of any subsequent breach.',
  },
  {
    'heading': 'Changes to These Terms and Conditions',
    'body': 'We reserve the right, at Our sole discretion, to modify or replace these Terms at any time. If a revision is material, We will make reasonable efforts to provide at least 30 days notice prior to any new terms taking effect. What constitutes a material change will be determined at Our sole discretion.\n\n'
        'By continuing to access or use Our Service after those revisions become effective, You agree to be bound by the revised Terms. If You do not agree to the new Terms, in whole or in part, please stop using the Service.',
  },
  {
    'heading': 'Grievance Officer & Contact Us',
    'body': 'In accordance with the Information Technology Act and Consumer Protection Rules, the details of the Grievance Officer for the Platform are:\n\n'
        'Name: Dhanush Kumar Minnakanti / Vishal Mummadi\n'
        'Designation: Grievance Officer, Way Drop Tech Private Limited\n'
        'Email: waydroptech@gmail.com\n'
        'Address: H. No. 6-50, Ramalayam Back Side, Nagineniprolu, Burgampahad, Khammam, Telangana - 507114, India.\n\n'
        'Support Hours: Monday to Saturday, 9:00 AM to 6:00 PM IST',
  },
];

final List<Map<String, String>> privacyPolicyContent = [
  {
    'heading': 'Interpretation and Definitions',
    'body': '',
    'style': 'title',
  },
  {
    'heading': 'Interpretation',
    'body': 'The words whose initial letters are capitalized have meanings defined under the following conditions. The following definitions shall have the same meaning regardless of whether they appear in singular or plural.',
  },
  {
    'heading': 'Definitions',
    'body': 'For the purposes of this Privacy Policy:\n\n'
        '• Account means a unique account created for You to access our Service or parts of our Service.\n\n'
        '• Application refers to Way Drop, the software program provided by the Company.\n\n'
        '• Company (referred to as either "the Company", "We", "Us" or "Our" in this Privacy Policy) refers to WAY DROP TECH PRIVATE LIMITED, H. No. 6-50, Ramalayam Back Side, Nagineniprolu, Burgampahad, Khammam, Telangana - 507114, India.\n\n'
        '• Country refers to: India\n\n'
        '• Device means any device that can access the Service such as a computer, a cell phone or a digital tablet.\n\n'
        '• Personal Data is any information that relates to an identified or identifiable individual.\n\n'
        '• Service refers to the Application, the Website or both.\n\n'
        '• Website refers to Way Drop, accessible from https://waydroptechs.netlify.app',
  },
  {
    'heading': 'Collecting and Using Your Personal Data',
    'body': '',
    'style': 'title',
  },
  {
    'heading': 'Types of Data Collected - Personal Data',
    'body': 'While using Our Service, We may ask You to provide Us with certain personally identifiable information that can be used to contact or identify You. Personally identifiable information may include, but is not limited to:\n'
        '• Email address\n'
        '• First name and last name\n'
        '• Phone number\n'
        '• Address, State, Province, ZIP/Postal code, City',
  },
  {
    'heading': 'Information Collected while Using the Application',
    'body': 'While using Our Application, in order to provide features of Our Application, We may collect, with Your prior permission:\n\n'
        '• Information regarding your precise and live location for ride matching, parcel tracking and navigation purposes.\n'
        '• Pictures and other information from your Device\'s camera and photo library.\n'
        '• Notification permissions for service updates and alerts.\n'
        '• Storage permissions required for uploading documents and images.\n'
        '• Device information such as device model, operating system version and app diagnostics.\n\n'
        '• Network & Device Identifiers: We automatically collect network-related information including your Internet Protocol (IP) address, mobile network operator details, device identifiers (such as Android ID, UUID, or IMEI), and application crash logs to enhance cyber security, server stability, and fraud prevention.\n\n'
        '• User Accounts & e-KYC: To use Way Drop services, users must register using a valid phone number and OTP verification. For Drop Partners, We collect government-issued identity documents including Aadhaar Card, Driving License, PAN Card, Vehicle Registration Certificate (RC), and Insurance documents for verification, safety, fraud prevention, and legal compliance.\n\n'
        '• User-to-User Data Sharing: To facilitate rides and parcel deliveries, We share necessary information such as name, vehicle details and live location between paired users (Drop Partners, passengers, senders, and receivers).\n\n'
        '• Payments Data: Payments are processed securely through trusted third-party payment service providers and gateways. We do not directly store your credit card, debit card, bank account details, CVV or UPI PIN on our servers.\n\n'
        '• Third-Party Services: We use trusted third-party providers for payment processing, analytics, hosting, notifications, support, and mapping (specifically utilizing Ola Maps APIs for real-time navigation, ride tracking, and distance calculations).',
  },
  {
    'heading': 'Use of Your Personal Data',
    'body': 'The Company may use Personal Data for the following purposes:\n\n'
        '• To provide and maintain our Service, including monitoring usage.\n'
        '• To manage Your Account: to manage Your registration as a user.\n'
        '• For the performance of a contract: for rides, parcel deliveries, transactions and related services.\n'
        '• To contact You: by email, phone calls, SMS, notifications or other forms of electronic communication.\n'
        '• To improve safety and security: including fraud prevention, suspicious activity detection, identity verification and abuse prevention.\n'
        '• To comply with legal obligations: including requests from law enforcement agencies, government authorities or courts where required by law.',
  },
  {
    'heading': 'User Responsibilities',
    'body': 'Users are responsible for providing accurate and updated information during registration and while using the Service. Users are also responsible for maintaining the confidentiality of their account credentials and OTP verification access.',
  },
  {
    'heading': 'Fraud Prevention & Account Suspension',
    'body': 'The Company reserves the right to suspend, restrict or terminate accounts involved in fraudulent, abusive, illegal, suspicious, unsafe or policy-violating activities without prior notice. We reserve the right to investigate complaints, violations or misuse of the Platform and cooperate with law enforcement authorities when required.',
  },
  {
    'heading': 'Retention and Transfer of Your Personal Data',
    'body': 'The Company will retain Your Personal Data only for as long as necessary for the purposes set out in this Privacy Policy. Your information may be processed at the Company\'s operating offices and in locations where service providers or related parties operate.',
  },
  {
    'heading': 'Delete Your Personal Data',
    'body': 'You have the right to delete or request assistance in deleting the Personal Data collected about You. Users may request deletion of their account and associated data directly from the Application Settings or by contacting Us through the email:\n\n'
        'Account Deletion Email: contact@waydrop.in',
  },
  {
    'heading': 'Security & Children\'s Privacy',
    'body': 'The security of Your Personal Data is important to Us. We implement reasonable security measures. However, no method of transmission is completely secure.\n\n'
        'Our Service does not address anyone under the age of 18. We do not knowingly collect personally identifiable information from individuals below 18 years of age. If You are a parent or guardian and become aware that Your child has provided Personal Data, please contact Us immediately.',
  },
  {
    'heading': 'Grievance Officer & Contact Info',
    'body': 'If you have any privacy-related concerns, data deletion requests, or complaints, please reach out to our designated officer:\n\n'
        'Email: contact@waydrop.in\n'
        'Address: WAY DROP TECH PRIVATE LIMITED, H. No. 6-50, Ramalayam Back Side, Nagineniprolu, Burgampahad, Khammam, Telangana - 507114, India.\n\n'
        'Support Hours: Monday to Saturday, 9:00 AM to 6:00 PM IST',
  },
];

final List<Map<String, String>> refundPolicyContent = [
  {
    'heading': '1. Cancellation Policy',
    'body': '',
    'style': 'title',
  },
  {
    'heading': 'A. City Rides',
    'body': '• Free Cancellation: Users may cancel a ride request completely free of charge before a Drop Partner accepts the request.\n\n'
        '• Chargeable Cancellation: If a cancellation is initiated after a Drop Partner has been assigned and is en route to the pickup location, a nominal cancellation fee will be levied to compensate for the Drop Partner\'s time and fuel.',
  },
  {
    'heading': 'B. Parcel Delivery',
    'body': '• Pre-Pickup (Cancellable): Senders can cancel a parcel delivery request for a full refund only if the cancellation is made before the delivery partner arrives at the pickup location.\n\n'
        '• Post-Pickup (Non-Cancellable): Once a parcel has been picked up and is in transit, the order is strictly non-cancellable. Under no circumstances will the delivery fee be refunded after the transit has commenced.',
  },
  {
    'heading': '2. Refund Policy',
    'body': '',
    'style': 'title',
  },
  {
    'heading': 'A. Failed or Unsuccessful Transactions',
    'body': 'If a payment is successfully deducted from your bank account, UPI, or card, but the transaction fails on our system or the service is not rendered, an automatic full refund will be initiated by the Company.',
  },
  {
    'heading': 'B. Refund Processing Timelines',
    'body': 'All approved refunds will be credited back to the user\'s original method of payment. Please allow 5 to 7 business days for the amount to successfully reflect in your account. (Note: Exact timelines are subject to the respective banking partners and payment gateway processing cycles).',
  },
  {
    'heading': 'C. Parcel Loss or Damage Liability',
    'body': 'As explicitly stated in our overarching Terms and Conditions, the total structural or monetary value of any parcel sent through Way Drop must not exceed ₹5,000.\n\n'
        'In the rare event of parcel loss, damage, or theft during transit, the Company\'s maximum aggregate liability to any user is strictly capped at ₹2,000 or the actual value of the parcel (whichever is lower).\n\n'
        'Any claim must be supported by the submission of valid, genuine purchase invoices for verification.',
  },
  {
    'heading': '3. Contact and Grievance Redressal',
    'body': 'For any disputes, refund claims, or cancellation inquiries, users are advised to contact our official Support Team directly:\n\n'
        'Email: contact@waydrop.in\n'
        'Support Hours: Monday to Saturday, 9:00 AM to 6:00 PM IST',
  },
];

// ── CUSTOMER SUPPORT FAQ SCREEN ─────────────────────────────────────────────
class FaqScreen extends StatefulWidget {
  const FaqScreen({super.key});

  @override
  State<FaqScreen> createState() => _FaqScreenState();
}

class _FaqScreenState extends State<FaqScreen> {
  int _expandedIndex = -1;

  final List<Map<String, String>> _faqs = [
    {
      'question': 'How do I track my delivery or ride in real-time?',
      'answer': 'Once your order matches with a Drop Partner, a live tracking map will automatically appear on your screen. You can also view active orders and track them at any time from the Activity tab on the home screen.',
    },
    {
      'question': 'What are the parcel size and weight capacity limits?',
      'answer': 'For local deliveries, parcels must fit safely on a motorcycle. For intercity parcel shipments, the maximum luggage weight preference limit is strictly capped at 50 kg per travel plan.',
    },
    {
      'question': 'What items are prohibited from being transported?',
      'answer': 'To ensure safety and legal compliance, you are strictly prohibited from sending cash/currency, jewelry/precious stones, alcohol/drugs, weapons/firearms, or hazardous chemicals. Accounts violating these rules are subject to immediate suspension.',
    },
    {
      'question': 'How are cancellation fees calculated?',
      'answer': 'Cancellations are completely free of charge before a Drop Partner has accepted your booking request. If you cancel after a partner is assigned and en route to the pickup point, a nominal cancellation fee is charged to compensate the partner.',
    },
    {
      'question': 'How long does a refund processing take?',
      'answer': 'If a booking fails or is canceled under eligible refund terms, the amount will be automatically initiated for refund. It generally takes 5 to 7 business days to reflect in your original payment method, depending on bank processing cycles.',
    },
  ];

  @override
  Widget build(BuildContext context) {
    const Color scaffoldBgColor = Colors.white;
    const Color textColor = Color(0xFF0F172A);
    const Color dividerColor = Color(0xFFE2E8F0);

    return Theme(
      data: ThemeData.light().copyWith(scaffoldBackgroundColor: scaffoldBgColor),
      child: Scaffold(
        backgroundColor: scaffoldBgColor,
        appBar: AppBar(
          backgroundColor: scaffoldBgColor,
          elevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20, color: textColor),
            onPressed: () => Navigator.pop(context),
          ),
          title: const Text(
            'FAQs',
            style: TextStyle(color: textColor, fontSize: 16, fontWeight: FontWeight.bold),
          ),
          centerTitle: true,
          shape: const Border(
            bottom: BorderSide(color: dividerColor, width: 1),
          ),
        ),
        body: SafeArea(
          child: ListView.builder(
            physics: const ClampingScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
            itemCount: _faqs.length,
            itemBuilder: (context, index) {
              final isExpanded = _expandedIndex == index;
              final faq = _faqs[index];

              return Container(
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: const Color(0xFFF8FAFC),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: dividerColor),
                ),
                child: Column(
                  children: [
                    InkWell(
                      onTap: () {
                        setState(() {
                          _expandedIndex = isExpanded ? -1 : index;
                        });
                      },
                      borderRadius: BorderRadius.circular(12),
                      child: Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                faq['question']!,
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                  color: textColor,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            AnimatedRotation(
                              turns: isExpanded ? 0.5 : 0.0,
                              duration: const Duration(milliseconds: 200),
                              child: const Icon(
                                Icons.keyboard_arrow_down_rounded,
                                color: Color(0xFF64748B),
                                size: 22,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (isExpanded) ...[
                      const Divider(height: 1, color: dividerColor),
                      Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            faq['answer']!,
                            style: const TextStyle(
                              fontSize: 13.5,
                              color: Color(0xFF475569),
                              height: 1.5,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
