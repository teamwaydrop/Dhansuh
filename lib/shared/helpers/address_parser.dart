
@Deprecated('Use LocationDisplayService.resolveCity()')
class AddressParser {
  /// Extracts the most specific city/town name from an address.
  /// Walks forwards from left to right, filtering out house/flat numbers, pincodes,
  /// street/landmark keywords, and states/countries.
  static String extractCity(String address) {
    if (address.isEmpty) return 'Other';
    
    // Split by commas
    final parts = address.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    
    final statesAndCountries = {
      'telangana', 'andhra pradesh', 'karnataka', 'tamil nadu', 'maharashtra',
      'delhi', 'goa', 'gujarat', 'haryana', 'himachal pradesh', 'kerala',
      'madhya pradesh', 'punjab', 'rajasthan', 'uttar pradesh', 'uttarakhand',
      'west bengal', 'bihar', 'chhattisgarh', 'odisha', 'ts', 'ap', 'ka', 'mh', 'in',
      'india', 'ind'
    };
    
    final streetKeywords = {
      'road', 'street', 'colony', 'nagar', 'flat', 'plot', 'beside', 'opposite',
      'near', 'floor', 'lane', 'building', 'apartment', 'house', 'h.no', 'h no',
      'shop', 'complex', 'cross', 'main', 'layout', 'avenue', 'ward', 'block',
      'phase', 'sector', 'gali', 'path', 'highway', 'bypass', 'flyover', 'bridge',
      'railway', 'station', 'airport', 'landmark', 'behind', 'under', 'above', 'next'
    };

    // Walk forwards (from left to right) to find the first candidate that is a town/city.
    for (final part in parts) {
      final partLower = part.toLowerCase();
      
      // Skip if it contains digits (typically door numbers, pincodes, plot numbers, etc.)
      if (RegExp(r'\d').hasMatch(partLower)) {
        continue;
      }
      
      // Skip if it contains any street/location keyword
      bool containsStreetKeyword = false;
      for (final kw in streetKeywords) {
        final regex = RegExp('\\b$kw\\b');
        if (regex.hasMatch(partLower)) {
          containsStreetKeyword = true;
          break;
        }
      }
      if (containsStreetKeyword) {
        continue;
      }
      
      // Skip if it's a known state or country
      if (statesAndCountries.contains(partLower)) {
        continue;
      }
      
      // Clean name: capitalize words
      final cleanPart = _capitalizeWords(part);
      if (cleanPart.isNotEmpty && cleanPart.length < 25) {
        return cleanPart;
      }
    }

    // Fallback 1: Old knownCities list logic (checking normalized string contains known city)
    const knownCities = [
      'hyderabad', 'bangalore', 'bengaluru', 'chennai', 'mumbai', 'pune', 
      'ahmedabad', 'delhi', 'kolkata', 'noida', 'gurgaon', 'gurugram', 
      'ghaziabad', 'faridabad', 'secunderabad', 'visakhapatnam', 'vizag', 
      'vijayawada', 'guntur', 'nellore', 'warangal', 'tirupati', 'jaipur',
      'kakinada', 'rajahmundry', 'kurnool', 'kadapa', 'anantapur', 'ongole',
      'eluru', 'vizianagaram', 'srikakulam', 'karimnagar', 'khammam', 'mahbubnagar'
    ];
    final normalized = address.toLowerCase();
    for (final city in knownCities) {
      if (normalized.contains(city)) {
        if (city == 'bengaluru' || city == 'bangalore') {
          return 'Bengaluru';
        }
        if (city == 'vizag') {
          return 'Visakhapatnam';
        }
        return city[0].toUpperCase() + city.substring(1);
      }
    }

    // Fallback 2: Walk backwards and clean the first non-state, non-digit part
    for (int i = parts.length - 1; i >= 0; i--) {
      final part = parts[i];
      final partLower = part.toLowerCase();
      
      if (partLower == 'india' || partLower == 'ind') continue;
      if (statesAndCountries.contains(partLower)) continue;
      if (RegExp(r'^\d+$').hasMatch(part.replaceAll(RegExp(r'\D'), ''))) continue;
      
      final clean = part.replaceAll(RegExp(r'\d+'), '').trim();
      if (clean.isNotEmpty && clean.length < 25) {
        return _capitalizeWords(clean);
      }
    }

    return 'Other';
  }

  static String _capitalizeWords(String input) {
    return input
        .split(' ')
        .where((w) => w.isNotEmpty)
        .map((w) => w[0].toUpperCase() + w.substring(1).toLowerCase())
        .join(' ');
  }

  /// Displays the cleanest city name possible, falling back to address extraction
  /// if the city is saved as generic 'Other' or needs more specific parsing.
  static String getCleanCityName(String? city, String? address, String defaultName) {
    if (city != null && city.isNotEmpty && city.toLowerCase() != 'other') {
      // Re-parse address if possible to make sure we get a specific city (e.g. Ponnur)
      // rather than the district (e.g. Guntur) if both are in the address
      if (address != null && address.isNotEmpty) {
        final extracted = extractCity(address);
        if (extracted != 'Other') {
          return extracted;
        }
      }
      return city;
    }
    if (address == null || address.isEmpty) {
      return defaultName;
    }
    return extractCity(address);
  }
}
