import 'package:flutter_test/flutter_test.dart';
import 'package:waydrop/core/providers/initial_data_provider.dart';

void main() {
  final now = DateTime.utc(2026, 11, 2, 15, 20);
  InitialRiderData seed({DateTime? at}) => InitialRiderData(
    rider: {'id': 'rider', 'user_id': 'owner'},
    todayEarnings: 0,
    fetchedAt: at ?? now,
  );
  test('one response is reusable once by each independent screen consumer', () {
    final value = seed();
    expect(value.consumeFor('Home', 'owner', now: now), isTrue);
    expect(value.consumeFor('Home', 'owner', now: now), isFalse);
    expect(value.consumeFor('Navigation', 'owner', now: now), isTrue);
  });
  test(
    'a newly validated response is reusable even after an earlier response',
    () {
      expect(seed().consumeFor('Home', 'owner', now: now), isTrue);
      expect(seed().consumeFor('Home', 'owner', now: now), isTrue);
    },
  );
  test(
    'incorrect account cannot consume or reuse another account response',
    () {
      final value = seed();
      expect(value.consumeFor('Home', 'other', now: now), isFalse);
      expect(value.consumeFor('Home', 'owner', now: now), isTrue);
      expect(value.consumeFor('Navigation', null, now: now), isFalse);
    },
  );
  test('expired and future-dated responses are rejected', () {
    expect(
      seed(
        at: now.subtract(const Duration(seconds: 5)),
      ).consumeFor('Home', 'owner', now: now),
      isFalse,
    );
    expect(
      seed(
        at: now.add(const Duration(seconds: 1)),
      ).consumeFor('Home', 'owner', now: now),
      isFalse,
    );
    expect(
      seed(
        at: now.subtract(const Duration(seconds: 4)),
      ).consumeFor('Home', 'owner', now: now),
      isTrue,
    );
  });
  test(
    'republishing an already consumed response does not reset its marker',
    () {
      final old = seed();
      final fresh = seed();
      expect(old.consumeFor('Home', 'owner', now: now), isTrue);
      expect(fresh.consumeFor('Home', 'owner', now: now), isTrue);
      expect(old.consumeFor('Home', 'owner', now: now), isFalse);
    },
  );
}
