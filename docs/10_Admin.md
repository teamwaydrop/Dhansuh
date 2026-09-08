# WayDrop Technical Documentation — Admin Panel Capabilities

**Version:** 1.0  
**Last Updated:** July 5, 2026  
**Maintainer:** Operations Tech Lead  
**Applies To Commit:** 241d836  

---

## 1. User Roles & Admin Access Controls

WayDrop manages user roles using the **`public.admins`** table, which is separated from passenger and rider profiles.

Admins authenticate through Supabase Auth. RLS policies on critical tables (like `pricing_config`, `dispatch_config`, and `admin_logs`) verify if the user's ID exists in `public.admins` before granting write access.

---

## 2. Core Administrative Workflows

### 2.1. KYC Moderation & Activation
- **KYC Reviews:** Admins can view documents uploaded to the `kyc_docs` storage bucket and approve or reject submissions.
- **Rejections:** When rejecting a submission, the admin must provide a reason. This reason is saved to `rider_kyc` and displayed to the rider. The system increments `rejection_count` and blocks the account for 7 days if the rider exceeds the limit.
- **Account Activations:** Once approved, the admin updates `activation_status` to `active`, creating the rider profile in `public.riders`.

### 2.2. Broadcast Notifications
- **Targeted Broadcasts:** Allows sending notifications to specific groups (e.g., all active riders in a city zone or passengers who haven't booked recently).
- **System-Wide Alerts:** Creates and dispatches mass notifications using the `send_admin_push_notification` database function, which sends push alerts via FCM.

### 2.3. Withdrawal Reviews & Payout Auditing
- **Withdrawal Requests:** Displays pending withdrawals from the `rider_withdrawals` table.
- **Approval Gate:** The admin checks the rider's wallet audit log (`wallet_audit_logs`) to verify their earnings history before approving the withdrawal.
- **Payout Trigger:** Approving a request triggers the `create-rider-withdrawal` edge function, which sends the payout to the rider via Cashfree.

### 2.4. System Configuration Controls
Admins can modify operational parameters in real-time without redeploying code:
- **Pricing Zones (`pricing_zones`):** Edit service locations, coordinate centers, and geofence radii.
- **Pricing Constants (`pricing_config`):** Adjust base fares, distance charges, weight charges, and commissions.
- **Dispatch Parameters (`dispatch_config`):** Configure timeouts, batch sizes, and radius scaling limits.

---

## 3. Database Audit Logging (`public.admin_logs`)

All administrative actions are logged in the **`admin_logs`** table to maintain a secure audit trail. These logs cannot be updated or deleted.

Logged fields include:
- `admin_id` (UUID): Reference to the admin who performed the action.
- `action_type` (Text): The category of the change (e.g. `kyc_approve`, `price_update`, `payout_approve`).
- `target_id` (UUID): Reference to the affected record (e.g. order ID, rider ID).
- `old_values` / `new_values` (JSONB): A snapshot of the fields before and after the modification.
- `ip_address` / `user_agent`: Network headers used for verification.
