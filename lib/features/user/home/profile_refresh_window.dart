/// Bounded display-data reuse for order events, never an authorization cache.
/// Manual refresh, resume and initial loads always revalidate profile data.
class ProfileRefreshWindow {
  String? _account;
  DateTime? _loadedAt;
  bool reuseFor(
    String account, {
    required bool ordersOnly,
    required DateTime now,
  }) {
    final age = _loadedAt == null ? null : now.difference(_loadedAt!);
    return ordersOnly &&
        _account == account &&
        age != null &&
        !age.isNegative &&
        age < const Duration(seconds: 30);
  }

  void recordSuccess(String account, DateTime now) {
    _account = account;
    _loadedAt = now;
  }
}
