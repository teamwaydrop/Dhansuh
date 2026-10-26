import 'dart:convert';
import '../home/pending_assignment_read.dart';

/// Only this screen's identical three-query batch. Every trigger requires a
/// fresh observation; overlapping triggers retain one trailing batch, not six.
class BookingsRefreshRead {
  final _reads = InFlightRead<BookingsObservation>();
  final _keys = <String, Set<String>>{};
  bool _disposed = false;
  Future<BookingsObservation> read(String accountId, String riderId,
      Future<List<dynamic>> Function() fetch) {
    final key = jsonEncode([accountId, riderId]);
    (_keys[accountId] ??= {}).add(key);
    _reads.invalidate(key);
    return _reads.read(key, () async {
      final revision = _reads.revisionFor(key);
      final results = await fetch();
      return BookingsObservation(accountId, riderId, key, revision, results);
    });
  }
  bool isCurrent(BookingsObservation result, String? accountId, String? riderId) =>
      !_disposed && result.accountId == accountId && result.riderId == riderId &&
      result.revision == _reads.revisionFor(result.key);
  void retire(String accountId) {
    for (final key in _keys[accountId] ?? <String>{}) { _reads.invalidate(key); }
  }
  void dispose() { _disposed = true; _reads.dispose(); }
}

class BookingsObservation {
  const BookingsObservation(this.accountId, this.riderId, this.key, this.revision, this.results);
  final String accountId;
  final String riderId;
  final String key;
  final int revision;
  final List<dynamic> results;
}
