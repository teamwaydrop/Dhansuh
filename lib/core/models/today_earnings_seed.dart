/// A complete, scoped observation. Stored partner earnings sum rider_earning;
/// they are not a newly computed universal take-home/net-after-all-taxes amount.
class TodayEarningsSeed {
  TodayEarningsSeed._(this.userId, this.riderId, this.dayStart, this.observedAt,
      this.grossFare, this.storedPartnerEarnings);
  final String userId;
  final String riderId;
  final DateTime dayStart;
  final DateTime observedAt;
  final double? grossFare;
  final double? storedPartnerEarnings;
  static const handoffWindow = Duration(seconds: 3);

  factory TodayEarningsSeed.fromRows({required String userId, required String riderId,
    required DateTime queryLocalDay, required DateTime observedAt,
    required Object? rows, required int? exactCount}) {
    var gross = 0.0;
    var partner = 0.0;
    var grossKnown = rows is List && exactCount != null && exactCount >= 0 && rows.length == exactCount;
    var partnerKnown = grossKnown;
    if (rows is List) {
      for (final row in rows) {
        if (row is! Map) { grossKnown = false; partnerKnown = false; continue; }
        final fare = _number(row['final_fare'] ?? row['current_fare']);
        if (!row.containsKey('final_fare') || !row.containsKey('current_fare') || fare == null ||
            (row['final_fare'] != null && _number(row['final_fare']) == null) ||
            (row['current_fare'] != null && _number(row['current_fare']) == null)) {
          grossKnown = false;
        } else { gross += fare; }
        final earning = _number(row['rider_earning']);
        if (!row.containsKey('rider_earning') || earning == null) {
          partnerKnown = false;
        } else { partner += earning; }
      }
    }
    return TodayEarningsSeed._(userId, riderId,
      DateTime(queryLocalDay.year, queryLocalDay.month, queryLocalDay.day).toUtc(), observedAt.toUtc(),
      grossKnown && gross.isFinite ? gross : null,
      partnerKnown && partner.isFinite ? partner : null);
  }

  bool matches(String? user, String? rider, DateTime now) =>
      user == userId && rider == riderId &&
      DateTime(now.year, now.month, now.day).toUtc() == dayStart;
  bool usableForHandoff(String? user, String? rider, DateTime now) =>
      matches(user, rider, now) && !now.toUtc().isBefore(observedAt) &&
      now.toUtc().difference(observedAt) < handoffWindow;
  static double? _number(Object? value) {
    if (value is! num && value is! String) return null;
    final number = double.tryParse(value.toString());
    return number != null && number.isFinite ? number : null;
  }
}

class StoredEarningsObservation {
  StoredEarningsObservation._(this.seed, this.revision);
  final TodayEarningsSeed seed;
  final int revision;
}

/// Active-order's established daily measure, with application-time fencing.
class StoredPartnerEarningsState {
  TodayEarningsSeed? _seed;
  int _revision = 0;
  bool _disposed = false;
  int beginRequest() => ++_revision;
  void invalidate() { _revision++; }
  bool isCurrent(int revision) => !_disposed && revision == _revision;
  StoredEarningsObservation observation(TodayEarningsSeed seed, int revision) =>
      StoredEarningsObservation._(seed, revision);
  bool acceptHandoff(TodayEarningsSeed? seed, String? user, String? rider, DateTime now) {
    if (_disposed || _revision != 0 || _seed != null || seed == null ||
        seed.storedPartnerEarnings == null || !seed.usableForHandoff(user, rider, now)) {
      return false;
    }
    _seed = seed;
    return true;
  }
  bool apply(StoredEarningsObservation result, String? user, String? rider, DateTime now) {
    if (!isCurrent(result.revision) || !result.seed.matches(user, rider, now)) return false;
    _seed = result.seed;
    return true;
  }
  double? valueFor(String? user, String? rider, DateTime now) {
    final seed = _seed;
    return !_disposed && seed != null && seed.matches(user, rider, now)
        ? seed.storedPartnerEarnings : null;
  }
  void dispose() { _disposed = true; _revision++; _seed = null; }
}
