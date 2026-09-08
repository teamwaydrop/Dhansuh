import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'dart:convert';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:waydrop/main.dart'; // Import providerContainer and navigatorKey
import 'package:waydrop/core/providers/app_mode_provider.dart';
import 'package:waydrop/core/providers/initial_data_provider.dart';
import 'package:waydrop/features/rider/orders/screens/rider_active_order_screen.dart';
import 'package:waydrop/features/rider/navigation/rider_main_navigation_screen.dart';
import 'package:waydrop/features/local_rides/tracking/screens/ride_tracking_screen.dart';
import 'package:waydrop/features/local_parcels/tracking/screens/parcel_tracking_screen.dart';
import 'package:waydrop/features/intercity/shared/screens/intercity_tracking_screen.dart';
import 'package:waydrop/modules/chat/screens/order_chat_screen.dart';
import 'package:waydrop/modules/notifications/screens/notification_detail_screen.dart';
import 'package:waydrop/features/intercity/shared/screens/intercity_searching_screen.dart';
import 'package:waydrop/features/rider/travel_plans/screens/travel_plan_details_screen.dart';
import 'package:waydrop/features/intercity/shared/services/intercity_matching_service.dart';
import 'package:waydrop/core/navigation/nav_trace.dart';

/// Top-level background message handler for FCM.
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  debugPrint("Handling a background message: ${message.messageId}");
}

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final _supabase = Supabase.instance.client;
  final FlutterLocalNotificationsPlugin _localNotifications = FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  /// Initializes FCM and sets up listeners.
  Future<void> initialize() async {
    if (_initialized) return;

    try {
      // Initialize Firebase (make sure Google Services configurations are present)
      await Firebase.initializeApp();

      // Set background message handler
      FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

      // Request notification permissions
      await requestPermissions();

      // Configure foreground notification presentation options
      await FirebaseMessaging.instance.setForegroundNotificationPresentationOptions(
        alert: true, // Show system tray banner/alert when app is open
        badge: true,
        sound: true,
      );

      // Initialize FlutterLocalNotificationsPlugin for Android and iOS
      const AndroidInitializationSettings initializationSettingsAndroid =
          AndroidInitializationSettings('@drawable/ic_stat_notify');
      const InitializationSettings initializationSettings = InitializationSettings(
        android: initializationSettingsAndroid,
        iOS: DarwinInitializationSettings(),
      );
      await _localNotifications.initialize(
        initializationSettings,
        onDidReceiveNotificationResponse: (NotificationResponse response) {
          if (response.payload != null) {
            try {
              final Map<String, dynamic> data = jsonDecode(response.payload!);
              handleNotificationTap(data);
            } catch (e) {
              debugPrint('Error parsing local notification response payload: $e');
            }
          }
        },
      );

      // Pre-create notification channels on Android
      if (!kIsWeb && Platform.isAndroid) {
        const AndroidNotificationChannel orderChannel = AndroidNotificationChannel(
          'order_alerts_v2',
          'Order Alerts',
          description: 'Alerts for nearby orders',
          importance: Importance.max,
          playSound: true,
          sound: RawResourceAndroidNotificationSound('order_nearby_sound'),
          enableVibration: true,
        );
        const AndroidNotificationChannel defaultChannel = AndroidNotificationChannel(
          'high_importance_channel',
          'High Importance Notifications',
          description: 'Used for critical order updates, chat messages, and alerts.',
          importance: Importance.max,
          playSound: true,
          enableVibration: true,
        );

        final androidPlugin = _localNotifications
            .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
        if (androidPlugin != null) {
          await androidPlugin.createNotificationChannel(orderChannel);
          await androidPlugin.createNotificationChannel(defaultChannel);
        }
      }

      // Listen for foreground messages
      FirebaseMessaging.onMessage.listen((RemoteMessage message) {
        debugPrint('Got a message whilst in the foreground!');
        debugPrint('Message data: ${message.data}');

        RemoteNotification? notification = message.notification;
        String? title = notification?.title ?? message.data['title']?.toString();
        String? body = notification?.body ?? message.data['body']?.toString();

        if ((title != null || body != null) && !kIsWeb) {
          final type = message.data['type']?.toString();
          final isOrderAssignment = type == 'order_assignment';
          
          if (isOrderAssignment) {
            // Issue 7 (notification sound consistency investigation): this is intentional, not a
            // gap -- local ride assignments already get an in-app "incoming order" sound/popup
            // from TWO independent, redundant sources that both listen directly to
            // rider_assignments realtime INSERTs and play the exact same order_nearby_sound.aac
            // asset: RiderHomeTab._showIncomingOrder()/_playOrderNearbySoundThrottled() and
            // RiderOrdersScreen._processAndFilterAssignments()/_playOrderNearbySoundThrottled().
            // Showing the FCM local-notification banner+sound here too would double the sound
            // whichever rider tab happens to be active. Background/killed-app delivery is
            // unaffected by this branch -- that sound/channel (order_alerts_v2/order_nearby_sound)
            // is set server-side in send-push-notification/index.ts and always fires, since these
            // in-app listeners aren't running when the app isn't in the foreground.
            //
            // Every OTHER notification type (including intercity match notifications) has no such
            // in-app popup/sound equivalent, so it intentionally keeps falling through to
            // _localNotifications.show() below, using high_importance_channel's system default
            // sound -- this is why an intercity match is reliably audible in the foreground while
            // a local ride assignment is (by design) silent here and audible via the in-app path
            // instead. Both paths are correct for what each notification type actually has.
            try {
              final currentCount = providerContainer.read(activeAssignmentsCountProvider);
              providerContainer.read(activeAssignmentsCountProvider.notifier).state = currentCount + 1;
            } catch (e) {
              debugPrint('Error updating active assignments badge: $e');
            }
            return; // Suppress local notification banner in foreground
          }

          final orderId = message.data['order_id']?.toString() ?? message.data['parcel_id']?.toString();
          final notificationId = orderId != null && orderId.isNotEmpty
              ? (orderId.hashCode & 0x7FFFFFFF)
              : (notification?.hashCode ?? message.messageId?.hashCode ?? DateTime.now().millisecond).toSigned(31);

          _localNotifications.show(
            notificationId,
            title,
            body,
            NotificationDetails(
              android: AndroidNotificationDetails(
                isOrderAssignment ? 'order_alerts_v2' : 'high_importance_channel',
                isOrderAssignment ? 'Order Alerts' : 'High Importance Notifications',
                channelDescription: isOrderAssignment
                    ? 'Alerts for nearby orders'
                    : 'Used for critical order updates, chat messages, and alerts.',
                importance: Importance.max,
                priority: Priority.high,
                icon: '@drawable/ic_stat_notify',
                color: const Color(0xFF01205F),
                sound: isOrderAssignment ? const RawResourceAndroidNotificationSound('order_nearby_sound') : null,
                playSound: true,
                enableVibration: true,
              ),
              iOS: DarwinNotificationDetails(
                presentAlert: true,
                presentBadge: true,
                presentSound: true,
                sound: isOrderAssignment ? 'order_nearby_sound.aac' : null,
              ),
            ),
            payload: jsonEncode(message.data),
          );
        }
      });

      // Listen for background message click taps (app was in background but running)
      FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
        debugPrint('Notification clicked while app in background: ${message.data}');
        handleNotificationTap(message.data);
      });

      // Handle message click when app was completely terminated
      FirebaseMessaging.instance.getInitialMessage().then((message) {
        if (message != null) {
          debugPrint('Notification clicked while app terminated: ${message.data}');
          Future.delayed(const Duration(milliseconds: 1000), () {
            handleNotificationTap(message.data);
          });
        }
      });

      // Listen for token refreshes
      FirebaseMessaging.instance.onTokenRefresh.listen((newToken) {
        debugPrint('FCM Token refreshed: $newToken');
        registerToken(newToken);
      });

      _initialized = true;
      debugPrint('NotificationService initialized successfully.');
      
      // Auto-register token if user is already logged in
      if (_supabase.auth.currentUser != null) {
        syncToken();
      }
    } catch (e) {
      debugPrint('NotificationService initialization error: $e');
    }
  }

  /// Requests notification permissions from the user.
  Future<void> requestPermissions() async {
    try {
      NotificationSettings settings = await FirebaseMessaging.instance.requestPermission(
        alert: true,
        announcement: false,
        badge: true,
        carPlay: false,
        criticalAlert: false,
        provisional: false,
        sound: true,
      );
      debugPrint('User granted permission: ${settings.authorizationStatus}');

      if (!kIsWeb && Platform.isAndroid) {
        await _localNotifications
            .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
            ?.requestNotificationsPermission();
      }
    } catch (e) {
      debugPrint('Error requesting notification permissions: $e');
    }
  }

  /// Fetches the current FCM token and registers it.
  Future<void> syncToken() async {
    try {
      final token = await FirebaseMessaging.instance.getToken();
      if (token != null) {
        debugPrint('Fetched FCM Token: $token');
        await registerToken(token);
      }
    } catch (e) {
      debugPrint('Error syncing FCM token: $e');
    }
  }

  /// Registers a token to the user_device_tokens table in Supabase.
  Future<void> registerToken(String fcmToken) async {
    try {
      final user = _supabase.auth.currentUser;
      if (user == null) {
        debugPrint('FCM registration skipped: No authenticated user.');
        return;
      }

      String deviceType = 'android';
      if (!kIsWeb) {
        if (Platform.isIOS) {
          deviceType = 'ios';
        }
      }

      await _supabase.from('user_device_tokens').upsert({
        'user_id': user.id,
        'fcm_token': fcmToken,
        'device_type': deviceType,
        'updated_at': DateTime.now().toIso8601String(),
      }, onConflict: 'fcm_token').timeout(const Duration(seconds: 8));

      debugPrint('FCM Token registered successfully to user: ${user.id}');
    } catch (e) {
      debugPrint('Error registering FCM token to database: $e');
    }
  }

  /// Removes the current FCM token from the database.
  Future<void> removeToken() async {
    try {
      final token = await FirebaseMessaging.instance.getToken();
      if (token != null) {
        await _supabase.from('user_device_tokens').delete().eq('fcm_token', token);
        debugPrint('FCM Token removed from database.');
      }
    } catch (e) {
      debugPrint('Error removing FCM token from database: $e');
    }
  }



  /// Opens the order chat screen for [orderId]/[riderId] -- the single canonical place Chat is
  /// ever pushed from a notification, so the exact same chat title/isSupport logic is never
  /// duplicated. Called both by the automatic 'chat_message'/'support_message' routing in
  /// handleNotificationTap() below and by NotificationDetailScreen's explicit "Open Chat" button
  /// (Issue 4, Phase 2) -- Chat only ever opens through one of those two, never automatically for
  /// an 'intercity_request' status notification.
  void openChatForOrder({
    required String orderId,
    String? riderId,
    bool isSupport = false,
  }) {
    final appMode = providerContainer.read(appModeProvider);
    final isRiderMode = appMode == AppMode.rider;
    final chatTitle = isSupport ? 'Customer Support' : (isRiderMode ? 'Client' : 'Drop Partner');

    NavTrace.begin('NotificationService', 'push OrderChatScreen (openChatForOrder) orderId=$orderId');
    navigatorKey.currentState?.push(
      MaterialPageRoute(
        builder: (_) => OrderChatScreen(
          orderId: orderId,
          riderId: riderId,
          chatTitle: chatTitle,
          isSupport: isSupport,
        ),
      ),
    );
    NavTrace.end('NotificationService', 'push OrderChatScreen (openChatForOrder) orderId=$orderId');
  }

  Future<void> handleNotificationTap(Map<String, dynamic> data) async {
    NavTrace.mark('NotificationService', 'handleNotificationTap ENTER payload=$data navStateNull=${navigatorKey.currentState == null}');
    try {
      final user = _supabase.auth.currentUser;
      if (user == null) {
        debugPrint('Auth is incomplete, queueing notification tap payload in SharedPreferences.');
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('pending_notification_payload', jsonEncode(data));
        return;
      }

      final notificationId = data['notification_id']?.toString();
      if (notificationId != null && notificationId.isNotEmpty) {
        _supabase.from('notifications').update({
          'is_read': true,
          'read_at': DateTime.now().toIso8601String(),
        }).eq('id', notificationId).timeout(const Duration(seconds: 8)).then((_) {
          debugPrint('Notification $notificationId marked as read in DB.');
        }).catchError((err) {
          debugPrint('Error marking notification as read: $err');
        });
      }

      final type = data['type']?.toString();
      final orderId = data['order_id']?.toString() ?? data['parcel_id']?.toString();

      debugPrint('Handling notification tap: type=$type, orderId=$orderId');

      if (type == 'travel_partners_available' || type == 'traveller_available') {
        // Phase 3 fix (Issue 2): both the aggregate 'travel_partners_available' and the
        // per-traveller 'traveller_available' notification are about ONE existing order/request --
        // route to IntercitySearchingScreen(orderId), the canonical per-order searching/matching
        // screen (already shows live matched travellers via its own realtime subscriptions, no
        // date picker), instead of the generic date/browse AvailablePartnersScreen. That screen
        // remains reachable from its own in-screen "Available Partners" icon and from Home/Activity
        // -- unchanged for those entry points.
        if (orderId != null && orderId.isNotEmpty) {
          navigatorKey.currentState?.push(
            MaterialPageRoute(builder: (_) => IntercitySearchingScreen(orderId: orderId)),
          );
        }
        return;
      }

      if (type == 'order_assignment') {
        final appMode = providerContainer.read(appModeProvider);
        if (appMode == AppMode.rider) {
          NavTrace.begin('NotificationService', 'pushAndRemoveUntil RiderMainNavigationScreen(orders) type=order_assignment');
          navigatorKey.currentState?.pushAndRemoveUntil(
            MaterialPageRoute(
              builder: (_) => const RiderMainNavigationScreen(initialIndex: 1), // Orders tab
            ),
            (_) => false,
          );
          NavTrace.end('NotificationService', 'pushAndRemoveUntil RiderMainNavigationScreen(orders) type=order_assignment');
        }
        return;
      }

      // ROOT-CAUSE FIX (real-APK reproduction, 2026-08-24): on_rider_review_insert() always stamps
      // a real 'order_id' into a new_rating notification's payload (jsonb_build_object(...,
      // 'order_id', NEW.order_id, ...)) -- a rating is always tied to a completed order, so
      // data['order_id'] is NEVER null/empty for a real rating notification. The previous fix
      // placed its NotificationDetailScreen push in an `else if (type == 'new_rating')` branch
      // that only runs when `orderId` is null/empty (it is the tail `else` of `if (orderId != null
      // && orderId.isNotEmpty) { ... }` below) -- so it was unreachable dead code for every real
      // rating tap. Execution instead entered the orderId-gated block, fetched the order, matched
      // none of its type checks (intercity_request/chat_message/support_message/order_status), and
      // silently fell through doing nothing -- exactly the "tap does nothing" symptom. Unlike
      // intercity_request (which genuinely needs the order lookup for its rider-mode Travel Plan
      // Details routing), new_rating never reads orderId/orderType at all, so it is moved here,
      // before the orderId gate, as its own unconditional early return -- same pattern as
      // order_assignment/travel_partners_available immediately above.
      if (type == 'new_rating') {
        NavTrace.begin('NotificationService', 'push NotificationDetailScreen type=new_rating');
        navigatorKey.currentState?.push(
          MaterialPageRoute(
            builder: (_) => NotificationDetailScreen(
              notificationId: data['notification_id']?.toString(),
              tapData: data,
            ),
          ),
        );
        NavTrace.end('NotificationService', 'push NotificationDetailScreen type=new_rating');
        return;
      }

      if (orderId != null && orderId.isNotEmpty) {
        // Fetch order details from Supabase to route correctly
        final response = await _supabase
            .from('orders')
            .select('order_type, distance_meters, rider_id')
            .eq('id', orderId)
            .maybeSingle()
            .timeout(const Duration(seconds: 8));

        if (response != null) {
          final orderType = response['order_type']?.toString();
          final distanceMeters = double.tryParse(response['distance_meters']?.toString() ?? '0') ?? 0.0;
          final riderId = response['rider_id']?.toString() ?? data['rider_id']?.toString() ?? data['traveller_id']?.toString();

          final appMode = providerContainer.read(appModeProvider);
          final isRiderMode = appMode == AppMode.rider;

          // Traveller-side 'intercity_request' notifications (new request, payment
          // verified, confirmed, rejected, etc.) all target the rider's own decision/status
          // screen, not chat — open the Travel Plan Details screen (which already has the
          // Accept/Reject/Details/Start-Transit bottom sheet) instead of jumping to chat.
          if (type == 'intercity_request' && isRiderMode) {
            final requestId = data['request_id']?.toString();
            bool opened = false;
            if (requestId != null && requestId.isNotEmpty) {
              try {
                final reqRow = await _supabase
                    .from('intercity_requests')
                    .select('route_id, traveller_id')
                    .eq('id', requestId)
                    .maybeSingle()
                    .timeout(const Duration(seconds: 8));
                final planId = reqRow?['route_id']?.toString();
                final travellerId = reqRow?['traveller_id']?.toString() ?? riderId;
                if (planId != null && planId.isNotEmpty && travellerId != null) {
                  final planRow = await _supabase
                      .from('rider_travel_plans')
                      .select()
                      .eq('id', planId)
                      .maybeSingle()
                      .timeout(const Duration(seconds: 8));
                  if (planRow != null) {
                    NavTrace.begin('NotificationService', 'push TravelPlanDetailsScreen type=intercity_request');
                    navigatorKey.currentState?.push(
                      MaterialPageRoute(
                        builder: (_) => TravelPlanDetailsScreen(
                          plan: Map<String, dynamic>.from(planRow),
                          rider: {'id': travellerId},
                          loadActiveOrder: (_) async {},
                          // Issue 2: routed through the single canonical
                          // cancel_travel_plan_by_traveller() RPC instead of a direct
                          // rider_travel_plans update. The reason is already collected by
                          // TravelPlanDetailsScreen._confirmDeletePlan (the shared
                          // CancellationReasonDialog) before this callback is ever invoked.
                          deleteTravelPlan: (planIdToDelete, reason) async {
                            await IntercityMatchingService.cancelTravelPlan(
                              routeId: planIdToDelete,
                              cancelReason: reason,
                            );
                          },
                        ),
                      ),
                    );
                    NavTrace.end('NotificationService', 'push TravelPlanDetailsScreen type=intercity_request');
                    opened = true;
                  }
                }
              } catch (e) {
                debugPrint('Error opening travel plan details from notification: $e');
              }
            }
            if (opened) return;
            // ISSUE 4 fix (Phase 2): previously fell through to the chat-opening block below --
            // an 'intercity_request' notification (a match/negotiation/payment/cancellation
            // status update) is NOT a chat message, and tapping it must never silently jump into
            // Chat. Falls through instead to the dedicated 'intercity_request' branch just below,
            // which opens the full-message NotificationDetailScreen.
          }

          // ISSUE 4 fix (Phase 2): 'intercity_request' notifications (new match, invitation,
          // discussion started, confirmed, rejected, paid, in_progress, completed, cancelled --
          // everything on_intercity_request_change() sends) are status updates ABOUT a
          // negotiation, never an actual chat message -- they used to be lumped into the same
          // "open Chat" bucket as real 'chat_message'/'support_message' notifications below,
          // which is why tapping a cancellation notification jumped straight into Chat instead of
          // showing the (possibly long, reason-bearing) notification text. Every notification of
          // this type now opens the full-message detail view instead; Chat stays one explicit tap
          // away via that screen's own "Open Chat" button (NotificationDetailScreen.openChat ->
          // openChatForOrder, the exact same method the genuine chat-message branch below calls).
          // The rider-mode Travel Plan Details routing above (still the more useful destination
          // when that lookup succeeds) is unaffected -- this only replaces what used to happen on
          // Chat-fallback / for a non-rider (passenger) viewer.
          if (type == 'intercity_request') {
            NavTrace.begin('NotificationService', 'push NotificationDetailScreen type=intercity_request');
            navigatorKey.currentState?.push(
              MaterialPageRoute(
                builder: (_) => NotificationDetailScreen(
                  notificationId: data['notification_id']?.toString(),
                  tapData: data,
                ),
              ),
            );
            NavTrace.end('NotificationService', 'push NotificationDetailScreen type=intercity_request');
            return;
          }

          if (type == 'chat_message' || type == 'support_message') {
            final isSupport = type == 'support_message' || (data['is_support']?.toString() == 'true');
            openChatForOrder(orderId: orderId, riderId: riderId, isSupport: isSupport);
          } else if (type == 'order_status') {
            if (isRiderMode) {
              // Rider mode is open -> redirect to rider active order screen
              NavTrace.begin('NotificationService', 'push RiderActiveOrderScreen type=order_status');
              navigatorKey.currentState?.push(
                MaterialPageRoute(
                  builder: (_) => RiderActiveOrderScreen(orderId: orderId),
                ),
              );
              NavTrace.end('NotificationService', 'push RiderActiveOrderScreen type=order_status');
            } else {
              // Stay on user mode, route user tracking screen
              NavTrace.begin('NotificationService', 'push *TrackingScreen orderType=$orderType type=order_status');
              navigatorKey.currentState?.push(
                MaterialPageRoute(
                  builder: (_) {
                    if (orderType == 'local_parcel') {
                      return ParcelTrackingScreen(orderId: orderId);
                    } else if (orderType == 'intercity_parcel' || orderType == 'intercity_ride' || (orderType == 'ride' && distanceMeters > 20000)) {
                      return IntercityTrackingScreen(orderId: orderId);
                    }
                    return RideTrackingScreen(orderId: orderId);
                  },
                ),
              );
              NavTrace.end('NotificationService', 'push *TrackingScreen orderType=$orderType type=order_status');
            }
          }
        }
      } else if (type == 'cod_settlement') {
        final appMode = providerContainer.read(appModeProvider);
        if (appMode == AppMode.rider) {
          NavTrace.begin('NotificationService', 'pushAndRemoveUntil RiderMainNavigationScreen(earnings) type=cod_settlement');
          navigatorKey.currentState?.pushAndRemoveUntil(
            MaterialPageRoute(
              builder: (_) => const RiderMainNavigationScreen(initialIndex: 2), // Earnings tab
            ),
            (_) => false,
          );
          NavTrace.end('NotificationService', 'pushAndRemoveUntil RiderMainNavigationScreen(earnings) type=cod_settlement');
        }
      } else if (type == 'subscription_expired' || type == 'subscription_expiring') {
        final appMode = providerContainer.read(appModeProvider);
        if (appMode == AppMode.rider) {
          NavTrace.begin('NotificationService', 'pushAndRemoveUntil RiderMainNavigationScreen(profile) type=$type');
          navigatorKey.currentState?.pushAndRemoveUntil(
            MaterialPageRoute(
              builder: (_) => const RiderMainNavigationScreen(initialIndex: 3), // Profile tab
            ),
            (_) => false,
          );
          NavTrace.end('NotificationService', 'pushAndRemoveUntil RiderMainNavigationScreen(profile) type=$type');
        }
      }
    } catch (e) {
      debugPrint('Error handling notification tap: $e');
    }
  }

  Future<void> processPendingNotificationQueue() async {
    try {
      final user = _supabase.auth.currentUser;
      if (user == null) {
        debugPrint('Cannot process pending notifications: User is still unauthenticated.');
        return;
      }
      final prefs = await SharedPreferences.getInstance();
      final pendingStr = prefs.getString('pending_notification_payload');
      if (pendingStr != null && pendingStr.isNotEmpty) {
        debugPrint('Processing queued pending notification payload: $pendingStr');
        final data = jsonDecode(pendingStr);
        await prefs.remove('pending_notification_payload');
        // Small delay to ensure navigator/context is fully loaded
        Future.delayed(const Duration(milliseconds: 500), () {
          handleNotificationTap(data);
        });
      }
    } catch (e) {
      debugPrint('Error processing pending notification queue: $e');
    }
  }
}


