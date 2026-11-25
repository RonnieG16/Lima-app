-- Lima upgrade v2: public browsing (no login), admin dashboard tools, theme settings, live updates.
-- Run this ONCE in the Supabase SQL Editor AFTER schema.sql. Safe to run again.

-- 1. Guests (not signed in) can browse listings, ratings, prices and farmer names. Nothing private is opened.
drop policy if exists listings_read on listings;
create policy listings_read on listings for select to anon, authenticated using (true);
drop policy if exists ratings_read on ratings;
create policy ratings_read on ratings for select to anon, authenticated using (true);
drop policy if exists prices_read on market_prices;
create policy prices_read on market_prices for select to anon, authenticated using (true);
grant select on listings, ratings, market_prices, public_profiles, site_settings to anon;

-- 2. Admin can set the look of the site (hero picture, tagline) as well as fees and banner.
create or replace function admin_set_setting(p_key text, p_value text) returns void language plpgsql security definer set search_path = public as $$
declare n numeric;
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  if p_key = 'banner' then
    if char_length(coalesce(p_value, '')) > 200 then raise exception 'Banner is limited to 200 characters'; end if;
  elsif p_key = 'tagline' then
    if char_length(coalesce(p_value, '')) > 120 then raise exception 'Tagline is limited to 120 characters'; end if;
  elsif p_key = 'hero_image_url' then
    if coalesce(p_value, '') <> '' and p_value !~ '^https://[^ ]{4,480}$' then raise exception 'Picture address must start with https://'; end if;
  elsif p_key in ('delivery_fee_ugx','platform_fee_pct','rider_share_pct','auto_release_hours') then
    begin n := p_value::numeric; exception when others then raise exception 'Value must be a number'; end;
    if p_key = 'delivery_fee_ugx' and (n < 0 or n > 50000) then raise exception 'Delivery fee must be 0 to 50,000'; end if;
    if p_key = 'platform_fee_pct' and (n < 0 or n > 20) then raise exception 'Platform fee must be 0 to 20 percent'; end if;
    if p_key = 'rider_share_pct' and (n < 0 or n > 100) then raise exception 'Rider share must be 0 to 100 percent'; end if;
    if p_key = 'auto_release_hours' and (n < 1 or n > 720 or n <> trunc(n)) then raise exception 'Auto-release must be a whole number of hours from 1 to 720'; end if;
  else raise exception 'Unknown setting'; end if;
  insert into site_settings(key, value) values (p_key, coalesce(p_value, '')) on conflict (key) do update set value = excluded.value, updated_at = now();
  perform log_action('setting_' || p_key, null);
end $$;

-- 3. Admin: change a user's role (cannot change your own, so you cannot lock yourself out).
create or replace function admin_set_role(p_user uuid, p_role text) returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  if p_user = auth.uid() then raise exception 'You cannot change your own role'; end if;
  if p_role not in ('buyer','farmer','agent','rider','admin') then raise exception 'Unknown role'; end if;
  update profiles set role = p_role where user_id = p_user;
  if not found then raise exception 'User not found'; end if;
  perform log_action('role_' || p_role, null);
end $$;

-- 4. Admin: one call for the overview numbers.
create or replace function admin_stats() returns json language plpgsql stable security definer set search_path = public as $$
declare r json;
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  select json_build_object(
    'users',      (select count(*) from profiles),
    'by_role',    (select coalesce(json_object_agg(role, c), '{}'::json) from (select role, count(*) c from profiles group by role) x),
    'listings',   (select count(*) from listings where qty_kg > 0),
    'orders',     (select count(*) from orders),
    'open_orders',(select count(*) from orders where status = 'open'),
    'held_ugx',   (select coalesce(sum(amount_ugx), 0) from payments where status in ('held','frozen')),
    'released_ugx',(select coalesce(sum(amount_ugx), 0) from payments where status = 'released'),
    'fees_ugx',   (select coalesce(sum(fee_ugx), 0) from payments where status = 'released'),
    'open_disputes',(select count(*) from disputes where status = 'open'),
    'new_feedback',(select count(*) from feedback where status = 'new'),
    'orders_7d',  (select coalesce(json_agg(json_build_object('d', d::date, 'n', (select count(*) from orders o where o.created_at::date = d::date)) order by d), '[]'::json)
                   from generate_series(current_date - 6, current_date, interval '1 day') d)
  ) into r;
  return r;
end $$;
revoke execute on function admin_set_role, admin_stats from public, anon;
grant execute on function admin_set_role, admin_stats to authenticated;

-- 5. Admin can read every order and payment (the order policy already allows it; payments too).
-- 6. Live updates: the app listens for new listings, orders and disputes.
do $$ begin
  begin alter publication supabase_realtime add table listings; exception when others then null; end;
  begin alter publication supabase_realtime add table orders; exception when others then null; end;
  begin alter publication supabase_realtime add table disputes; exception when others then null; end;
end $$;

insert into site_settings(key, value) values ('tagline', 'Fresh from the farm. Paid only when it arrives.'), ('hero_image_url', '') on conflict do nothing;
