/// The Partner Service Mode a rider has self-selected: which family of jobs
/// (Local Ride/Parcel vs Intercity Traveller) they receive. Mirrors
/// `public.partner_service_mode_enum` in the database. A rider's raw
/// `riders.service_mode` value is `null` until they make a choice — that
/// state is represented here by [PartnerServiceMode.fromDb] returning
/// `null`, never by inventing a default.
enum PartnerServiceMode {
  local,
  intercity;

  String get dbValue => switch (this) {
        PartnerServiceMode.local => 'local',
        PartnerServiceMode.intercity => 'intercity',
      };

  String get label => switch (this) {
        PartnerServiceMode.local => 'Local City Partner',
        PartnerServiceMode.intercity => 'Intercity Traveller',
      };

  String get description => switch (this) {
        PartnerServiceMode.local =>
          'Local ride and parcel delivery requests in your city.',
        PartnerServiceMode.intercity =>
          'Travel Together, Intercity Parcel, and Travel Plan requests between cities.',
      };

  static PartnerServiceMode? fromDb(Object? value) {
    switch (value) {
      case 'local':
        return PartnerServiceMode.local;
      case 'intercity':
        return PartnerServiceMode.intercity;
      default:
        return null;
    }
  }
}
