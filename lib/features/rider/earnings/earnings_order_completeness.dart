/// Same-response exact cardinality only; never infer a deployed row cap.
/// Preserve model/defaulting semantics: this checks shape, not financial formulas.
List<Map<String, dynamic>> completeEarningsOrders(Object? rows, int? count) {
  if (rows is! List || count == null || count < 0 || rows.length != count) {
    throw StateError('Incomplete earnings response');
  }
  return List<Map<String, dynamic>>.from(rows);
}
