class LocationDisplayService {
  /// Resolves the city name directly from the city field.
  /// If it is null, empty, or 'other', we fallback to the fallback string.
  static String resolveCity({
    String? city,
    String? address,
    required String fallback,
  }) {
    if (city != null && city.trim().isNotEmpty && city.toLowerCase() != 'other') {
      return city.trim();
    }
    if (address == null || address.trim().isEmpty) {
      return fallback;
    }
    
    final statesAndIgnoreList = {
      'andhra pradesh', 'arunachal pradesh', 'assam', 'bihar', 'chhattisgarh',
      'goa', 'gujarat', 'haryana', 'himachal pradesh', 'jharkhand', 'karnataka',
      'kerala', 'madhya pradesh', 'maharashtra', 'manipur', 'meghalaya', 'mizoram',
      'nagaland', 'odisha', 'punjab', 'rajasthan', 'sikkim', 'tamil nadu',
      'telangana', 'tripura', 'uttar pradesh', 'uttarakhand', 'west bengal',
      'delhi', 'jammu and kashmir', 'ladakh', 'puducherry', 'pondicherry',
      'chandigarh', 'lakshadweep', 'india', 'telangana state', 'ap'
    };

    final parts = address.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    for (int i = parts.length - 1; i >= 0; i--) {
      final cleanPart = parts[i].replaceAll(RegExp(r'\d+'), '').trim();
      final lowerPart = cleanPart.toLowerCase();
      if (lowerPart.isEmpty || statesAndIgnoreList.contains(lowerPart)) {
        continue;
      }
      if (cleanPart.length > 2 && cleanPart.length < 25) {
        return cleanPart;
      }
    }
    return fallback;
  }
}
