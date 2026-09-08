-- Migration: Stop legally-required records from being cascade-destroyable via public.users.
-- Date: 2026-07-31
--
-- The delete-account flow (20260731000000) never issues DELETE FROM public.users -- it only
-- anonymizes the row in place -- so this is defense-in-depth, not something the new flow itself
-- triggers. But six FKs referencing public.users(id) are currently ON DELETE CASCADE, which means
-- any future accidental or malicious hard-delete of a user (a fat-fingered admin query, a future
-- "GDPR full erasure" feature added without reading this file) would silently destroy data this
-- platform is legally required to retain:
--   - rider_kyc_user_id_fkey: Aadhaar/PAN/DL numbers + verification photos
--   - riders_user_id_fkey: the entire rider profile, which several other tables key off
--     (rider_payout_accounts, rider_withdrawals, wallet_transactions, government_tax_ledger,
--     rider_reviews all reference riders(id), not users(id) directly -- blocking the
--     riders_user_id_fkey CASCADE at its root is what protects all of those transitively, same as
--     orders.user_id already being ON DELETE RESTRICT protects any user with order history)
--   - order_chat_messages_user_id_fkey: chat transcripts, which are dispute/investigation evidence
--     AND the in-app "support tickets" (order_chat_messages rows with is_support = true --
--     admin_support_chats_screen.dart queries this same table, there is no separate ticket table)
--   - data_deletion_requests_user_id_fkey: the audit trail of "this user requested deletion" --
--     it would be perverse for the record of a deletion request to itself be destroyable by a
--     delete
--   - user_devices_user_id_fkey: device fingerprint/IP history used for fraud investigation
--   - notifications_user_id_fkey: the notification history log (public.notifications)
--
-- Changed to RESTRICT: a hard DELETE FROM users for anyone with KYC, a rider profile, chat/support
-- history, device history, notification history, or a deletion request now fails loudly with a
-- foreign-key violation instead of quietly destroying evidence. This matches the existing
-- (already-correct) behavior of orders.user_id.

ALTER TABLE public.rider_kyc DROP CONSTRAINT IF EXISTS rider_kyc_user_id_fkey;
ALTER TABLE public.rider_kyc
    ADD CONSTRAINT rider_kyc_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE RESTRICT;

ALTER TABLE public.riders DROP CONSTRAINT IF EXISTS riders_user_id_fkey;
ALTER TABLE public.riders
    ADD CONSTRAINT riders_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE RESTRICT;

ALTER TABLE public.order_chat_messages DROP CONSTRAINT IF EXISTS order_chat_messages_user_id_fkey;
ALTER TABLE public.order_chat_messages
    ADD CONSTRAINT order_chat_messages_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE RESTRICT;

ALTER TABLE public.data_deletion_requests DROP CONSTRAINT IF EXISTS data_deletion_requests_user_id_fkey;
ALTER TABLE public.data_deletion_requests
    ADD CONSTRAINT data_deletion_requests_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE RESTRICT;

ALTER TABLE public.user_devices DROP CONSTRAINT IF EXISTS user_devices_user_id_fkey;
ALTER TABLE public.user_devices
    ADD CONSTRAINT user_devices_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE RESTRICT;

ALTER TABLE public.notifications DROP CONSTRAINT IF EXISTS notifications_user_id_fkey;
ALTER TABLE public.notifications
    ADD CONSTRAINT notifications_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE RESTRICT;
