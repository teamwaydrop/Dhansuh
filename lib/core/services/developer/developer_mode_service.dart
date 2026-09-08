/// Single source of truth for "Developer Test Mode" eligibility.
///
/// Flagged accounts (users.is_developer = true) or admins (users.role =
/// 'admin') can bypass service-area restrictions for testing. The flag is
/// never self-grantable (see 20260724000000_add_developer_test_mode_flag.sql)
/// so this fails closed by default and whenever the profile is unknown.
class DeveloperModeService {
  static final DeveloperModeService instance = DeveloperModeService._();
  DeveloperModeService._();

  bool _isEnabled = false;

  bool get isDeveloperTestModeEnabled => _isEnabled;

  void setFromProfile(Map<String, dynamic>? profile) {
    if (profile == null) {
      _isEnabled = false;
      return;
    }
    _isEnabled = profile['is_developer'] == true || profile['role'] == 'admin';
  }

  void clear() {
    _isEnabled = false;
  }
}
