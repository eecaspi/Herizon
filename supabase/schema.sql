-- =====================================================================
-- HERizon | שיחות היכרות  —  סכמת מסד הנתונים (Supabase / Postgres)
-- להרצה פעם אחת: Supabase → SQL Editor → New query → הדביקי והריצי (Run)
-- =====================================================================

-- ---------- טבלאות ----------
create table if not exists public.admins (
  email text primary key                      -- מיילים של המנהלות (אותיות קטנות)
);

create table if not exists public.settings (
  key   text primary key,
  value text not null default ''
);
insert into public.settings (key, value) values
  ('meet_link', ''),                          -- קישור קבוע ל-Google Meet
  ('admin_notify_email', '')                  -- לאן נשלחת התראה על ראיון חדש
on conflict (key) do nothing;

create table if not exists public.slots (     -- משבצות של 10 דקות
  id         uuid primary key default gen_random_uuid(),
  starts_at  timestamptz not null unique,
  blocked    boolean not null default false,
  created_at timestamptz not null default now()
);

create table if not exists public.bookings (
  id                   uuid primary key default gen_random_uuid(),
  slot_id              uuid references public.slots(id) on delete set null,
  starts_at            timestamptz not null,
  token                uuid not null unique default gen_random_uuid(),  -- לינק אישי לשינוי/ביטול
  full_name            text not null check (char_length(full_name) between 2 and 100),
  email                text not null check (email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  phone                text not null check (char_length(phone) between 7 and 20),
  status               text not null default 'scheduled'
                       check (status in ('scheduled','completed','no_show','cancelled')),
  notes                text not null default '',
  confirmation_sent_at timestamptz,
  reminder_sent_at     timestamptz,
  created_at           timestamptz not null default now()
);

-- הגנה סופית מפני כפילות: משבצת אחת = ראיון פעיל אחד, גם אם שתי בקשות מגיעות באותו רגע
create unique index if not exists one_active_booking_per_slot
  on public.bookings (slot_id) where status <> 'cancelled' and slot_id is not null;
create index if not exists bookings_starts_idx on public.bookings (starts_at);
create index if not exists bookings_email_idx  on public.bookings (lower(email));

-- ---------- הרשאות ----------
create or replace function public.is_admin() returns boolean
language sql security definer stable set search_path = public as $$
  select exists (
    select 1 from public.admins
    where lower(email) = lower(coalesce(auth.jwt() ->> 'email', ''))
  );
$$;

alter table public.admins   enable row level security;
alter table public.settings enable row level security;
alter table public.slots    enable row level security;
alter table public.bookings enable row level security;

drop policy if exists admins_read    on public.admins;
drop policy if exists settings_admin on public.settings;
drop policy if exists slots_admin    on public.slots;
drop policy if exists bookings_admin on public.bookings;

create policy admins_read    on public.admins   for select to authenticated using (public.is_admin());
create policy settings_admin on public.settings for all    to authenticated using (public.is_admin()) with check (public.is_admin());
create policy slots_admin    on public.slots    for all    to authenticated using (public.is_admin()) with check (public.is_admin());
create policy bookings_admin on public.bookings for all    to authenticated using (public.is_admin()) with check (public.is_admin());

-- מועמדות (anon) אינן מקבלות גישה ישירה לאף טבלה. הכול עובר דרך הפונקציות שלמטה.
revoke all on public.admins, public.settings, public.slots, public.bookings from anon;

-- ---------- פונקציות למועמדות (ללא התחברות) ----------

-- רשימת מועדים פנויים בלבד: בלי שמות ובלי שום פרט על מועמדות אחרות
create or replace function public.get_open_slots()
returns table (starts_at timestamptz)
language sql security definer stable set search_path = public as $$
  select s.starts_at
  from public.slots s
  where not s.blocked
    and s.starts_at > now() + interval '60 minutes'
    and not exists (select 1 from public.bookings b where b.slot_id = s.id and b.status <> 'cancelled')
  order by s.starts_at
  limit 3000;
$$;

-- קביעת ראיון. הנעילה (for update) + האינדקס הייחודי מבטיחים שרק מועמדת אחת תקבל את המשבצת
create or replace function public.book_slot(
  p_starts_at timestamptz, p_name text, p_email text, p_phone text
) returns json
language plpgsql security definer set search_path = public as $$
declare
  v_slot  public.slots;
  v_token uuid;
  v_meet  text;
begin
  p_name  := btrim(coalesce(p_name, ''));
  p_email := lower(btrim(coalesce(p_email, '')));
  p_phone := btrim(coalesce(p_phone, ''));

  if char_length(p_name) not between 2 and 100
     or p_email !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'
     or char_length(p_phone) not between 7 and 20 then
    return json_build_object('ok', false, 'error', 'invalid');
  end if;

  select * into v_slot from public.slots where starts_at = p_starts_at for update;
  if not found or v_slot.blocked or v_slot.starts_at <= now() + interval '60 minutes' then
    return json_build_object('ok', false, 'error', 'unavailable');
  end if;
  if exists (select 1 from public.bookings where slot_id = v_slot.id and status <> 'cancelled') then
    return json_build_object('ok', false, 'error', 'unavailable');
  end if;
  if exists (select 1 from public.bookings
             where lower(email) = p_email and status = 'scheduled' and starts_at > now()) then
    return json_build_object('ok', false, 'error', 'already_booked');
  end if;

  insert into public.bookings (slot_id, starts_at, full_name, email, phone)
  values (v_slot.id, v_slot.starts_at, p_name, p_email, p_phone)
  returning token into v_token;

  select value into v_meet from public.settings where key = 'meet_link';
  return json_build_object('ok', true, 'token', v_token,
                           'starts_at', v_slot.starts_at, 'meet_link', coalesce(v_meet, ''));
exception when unique_violation then
  return json_build_object('ok', false, 'error', 'unavailable');
end;
$$;

-- פרטי ראיון לפי לינק אישי (בלי מייל וטלפון)
create or replace function public.get_booking_by_token(p_token uuid) returns json
language plpgsql security definer stable set search_path = public as $$
declare b public.bookings; v_meet text;
begin
  select * into b from public.bookings where token = p_token;
  if not found then return json_build_object('ok', false); end if;
  select value into v_meet from public.settings where key = 'meet_link';
  return json_build_object('ok', true, 'name', b.full_name, 'starts_at', b.starts_at,
                           'status', b.status, 'meet_link', coalesce(v_meet, ''));
end;
$$;

create or replace function public.cancel_booking_by_token(p_token uuid) returns json
language plpgsql security definer set search_path = public as $$
begin
  update public.bookings set status = 'cancelled'
  where token = p_token and status = 'scheduled' and starts_at > now();
  if not found then return json_build_object('ok', false, 'error', 'not_cancellable'); end if;
  return json_build_object('ok', true);
end;
$$;

-- פונקציה פנימית להעברת ראיון למשבצת אחרת (לא חשופה ישירות)
create or replace function public.move_booking_internal(p_id uuid, p_new timestamptz) returns json
language plpgsql security definer set search_path = public as $$
declare v_slot public.slots;
begin
  select * into v_slot from public.slots where starts_at = p_new for update;
  if not found or v_slot.blocked or v_slot.starts_at <= now() + interval '60 minutes' then
    return json_build_object('ok', false, 'error', 'unavailable');
  end if;
  if exists (select 1 from public.bookings
             where slot_id = v_slot.id and status <> 'cancelled' and id <> p_id) then
    return json_build_object('ok', false, 'error', 'unavailable');
  end if;
  update public.bookings
     set slot_id = v_slot.id, starts_at = v_slot.starts_at,
         confirmation_sent_at = null, reminder_sent_at = null
   where id = p_id and status = 'scheduled';
  if not found then return json_build_object('ok', false, 'error', 'not_scheduled'); end if;
  return json_build_object('ok', true, 'starts_at', v_slot.starts_at);
exception when unique_violation then
  return json_build_object('ok', false, 'error', 'unavailable');
end;
$$;

create or replace function public.reschedule_booking_by_token(p_token uuid, p_new timestamptz) returns json
language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  select id into v_id from public.bookings
   where token = p_token and status = 'scheduled' and starts_at > now();
  if v_id is null then return json_build_object('ok', false, 'error', 'not_scheduled'); end if;
  return public.move_booking_internal(v_id, p_new);
end;
$$;

-- ---------- פונקציות למנהלות (דורשות התחברות + רשימת admins) ----------
create or replace function public.admin_add_slots(p_starts timestamptz[]) returns integer
language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  insert into public.slots (starts_at)
  select distinct unnest(p_starts) on conflict (starts_at) do nothing;
  get diagnostics n = row_count;
  return n;
end;
$$;

create or replace function public.admin_set_blocked(p_starts timestamptz[], p_blocked boolean) returns integer
language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  update public.slots set blocked = p_blocked where starts_at = any (p_starts);
  get diagnostics n = row_count;
  return n;
end;
$$;

-- מוחקת רק משבצות שאין להן ראיון פעיל
create or replace function public.admin_delete_slots(p_starts timestamptz[]) returns integer
language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  delete from public.slots s
   where s.starts_at = any (p_starts)
     and not exists (select 1 from public.bookings b where b.slot_id = s.id and b.status <> 'cancelled');
  get diagnostics n = row_count;
  return n;
end;
$$;

create or replace function public.admin_move_booking(p_id uuid, p_new timestamptz) returns json
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  return public.move_booking_internal(p_id, p_new);
end;
$$;

-- ---------- הרשאות הרצה ----------
revoke execute on all functions in schema public from public, anon, authenticated;

grant execute on function public.get_open_slots()                              to anon, authenticated;
grant execute on function public.book_slot(timestamptz, text, text, text)      to anon, authenticated;
grant execute on function public.get_booking_by_token(uuid)                    to anon, authenticated;
grant execute on function public.cancel_booking_by_token(uuid)                 to anon, authenticated;
grant execute on function public.reschedule_booking_by_token(uuid, timestamptz) to anon, authenticated;

grant execute on function public.is_admin()                                    to authenticated;
grant execute on function public.admin_add_slots(timestamptz[])                to authenticated;
grant execute on function public.admin_set_blocked(timestamptz[], boolean)     to authenticated;
grant execute on function public.admin_delete_slots(timestamptz[])             to authenticated;
grant execute on function public.admin_move_booking(uuid, timestamptz)         to authenticated;

-- ---------- מנהלות ----------
-- 1) צרי משתמשות ב: Authentication → Users → Add user (סמני Auto Confirm)
-- 2) הוסיפי כאן את אותם מיילים (החליפי והריצי):
-- insert into public.admins (email) values ('you@example.com'), ('partner@example.com');
