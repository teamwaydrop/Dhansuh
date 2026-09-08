-- Migration: Add missing indexes on public.notifications.
-- Date: 2026-07-30
--
-- ROOT CAUSE (verified): notifications has zero indexes, not even on user_id -- the exact column
-- used by its own RLS policy (auth.uid() = user_id, 20260617000000_add_order_notification_mode.sql)
-- and by every query against it: NotificationBadgeService.refresh() (filters user_id + is_read)
-- and the notifications inbox screen (filters user_id, orders by created_at). Badge refresh is
-- realtime-triggered on every notification insert/update system-wide, so every notification event
-- forces a sequential scan of the whole table for the affected user as the table grows.

CREATE INDEX IF NOT EXISTS idx_notifications_user_id_is_read
    ON public.notifications USING btree (user_id, is_read);

CREATE INDEX IF NOT EXISTS idx_notifications_user_id_created_at
    ON public.notifications USING btree (user_id, created_at DESC);
