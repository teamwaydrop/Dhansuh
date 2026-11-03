/// Skip only a proven GPS-only update. Missing previous business fields are
/// unknown, not unchanged (identity/column selections can yield partial rows).
bool isLocationOnlyRiderUpdate(
  Map<String, dynamic> previous,
  Map<String, dynamic> current,
  Set<String> locationFields,
) =>
    previous.isNotEmpty &&
    current.isNotEmpty &&
    current.entries.every(
      (entry) =>
          locationFields.contains(entry.key) ||
          (previous.containsKey(entry.key) &&
              previous[entry.key] == entry.value),
    );
