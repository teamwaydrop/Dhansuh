import 'package:flutter/foundation.dart';

enum ErrorType {
  offline,
  slow,
  backend,
  general,
}

class GlobalAppError {
  final ErrorType type;
  final String message;
  final VoidCallback? onRetry;

  GlobalAppError({
    required this.type,
    required this.message,
    this.onRetry,
  });
}

class GlobalErrorController {
  static final GlobalErrorController _instance = GlobalErrorController._internal();
  factory GlobalErrorController() => _instance;
  GlobalErrorController._internal();

  final ValueNotifier<GlobalAppError?> errorNotifier = ValueNotifier<GlobalAppError?>(null);

  /// Triggers a global app error screen of the specified type.
  void showError(GlobalAppError error) {
    errorNotifier.value = error;
  }

  /// Clears any currently showing global error screen.
  void clearError() {
    errorNotifier.value = null;
  }
}
