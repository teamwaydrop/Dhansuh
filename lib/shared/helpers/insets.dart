import 'package:flutter/material.dart';

class Insets {
  static double top(BuildContext context) =>
      MediaQuery.of(context).viewPadding.top;

  static double bottom(BuildContext context) =>
      MediaQuery.of(context).viewPadding.bottom;
}
