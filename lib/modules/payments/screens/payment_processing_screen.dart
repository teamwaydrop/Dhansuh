import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_cashfree_pg_sdk/api/cferrorresponse/cferrorresponse.dart';
import 'package:waydrop/modules/payments/services/payment_service.dart';
import 'package:waydrop/modules/payments/services/payment_debug_trace.dart';

enum PaymentUIState {
  initializing,
  redirecting,
  processing,
  pending,
  success,
  failed,
  cancelled,
}

class PaymentProcessingScreen extends StatefulWidget {
  final String paymentCode;
  final String paymentId;
  final String orderId;
  final String? paymentSessionId;
  final double amount;
  final String paymentForLabel;

  // Optional overrides so this same processing/realtime/poll state machine can serve callers with
  // different copy (e.g. the driver's "Cashfree QR" flow) without duplicating it. Null/omitted
  // reproduces today's passenger-checkout copy exactly -- existing call sites need no changes.
  final String? screenTitle;
  final String? instructionText;
  final String? successHeadline;

  // TEMP DEBUG INSTRUMENTATION: the payment_for value ('subscription' / 'tax_due' / etc.), used
  // to tag every PaymentTrace log line from this screen so a single flow's trail (start button ->
  // ... -> payment end) can be filtered out of the full run log. Falls back to paymentForLabel if
  // not supplied (existing call sites that haven't been updated). See payment_debug_trace.dart.
  final String? flowTag;

  const PaymentProcessingScreen({
    super.key,
    required this.paymentCode,
    required this.paymentId,
    required this.orderId,
    required this.amount,
    required this.paymentForLabel,
    this.paymentSessionId,
    this.screenTitle,
    this.instructionText,
    this.successHeadline,
    this.flowTag,
  });

  @override
  State<PaymentProcessingScreen> createState() => _PaymentProcessingScreenState();
}

class _PaymentProcessingScreenState extends State<PaymentProcessingScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  PaymentUIState _state = PaymentUIState.initializing;
  String _statusMessage = 'Creating secure payment...';
  String? _failureReason;
  bool _isCheckingStatus = false;

  StreamSubscription? _statusSubscription;
  Timer? _fallbackTimer;
  Timer? _timeoutTimer;

  // Phase 8 P2 fix: realtime-health gate for the fallback poll below, mirroring the same proven
  // pattern already used in RealtimeOrderController/rider_orders_screen/intercity_searching_screen
  // -- while the realtime payments-row subscription has delivered an update recently, the 10s
  // fallback tick is a pure duplicate (verify-payment would just re-confirm what realtime already
  // reported), so it's skipped. The fallback stays as the safety net the moment realtime goes
  // quiet/stale, and the 3-minute global timeout and _stopBackgroundWork() cleanup are unchanged.
  DateTime? _lastRealtimeEventAt;

  // Resource-cleanup-only guards (Performance Roadmap P0 #1): _startFlow() is only ever called
  // once today (from initState), and _stopBackgroundWork() is only ever reached from the four
  // exit paths below -- these flags make both facts explicit invariants instead of implicit ones,
  // so a future call site can never accidentally register a second realtime subscription/timer
  // set, or double-cancel/re-enter cleanup. No behavioural change on the existing single-call path.
  bool _flowStarted = false;
  bool _cleanedUp = false;

  late AnimationController _rotationController;

  // TEMP DEBUG INSTRUMENTATION: tag used for every PaymentTrace log line from this screen
  // instance. See payment_debug_trace.dart.
  String get _flow => widget.flowTag ?? widget.paymentForLabel;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _rotationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();

    PaymentTrace.start(_flow);
    _startFlow();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopBackgroundWork();
    _rotationController.dispose();
    PaymentService.clearActivePaymentCallbacks();
    PaymentTrace.end(_flow);
    super.dispose();
  }

  // Single, idempotent teardown point for every background resource this screen opens (the
  // Realtime status subscription and both timers) -- called from every terminal/exit path: payment
  // success, payment failure, payment cancelled, the 3-minute pending-verification timeout (which
  // routes through _handleFailure), and dispose() (covers the user leaving the screen by any route,
  // since Flutter tears this State down via dispose() regardless of which button/gesture triggered
  // the pop). Guarded so it can never run its cancellation logic twice or leave a stale reference
  // behind -- calling it a second time (e.g. dispose() after _handleFailure already ran) is a no-op.
  // This does NOT change when cleanup happens versus before: every call site below already called
  // the same three cancels individually; this only collapses them into one verified path so no
  // future exit branch can be added without also getting cleanup.
  void _stopBackgroundWork() {
    if (_cleanedUp) return;
    _cleanedUp = true;
    _statusSubscription?.cancel();
    _statusSubscription = null;
    _fallbackTimer?.cancel();
    _fallbackTimer = null;
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The passenger/driver returns from the Cashfree web checkout tab by
    // backgrounding-then-resuming the app (browser/UPI app switch). Don't
    // wait for the next 10s poll tick — check immediately on resume.
    if (state == AppLifecycleState.resumed && _state == PaymentUIState.processing) {
      _runVerificationCheck();
    }
  }

  void _startFlow() async {
    // Guard against ever registering a second realtime subscription/timer set for this screen
    // instance (Performance Roadmap P0 #1 -- "prevent duplicate listeners"/"prevent duplicate
    // polling"). _startFlow() is only called once today (initState), so this is a hardening
    // invariant, not a fix for an observed double-call -- it costs nothing on the existing path.
    if (_flowStarted) return;
    _flowStarted = true;

    // Wait for the route transition to complete before triggering native overlay
    await Future.delayed(const Duration(milliseconds: 600));
    if (!mounted) return;

    // 1. If we have a session ID, open payment gateway immediately
    debugPrint(
      'STEP 3c: PaymentProcessingScreen._startFlow => '
      'paymentSessionId=${widget.paymentSessionId} orderId=${widget.orderId}',
    );
    if (widget.paymentSessionId != null) {
      setState(() {
        _state = PaymentUIState.redirecting;
        _statusMessage = 'Connecting to Cashfree...';
      });

      // Route this attempt's result through the single, permanently-registered native callback
      // (PaymentService.initializeCallbacks(), called once at app startup) rather than calling the
      // SDK's own setCallback() again here. Re-invoking setCallback() per screen used to replay any
      // stale terminal response cached from a PREVIOUS payment attempt straight into this screen's
      // handler, near-instantly and before doPayment() below had any chance to open the real
      // checkout/QR -- see PaymentService.registerActivePaymentCallbacks for the full root cause.
      PaymentService.registerActivePaymentCallbacks(
        flowLabel: _flow,
        onSuccess: (String orderId) {
          debugPrint('SDK SUCCESS CALLBACK => $orderId');
        },
        onError: (CFErrorResponse error, String orderId) {
          debugPrint('SDK ERROR CALLBACK => ${error.getMessage()}');
          _onPaymentSDKError(error);
        },
      );

      final opened = await PaymentService.openPayment(
        orderId: widget.orderId,
        paymentSessionId: widget.paymentSessionId!,
        flowLabel: _flow,
      );

      debugPrint('STEP 7b: PaymentService.openPayment() returned opened=$opened');

      if (!mounted) return;

      if (!opened) {
        PaymentTrace.abnormalExit('_startFlow', _flow, 'PaymentService.openPayment() returned false');
        _handleFailure('Unable to open payment gateway. Please try again.');
        return;
      }

      setState(() {
        _state = PaymentUIState.processing;
        _statusMessage = "Payment interface opened.\nWe're verifying it securely...";
      });
    } else {
      // If we don't have session ID, we start in processing state (e.g. for re-verification)
      setState(() {
        _state = PaymentUIState.processing;
        _statusMessage = 'Checking payment status...';
      });
    }

    // 2. Start Realtime Listener on PostgreSQL payments table
    _statusSubscription = PaymentService.listenPaymentStatus(widget.paymentId).listen((paymentRecord) {
      PaymentTrace.step('REALTIME_UPDATE', _flow, paymentRecord);
      if (paymentRecord == null) return;
      _lastRealtimeEventAt = DateTime.now();
      final status = paymentRecord['payment_status']?.toString().toLowerCase();
      _onPaymentStatusChanged(status, paymentRecord['failure_reason']?.toString());
    });

    // 3. Start Periodic Verification Fallback (every 10s)
    _fallbackTimer = Timer.periodic(const Duration(seconds: 10), (timer) {
      // Realtime-health gate: while the payments-row subscription has delivered an update
      // recently, this tick is a pure duplicate -- skip it. Stays as the fallback the moment
      // realtime goes quiet/stale, exactly like the other pollers this pattern is copied from.
      final lastEvent = _lastRealtimeEventAt;
      if (lastEvent != null && DateTime.now().difference(lastEvent) < const Duration(seconds: 15)) {
        return;
      }
      _runVerificationCheck();
    });

    // Run first check after 5 seconds to catch quick checkouts
    Future.delayed(const Duration(seconds: 5), () {
      if (mounted && _state == PaymentUIState.processing) {
        _runVerificationCheck();
      }
    });

    // 4. Global Timeout (3 minutes)
    _timeoutTimer = Timer(const Duration(minutes: 3), () {
      if (mounted && (_state == PaymentUIState.processing || _state == PaymentUIState.initializing)) {
        _handleFailure('Verification timed out. Please check your bank and refresh.');
      }
    });
  }

  void _onPaymentSDKError(CFErrorResponse error) {
    if (!mounted) return;
    debugPrint(
      'STEP 9: _onPaymentSDKError fired (this is what flips the UI to "Still verifying '
      'your payment...") => message=${error.getMessage()} code=${error.getCode()} '
      'type=${error.getType()} status=${error.getStatus()}',
    );
    PaymentTrace.step(
      '_onPaymentSDKError',
      _flow,
      {'code': error.getCode(), 'message': error.getMessage(), 'type': error.getType(), 'status': error.getStatus()},
    );
    // The SDK's free-text error message is never authoritative for whether money moved --
    // Cashfree itself only ever reports SUCCESS/FAILED/CANCELLED/USER_DROPPED/pending via
    // verify-payment (see its "CHECK FAILED PAYMENTS" branch), which is real gateway truth with a
    // real failure_reason.
    //
    // ROOT CAUSE of the real-device "Payment Cancelled" false-positive: on Android, backgrounding
    // the Cashfree checkout WebView (e.g. the OS switching to a UPI app to let the passenger
    // authorize the payment, or a plain task-switcher swipe) can make the SDK fire this onError
    // callback well before the passenger has actually finished (or even started) authorizing --
    // it is not proof the checkout was cancelled. verify-payment reporting "pending" here means
    // Cashfree DOES have a record of this attempt and just hasn't resolved it yet -- that is the
    // opposite of "no payment attempt exists," so it must never be treated as a cancellation.
    // Only a real terminal SUCCESS/FAILED/CANCELLED/USER_DROPPED record from Cashfree (handled
    // below via _onPaymentStatusChanged, for both this check and the normal 5s/10s/app-resume
    // polling) is ever shown as a resolved outcome.
    _runVerificationCheck(
      onStillPending: () {
        if (!mounted) return;
        // Not proof of cancellation. Surface the honest "still verifying" pending state (Refresh /
        // Go Back available) instead of a false "Payment Cancelled" -- but only if nothing else
        // already resolved this screen (e.g. a concurrent poll tick observed success while this
        // check was in flight). Deliberately do NOT cancel the fallback timer / realtime
        // subscription: this screen keeps listening/polling in the background so a genuine
        // success/failure landing moments later (the passenger was still authorizing in their UPI
        // app) still resolves it automatically.
        if (_state == PaymentUIState.processing) {
          setState(() {
            _state = PaymentUIState.pending;
            _statusMessage = 'Still verifying your payment...';
          });
        }
      },
    );
  }

  Future<void> _runVerificationCheck({VoidCallback? onStillPending}) async {
    if (_isCheckingStatus || !mounted) return;
    setState(() => _isCheckingStatus = true);

    try {
      final response = await PaymentService.verifyPayment(widget.paymentCode, flowLabel: _flow);
      final status = response?['payment_status']?.toString().toLowerCase();
      PaymentTrace.step('POLLING_UPDATE', _flow, {'status': status, 'response': response});
      if (response == null || status == null || status == 'pending') {
        onStillPending?.call();
      } else {
        _onPaymentStatusChanged(status, response['failure_reason']?.toString());
      }
    } catch (e, st) {
      debugPrint('Manual verification poll failed: $e');
      PaymentTrace.exceptionAt('_runVerificationCheck', _flow, e, st);
      onStillPending?.call();
    } finally {
      if (mounted) {
        setState(() => _isCheckingStatus = false);
      }
    }
  }

  void _onPaymentStatusChanged(String? status, String? reason) {
    if (!mounted) return;
    PaymentTrace.step('PAYMENT_STATUS_CHANGED', _flow, {'status': status, 'reason': reason});

    if (status == 'paid') {
      _stopBackgroundWork();
      setState(() {
        _state = PaymentUIState.success;
        _statusMessage = widget.successHeadline ?? 'Payment Successful!\nCompleting your booking...';
      });

      // Automatically return success after a short visual delay
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted) {
          final result = {
            'success': true,
            'payment_id': widget.paymentId,
            'payment_code': widget.paymentCode,
          };
          PaymentTrace.step('NAVIGATION_RETURN', _flow, result);
          PaymentTrace.end(_flow);
          Navigator.pop(context, result);
        }
      });
    } else if (status == 'failed') {
      _handleFailure(reason ?? 'Transaction was declined by your bank.');
    } else if (status == 'cancelled') {
      _stopBackgroundWork();
      setState(() {
        _state = PaymentUIState.cancelled;
        _statusMessage = 'Payment Cancelled';
        _failureReason = 'No amount was charged from your account.';
      });
    } else if (status == 'expired') {
      _handleFailure('Payment session expired. Please retry.');
    }
  }

  // TEMP DEBUG INSTRUMENTATION: every user-driven "leave this screen" action funnels through here
  // so it shows up as a NAVIGATION_RETURN trace line, same as the automatic success-path pop.
  void _navigateBack(String action) {
    PaymentTrace.step('NAVIGATION_RETURN', _flow, action);
    PaymentTrace.end(_flow);
    Navigator.pop(context, action);
  }

  void _handleFailure(String reason) {
    PaymentTrace.abnormalExit('_handleFailure', _flow, reason);
    _stopBackgroundWork();
    setState(() {
      _state = PaymentUIState.failed;
      _statusMessage = 'Payment Failed';
      _failureReason = reason;
    });
  }

  Widget _buildLoadingIndicator(Color color) {
    return SizedBox(
      height: 64,
      width: 64,
      child: CircularProgressIndicator(
        strokeWidth: 5,
        valueColor: AlwaysStoppedAnimation<Color>(color),
        backgroundColor: color.withValues(alpha: 0.1),
      ),
    );
  }

  Widget _buildStatusIcon() {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    switch (_state) {
      case PaymentUIState.initializing:
      case PaymentUIState.redirecting:
        return _buildLoadingIndicator(const Color(0xFF10B981));
      case PaymentUIState.processing:
        return Stack(
          alignment: Alignment.center,
          children: [
            _buildLoadingIndicator(const Color(0xFF10B981)),
            Icon(Icons.lock_outline_rounded, size: 24, color: const Color(0xFF10B981)),
          ],
        );
      case PaymentUIState.pending:
        return Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFFFFFBEB).withValues(alpha: 0.15) : const Color(0xFFFEF3C7),
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.hourglass_empty_rounded, size: 40, color: Color(0xFFD97706)),
        );
      case PaymentUIState.success:
        return Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFFD1FAE5).withValues(alpha: 0.15) : const Color(0xFFD1FAE5),
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.check_circle_rounded, size: 40, color: Color(0xFF10B981)),
        );
      case PaymentUIState.failed:
        return Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFFFEE2E2).withValues(alpha: 0.15) : const Color(0xFFFEE2E2),
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.error_outline_rounded, size: 40, color: Color(0xFFEF4444)),
        );
      case PaymentUIState.cancelled:
        return Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFFF1F5F9).withValues(alpha: 0.15) : const Color(0xFFF1F5F9),
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.cancel_outlined, size: 40, color: Color(0xFF64748B)),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final backgroundColor = isDark ? const Color(0xFF0B0F17) : Colors.white;
    final cardColor = isDark ? const Color(0xFF151B26) : const Color(0xFFF8FAFC);
    final primaryTextColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final secondaryTextColor = isDark ? const Color(0xFF94A3B8) : const Color(0xFF475569);
    final borderCol = isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0);

    return PopScope(
      canPop: _state == PaymentUIState.failed || _state == PaymentUIState.cancelled || _state == PaymentUIState.pending,
      child: Scaffold(
        backgroundColor: backgroundColor,
        appBar: widget.screenTitle == null
            ? null
            : AppBar(
                title: Text(widget.screenTitle!),
                backgroundColor: backgroundColor,
                foregroundColor: primaryTextColor,
                elevation: 0,
              ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 20.0),
            child: Column(
              children: [
                const Spacer(),
                
                // Status Visual representation card
                Container(
                  padding: const EdgeInsets.all(32),
                  decoration: BoxDecoration(
                    color: cardColor,
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: borderCol),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: isDark ? 0.3 : 0.04),
                        blurRadius: 20,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _buildStatusIcon(),
                      const SizedBox(height: 24),
                      Text(
                        _statusMessage,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: primaryTextColor,
                        ),
                      ),
                      if (_failureReason != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          _failureReason!,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            color: const Color(0xFFEF4444),
                          ),
                        ),
                      ],
                      const SizedBox(height: 24),
                      Divider(color: borderCol, height: 1),
                      const SizedBox(height: 20),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'Payment For:',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: secondaryTextColor,
                            ),
                          ),
                          Flexible(
                            child: Text(
                              widget.paymentForLabel,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.right,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                                color: primaryTextColor,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'Amount:',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: secondaryTextColor,
                            ),
                          ),
                          Text(
                            '₹${widget.amount.toStringAsFixed(2)}',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                              color: const Color(0xFF10B981),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                const Spacer(),

                // Action buttons based on status
                if (_state == PaymentUIState.failed || _state == PaymentUIState.cancelled) ...[
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => _navigateBack('change_method'),
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            side: BorderSide(color: borderCol),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                          ),
                          child: Text(
                            'Change Method',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              color: primaryTextColor,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: ElevatedButton(
                          onPressed: () => _navigateBack('retry'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF10B981),
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                          ),
                          child: const Text(
                            'Retry Payment',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: () {
                      // Navigate to Support screen or pop with status support
                      _navigateBack('support');
                    },
                    child: Text(
                      'Contact Customer Support',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: const Color(0xFF10B981),
                      ),
                    ),
                  ),
                ] else if (_state == PaymentUIState.pending) ...[
                  ElevatedButton(
                    onPressed: _isCheckingStatus ? null : _runVerificationCheck,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF10B981),
                      minimumSize: const Size.fromHeight(54),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    ),
                    child: _isCheckingStatus
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.0),
                          )
                        : const Text(
                            'Refresh Payment Status',
                            style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.white),
                          ),
                  ),
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: () => _navigateBack('home'),
                    child: Text(
                      'Go Back to Home',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: secondaryTextColor,
                      ),
                    ),
                  ),
                ] else ...[
                  // Processing loading message
                  Text(
                    widget.instructionText ??
                        'Do not close this screen or press back.\nWe are establishing a secure gateway session.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: secondaryTextColor,
                    ),
                  ),
                ],
                const SizedBox(height: 10),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
