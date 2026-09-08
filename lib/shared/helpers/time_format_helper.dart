/// Shared 12-hour time formatting, used everywhere a raw DateTime needs to be shown as a time
/// (e.g. "1:00 PM") instead of 24-hour clock (e.g. "13:00"). No `intl` package dependency is
/// pulled in for this — the app doesn't already depend on it, and this mirrors the hand-rolled
/// AM/PM conversion already used elsewhere in the codebase (e.g.
/// TravelPlanDetailsScreen.formatRelativeDate), just centralized so it isn't re-implemented
/// (and re-forgotten) at every call site.
class TimeFormatHelper {
  TimeFormatHelper._();

  /// Formats the time-of-day portion of [dateTime] as "1:00 PM" / "12:30 AM".
  static String formatTime12Hour(DateTime dateTime) {
    final hour24 = dateTime.hour;
    final amPm = hour24 >= 12 ? 'PM' : 'AM';
    final hour12 = hour24 % 12 == 0 ? 12 : hour24 % 12;
    final minute = dateTime.minute.toString().padLeft(2, '0');
    return '$hour12:$minute $amPm';
  }

  /// Formats [dateTime] as "21/07/2026 1:00 PM".
  static String formatDateTime12Hour(DateTime dateTime) {
    final day = dateTime.day.toString().padLeft(2, '0');
    final month = dateTime.month.toString().padLeft(2, '0');
    return '$day/$month/${dateTime.year} ${formatTime12Hour(dateTime)}';
  }
}
