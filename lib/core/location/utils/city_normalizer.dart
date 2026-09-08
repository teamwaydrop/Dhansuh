class CityNormalizer {
  /// Trims and converts the city name string to lowercase.
  /// If the string is empty, returns an empty string "".
  static String normalize(String value) {
    return value.trim().toLowerCase();
  }
}
