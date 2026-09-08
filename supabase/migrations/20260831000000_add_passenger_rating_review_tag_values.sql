-- Migration: Issue 6 -- intercity parcel rating submission fails with
-- "invalid input value for enum review_tag: \"ready_at_pickup\", code: 22P02".
--
-- ROOT CAUSE (confirmed via live enum inspection, not assumed): the review_tag enum
-- (rider_reviews.tags, a review_tag[] column) was originally built exclusively for the
-- "passenger rates driver/traveller" direction -- its values (clean_vehicle, polite_behavior,
-- safe_driving, on_time, dirty_vehicle, rude_behavior, unsafe_driving, late_arrival, other) are all
-- vehicle/driving concepts. rider_rating_screen.dart's "Issue 6B fix" later added role-aware tag
-- sets so a Traveller/Rider rating a Passenger (widget.ratedByRider == true) shows
-- passenger-appropriate categories instead (On Time, Good Behaviour, Respectful, Easy to
-- Communicate With, Clear Instructions, Cooperative, Ready at Pickup / Late at Pickup, Rude
-- Behaviour, Poor Communication, Uncooperative, Changed Plans Unexpectedly, No-show) -- but the
-- enum itself was never extended to match, so every one of those tag keys except 'on_time'/'other'
-- fails at INSERT time with 22P02. The passenger-rates-traveller direction was and remains fully
-- covered by the existing values -- this migration adds no vehicle/driving values and does not
-- touch that direction at all.
--
-- FIX: add the missing passenger-rating-specific values as new enum members (the client's tags are
-- an intentional, already-shipped design -- a passenger cannot legitimately be rated on vehicle
-- cleanliness or driving safety, so remapping to the existing driver-oriented values would be
-- semantically wrong, not a real fix). ALTER TYPE ... ADD VALUE IF NOT EXISTS is additive and
-- idempotent -- no existing review_tag value is renamed, removed, or reordered, so every existing
-- saved rider_reviews.tags row remains exactly as valid and readable as before this migration.
--
-- Postgres note: ALTER TYPE ... ADD VALUE cannot be used in the same transaction as a statement
-- that references the new value, but this migration only adds values -- nothing here uses them.

ALTER TYPE public.review_tag ADD VALUE IF NOT EXISTS 'good_behaviour';
ALTER TYPE public.review_tag ADD VALUE IF NOT EXISTS 'respectful';
ALTER TYPE public.review_tag ADD VALUE IF NOT EXISTS 'easy_to_communicate';
ALTER TYPE public.review_tag ADD VALUE IF NOT EXISTS 'clear_instructions';
ALTER TYPE public.review_tag ADD VALUE IF NOT EXISTS 'cooperative';
ALTER TYPE public.review_tag ADD VALUE IF NOT EXISTS 'ready_at_pickup';
ALTER TYPE public.review_tag ADD VALUE IF NOT EXISTS 'late_at_pickup';
ALTER TYPE public.review_tag ADD VALUE IF NOT EXISTS 'rude_behaviour';
ALTER TYPE public.review_tag ADD VALUE IF NOT EXISTS 'poor_communication';
ALTER TYPE public.review_tag ADD VALUE IF NOT EXISTS 'uncooperative';
ALTER TYPE public.review_tag ADD VALUE IF NOT EXISTS 'changed_plans';
ALTER TYPE public.review_tag ADD VALUE IF NOT EXISTS 'no_show';
