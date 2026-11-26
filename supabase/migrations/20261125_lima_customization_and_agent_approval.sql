-- Lima admin customization, media limits and field-agent approval
-- Run after the existing Lima schema.sql in Supabase SQL Editor.
-- Existing order/listing history is preserved; app-side deletion hides linked listings.

alter table public.profiles
  add column if not exists approval_status text not null default 'approved';

alter table public.profiles
  drop constraint if exists profiles_approval_status_check;
alter table public.profiles
  add constraint profiles_approval_status_check
  check (approval_status in ('pending', 'approved', 'rejected'));

create or replace function public.lima_guard_agent_approval()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    if new.role = 'agent' then
      new.approval_status := 'pending';
    end if;
    return new;
  end if;

  if new.role = 'agent' and old.role is distinct from 'agent' then
    new.approval_status := 'pending';
  end if;

  -- A user cannot approve their own agent account through profile updates.
  if auth.uid() is not null
     and auth.uid() = old.user_id
     and new.approval_status is distinct from old.approval_status then
    new.approval_status := old.approval_status;
  end if;
  return new;
end;
$$;

drop trigger if exists lima_guard_agent_approval on public.profiles;
create trigger lima_guard_agent_approval
before insert or update on public.profiles
for each row execute function public.lima_guard_agent_approval();

create or replace function public.lima_notify_admin_new_agent()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    if new.role = 'agent' and new.approval_status = 'pending' then
      insert into public.notifications (user_id, message, read)
      select p.user_id,
             'New village-agent account awaiting approval: ' || coalesce(new.name, 'Field agent'),
             false
      from public.profiles p
      where p.role = 'admin';
    end if;
    return new;
  end if;

  if new.role = 'agent'
     and new.approval_status = 'pending'
     and (old.role is distinct from 'agent' or old.approval_status is distinct from 'pending') then
    insert into public.notifications (user_id, message, read)
    select p.user_id,
           'New village-agent account awaiting approval: ' || coalesce(new.name, 'Field agent'),
           false
    from public.profiles p
    where p.role = 'admin';
  end if;
  return new;
end;
$$;

drop trigger if exists lima_notify_admin_new_agent on public.profiles;
create trigger lima_notify_admin_new_agent
after insert or update of role, approval_status on public.profiles
for each row execute function public.lima_notify_admin_new_agent();

create or replace function public.admin_approve_agent(p_user uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (
    select 1 from public.profiles
    where user_id = auth.uid() and role = 'admin'
  ) then
    raise exception 'Only an administrator can approve field agents';
  end if;

  update public.profiles
  set approval_status = 'approved'
  where user_id = p_user and role = 'agent' and approval_status = 'pending';

  if not found then
    raise exception 'Agent account not found or already reviewed';
  end if;

  insert into public.notifications (user_id, message, read)
  values (p_user, 'Your Lima village-agent account has been approved.', false);
end;
$$;

revoke all on function public.admin_approve_agent(uuid) from public;
grant execute on function public.admin_approve_agent(uuid) to authenticated;

-- Raise the existing photos bucket cap to 30 MB. The app itself limits images
-- to 10 MB and weather background videos to 30 MB.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('photos', 'photos', true, 31457280,
       array['image/*', 'video/mp4', 'video/webm', 'video/quicktime'])
on conflict (id) do update
set file_size_limit = 31457280,
    allowed_mime_types = excluded.allowed_mime_types;

-- Block a pending field agent from writing listings through direct API calls.
create or replace function public.lima_require_approved_agent()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is not null and exists (
    select 1 from public.profiles
    where user_id = auth.uid()
      and role = 'agent'
      and approval_status <> 'approved'
  ) then
    raise exception 'Your village-agent account is awaiting administrator approval';
  end if;
  return new;
end;
$$;

drop trigger if exists lima_require_approved_agent on public.listings;
create trigger lima_require_approved_agent
before insert or update on public.listings
for each row execute function public.lima_require_approved_agent();

-- Notify all administrators in their Lima inbox about operational events.
create or replace function public.lima_notify_admin_event()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_message text;
begin
  if tg_table_name = 'orders' then
    v_message := 'New order received: ' || coalesce(new.order_id::text, 'order');
  elsif tg_table_name = 'disputes' then
    v_message := 'A new order dispute needs review.';
  elsif tg_table_name = 'feedback' then
    v_message := 'New user feedback received.';
  else
    return new;
  end if;

  insert into public.notifications (user_id, message, read)
  select p.user_id, v_message, false
  from public.profiles p
  where p.role = 'admin';
  return new;
end;
$$;

drop trigger if exists lima_admin_order_alert on public.orders;
create trigger lima_admin_order_alert
after insert on public.orders
for each row execute function public.lima_notify_admin_event();

drop trigger if exists lima_admin_dispute_alert on public.disputes;
create trigger lima_admin_dispute_alert
after insert on public.disputes
for each row execute function public.lima_notify_admin_event();

drop trigger if exists lima_admin_feedback_alert on public.feedback;
create trigger lima_admin_feedback_alert
after insert on public.feedback
for each row execute function public.lima_notify_admin_event();

-- ---------------------------------------------------------------------------
-- Part 2: payment status column, no duplicate admin alerts, reject agents,
-- and every admin-editable setting (logo, name, colours, pictures, weather media)
-- ---------------------------------------------------------------------------
alter table public.orders add column if not exists payment_status text not null default 'unpaid';

-- report_problem() and send_feedback() already notify admins, so these triggers would send each alert twice.
drop trigger if exists lima_admin_dispute_alert on public.disputes;
drop trigger if exists lima_admin_feedback_alert on public.feedback;

create or replace function public.admin_reject_agent(p_user uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.profiles where user_id = auth.uid() and role = 'admin') then
    raise exception 'Only an administrator can review field agents';
  end if;
  update public.profiles set approval_status = 'rejected'
  where user_id = p_user and role = 'agent' and approval_status = 'pending';
  if not found then raise exception 'Agent account not found or already reviewed'; end if;
  insert into public.notifications (user_id, message, read)
  values (p_user, 'Your Lima village-agent account was not approved.', false);
end $$;
revoke all on function public.admin_reject_agent(uuid) from public;
grant execute on function public.admin_reject_agent(uuid) to authenticated;

create or replace function public.admin_set_setting(p_key text, p_value text)
returns void language plpgsql security definer set search_path = public as $$
declare n numeric; lim int;
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  if p_key = 'banner' then
    if char_length(coalesce(p_value, '')) > 200 then raise exception 'Banner is limited to 200 characters'; end if;
  elsif p_key in ('tagline', 'promo_title', 'promo_text', 'app_name', 'env_label', 'footer_text') then
    lim := case p_key when 'tagline' then 120 when 'promo_title' then 80 when 'app_name' then 30 when 'env_label' then 20 else 200 end;
    if char_length(coalesce(p_value, '')) > lim then raise exception 'That text is too long'; end if;
  elsif p_key in ('color_deep', 'color_leaf', 'color_lime') then
    if coalesce(p_value, '') <> '' and p_value !~ '^#[0-9a-fA-F]{6}$' then raise exception 'Colour must look like #0d3b2a'; end if;
  elsif p_key in ('logo_url', 'hero_image_url', 'img_promo', 'img_prices', 'img_auth', 'img_market', 'img_weather', 'img_admin', 'img_footer',
                  'weather_video_url', 'img_cat_grains', 'img_cat_vegetables', 'img_cat_fruits', 'img_cat_tubers', 'img_cat_cash', 'img_cat_other') then
    if coalesce(p_value, '') <> '' and p_value !~ '^https://[^ ]{4,480}$' then raise exception 'Picture or video address must start with https://'; end if;
  elsif p_key in ('delivery_fee_ugx', 'platform_fee_pct', 'rider_share_pct', 'auto_release_hours') then
    begin n := p_value::numeric; exception when others then raise exception 'Value must be a number'; end;
    if p_key = 'delivery_fee_ugx' and (n < 0 or n > 50000) then raise exception 'Delivery fee must be 0 to 50,000'; end if;
    if p_key = 'platform_fee_pct' and (n < 0 or n > 20) then raise exception 'Platform fee must be 0 to 20 percent'; end if;
    if p_key = 'rider_share_pct' and (n < 0 or n > 100) then raise exception 'Rider share must be 0 to 100 percent'; end if;
    if p_key = 'auto_release_hours' and (n < 1 or n > 720 or n <> trunc(n)) then raise exception 'Auto-release must be a whole number of hours from 1 to 720'; end if;
  else raise exception 'Unknown setting'; end if;
  insert into site_settings(key, value) values (p_key, coalesce(p_value, ''))
    on conflict (key) do update set value = excluded.value, updated_at = now();
  perform log_action('setting_' || p_key, null);
end $$;

-- ---------------------------------------------------------------------------
-- Part 3: buyer can cancel an order before the farmer accepts it (stage 1 or 2)
-- ---------------------------------------------------------------------------
create or replace function public.cancel_order(p_order uuid)
returns void language plpgsql security definer set search_path = public as $$
declare o orders; l listings; was_paid boolean;
begin
  select * into o from orders where order_id = p_order for update;
  if not found or o.buyer_id <> auth.uid() then raise exception 'Not your order'; end if;
  if o.status <> 'open' then raise exception 'This order is already %', o.status; end if;
  if o.stage > 2 then raise exception 'The farmer has already accepted this order. Report a problem instead.'; end if;
  was_paid := o.stage = 2;
  select * into l from listings where listing_id = o.listing_id;
  update orders set status = 'cancelled', payment_status = 'cancelled' where order_id = p_order;
  if was_paid then
    update payments set status = 'refunded', released_at = now() where order_id = p_order;
  end if;
  update listings set qty_kg = qty_kg + o.qty_kg where listing_id = o.listing_id;
  perform log_action('order_cancelled', p_order);
  perform notify(l.farmer_id, 'An order was cancelled by the buyer before you accepted it');
  if was_paid then
    insert into notifications (user_id, message, read)
    select user_id, 'Order cancelled after payment: refund needed through Pesapal', false from profiles where role = 'admin';
  end if;
end $$;
revoke all on function public.cancel_order(uuid) from public, anon;
grant execute on function public.cancel_order(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Part 4: produce status (available, sold out, hidden)
-- ---------------------------------------------------------------------------
alter table public.listings add column if not exists status text not null default 'available';
alter table public.listings drop constraint if exists listings_status_check;
alter table public.listings add constraint listings_status_check check (status in ('available', 'sold_out', 'hidden'));
-- Listings the old app "deleted" by setting the quantity to 0 stay out of the market.
update public.listings set status = 'hidden' where qty_kg <= 0 and status = 'available';

create or replace function public.lima_listing_status()
returns trigger language plpgsql as $$
begin
  -- Running out of stock marks the produce sold out.
  if new.status = 'available' and new.qty_kg <= 0 then new.status := 'sold_out'; end if;
  -- Restocking (or a cancelled order returning kg) puts sold-out produce back on sale.
  if tg_op = 'UPDATE' and old.qty_kg <= 0 and new.qty_kg > 0 and old.status = 'sold_out' and new.status = 'sold_out' then
    new.status := 'available';
  end if;
  return new;
end $$;
drop trigger if exists lima_listing_status on public.listings;
create trigger lima_listing_status before insert or update on public.listings
for each row execute function public.lima_listing_status();

-- Same as the original place_order, plus a check that the produce is on sale.
create or replace function public.place_order(p_listing uuid, p_qty numeric, p_mode text) returns uuid
language plpgsql security definer set search_path = public as $$
declare l listings; oid uuid; df numeric;
begin
  if my_role() <> 'buyer' then raise exception 'Only buyers can order'; end if;
  select * into l from listings where listing_id = p_listing for update;
  if not found then raise exception 'Listing not found'; end if;
  if l.status <> 'available' then raise exception 'This produce is % right now', replace(l.status, '_', ' '); end if;
  if p_qty is null or p_qty <= 0 then raise exception 'Quantity must be above zero'; end if;
  if p_qty > l.qty_kg then raise exception 'Only % kg in stock', l.qty_kg; end if;
  update listings set qty_kg = qty_kg - p_qty where listing_id = p_listing;
  df := case when p_mode = 'delivery' then setting_num('delivery_fee_ugx', 3000) else 0 end;
  insert into orders(listing_id, buyer_id, qty_kg, mode, delivery_fee_ugx) values (p_listing, auth.uid(), p_qty, p_mode, df) returning order_id into oid;
  insert into payments(order_id, amount_ugx, fee_ugx) values (oid, p_qty * l.price_ugx + df, round(p_qty * l.price_ugx * setting_num('platform_fee_pct', 5) / 100));
  perform log_action('order_placed', oid);
  return oid;
end $$;
revoke all on function public.place_order(uuid, numeric, text) from public, anon;
grant execute on function public.place_order(uuid, numeric, text) to authenticated;
