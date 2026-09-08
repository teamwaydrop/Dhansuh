import 'package:flutter_riverpod/flutter_riverpod.dart';

enum AppMode {

  user,

  rider,
}

class AppModeNotifier
    extends StateNotifier<AppMode> {

  AppModeNotifier()
      : super(AppMode.user);

  void switchToUser() {

    state = AppMode.user;
  }

  void switchToRider() {

    state = AppMode.rider;
  }

  void toggle() {

    state =
        state == AppMode.user

            ? AppMode.rider

            : AppMode.user;
  }
}

final appModeProvider =

StateNotifierProvider<
    AppModeNotifier,
    AppMode>(

  (ref) {

    return AppModeNotifier();
  },
);