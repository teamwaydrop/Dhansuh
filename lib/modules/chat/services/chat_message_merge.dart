/// Merge a delayed history response, realtime delivery and persisted outbox
/// without dropping newer messages or showing a temporary/server pair twice.
List<Map<String, dynamic>> mergeChatMessages(
  List<Map<String, dynamic>> current,
  Iterable<Map<String, dynamic>> incoming,
) {
  String identity(Map<String, dynamic> row) {
    final id = (row['client_message_id'] ?? row['id']).toString();
    return id.startsWith('temp_') ? id.substring(5) : id;
  }

  bool pending(Map<String, dynamic> row) =>
      row['is_offline'] == true || row['id'].toString().startsWith('temp_');
  final rows = <String, Map<String, dynamic>>{};
  for (final row in [...current, ...incoming]) {
    final key = identity(row);
    final previous = rows[key];
    if (previous == null || pending(previous) || !pending(row)) {
      rows[key] = Map<String, dynamic>.from(row);
    }
  }
  final result = rows.values.toList();
  // Partial legacy fixtures/rows keep their insertion order. A comparator that
  // returns zero for only some pairs would not define a consistent ordering.
  if (result.any(
    (row) => DateTime.tryParse(row['created_at']?.toString() ?? '') == null,
  )) {
    return result;
  }
  result.sort((a, b) {
    final aTime = DateTime.tryParse(a['created_at']?.toString() ?? '');
    final bTime = DateTime.tryParse(b['created_at']?.toString() ?? '');
    final time = aTime!.compareTo(bTime!);
    return time != 0 ? time : identity(a).compareTo(identity(b));
  });
  return result;
}
