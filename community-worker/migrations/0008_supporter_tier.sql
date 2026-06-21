-- Patronage badge. A member's current Septena+ support tier, asserted by the
-- app from its StoreKit entitlement over the already-attested channel (the badge
-- gates nothing, so client-asserted is fine — see PUT /api/me/support). Null is
-- the free tier, which is the common case, so the column is nullable with no
-- default. `supporter_since` stamps when a tier was first set (kept across tier
-- changes, cleared when the tier is cleared) for a future "supporter since" line.
alter table user_profile add column supporter_tier text
  check (supporter_tier is null or supporter_tier in ('annual', 'monthly', 'lifetime'));
alter table user_profile add column supporter_since text;
