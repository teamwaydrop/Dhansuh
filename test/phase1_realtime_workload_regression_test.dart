import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final session = _read('lib/core/services/session/user_session_service.dart');
  final incoming = _read(
    'lib/features/rider/orders/widgets/incoming_order_card.dart',
  );
  final chat = _read('lib/modules/chat/screens/order_chat_screen.dart');
  final payment = _read('lib/modules/payments/services/payment_service.dart');
  final home = _read('lib/features/user/home/home_tab.dart');

  group('single-binding channels use RealtimeManager', () {
    test('user suspension listener is pooled and idempotently removable', () {
      expect(session.contains("owner: 'UserSessionService'"), isTrue);
      expect(session.contains("filterColumn: 'id'"), isTrue);
      expect(session.contains('RealtimeManager.instance.unsubscribe('), isTrue);
      expect(session.contains(".channel('user-suspension-"), isFalse);
    });

    test('incoming order card pools both update listeners', () {
      expect(incoming.contains("owner: 'IncomingOrderCard_Order'"), isTrue);
      expect(
        incoming.contains("owner: 'IncomingOrderCard_Assignment'"),
        isTrue,
      );
      expect(incoming.contains('.channel('), isFalse);
      expect(
        'RealtimeManager.instance.unsubscribe('
            .allMatches(incoming)
            .length,
        2,
      );
    });

    test('chat listens only for message inserts and removes dead raw state', () {
      expect(chat.contains("owner: 'OrderChatScreen_Messages'"), isTrue);
      expect(chat.contains('event: PostgresChangeEvent.insert'), isTrue);
      expect(chat.contains('RealtimeChannel? _requestChannel'), isFalse);
      expect(chat.contains('supabase.channel('), isFalse);
    });

    test('payment listeners pool by payment ID and unsubscribe on cancel', () {
      expect(payment.contains("owner: 'PaymentService'"), isTrue);
      expect(payment.contains("final channelName = 'payment-\$paymentId';"), isTrue);
      expect(payment.contains('controller.onCancel = () {'), isTrue);
      expect(payment.contains('supabase.channel('), isFalse);
    });
  });

  test('the intentionally multiplexed home channel handles removal futures', () {
    expect(home.contains('await supabase.removeChannel(channelToRemove);'), isTrue);
    expect(
      'unawaited(_removeMultiplexedHomeChannel(channel!));'
          .allMatches(home)
          .length,
      2,
    );
    expect(
      '.onPostgresChanges('.allMatches(home).length,
      greaterThanOrEqualTo(3),
      reason: 'Home keeps one raw channel because it multiplexes three table bindings.',
    );
  });
}
