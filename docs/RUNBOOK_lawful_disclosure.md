# Runbook — Lawful Police / Government Information Disclosure

**Owner:** Compliance / Operations (an active `public.admins` account).
**Scope:** responding to a lawful written request for information about a
WayDrop user identified by a phone number.

> This is an internal operational control, **not legal advice**. Whether a
> particular request is valid, and what may be disclosed, is a decision for
> WayDrop's counsel. This runbook only makes the operational steps and the
> audit trail consistent.

## Absolute rules

- **There is no public / self-service phone lookup.** Every function here is
  `is_admin()`-gated (email in `public.admins`, `is_active`) and unavailable to
  riders and passengers.
- The **full phone number is never stored** on the disclosure record — only the
  last 4 digits.
- Data retrieval is **scoped to one target user** and their own rides. You
  cannot page arbitrary records.
- The disclosure must be **recorded before** ride history can be retrieved.
- `public.lawful_disclosure_requests` and `public.admin_logs` are **immutable**
  to every client role.

## Steps

1. **Receive the request in writing.** Confirm the requesting authority, the
   officer, a reference/FIR/notice number if any, and the legal basis
   (e.g. a CrPC 91 notice). Route to counsel if there is any doubt — attest the
   internal legal review before proceeding.

2. **Open** WayDrop → Profile → **Admin Panel → Lawful Disclosure**.

3. **Fill the request details**: requesting authority, reference number, legal
   basis, tick *Internal legal review completed*, and select the **disclosure
   scope** (only the categories the request actually asks for).

4. **Enter the phone number** (10-digit, `+91…`, or `91…` — it is normalized to
   the last 10 digits) → **Look up identity**. This returns the matched user's
   name, user code, email, phone last-4, registration date, and whether they are
   a Drop Partner. The lookup itself is logged to `admin_logs` (last-4 only).

5. **Record disclosure & retrieve rides.** This writes an immutable
   `lawful_disclosure_requests` row and an `admin_logs` entry, then returns the
   **scoped** result: user identity, rider/KYC summary (if a partner), rides as
   passenger, rides as Drop Partner (each with timestamps, pickup/drop, fare,
   payment method, status). Capped at 500 rides per side.

6. **Copy the full result** and hand only the legally-requested fields to the
   authority through your normal secure channel. Keep the working copy with the
   case file.

## SQL equivalent (Studio, as an admin)

```sql
-- 1. identify
SELECT public.admin_lookup_user_by_phone('9876543210');

-- 2. record the disclosure (returns disclosure_id)
SELECT public.admin_record_lawful_disclosure(
  p_target_user_id       => '<user-uuid>',
  p_requesting_authority  => 'Cyberabad Police, PS Gachibowli',
  p_legal_basis           => 'CrPC 91 notice dated 2026-09-05',
  p_disclosed_scope       => ARRAY['user_identity','rides_as_passenger'],
  p_reference_number      => 'FIR 123/2026',
  p_legal_review_confirmed => true
);

-- 3. retrieve the scoped history
SELECT public.admin_get_disclosure_ride_history('<disclosure_id>');

-- audit trail
SELECT * FROM public.lawful_disclosure_requests ORDER BY created_at DESC;
SELECT * FROM public.admin_logs WHERE action_type LIKE 'lawful_%' ORDER BY created_at DESC;
```

## Known gaps / notes

- Identity-document **images and full Aadhaar/PAN/DL numbers** are **not**
  returned by `admin_get_disclosure_ride_history` — it returns a KYC *summary*
  (name, father's name, DOB, vehicle). If a request specifically and lawfully
  requires the document images, retrieve them separately from the `rider_kyc`
  row + `rider_kyc` storage bucket (admin access), and note that in
  `result_summary` / `notes`.
- If the target user's phone is stored in a non-standard format, the lookup
  matches on the **last 10 digits**, which covers all known variants.
- Nothing here changes ride, payment, tax, or dispatch behaviour.
