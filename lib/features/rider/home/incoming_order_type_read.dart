import 'pending_assignment_read.dart';

/// Display enrichment only, never assignment/acceptance evidence. Share exact
/// owner/rider/order in-flight lookups; do not cache completed results.
class IncomingOrderTypeRead {
  final _reads = PendingAssignmentRead();
  Future<String?> read({required String userId, required String riderId,
    required String orderId, required Future<Map<String, dynamic>?> Function() fetch}) async {
    final rows = await _reads.read('$userId/$riderId/$orderId', () async {
      final row = await fetch();
      return row == null ? [] : [row];
    });
    return rows.isEmpty ? null : rows.single['order_type']?.toString();
  }
  void dispose() => _reads.dispose();
}
