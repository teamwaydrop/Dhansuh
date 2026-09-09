# Runbook — Partner (Drop Partner / Rider) KYC Review

**Owner:** Operations (an active `public.admins` account).
**Supersedes:** the KYC section of `docs/10_Admin.md` (which is stale — wrong
bucket name `kyc_docs`, describes screens that were never built).

## Where the data is

| Item | Location |
|---|---|
| Application row | `public.rider_kyc` (one per applicant, `user_id → users.id`) |
| Identity fields | `full_name`, `father_name`, `date_of_birth`, `aadhaar_number`, `pan_number`, `driving_license_number`, `vehicle_type`, `vehicle_number` |
| Document images | Private Storage bucket **`rider_kyc`**, columns hold **bare object paths**: `rider_image`, `aadhaar_front_image`, `aadhaar_back_image`, `pan_front_image`, `pan_back_image`, `license_front_image`, `license_back_image`, `vehicle_image`, `VECHILE_RC_front_image`, `VECHILE_RC_back_image` |
| Status | `kyc_status` (`pending`/`under_review`/`resubmitted`/`approved`/`rejected`), `activation_status` (`inactive`/`profile_pending`/`active`/`suspended`) |
| Review metadata | `handled_by_admin_id → admins.id`, `approved_at`, `rejected_at`, `activated_at`, `rejection_reason`, `rejection_count`, `blocked_until` |
| Extra vehicles | `public.rider_vehicles` (same approve/reject pattern) |
| Audit | `public.admin_logs` (`action_type` `kyc_approve` / `kyc_reject`) |

## Option A — In the app (recommended)

1. **WayDrop → Profile → Admin Panel → Partner KYC Review** (visible only to an
   active `public.admins` row).
2. The list shows every application in `pending` / `under_review` /
   `resubmitted`, with rejection count and block status.
3. Open one → review identity fields and each **document image** (loaded via a
   short-lived signed URL; tap to zoom).
4. **Approve** → confirms, then calls `admin_review_rider_kyc(kyc_id,'approve')`:
   - sets `kyc_status='approved'`, `activation_status='active'`,
     `handled_by_admin_id`, `approved_at`, `activated_at`
   - the existing trigger `trigger_create_rider_profile` creates the
     `public.riders` row (`account_status='offline'`, `is_verified=true`)
   - fires a push notification to the partner ("Partner verification approved")
   - writes an `admin_logs` row
5. **Reject** → enter a **reason** (shown to the partner), then calls
   `admin_review_rider_kyc(kyc_id,'reject',reason)`:
   - sets `kyc_status='rejected'`, `activation_status='inactive'`,
     `rejection_reason`, `rejected_at`, `rejection_count += 1`
   - on the **2nd or later** rejection, sets `blocked_until = now() + 7 days`
     (mirrors the existing `create-rider-kyc` resubmission rule)
   - fires a push notification with the reason
   - writes an `admin_logs` row

## Option B — Direct (Supabase Studio, as an admin)

```sql
-- queue
SELECT public.admin_list_kyc_queue();

-- documents: for each non-null path column
--   Storage → bucket rider_kyc → open the object at that path
-- OR mint a signed URL:
SELECT storage.create_signed_url('rider_kyc', '<path from the column>', 600);

-- decision
SELECT public.admin_review_rider_kyc('<kyc_id>', 'approve');
SELECT public.admin_review_rider_kyc('<kyc_id>', 'reject', 'Aadhaar back photo is blurry.');
```

## Notes

- The partner's app polls their own `rider_kyc` row
  (`rider_kyc_pending_screen` / `rider_entry_handler`); the push notification is
  a convenience, not the mechanism.
- After approval the partner still completes payout details + service-mode
  selection before they can go online — unchanged existing flow.
- `admin_review_rider_kyc` refuses to act on a KYC that is already
  `approved`/`rejected` — resubmission moves it back to `resubmitted` via the
  existing `create-rider-kyc` Edge Function.
