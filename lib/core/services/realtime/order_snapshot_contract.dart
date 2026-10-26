class OrderSnapshotContract {
  // Version 1's unsupported fee columns/non-null assumptions are not redefined.
  // Legacy/missing snapshots continue through the controller's direct-read fallback.
  static const int version = 2;

  static const Set<String> requiredKeys = {
    'contract_version',
    'id',
    'updated_at',
    'order_code',
    'user_id',
    'rider_id',
    'order_type',
    'vehicle_type',
    'order_status',
    'distance_meters',
    'distance_km',
    'estimated_duration_min',
    'actual_duration_min',
    'time_taken_seconds',
    'pickup_address',
    'pickup_lat',
    'pickup_lng',
    'destination_address',
    'destination_lat',
    'destination_lng',
    'actual_fare',
    'current_fare',
    'final_fare',
    'base_fare',
    'distance_fare',
    'time_fare',
    'waiting_charge',
    'platform_fee',
    'payment_mode',
    'payment_status',
    'payment_id',
    'fare_payment_method',
    'fare_payment_attempted_at',
    'pickup_otp',
    'delivery_otp',
    'parcel_type',
    'receiver_name',
    'receiver_phone',
    'weight_category',
    'actual_weight_kg',
    'parcel_images',
    'special_instructions',
    'created_at',
    'accepted_at',
    'rider_arrived_at',
    'picked_up_at',
    'rider_at_drop_at',
    'completed_at',
    'cancelled_at',
    'boost_amount',
    'boost_percentage',
    'pickup_city',
    'destination_city',
    'travel_date',
    'seats_requested',
    'trip_started_at',
    'gst_percentage',
    'gst_amount',
    'commission_percentage',
    'commission_amount',
    'rider_earning',
    'boost_company_earning',
    'boost_rider_earning',
  };

  static const Set<String> _requiredStrings = {
    'id',
    'order_code',
    'user_id',
    'order_type',
    'order_status',
    'pickup_address',
    'destination_address',
    'payment_mode',
    'payment_status',
  };

  static const Set<String> _nullableStrings = {
    'rider_id',
    'vehicle_type',
    'payment_id',
    'fare_payment_method',
    'pickup_otp',
    'delivery_otp',
    'parcel_type',
    'receiver_name',
    'receiver_phone',
    'weight_category',
    'special_instructions',
    'pickup_city',
    'destination_city',
  };

  static const Set<String> _requiredNumbers = {
    'distance_meters',
    'distance_km',
    'pickup_lat',
    'pickup_lng',
    'destination_lat',
    'destination_lng',
    'actual_fare',
    'current_fare',
  };

  static const Set<String> _nullableNumbers = {
    'base_fare',
    'distance_fare',
    'time_fare',
    'waiting_charge',
    'platform_fee',
    'boost_amount',
    'boost_percentage',
    'gst_percentage',
    'gst_amount',
    'commission_percentage',
    'commission_amount',
    'rider_earning',
    'boost_company_earning',
    'boost_rider_earning',
    'estimated_duration_min',
    'actual_duration_min',
    'time_taken_seconds',
    'final_fare',
    'actual_weight_kg',
    'seats_requested',
  };

  static const Set<String> _nullableTimestamps = {
    'fare_payment_attempted_at',
    'accepted_at',
    'rider_arrived_at',
    'picked_up_at',
    'rider_at_drop_at',
    'completed_at',
    'cancelled_at',
    'travel_date',
    'trip_started_at',
  };

  static Map<String, dynamic>? validate(
    Object? raw, {
    required String expectedOrderId,
  }) {
    if (raw is! Map) return null;
    if (raw.keys.any((key) => key is! String)) return null;
    final snapshot = Map<String, dynamic>.from(raw);
    if (snapshot['contract_version'] != version ||
        snapshot['id'] != expectedOrderId ||
        !requiredKeys.every(snapshot.containsKey)) {
      return null;
    }

    for (final key in _requiredStrings) {
      final value = snapshot[key];
      if (value is! String || value.isEmpty) return null;
    }
    for (final key in _nullableStrings) {
      final value = snapshot[key];
      if (value != null && value is! String) return null;
    }
    for (final key in _requiredNumbers) {
      if (!_isFiniteNumber(snapshot[key])) return null;
    }
    for (final key in _nullableNumbers) {
      final value = snapshot[key];
      if (value != null && !_isFiniteNumber(value)) return null;
    }
    final seats = snapshot['seats_requested'];
    if (seats != null && int.tryParse(seats.toString()) == null) return null;

    final updatedAt = snapshot['updated_at'];
    if (updatedAt is! String || !_isTimezoneAwareTimestamp(updatedAt)) {
      return null;
    }
    final createdAt = snapshot['created_at'];
    if (createdAt != null &&
        (createdAt is! String || !_isTimezoneAwareTimestamp(createdAt))) {
      return null;
    }
    for (final key in _nullableTimestamps) {
      final value = snapshot[key];
      if (value != null &&
          (value is! String ||
              !(key == 'travel_date' && _isCalendarDate(value) ||
                  _isTimezoneAwareTimestamp(value)))) {
        return null;
      }
    }

    final images = snapshot['parcel_images'];
    if (images is! List || images.any((item) => item is! String)) return null;
    return snapshot;
  }

  static bool _isFiniteNumber(Object? value) {
    final number = value is num
        ? value.toDouble()
        : value is String
        ? double.tryParse(value)
        : null;
    return number != null && number.isFinite;
  }

  static bool _isTimezoneAwareTimestamp(String value) {
    final match = RegExp(
      r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d{1,6})?(Z|[+-]\d{2}:\d{2})$',
    ).firstMatch(value);
    if (match == null) return false;
    final year = int.parse(match[1]!);
    final month = int.parse(match[2]!);
    final day = int.parse(match[3]!);
    final date = DateTime.utc(year, month, day);
    if (date.year != year || date.month != month || date.day != day ||
        int.parse(match[4]!) > 23 || int.parse(match[5]!) > 59 ||
        int.parse(match[6]!) > 59) {
      return false;
    }
    final zone = match[7]!;
    if (zone != 'Z' &&
        (int.parse(zone.substring(1, 3)) > 23 ||
         int.parse(zone.substring(4, 6)) > 59)) {
      return false;
    }
    return DateTime.tryParse(value) != null;
  }

  static bool _isCalendarDate(String value) {
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) return false;
    final date = DateTime.tryParse(value);
    return date != null && date.toIso8601String().substring(0, 10) == value;
  }
}
