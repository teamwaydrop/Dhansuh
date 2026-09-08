// Shared: resolve the Cashfree `customer_details.customer_phone` value.
//
// Cashfree's PG order `customer_phone` expects the bare 10-digit Indian mobile number
// ("9876543210"), which is what shows in its checkout as "Payment Options for +91 9876543210".
// Supabase GoTrue stores a phone-OTP user's number as E.164 minus the '+' ("919876543210") on
// auth.users.phone -- the same value the Flutter client strips a "91" prefix from before
// displaying it (see lib/features/user/profile/profile_tab.dart's _cleanPhoneCode).
//
// This helper does NOT invent a number. It normalizes what is already stored, and returns null
// when nothing valid is available so the caller can decide (reject vs. fall back).

/// Normalize an Indian phone string to the bare 10-digit local form Cashfree wants.
/// Returns null if the input can't be reduced to exactly 10 digits.
export function normalizeIndianPhone(raw: string | null | undefined): string | null {
  if (raw == null) return null;
  const digits = String(raw).replace(/\D/g, "");
  if (digits.length === 0) return null;
  // Strip a leading '91' country code when the remainder is a full 10-digit number.
  const local = digits.length > 10 && digits.startsWith("91") ? digits.slice(-10) : digits;
  return /^\d{10}$/.test(local) ? local : null;
}

/// Fixed placeholder used ONLY for the reviewer / Play-Store-review bypass account:
/// lib/features/auth/screens/otp_screen.dart signs it in via `signInAnonymously()` when the
/// entered phone is kReviewerBypassPhone ('9999999999') and the OTP is '123456' -- that account
/// legitimately has no real phone (auth.users.phone is null, is_anonymous is true). This value
/// must NEVER be used for a real (non-anonymous) customer.
export const CASHFREE_REVIEWER_TEST_PHONE = "9999999999";

/// Resolve the Cashfree customer_phone for a person identified by their Supabase user id.
///
/// - Anonymous (reviewer bypass) user  -> CASHFREE_REVIEWER_TEST_PHONE.
/// - Real user with a phone on auth.users -> that number, normalized to 10 digits.
/// - Real user with no auth phone but one mirrored on public.users -> that, normalized.
/// - Real user with no phone anywhere -> null (caller must reject; never substitute a number).
///
/// `admin` must be a service-role Supabase client (typed `any`, matching this repo's other
/// _shared helpers, e.g. production_config_cache.ts).
export async function resolveCashfreeCustomerPhone(
  // deno-lint-ignore no-explicit-any
  admin: any,
  userId: string,
): Promise<{ phone: string; isReviewer: boolean } | { phone: null; isReviewer: false }> {
  let authUser: { phone?: string | null; is_anonymous?: boolean } | null = null;
  try {
    const res = await admin.auth.admin.getUserById(userId);
    authUser = (res?.data?.user as { phone?: string | null; is_anonymous?: boolean } | null) ?? null;
  } catch (_e) {
    authUser = null;
  }

  if (authUser?.is_anonymous === true) {
    return { phone: CASHFREE_REVIEWER_TEST_PHONE, isReviewer: true };
  }

  let phone = normalizeIndianPhone(authUser?.phone);
  if (!phone) {
    try {
      const { data } = await admin.from("users").select("phone").eq("id", userId).maybeSingle();
      phone = normalizeIndianPhone(data?.phone);
    } catch (_e) {
      phone = null;
    }
  }

  return phone ? { phone, isReviewer: false } : { phone: null, isReviewer: false };
}
