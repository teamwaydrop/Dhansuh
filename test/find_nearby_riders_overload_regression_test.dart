import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final migration = File(
    'docs/migration-review/not-applied/20261026000000_remove_legacy_find_nearby_riders_overload.sql',
  ).readAsStringSync();

  test('removes the legacy five-argument nearby-rider overload', () {
    expect(
      RegExp(
        r'DROP FUNCTION IF EXISTS public\.find_nearby_riders\(\s*uuid,\s*double precision,\s*double precision,\s*double precision,\s*integer\s*\)',
        caseSensitive: false,
      ).hasMatch(migration),
      isTrue,
    );
  });

  test('keeps authenticated dispatch access to the optimized overload', () {
    expect(
      RegExp(
        r'GRANT EXECUTE ON FUNCTION public\.find_nearby_riders\(\s*uuid,\s*double precision,\s*double precision,\s*double precision,\s*integer,\s*uuid\[\]\s*\) TO authenticated, service_role',
        caseSensitive: false,
      ).hasMatch(migration),
      isTrue,
    );
  });
}
