/// Compile-time configuration values injected via `--dart-define-from-file=.env`.
///
/// These are baked into the release binary at build time instead of being
/// shipped as a plaintext `.env` asset, so run/build commands must include
/// `--dart-define-from-file=.env` (or individual `--dart-define=KEY=VALUE`
/// flags) for these to be populated.
class Env {
  static const String supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const String supabaseAnonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
  );
  static const String olaMapsApiKey = String.fromEnvironment(
    'OLA_MAPS_API_KEY',
  );
}
