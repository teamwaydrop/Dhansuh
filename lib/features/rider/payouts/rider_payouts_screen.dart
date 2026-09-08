import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:waydrop/core/services/realtime/realtime_manager.dart';
import 'package:waydrop/shared/widgets/skeleton_loader.dart';

class RiderPayoutsScreen extends StatefulWidget {
  final String riderId;

  const RiderPayoutsScreen({
    super.key,
    required this.riderId,
  });

  @override
  State<RiderPayoutsScreen> createState() => _RiderPayoutsScreenState();
}

class _RiderPayoutsScreenState extends State<RiderPayoutsScreen> {
  final supabase = Supabase.instance.client;
  List<Map<String, dynamic>> payoutTransactions = [];
  bool loading = true;
  // Egress fix: migrated from a raw supabase.channel() with a fixed (non-per-user) name -- the
  // exact same bug already fixed once in rider_earnings_tab.dart's own withdrawal channel, missed
  // here. Now pools with that screen's identical table/event/filter subscription.
  String? _withdrawalsSubChannel;
  String? _withdrawalsSubId;

  static const Color primaryLime = Color(0xFFC5FF30);
  static const Color darkBg = Color(0xFF0B0F19);
  static const Color darkCard = Color(0xFF131926);
  static const Color textGray = Color(0xFF94A3B8);

  @override
  void initState() {
    super.initState();
    loadPayouts();
    _subscribeWithdrawals();
  }

  @override
  void dispose() {
    if (_withdrawalsSubChannel != null && _withdrawalsSubId != null) {
      RealtimeManager.instance.unsubscribe(_withdrawalsSubChannel!, _withdrawalsSubId!);
    }
    super.dispose();
  }

  Future<void> loadPayouts() async {
    try {
      // Sync pending/processing withdrawals from Cashfree
      try {
        await supabase.functions.invoke(
          'create-rider-withdrawal',
          method: HttpMethod.get,
        );
      } catch (syncErr) {
        debugPrint('Withdrawal sync payouts error => $syncErr');
      }

      await fetchWithdrawalsOnly();
      if (mounted) {
        setState(() => loading = false);
      }
    } catch (e) {
      debugPrint('LOAD PAYOUTS ERROR => $e');
      if (mounted) {
        setState(() => loading = false);
      }
    }
  }

  Future<void> fetchWithdrawalsOnly() async {
    try {
      // Egress fix: narrowed to the fields _WithdrawalRow reads (grepped exhaustively) -- same
      // field list rider_earnings_tab.dart already uses for the identical table.
      final withdrawalsData = await supabase
          .from('rider_withdrawals')
          .select('amount, status, created_at, cashfree_response, transfer_id, cashfree_reference_id')
          .eq('rider_id', widget.riderId)
          .order('created_at', ascending: false)
          .limit(50);

      if (mounted) {
        setState(() {
          payoutTransactions = List<Map<String, dynamic>>.from(withdrawalsData);
        });
      }
    } catch (e) {
      debugPrint('FETCH WITHDRAWALS ONLY ERROR => $e');
    }
  }

  void _subscribeWithdrawals() {
    final user = supabase.auth.currentUser;
    if (user == null) return;

    _withdrawalsSubChannel = 'rider-withdrawals-${user.id}';
    _withdrawalsSubId = RealtimeManager.instance.subscribe(
      channelName: _withdrawalsSubChannel!,
      table: 'rider_withdrawals',
      owner: 'RiderPayoutsScreen_Withdrawals',
      event: PostgresChangeEvent.all,
      schema: 'public',
      filterColumn: 'user_id',
      filterValue: user.id,
      callback: (payload) {
        fetchWithdrawalsOnly();
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: darkBg,
      appBar: AppBar(
        backgroundColor: darkBg,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white, size: 20),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text(
          'Payout Transactions',
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 20,
          ),
        ),
        centerTitle: true,
      ),
      body: SafeArea(
        child: loading
            ? const SkeletonLoader()
            : payoutTransactions.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.account_balance_wallet_rounded, color: textGray.withValues(alpha: 0.3), size: 48),
                        const SizedBox(height: 12),
                        const Text(
                          'No transactions completed yet',
                          style: TextStyle(color: textGray, fontSize: 15, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                  )
                 : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                    itemCount: payoutTransactions.length,
                    itemBuilder: (context, index) {
                      final tx = payoutTransactions[index];
                      return _WithdrawalRow(withdrawal: tx);
                    },
                  ),
      ),
    );
  }
}

class _WithdrawalRow extends StatefulWidget {
  final Map<String, dynamic> withdrawal;
  const _WithdrawalRow({required this.withdrawal});

  @override
  State<_WithdrawalRow> createState() => _WithdrawalRowState();
}

class _WithdrawalRowState extends State<_WithdrawalRow> {
  bool _isExpanded = false;

  @override
  Widget build(BuildContext context) {
    final withdrawal = widget.withdrawal;
    final amount = double.tryParse(withdrawal['amount']?.toString() ?? '0') ?? 0.0;
    final status = withdrawal['status'] ?? 'pending';
    final date = withdrawal['created_at'] ?? '';
    final dt = DateTime.tryParse(date.toString())?.toLocal();
    final dateStr = dt != null
        ? '${dt.day}/${dt.month} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}'
        : '';
    final fullDateStr = dt != null
        ? '${dt.day}/${dt.month}/${dt.year} at ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}:${dt.second.toString().padLeft(2, '0')}'
        : 'N/A';

    Color statusColor;
    IconData statusIcon;
    String statusText;

    switch (status) {
      case 'success':
        statusColor = _RiderPayoutsScreenState.primaryLime;
        statusIcon = Icons.check_circle_rounded;
        statusText = 'Success';
        break;
      case 'failed':
        statusColor = const Color(0xFFEF4444);
        statusIcon = Icons.error_rounded;
        statusText = 'Failed';
        break;
      case 'processing':
        statusColor = const Color(0xFF3B82F6);
        statusIcon = Icons.hourglass_empty_rounded;
        statusText = 'Processing';
        break;
      case 'pending':
      default:
        statusColor = const Color(0xFFF59E0B);
        statusIcon = Icons.hourglass_top_rounded;
        statusText = 'Pending';
        break;
    }

    String? errorMessage;
    if (withdrawal['cashfree_response'] != null) {
      final resp = withdrawal['cashfree_response'];
      if (resp is Map) {
        errorMessage = resp['message']?.toString() ?? resp['error']?.toString();
      }
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: _RiderPayoutsScreenState.darkCard,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05), width: 1.5),
      ),
      child: InkWell(
        onTap: () {
          setState(() {
            _isExpanded = !_isExpanded;
          });
        },
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: statusColor.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(statusIcon, color: statusColor, size: 18),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Withdrawal - $statusText',
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                          ),
                        ),
                        Text(
                          dateStr,
                          style: const TextStyle(
                            fontSize: 11,
                            color: _RiderPayoutsScreenState.textGray,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Row(
                    children: [
                      Text(
                        '-₹${amount.toStringAsFixed(2)}',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w900,
                          color: statusColor,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Icon(
                        _isExpanded ? Icons.keyboard_arrow_up_rounded : Icons.keyboard_arrow_down_rounded,
                        color: _RiderPayoutsScreenState.textGray,
                        size: 16,
                      ),
                    ],
                  ),
                ],
              ),
              if (_isExpanded) ...[
                const SizedBox(height: 12),
                const Divider(color: Colors.white10, height: 1),
                const SizedBox(height: 12),
                _buildDetailRow('Transaction ID', withdrawal['transfer_id'] ?? 'N/A'),
                const SizedBox(height: 8),
                _buildDetailRow('Ref ID', withdrawal['cashfree_reference_id'] ?? 'N/A'),
                const SizedBox(height: 8),
                _buildDetailRow('Date', fullDateStr),
                if (errorMessage != null && errorMessage.trim().isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEF4444).withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: const Color(0xFFEF4444).withValues(alpha: 0.2)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Row(
                          children: [
                            Icon(Icons.info_outline, color: Color(0xFFEF4444), size: 14),
                            SizedBox(width: 6),
                            Text(
                              'Failure Reason',
                              style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFFEF4444)),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          errorMessage,
                          style: const TextStyle(fontSize: 11, color: Color(0xFFFDA4AF), fontWeight: FontWeight.w500),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDetailRow(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: const TextStyle(fontSize: 11, color: _RiderPayoutsScreenState.textGray, fontWeight: FontWeight.w500)),
        const SizedBox(width: 16),
        Expanded(
          child: Text(
            value,
            textAlign: TextAlign.end,
            style: const TextStyle(fontSize: 11, color: Colors.white, fontWeight: FontWeight.bold),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
