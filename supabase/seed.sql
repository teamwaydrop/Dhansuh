-- Local-development-only seed data. Per [db.seed] in supabase/config.toml, this file is
-- applied ONLY by `supabase db reset` against a local dev database -- `supabase db push`
-- to the linked project never runs this file, so nothing here ever reaches production
-- automatically.
--
-- SYNTHETIC DEMO DATA (Phase 14 -- WayDrop Rewards/Coupons). "123456789" and "abcdefgh"
-- are placeholder example coupon codes only, not real merchant credentials. Replace or
-- remove before onboarding a real Restaurant/Shopping Mall merchant; add real merchants
-- as additional reward_offers rows the same way (via Supabase Studio on the linked
-- project, matching how every other admin-configured table in this schema is edited).

INSERT INTO public.reward_offers (
    category_id, merchant_name, title, description,
    discount_type, discount_value, coupon_code,
    redemption_instructions, terms, is_active, sort_order
)
SELECT
    c.id, 'Restaurant', 'Get 10% OFF at Restaurant',
    'Synthetic demo offer for local development/testing only.',
    'percentage', 10, '123456789',
    'Show this offer to the merchant at billing to redeem.',
    'Synthetic example only. Not a real production offer.',
    true, 1
FROM public.reward_offer_categories c
WHERE c.code = 'restaurants'
ON CONFLICT DO NOTHING;

INSERT INTO public.reward_offers (
    category_id, merchant_name, title, description,
    discount_type, discount_value, coupon_code,
    redemption_instructions, terms, is_active, sort_order
)
SELECT
    c.id, 'Shopping Mall', 'Get 10% OFF at Shopping Mall',
    'Synthetic demo offer for local development/testing only.',
    'percentage', 10, 'abcdefgh',
    'Show this offer to the merchant at billing to redeem.',
    'Synthetic example only. Not a real production offer.',
    true, 1
FROM public.reward_offer_categories c
WHERE c.code = 'shopping_malls'
ON CONFLICT DO NOTHING;
