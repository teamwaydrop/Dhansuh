import 'dart:async';
import 'dart:math';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../local_rides/booking/nearby_rider_refresh.dart';

/// Cosmetic map read only: skip overlap and let the existing timer refresh next.
class NearbyParcelRiderRead {
  NearbyParcelRiderRead(this.client, {this.onAccountChanged}) {
    _accountId = client.auth.currentUser?.id;
    _auth = client.auth.onAuthStateChange.listen((event) {
      if (_disposed) return;
      final next = event.session?.user.id;
      if (next != _accountId) {
        _accountId = next;
        _refresh.invalidate(); // Also fence A -> B -> A replays.
        onAccountChanged?.call();
      }
    });
  }
  final SupabaseClient client;
  final void Function()? onAccountChanged;
  bool _disposed = false;
  final _refresh = NearbyRiderRefresh();
  late final StreamSubscription<AuthState> _auth;
  String? _accountId;
  void invalidate() => _refresh.invalidate();
  void dispose() { _disposed = true; _refresh.dispose(); _auth.cancel(); }

  Future<void> run({required double lat, required double lng,
      required bool Function() isCurrent,
      required Future<void> Function(List<Map<String, dynamic>>) apply}) {
    final accountId = client.auth.currentUser?.id;
    return _refresh.run<List<Map<String, dynamic>>>(
      fetch: () => _fetch(lat, lng),
      isCurrent: () => client.auth.currentUser?.id == accountId && isCurrent(),
      apply: apply,
    );
  }

  Future<List<Map<String, dynamic>>> _fetch(double pickupLat, double pickupLng) async {
    const radiusKm = 5.0;
    const kmPerDegreeLat = 111.32;
    final latDelta = radiusKm / kmPerDegreeLat;
    final lngDegreeKm = kmPerDegreeLat * cos(pickupLat * (pi / 180)).abs();
    final lngDelta = radiusKm / (lngDegreeKm < 0.000001 ? 0.000001 : lngDegreeKm);
    final response = await client.from('riders').select(
      'id, current_lat, current_lng, current_heading, rider_kyc!riders_kyc_id_fkey(vehicle_type)',
    ).eq('account_status', 'online').not('current_lat', 'is', null).not('current_lng', 'is', null)
        .gte('current_lat', pickupLat - latDelta).lte('current_lat', pickupLat + latDelta)
        .gte('current_lng', pickupLng - lngDelta).lte('current_lng', pickupLng + lngDelta);
    return (response as List).map<Map<String, dynamic>>((r) {
      final map = Map<String, dynamic>.from(r as Map);
      final kyc = map['rider_kyc!riders_kyc_id_fkey'] ?? map['rider_kyc'];
      String vehicleType = 'bike';
      if (kyc is Map) {
        vehicleType = kyc['vehicle_type']?.toString().toLowerCase().trim() ?? 'bike';
      } else if (kyc is List && kyc.isNotEmpty && kyc[0] is Map) {
        vehicleType = kyc[0]['vehicle_type']?.toString().toLowerCase().trim() ?? 'bike';
      }
      if (vehicleType == 'car') {
        vehicleType = 'cab';
      }
      map['vehicle_type'] = vehicleType;
      map.remove('rider_kyc!riders_kyc_id_fkey');
      map.remove('rider_kyc');
      return map;
    }).where((rider) {
      final lat = double.tryParse(rider['current_lat']?.toString() ?? '');
      final lng = double.tryParse(rider['current_lng']?.toString() ?? '');
      if (lat == null || lng == null) return false;
      const p = 0.017453292519943295;
      final a = 0.5 - cos((lat - pickupLat) * p) / 2 + cos(pickupLat * p) * cos(lat * p) *
          (1 - cos((lng - pickupLng) * p)) / 2;
      final distanceKm = 12742 * asin(sqrt(a));
      return distanceKm <= 5.0;
    }).toList();
  }
}
