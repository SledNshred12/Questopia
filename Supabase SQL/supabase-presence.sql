-- Questopia v1.44: friends can see when you are online (green dot) or when you were last online (grey dot).
-- Supabase: SQL Editor > New query > paste > Run. Safe to run again.
--
-- While the game is open it saves the time you were last seen. ONLY your accepted friends can read it, through
-- presence_friends(). A player can turn it off in Account, and then friends see nothing for them.
-- The table can't be read directly.

create table if not exists public.presence (
  user_id uuid primary key references auth.users (id) on delete cascade,
  last_seen timestamptz not null default now(),
  visible boolean not null default true
);
alter table public.presence enable row level security;
revoke all on public.presence from anon, authenticated;

-- "I'm here" (the game calls this about once a minute). p_visible = null keeps the current setting.
create or replace function public.presence_ping(p_visible boolean default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'not signed in'; end if;
  insert into public.presence (user_id, last_seen, visible)
    values (me, now(), coalesce(p_visible, true))
  on conflict (user_id) do update
    set last_seen = now(), visible = coalesce(p_visible, public.presence.visible);
  return jsonb_build_object('ok', true);
end $$;

-- how long ago each ACCEPTED friend was seen, by friend code (ago = seconds, null = never; hidden = they turned it off)
create or replace function public.presence_friends()
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'not signed in'; end if;
  return coalesce((
    select jsonb_agg(
      case when pr.visible is false then jsonb_build_object('code', p.friend_code, 'hidden', true)
           else jsonb_build_object('code', p.friend_code, 'ago', case when pr.last_seen is null then null else floor(extract(epoch from (now() - pr.last_seen)))::bigint end) end)
    from public.friendships f
    join public.profiles p on p.user_id = case when f.requester = me then f.addressee else f.requester end
    left join public.presence pr on pr.user_id = p.user_id
    where f.status = 'accepted' and me in (f.requester, f.addressee)
  ), '[]'::jsonb);
end $$;

revoke all on function public.presence_ping(boolean) from public, anon;
revoke all on function public.presence_friends() from public, anon;
grant execute on function public.presence_ping(boolean) to authenticated;
grant execute on function public.presence_friends() to authenticated;
