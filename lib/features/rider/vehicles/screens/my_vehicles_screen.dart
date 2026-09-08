import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:waydrop/features/rider/vehicles/screens/add_vehicle_screen.dart';
import 'package:waydrop/shared/helpers/insets.dart';

/// Lists every vehicle verified for this Drop Partner: the original vehicle
/// captured during one-time person KYC (always shown, tagged "KYC"), plus
/// any additional vehicles added independently via [AddVehicleScreen] and
/// stored in `rider_vehicles`. Each additional vehicle carries its own
/// pending/approved/rejected status, separate from the person KYC status.
class MyVehiclesScreen extends StatefulWidget {
  final String riderId;
  final Map<String, dynamic>? kyc;

  const MyVehiclesScreen({super.key, required this.riderId, required this.kyc});

  @override
  State<MyVehiclesScreen> createState() => _MyVehiclesScreenState();
}

class _MyVehiclesScreenState extends State<MyVehiclesScreen> {
  final supabase = Supabase.instance.client;
  bool loading = true;
  List<Map<String, dynamic>> vehicles = [];

  static const Color darkBg = Color(0xFF0B0F19);
  static const Color darkCard = Color(0xFF131926);
  static const Color primaryLime = Color(0xFFC5FF30);
  static const Color textGray = Color(0xFF94A3B8);

  @override
  void initState() {
    super.initState();
    _loadVehicles();
  }

  Future<void> _loadVehicles() async {
    setState(() => loading = true);
    try {
      // Egress fix: narrowed to the 4 fields _vehicleCard() reads.
      final res = await supabase
          .from('rider_vehicles')
          .select('vehicle_type, vehicle_number, status, rejection_reason')
          .eq('rider_id', widget.riderId)
          .order('created_at', ascending: false);
      if (mounted) {
        setState(() {
          vehicles = List<Map<String, dynamic>>.from(res);
          loading = false;
        });
      }
    } catch (e) {
      debugPrint('LOAD RIDER VEHICLES ERROR => $e');
      if (mounted) setState(() => loading = false);
    }
  }

  IconData _iconFor(String? type) {
    switch (type) {
      case 'bike':
        return Icons.motorcycle_rounded;
      case 'auto':
        return Icons.electric_rickshaw_rounded;
      case 'cab':
        return Icons.local_taxi_rounded;
      default:
        return Icons.directions_car_rounded;
    }
  }

  String _capitalize(String text) {
    if (text.isEmpty) return text;
    return text[0].toUpperCase() + text.substring(1);
  }

  String _statusLabel(String status) {
    switch (status) {
      case 'approved':
        return 'Verified';
      case 'rejected':
        return 'Rejected';
      default:
        return 'Pending Verification';
    }
  }

  Widget _statusPill(String status) {
    Color color;
    switch (status) {
      case 'approved':
        color = const Color(0xFF22C55E);
        break;
      case 'rejected':
        color = const Color(0xFFEF4444);
        break;
      default:
        color = const Color(0xFFF59E0B);
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
      child: Text(_statusLabel(status), style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w800)),
    );
  }

  Widget _vehicleCard({
    required String type,
    required String number,
    required String status,
    String? rejectionReason,
    bool isPrimary = false,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: darkCard,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(color: primaryLime.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(14)),
                    child: Icon(_iconFor(type), color: primaryLime, size: 20),
                  ),
                  const SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(_capitalize(type), style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w900)),
                          if (isPrimary) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(6)),
                              child: const Text('KYC', style: TextStyle(color: textGray, fontSize: 9, fontWeight: FontWeight.w800)),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(number, style: const TextStyle(color: textGray, fontSize: 12, fontWeight: FontWeight.w600)),
                    ],
                  ),
                ],
              ),
              _statusPill(status),
            ],
          ),
          if (status == 'rejected' && rejectionReason != null && rejectionReason.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text('Reason: $rejectionReason', style: const TextStyle(color: Color(0xFFEF4444), fontSize: 11, fontStyle: FontStyle.italic)),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final kycVehicleType = widget.kyc?['vehicle_type']?.toString();
    final kycVehicleNumber = widget.kyc?['vehicle_number']?.toString() ?? '';
    final kycStatus = widget.kyc?['kyc_status']?.toString() ?? 'approved';
    final hasKycVehicle = kycVehicleType != null && kycVehicleType.isNotEmpty;

    return Scaffold(
      backgroundColor: darkBg,
      appBar: AppBar(
        backgroundColor: darkCard,
        elevation: 0,
        title: const Text('My Vehicles', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18)),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator(color: primaryLime))
          : RefreshIndicator(
              onRefresh: _loadVehicles,
              color: primaryLime,
              child: ListView(
                padding: EdgeInsets.fromLTRB(16, 16, 16, 96 + Insets.bottom(context)),
                children: [
                  const Text(
                    'VERIFIED VEHICLES',
                    style: TextStyle(color: textGray, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 0.8),
                  ),
                  const SizedBox(height: 10),
                  if (hasKycVehicle)
                    _vehicleCard(
                      type: kycVehicleType,
                      number: kycVehicleNumber,
                      status: kycStatus == 'approved' ? 'approved' : kycStatus,
                      isPrimary: true,
                    ),
                  ...vehicles.map((v) => _vehicleCard(
                        type: v['vehicle_type']?.toString() ?? '',
                        number: v['vehicle_number']?.toString() ?? '',
                        status: v['status']?.toString() ?? 'pending',
                        rejectionReason: v['rejection_reason']?.toString(),
                      )),
                  if (!hasKycVehicle && vehicles.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 40),
                      child: Column(
                        children: [
                          Icon(Icons.directions_car_outlined, size: 48, color: Colors.white.withValues(alpha: 0.15)),
                          const SizedBox(height: 12),
                          const Text('No vehicles yet', style: TextStyle(color: textGray, fontSize: 13)),
                        ],
                      ),
                    ),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    height: 54,
                    child: ElevatedButton.icon(
                      onPressed: () async {
                        final added = await Navigator.push(
                          context,
                          MaterialPageRoute(builder: (_) => AddVehicleScreen(riderId: widget.riderId)),
                        );
                        if (added == true) _loadVehicles();
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: primaryLime,
                        foregroundColor: Colors.black,
                        elevation: 0,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      ),
                      icon: const Icon(Icons.add_rounded),
                      label: const Text('Add Vehicle', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}
