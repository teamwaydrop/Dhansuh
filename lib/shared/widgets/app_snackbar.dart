import 'package:flutter/material.dart';

enum SnackBarType { success, error, info }

String _sanitizeMessage(String rawMessage) {
  final msg = rawMessage.toLowerCase();
  
  if (msg.contains("payment_method_enum") || 
      msg.contains("payment db insert failed") ||
      msg.contains("22p02")) {
    return "Payment failed. Please select a valid payment method.";
  }
  if (msg.contains("23505")) {
    return "This record already exists in our system.";
  }
  if (msg.contains("permission denied") || 
      msg.contains("42501") ||
      msg.contains("forbidden")) {
    return "Access denied. You do not have permission to do this.";
  }
  // Only a raw, unparsed exception dump ("FunctionException(status: 500, ...)") should be
  // collapsed here -- a message our own edge functions deliberately returned (extracted from the
  // response body, e.g. a Cashfree gateway rejection reason) must reach the user as-is even if it
  // happens to mention "status: 500" or a real internal error, since that's the whole point of it.
  final isRawServerExceptionDump =
      RegExp(r'functionexception\s*\(', caseSensitive: false).hasMatch(rawMessage) &&
      (msg.contains("status: 500") || msg.contains("internal server error"));
  if (isRawServerExceptionDump) {
    return "Server error occurred. Please try again in a few moments.";
  }
  if (msg.contains("socketexception") || 
      msg.contains("timeoutexception") ||
      msg.contains("network") ||
      msg.contains("failed host lookup")) {
    return "Network error. Please check your internet connection.";
  }
  if (msg.contains("invalid login credentials")) {
    return "Invalid credentials. Please verify your details.";
  }

  // Only collapse messages that look like a raw exception dump (constructor-style text such as
  // "FunctionException(status: ..., details: ...)" or a Postgrest error object) -- these leak
  // internal shape without being useful to the driver/passenger. A message our own edge functions
  // deliberately wrote (e.g. "Please confirm that this UPI ID belongs to you...", a Cashfree
  // gateway rejection reason) is exactly what the user needs to see and must never be replaced
  // just for being longer than some arbitrary length.
  final looksLikeRawException = RegExp(r'(FunctionException|PostgrestException)\s*\(').hasMatch(rawMessage);
  if (looksLikeRawException) {
    return "Something went wrong. Please try again.";
  }

  return rawMessage;
}

void showAppSnackBar(
  BuildContext context,
  String message, {
  SnackBarType type = SnackBarType.info,
}) {
  final sanitizedMessage = _sanitizeMessage(message);
  ScaffoldMessenger.of(context).hideCurrentSnackBar();

  Color backgroundColor;
  IconData icon;

  switch (type) {
    case SnackBarType.success:
      backgroundColor = const Color(0xFF1B7A44); // Emerald Green
      icon = Icons.check_circle_rounded;
      break;
    case SnackBarType.error:
      backgroundColor = const Color(0xFFEF4444); // Red
      icon = Icons.error_rounded;
      break;
    case SnackBarType.info:
      backgroundColor = const Color(0xFF1E293B); // Premium Slate
      icon = Icons.info_rounded;
      break;
  }

  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      behavior: SnackBarBehavior.floating,
      elevation: 4,
      backgroundColor: backgroundColor,
      duration: const Duration(seconds: 3),
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      content: Row(
        children: [
          Icon(
            icon,
            color: Colors.white,
            size: 20,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              sanitizedMessage,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.1,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}