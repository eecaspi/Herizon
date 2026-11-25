-- =====================================================================
-- הוספת שדה "שנות ניסיון" לקביעת ראיון
-- להרצה פעם אחת: Supabase -> SQL Editor -> New query -> הדביקי והריצי (Run)
-- =====================================================================
alter table public.bookings
  add column if not exists experience_years smallint check (experience_years between 0 and 60);

-- מסירים את הגרסה הישנה של הפונקציה (4 פרמטרים) ויוצרים את החדשה (5 פרמטרים)
drop function if exists public.book_slot(timestamptz, text, text, text);

-- קביעת ראיון. הנעילה (for update) + האינדקס הייחודי מבטיחים שרק מועמדת אחת תקבל את המשבצת
create or replace function public.book_slot(
  p_starts_at timestamptz, p_name text, p_email text, p_phone text, p_experience smallint default null
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
     or char_length(p_phone) not between 7 and 20
     or (p_experience is not null and p_experience not between 0 and 60) then
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

  insert into public.bookings (slot_id, starts_at, full_name, email, phone, experience_years)
  values (v_slot.id, v_slot.starts_at, p_name, p_email, p_phone, p_experience)
  returning token into v_token;

  select value into v_meet from public.settings where key = 'meet_link';
  return json_build_object('ok', true, 'token', v_token,
                           'starts_at', v_slot.starts_at, 'meet_link', coalesce(v_meet, ''));
exception when unique_violation then
  return json_build_object('ok', false, 'error', 'unavailable');
end;
$$;

revoke execute on function public.book_slot(timestamptz, text, text, text, smallint) from public;
grant  execute on function public.book_slot(timestamptz, text, text, text, smallint) to anon, authenticated;
