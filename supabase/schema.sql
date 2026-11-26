-- Lima: Supabase schema (from the draw.io ERD). Run once in Supabase > SQL Editor.
-- Payments are taken on Pesapal's hosted checkout (sandbox). No card, PIN or OTP data is stored in this database.


-- ---------- tables (ERD: USER, LISTING, ORDER, PAYMENT, DELIVERY, RATING, DISPUTE, MARKET_PRICE, AUDIT_LOG)
create table if not exists profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  name text not null check (char_length(name) between 2 and 100),
  phone_no text not null check (phone_no ~ '^0[0-9]{9}$'),
  role text not null check (role in ('buyer','farmer','agent','rider','admin')),
  region text, district text, town text, market text,
  phone_verified boolean not null default false,
  onboarded boolean not null default true,    -- false for Google sign-ups until they choose a role and phone
  sms_opt_in boolean not null default false,   -- queue SMS copies of alerts (needs the send-sms Edge Function)
  created_at timestamptz not null default now()
);

create table if not exists listings (
  listing_id uuid primary key default gen_random_uuid(),
  farmer_id uuid not null references profiles(user_id),
  posted_by uuid not null references profiles(user_id),
  produce text not null check (char_length(produce) between 2 and 50),
  qty_kg numeric(10,2) not null check (qty_kg >= 0),
  price_ugx numeric(12,2) not null check (price_ugx > 0),      -- per kg
  harvest_date date not null check (harvest_date <= current_date),
  district text not null, town text not null,
  photo_url text,
  market text,
  category text not null default 'Other' check (category in ('Grains','Vegetables','Fruits','Tubers','Cash crops','Other')),
  created_at timestamptz not null default now()
);

create table if not exists orders (
  order_id uuid primary key default gen_random_uuid(),
  listing_id uuid not null references listings(listing_id),
  buyer_id uuid not null references profiles(user_id),
  qty_kg numeric(10,2) not null check (qty_kg > 0),
  mode text not null check (mode in ('delivery','pickup')),
  stage smallint not null default 1 check (stage between 1 and 7),
  -- 1 Placed, 2 Paid (escrow), 3 Accepted, 4 Ready, 5 In transit, 6 Delivered, 7 Confirmed
  status text not null default 'open' check (status in ('open','completed','cancelled','disputed')),
  delivery_fee_ugx numeric(12,2) not null default 0,   -- flat fee for rider delivery (Lima keeps 10%)
  delivered_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists payments (
  payment_id uuid primary key default gen_random_uuid(),
  order_id uuid not null unique references orders(order_id),
  amount_ugx numeric(12,2) not null,
  fee_ugx numeric(12,2) not null default 0,
  status text not null default 'pending' check (status in ('pending','held','frozen','released','refunded')),
  released_at timestamptz
);

create table if not exists deliveries (
  delivery_id uuid primary key default gen_random_uuid(),
  order_id uuid not null unique references orders(order_id),
  rider_id uuid references profiles(user_id),
  status text not null default 'waiting',
  delivered_at timestamptz
);

create table if not exists ratings (
  rating_id uuid primary key default gen_random_uuid(),
  order_id uuid not null references orders(order_id),
  rater_id uuid not null references profiles(user_id),
  ratee_id uuid not null references profiles(user_id),
  stars smallint not null check (stars between 1 and 5),
  comment text,
  unique (order_id, rater_id)
);

create table if not exists disputes (
  dispute_id uuid primary key default gen_random_uuid(),
  order_id uuid not null unique references orders(order_id),
  reason text not null,
  evidence_ref text,
  status text not null default 'open' check (status in ('open','refunded','released')),
  decided_by uuid references profiles(user_id),
  created_at timestamptz not null default now()
);

create table if not exists market_prices (
  price_id uuid primary key default gen_random_uuid(),
  produce text not null, district text not null default 'All',
  avg_price_ugx numeric(12,2) not null check (avg_price_ugx > 0),
  as_of date not null default current_date
);

create table if not exists audit_log (
  log_id bigint generated always as identity primary key,
  actor_id uuid, action text not null, entity_id uuid,
  logged_at timestamptz not null default now()
);

create table if not exists cart_items (
  user_id uuid not null default auth.uid() references profiles(user_id) on delete cascade,
  listing_id uuid not null references listings(listing_id) on delete cascade,
  qty numeric(10,2) not null check (qty > 0),
  primary key (user_id, listing_id)
);
create table if not exists wishlist (
  user_id uuid not null default auth.uid() references profiles(user_id) on delete cascade,
  listing_id uuid not null references listings(listing_id) on delete cascade,
  primary key (user_id, listing_id)
);
create table if not exists notifications (   -- in-app inbox (SMS/push are out of MVP scope)
  id bigint generated always as identity primary key,
  user_id uuid not null references profiles(user_id) on delete cascade,
  message text not null, read boolean not null default false,
  created_at timestamptz not null default now()
);
create table if not exists messages (        -- short chat between the parties of one order
  id bigint generated always as identity primary key,
  order_id uuid not null references orders(order_id) on delete cascade,
  sender_id uuid not null references profiles(user_id),
  body text not null check (char_length(body) between 1 and 500),
  created_at timestamptz not null default now()
);

create table if not exists site_settings (   -- admin-controlled platform settings
  key text primary key, value text not null, updated_at timestamptz not null default now()
);
insert into site_settings(key, value) values
  ('delivery_fee_ugx','3000'), ('platform_fee_pct','5'), ('rider_share_pct','90'), ('auto_release_hours','48'), ('banner','')
  on conflict do nothing;
create table if not exists feedback (
  id bigint generated always as identity primary key,
  user_id uuid not null default auth.uid() references profiles(user_id) on delete cascade,
  kind text not null default 'idea' check (kind in ('bug','idea','praise','other')),
  message text not null check (char_length(message) between 5 and 1000),
  status text not null default 'new' check (status in ('new','seen','resolved')),
  created_at timestamptz not null default now()
);
create table if not exists sms_outbox (      -- filled by notify() for users who opted in; drained by supabase/functions/send-sms
  id bigint generated always as identity primary key,
  user_id uuid references profiles(user_id) on delete cascade,
  phone_no text not null, message text not null,
  status text not null default 'queued' check (status in ('queued','sent','failed')),
  created_at timestamptz not null default now(), sent_at timestamptz
);

-- Upgrade path for projects created from an earlier version of this file
alter table profiles add column if not exists sms_opt_in boolean not null default false;
alter table profiles add column if not exists onboarded boolean not null default true;
alter table listings add column if not exists market text;

-- ---------- helpers
create or replace function is_admin() returns boolean language sql stable security definer set search_path = public as
$$ select exists (select 1 from profiles where user_id = auth.uid() and role = 'admin') $$;

create or replace function my_role() returns text language sql stable security definer set search_path = public as
$$ select role from profiles where user_id = auth.uid() $$;

-- Used by RLS on deliveries (security definer avoids orders <-> deliveries policy recursion)
create or replace function is_buyer_of(p_order uuid) returns boolean language sql stable security definer set search_path = public as
$$ select exists (select 1 from orders where order_id = p_order and buyer_id = auth.uid()) $$;

create or replace function is_order_party(p_order uuid) returns boolean language sql stable security definer set search_path = public as
$$ select is_admin() or exists (select 1 from orders o join listings l using (listing_id)
     left join deliveries d on d.order_id = o.order_id
     where o.order_id = p_order and (o.buyer_id = auth.uid() or l.farmer_id = auth.uid() or l.posted_by = auth.uid() or d.rider_id = auth.uid())) $$;

create or replace function log_action(p_action text, p_entity uuid) returns void
language sql security definer set search_path = public as
$$ insert into audit_log(actor_id, action, entity_id) values (auth.uid(), p_action, p_entity) $$;

create or replace function notify(p_user uuid, p_msg text) returns void
language plpgsql security definer set search_path = public as $$
begin
  insert into notifications(user_id, message) values (p_user, p_msg);
  insert into sms_outbox(user_id, phone_no, message)
    select user_id, phone_no, left(p_msg, 160) from profiles where user_id = p_user and sms_opt_in;
end $$;
create or replace function setting_num(p_key text, p_default numeric) returns numeric language sql stable security definer set search_path = public as
$$ select coalesce((select nullif(value, '')::numeric from site_settings where key = p_key), p_default) $$;
-- helpers must not be callable from the browser (would allow audit/notification spam)
revoke execute on function log_action, notify, setting_num from public, anon, authenticated;

-- Public-safe view of profiles (no phone number)
create or replace view public_profiles as
  select user_id, name, role, district, town from profiles;
grant select on public_profiles to authenticated;

-- ---------- row level security
alter table profiles enable row level security;
alter table listings enable row level security;
alter table orders enable row level security;
alter table payments enable row level security;
alter table deliveries enable row level security;
alter table ratings enable row level security;
alter table disputes enable row level security;
alter table market_prices enable row level security;
alter table audit_log enable row level security;

create policy profiles_read on profiles for select to authenticated using (user_id = auth.uid() or is_admin());
create policy profiles_update_own on profiles for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid() and role = my_role()); -- role cannot be changed by the user

create policy listings_read on listings for select to authenticated using (true);
create policy listings_insert on listings for insert to authenticated
  with check (posted_by = auth.uid() and (
    (my_role() = 'farmer' and farmer_id = auth.uid()) or my_role() = 'agent'));
create policy listings_update on listings for update to authenticated
  using (farmer_id = auth.uid() or posted_by = auth.uid() or is_admin());
create policy listings_delete on listings for delete to authenticated
  using (farmer_id = auth.uid() or posted_by = auth.uid() or is_admin());

create policy orders_read on orders for select to authenticated using (
  buyer_id = auth.uid() or is_admin()
  or exists (select 1 from listings l where l.listing_id = orders.listing_id and (l.farmer_id = auth.uid() or l.posted_by = auth.uid()))
  or exists (select 1 from deliveries d where d.order_id = orders.order_id and d.rider_id = auth.uid())
  or (my_role() = 'rider' and orders.stage = 4 and orders.mode = 'delivery'));

create policy payments_read on payments for select to authenticated using (
  is_admin() or exists (select 1 from orders o where o.order_id = payments.order_id and (o.buyer_id = auth.uid()
    or exists (select 1 from listings l where l.listing_id = o.listing_id and l.farmer_id = auth.uid()))));
create policy deliveries_read on deliveries for select to authenticated using (
  is_admin() or rider_id = auth.uid() or is_buyer_of(order_id));
create policy ratings_read on ratings for select to authenticated using (true);
create policy disputes_read on disputes for select to authenticated using (
  is_admin() or exists (select 1 from orders o where o.order_id = disputes.order_id and o.buyer_id = auth.uid()));
create policy prices_read on market_prices for select to authenticated using (true);
create policy prices_admin on market_prices for all to authenticated using (is_admin()) with check (is_admin());
create policy audit_admin on audit_log for select to authenticated using (is_admin());

alter table cart_items enable row level security;
alter table wishlist enable row level security;
alter table notifications enable row level security;
alter table messages enable row level security;
alter table site_settings enable row level security;
alter table feedback enable row level security;
alter table sms_outbox enable row level security;   -- no policies: only the service role (Edge Function) can touch it
create policy cart_own on cart_items for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid() and my_role() = 'buyer');
create policy wish_own on wishlist for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy notif_read on notifications for select to authenticated using (user_id = auth.uid());
create policy msg_read on messages for select to authenticated using (is_order_party(order_id));
create policy settings_read on site_settings for select using (true);
create policy feedback_read on feedback for select to authenticated using (user_id = auth.uid() or is_admin());

-- Block direct writes to money/state tables: only the functions below (security definer) may change them.
revoke insert, update, delete on orders, payments, deliveries, ratings, disputes, audit_log from authenticated, anon;
revoke insert, update, delete on messages, notifications, site_settings, feedback from authenticated, anon;
revoke all on sms_outbox from authenticated, anon;

-- ---------- profile creation on sign-up (admin can never be self-selected)
create or replace function handle_new_user() returns trigger language plpgsql security definer set search_path = public as $$
declare r text := coalesce(new.raw_user_meta_data->>'role','buyer');
        social boolean := coalesce(new.raw_app_meta_data->>'provider','email') <> 'email';   -- e.g. Google
        nm text := coalesce(nullif(new.raw_user_meta_data->>'name',''), nullif(new.raw_user_meta_data->>'full_name',''), 'User');
begin
  if social or r not in ('buyer','farmer','agent','rider') then r := 'buyer'; end if;   -- social sign-ups choose a role later; admin can never be chosen
  if char_length(nm) < 2 then nm := 'User'; end if;
  insert into profiles(user_id, name, phone_no, role, region, district, town, market, onboarded)
  values (new.id, left(nm, 100),
          case when social then '0700000000' else coalesce(new.raw_user_meta_data->>'phone_no','0700000000') end, r,
          new.raw_user_meta_data->>'region', new.raw_user_meta_data->>'district',
          new.raw_user_meta_data->>'town', new.raw_user_meta_data->>'market', not social);
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute function handle_new_user();

-- Mock phone verification (demo code 123456 shown on screen; no real OTP is collected)
create or replace function verify_phone(p_code text) returns void language plpgsql security definer set search_path = public as $$
begin
  if p_code <> '123456' then raise exception 'Wrong code'; end if;
  update profiles set phone_verified = true where user_id = auth.uid();
  perform log_action('phone_verified', auth.uid());
end $$;

-- ---------- escrow workflow (each step checks who is calling and which stage the order is in)
create or replace function place_order(p_listing uuid, p_qty numeric, p_mode text) returns uuid
language plpgsql security definer set search_path = public as $$
declare l listings; oid uuid; df numeric;
begin
  if my_role() <> 'buyer' then raise exception 'Only buyers can order'; end if;
  select * into l from listings where listing_id = p_listing for update;
  if not found then raise exception 'Listing not found'; end if;
  if p_qty is null or p_qty <= 0 then raise exception 'Quantity must be above zero'; end if;
  if p_qty > l.qty_kg then raise exception 'Only % kg in stock', l.qty_kg; end if;
  update listings set qty_kg = qty_kg - p_qty where listing_id = p_listing;
  df := case when p_mode = 'delivery' then setting_num('delivery_fee_ugx', 3000) else 0 end;
  insert into orders(listing_id, buyer_id, qty_kg, mode, delivery_fee_ugx) values (p_listing, auth.uid(), p_qty, p_mode, df) returning order_id into oid;
  insert into payments(order_id, amount_ugx, fee_ugx) values (oid, p_qty * l.price_ugx + df, round(p_qty * l.price_ugx * setting_num('platform_fee_pct', 5) / 100));
  perform log_action('order_placed', oid);
  return oid;
end $$;

-- Escrow hold. Live payments reach this step through the pay-webhook function after Pesapal confirms them; this function also drives the offline test suite.
create or replace function pay_order(p_order uuid, p_simulate_fail boolean default false) returns void
language plpgsql security definer set search_path = public as $$
declare o orders;
begin
  select * into o from orders where order_id = p_order for update;
  if not found or o.buyer_id <> auth.uid() then raise exception 'Not your order'; end if;
  if o.stage <> 1 then raise exception 'Order already paid'; end if;
  if p_simulate_fail then
    update payments set status = 'pending' where order_id = p_order;
    raise exception 'The payment was declined (test). Please retry.';
  end if;
  update payments set status = 'held' where order_id = p_order;
  update orders set stage = 2 where order_id = p_order;
  perform log_action('escrow_held', p_order);
  perform notify((select farmer_id from listings where listing_id = o.listing_id), 'New paid order: please accept it');
end $$;

create or replace function farmer_step(p_order uuid, p_to smallint) returns void
language plpgsql security definer set search_path = public as $$
declare o orders; l listings;
begin
  select * into o from orders where order_id = p_order for update;
  select * into l from listings where listing_id = o.listing_id;
  if l.farmer_id <> auth.uid() and l.posted_by <> auth.uid() then raise exception 'Not your listing'; end if;
  if o.status <> 'open' then raise exception 'Order is %', o.status; end if;
  if not ((o.stage = 2 and p_to = 3) or (o.stage = 3 and p_to = 4)) then raise exception 'Invalid step'; end if;
  update orders set stage = p_to where order_id = p_order;
  if p_to = 4 then insert into deliveries(order_id, status) values (p_order, 'ready') on conflict do nothing; end if;
  perform log_action('farmer_stage_' || p_to, p_order);
  perform notify(o.buyer_id, case p_to when 3 then 'The farmer accepted your order' else 'Your order is ready' end);
  if p_to = 4 and o.mode = 'delivery' then
    insert into notifications(user_id, message) select user_id, 'New delivery job available' from profiles where role = 'rider';
  end if;
end $$;

create or replace function rider_step(p_order uuid, p_to smallint) returns void
language plpgsql security definer set search_path = public as $$
declare o orders;
begin
  if my_role() <> 'rider' then raise exception 'Only riders'; end if;
  select * into o from orders where order_id = p_order for update;
  if o.status <> 'open' then raise exception 'Order is %', o.status; end if;
  if o.stage = 4 and p_to = 5 and o.mode = 'delivery' then
    update deliveries set rider_id = auth.uid(), status = 'in_transit' where order_id = p_order;
  elsif o.stage = 5 and p_to = 6 and exists (select 1 from deliveries where order_id = p_order and rider_id = auth.uid()) then
    update deliveries set status = 'delivered', delivered_at = now() where order_id = p_order;
  else raise exception 'Invalid step'; end if;
  update orders set stage = p_to, delivered_at = case when p_to = 6 then now() else delivered_at end where order_id = p_order;
  perform log_action('rider_stage_' || p_to, p_order);
  perform notify(o.buyer_id, case p_to when 5 then 'Your order is on the way' else 'Your order was delivered: please confirm receipt' end);
end $$;

-- Pickup orders skip the rider: farmer hands over, buyer confirms
create or replace function pickup_handover(p_order uuid) returns void
language plpgsql security definer set search_path = public as $$
declare o orders; l listings;
begin
  select * into o from orders where order_id = p_order for update;
  select * into l from listings where listing_id = o.listing_id;
  if o.mode <> 'pickup' or o.stage <> 4 or (l.farmer_id <> auth.uid() and l.posted_by <> auth.uid()) then raise exception 'Invalid step'; end if;
  update orders set stage = 6, delivered_at = now() where order_id = p_order;
  perform log_action('pickup_handover', p_order);
  perform notify(o.buyer_id, 'Produce handed over: please confirm receipt');
end $$;

create or replace function confirm_receipt(p_order uuid) returns void
language plpgsql security definer set search_path = public as $$
declare o orders;
begin
  select * into o from orders where order_id = p_order for update;
  if o.buyer_id <> auth.uid() or o.stage <> 6 or o.status <> 'open' then raise exception 'Cannot confirm this order'; end if;
  update orders set stage = 7, status = 'completed' where order_id = p_order;
  update payments set status = 'released', released_at = now() where order_id = p_order;
  perform log_action('escrow_released', p_order);
  perform notify((select farmer_id from listings where listing_id = o.listing_id), 'Buyer confirmed receipt: payment released to you');
end $$;

create or replace function report_problem(p_order uuid, p_reason text, p_evidence text) returns void
language plpgsql security definer set search_path = public as $$
declare o orders;
begin
  select * into o from orders where order_id = p_order for update;
  if o.buyer_id <> auth.uid() or o.stage not between 5 and 6 or o.status <> 'open' then raise exception 'Cannot report this order'; end if;
  if p_reason is null or char_length(p_reason) < 5 then raise exception 'Please describe the problem'; end if;
  insert into disputes(order_id, reason, evidence_ref) values (p_order, p_reason, p_evidence);
  update orders set status = 'disputed' where order_id = p_order;
  update payments set status = 'frozen' where order_id = p_order;
  perform log_action('dispute_opened', p_order);
  insert into notifications(user_id, message) select user_id, 'New dispute to review' from profiles where role = 'admin';
  perform notify((select farmer_id from listings where listing_id = o.listing_id), 'A buyer reported a problem: payment is frozen');
end $$;

create or replace function admin_decide(p_dispute uuid, p_decision text) returns void
language plpgsql security definer set search_path = public as $$
declare d disputes; o orders;
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  select * into d from disputes where dispute_id = p_dispute for update;
  if d.status <> 'open' then raise exception 'Already decided'; end if;
  select * into o from orders where order_id = d.order_id for update;
  if p_decision = 'refund' then
    update payments set status = 'refunded', released_at = now() where order_id = o.order_id;
    update orders set status = 'cancelled' where order_id = o.order_id;
    update listings set qty_kg = qty_kg + o.qty_kg where listing_id = o.listing_id;
    update disputes set status = 'refunded', decided_by = auth.uid() where dispute_id = p_dispute;
  elsif p_decision = 'release' then
    update payments set status = 'released', released_at = now() where order_id = o.order_id;
    update orders set status = 'completed', stage = 7 where order_id = o.order_id;
    update disputes set status = 'released', decided_by = auth.uid() where dispute_id = p_dispute;
  else raise exception 'Decision must be refund or release'; end if;
  perform log_action('dispute_' || p_decision, d.order_id);
  perform notify(o.buyer_id, 'Dispute decided: ' || p_decision);
  perform notify((select farmer_id from listings where listing_id = o.listing_id), 'Dispute decided: ' || p_decision);
end $$;

create or replace function rate_order(p_order uuid, p_ratee uuid, p_stars smallint, p_comment text) returns void
language plpgsql security definer set search_path = public as $$
declare o orders;
begin
  select * into o from orders where order_id = p_order;
  if o.buyer_id <> auth.uid() or o.status <> 'completed' then raise exception 'You can rate only completed orders you bought'; end if;
  insert into ratings(order_id, rater_id, ratee_id, stars, comment) values (p_order, auth.uid(), p_ratee, p_stars, p_comment);
  perform log_action('rated', p_order);
end $$;

create or replace function checkout(p_mode text) returns integer language plpgsql security definer set search_path = public as $$
declare c record; n int := 0;
begin
  if my_role() <> 'buyer' then raise exception 'Only buyers can check out'; end if;
  for c in select * from cart_items where user_id = auth.uid() loop
    perform place_order(c.listing_id, c.qty, p_mode); n := n + 1;   -- one order (and one escrow) per listing
  end loop;
  if n = 0 then raise exception 'Your cart is empty'; end if;
  delete from cart_items where user_id = auth.uid();
  return n;
end $$;

create or replace function pay_all() returns integer language plpgsql security definer set search_path = public as $$
declare r record; n int := 0;
begin
  for r in select order_id from orders where buyer_id = auth.uid() and stage = 1 and status = 'open' loop
    perform pay_order(r.order_id, false); n := n + 1;
  end loop;
  return n;
end $$;

create or replace function send_message(p_order uuid, p_body text) returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_order_party(p_order) then raise exception 'You are not part of this order'; end if;
  if p_body is null or char_length(trim(p_body)) = 0 or char_length(p_body) > 500 then raise exception 'Message must be 1 to 500 characters'; end if;
  insert into messages(order_id, sender_id, body) values (p_order, auth.uid(), trim(p_body));
end $$;

create or replace function mark_read() returns void language sql security definer set search_path = public as
$$ update notifications set read = true where user_id = auth.uid() $$;

-- Auto-confirm: release escrow after delivery (default 48 h, see site_settings) if the buyer neither confirmed nor complained.
-- Not callable from the app. Schedule it with pg_cron (Dashboard > Database > Extensions > pg_cron), then run:
--   select cron.schedule('lima-auto-release', '0 * * * *', 'select auto_release_overdue()');
create or replace function auto_release_overdue() returns integer language plpgsql security definer set search_path = public as $$
declare r record; n int := 0;
begin
  for r in select order_id, buyer_id from orders where stage = 6 and status = 'open' and delivered_at < now() - make_interval(hours => setting_num('auto_release_hours', 48)::int) for update loop
    update orders set stage = 7, status = 'completed' where order_id = r.order_id;
    update payments set status = 'released', released_at = now() where order_id = r.order_id;
    insert into audit_log(actor_id, action, entity_id) values (null, 'escrow_auto_released', r.order_id);
    perform notify(r.buyer_id, 'Order auto-confirmed after 48 hours: payment released');
    n := n + 1;
  end loop;
  return n;
end $$;
revoke execute on function auto_release_overdue from public, anon, authenticated;

-- Feedback and site settings
create or replace function send_feedback(p_kind text, p_message text) returns void language plpgsql security definer set search_path = public as $$
begin
  if p_kind not in ('bug','idea','praise','other') then raise exception 'Unknown feedback type'; end if;
  if p_message is null or char_length(trim(p_message)) < 5 or char_length(p_message) > 1000 then raise exception 'Feedback must be 5 to 1000 characters'; end if;
  if (select count(*) from feedback where user_id = auth.uid() and created_at > now() - interval '1 day') >= 10 then raise exception 'Daily feedback limit reached'; end if;
  insert into feedback(user_id, kind, message) values (auth.uid(), p_kind, trim(p_message));
  insert into notifications(user_id, message) select user_id, 'New feedback received' from profiles where role = 'admin';
  perform log_action('feedback_sent', auth.uid());
end $$;

create or replace function admin_feedback_status(p_id bigint, p_status text) returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  if p_status not in ('new','seen','resolved') then raise exception 'Unknown status'; end if;
  update feedback set status = p_status where id = p_id;
end $$;

create or replace function admin_set_setting(p_key text, p_value text) returns void language plpgsql security definer set search_path = public as $$
declare n numeric;
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  if p_key = 'banner' then
    if char_length(coalesce(p_value, '')) > 200 then raise exception 'Banner is limited to 200 characters'; end if;
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

-- Google (social) sign-ups choose their role, phone and location once. Admin can never be chosen here.
create or replace function complete_profile(p_role text, p_phone text, p_region text, p_district text, p_town text, p_market text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from profiles where user_id = auth.uid() and not onboarded) then raise exception 'Profile already set up'; end if;
  if p_role not in ('buyer','farmer','agent','rider') then raise exception 'Choose buyer, farmer, village agent or rider'; end if;
  if p_phone is null or p_phone !~ '^0[0-9]{9}$' then raise exception 'Phone must be 10 digits starting with 0'; end if;
  update profiles set role = p_role, phone_no = p_phone, region = p_region, district = p_district, town = p_town, market = p_market,
         onboarded = true, phone_verified = false where user_id = auth.uid();
  perform log_action('profile_completed', auth.uid());
end $$;

revoke execute on function place_order, pay_order, farmer_step, rider_step, pickup_handover, confirm_receipt,
  report_problem, admin_decide, rate_order, verify_phone, checkout, pay_all, send_message, mark_read, send_feedback, admin_feedback_status, admin_set_setting, complete_profile from public, anon;
grant execute on function place_order, pay_order, farmer_step, rider_step, pickup_handover, confirm_receipt,
  report_problem, admin_decide, rate_order, verify_phone, checkout, pay_all, send_message, mark_read, send_feedback, admin_feedback_status, admin_set_setting, complete_profile to authenticated;

-- ---------- realtime: lets the app show alerts the moment a notification is created
do $$ begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    begin alter publication supabase_realtime add table notifications;
    exception when duplicate_object then null; end;
  end if;
end $$;

-- ---------- storage for listing/evidence photos
insert into storage.buckets (id, name, public) values ('photos','photos', true) on conflict do nothing;
create policy photos_read on storage.objects for select using (bucket_id = 'photos');
create policy photos_upload on storage.objects for insert to authenticated with check (bucket_id = 'photos');

-- ---------- seed: fictitious market prices
insert into market_prices (produce, district, avg_price_ugx) values
 ('Maize','All',1200),('Beans','All',3200),('Matooke','All',1500),('Tomatoes','All',2500),
 ('Cassava','All',900),('Coffee (kiboko)','All',5200),('Irish potatoes','All',1800),('Onions','All',2800);

-- After the demo accounts exist, promote one admin (run manually):
-- update profiles set role = 'admin' where user_id = (select id from auth.users where email = 'admin@lima.test');
