/// DEFAULT replica identity often omits old is_read. Learn bounded, account-scoped
/// state from full new records; unknown events always trigger reconciliation.
class NotificationCountEvents {
  final Map<String, bool> _read = {};
  void clear() => _read.clear();

  bool needsRefresh(String type, Map<String, dynamic> record) {
    final id = record['id']?.toString();
    if (id == null) return true;
    if (type == 'DELETE') {
      _read.remove(id);
      return true;
    }
    final value = record['is_read'];
    if (value is! bool) return true;
    final previous = _read[id];
    if (_read.length >= 256 && !_read.containsKey(id)) {
      _read.remove(_read.keys.first);
    }
    _read[id] = value;
    return type != 'UPDATE' || previous == null || previous != value;
  }
}
