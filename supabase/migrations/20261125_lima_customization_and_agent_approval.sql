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
