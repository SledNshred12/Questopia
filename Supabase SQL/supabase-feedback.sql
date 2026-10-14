-- Questopia v1.39 (updated for v1.41: Approved tab): Report issue / Submit Idea board with likes and dislikes.
-- Supabase: SQL Editor > New query > paste > Run. Safe to run again.
--
-- Signed-in players can post an issue or an idea (max 5 a day), and like or dislike posts (one vote each, tap again to undo).
-- An ADMIN (anyone in the existing "admins" table) can also mark a post Planned / Done / Declined, and hide or delete any post.
-- You can read everything in the app (menu-free buttons at the bottom of the home screen) or in Table Editor > feedback_posts.
-- The tables can't be read directly by players, only through these functions.

create table if not exists public.feedback_posts (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users (id) on delete cascade,
  kind text not null check (kind in ('issue', 'idea')),
  body text not null check (char_length(body) between 5 and 500),
  author text not null default 'Player',
  status text not null default 'open' check (status in ('open', 'planned', 'done', 'declined')),
  created_at timestamptz not null default now()
);
alter table public.feedback_posts add column if not exists approved boolean not null default false;
create index if not exists feedback_posts_kind_idx on public.feedback_posts (kind, created_at desc);
create index if not exists feedback_posts_user_idx on public.feedback_posts (user_id, created_at);

create table if not exists public.feedback_votes (
  post_id bigint not null references public.feedback_posts (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  v smallint not null check (v in (1, -1)),
  primary key (post_id, user_id)
);

alter table public.feedback_posts enable row level security;
alter table public.feedback_votes enable row level security;
revoke all on public.feedback_posts, public.feedback_votes from anon, authenticated;

create or replace function public.feedback_is_admin()
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select auth.uid() is not null and exists (select 1 from public.admins a where a.user_id = auth.uid())
$$;

-- the board for one kind ('issue' or 'idea') that is not approved yet, or 'approved' for every approved post, best first
create or replace function public.feedback_list(p_kind text)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'not signed in'; end if;
  if p_kind not in ('issue', 'idea', 'approved') then return '[]'::jsonb; end if;
  return coalesce((
    select jsonb_agg(row_to_json(t)) from (
      select p.id, p.kind, p.body, p.author, p.status, p.approved, p.created_at,
        (select count(*) from public.feedback_votes v where v.post_id = p.id and v.v = 1) as up,
        (select count(*) from public.feedback_votes v where v.post_id = p.id and v.v = -1) as down,
        coalesce((select v.v from public.feedback_votes v where v.post_id = p.id and v.user_id = me), 0) as mine,
        (p.user_id = me) as own
      from public.feedback_posts p
      where case when p_kind = 'approved' then p.approved else (p.kind = p_kind and not p.approved) end
      order by (select coalesce(sum(v.v), 0) from public.feedback_votes v where v.post_id = p.id) desc, p.created_at desc
      limit 100
    ) t
  ), '[]'::jsonb);
end $$;

create or replace function public.feedback_post(p_kind text, p_body text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare me uuid := auth.uid(); b text := btrim(coalesce(p_body, '')); nm text;
begin
  if me is null then raise exception 'not signed in'; end if;
  if p_kind not in ('issue', 'idea') then return jsonb_build_object('ok', false, 'error', 'bad_kind'); end if;
  if char_length(b) < 5 then return jsonb_build_object('ok', false, 'error', 'too_short'); end if;
  if char_length(b) > 500 then return jsonb_build_object('ok', false, 'error', 'too_long'); end if;
  if b ~* '(https?:|www\.|\.com|@)' or b ~ '[0-9][^0-9]{0,2}[0-9][^0-9]{0,2}[0-9][^0-9]{0,2}[0-9][^0-9]{0,2}[0-9][^0-9]{0,2}[0-9][^0-9]{0,2}[0-9]' then
    return jsonb_build_object('ok', false, 'error', 'no_contact');
  end if;
  if (select count(*) from public.feedback_posts p where p.user_id = me and p.created_at > now() - interval '1 day') >= 5 and not public.feedback_is_admin() then
    return jsonb_build_object('ok', false, 'error', 'slow_down');
  end if;
  select username into nm from public.profiles where user_id = me;
  insert into public.feedback_posts (user_id, kind, body, author) values (me, p_kind, b, coalesce(nullif(nm, ''), 'Player'));
  return jsonb_build_object('ok', true);
end $$;

-- p_v: 1 = like, -1 = dislike, 0 = take my vote back
create or replace function public.feedback_vote(p_post bigint, p_v int)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'not signed in'; end if;
  if not exists (select 1 from public.feedback_posts where id = p_post) then return jsonb_build_object('ok', false, 'error', 'gone'); end if;
  if p_v = 0 then
    delete from public.feedback_votes where post_id = p_post and user_id = me;
  elsif p_v in (1, -1) then
    insert into public.feedback_votes (post_id, user_id, v) values (p_post, me, p_v)
      on conflict (post_id, user_id) do update set v = excluded.v;
  else
    return jsonb_build_object('ok', false, 'error', 'bad_vote');
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- delete: the author can delete their own post, an admin can delete any post
create or replace function public.feedback_remove(p_post bigint)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'not signed in'; end if;
  delete from public.feedback_posts where id = p_post and (user_id = me or public.feedback_is_admin());
  return jsonb_build_object('ok', true);
end $$;

-- admins only: approve a post (it moves to the Approved tab) or take the approval back
create or replace function public.feedback_approve(p_post bigint, p_approved boolean)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if not public.feedback_is_admin() then return jsonb_build_object('ok', false, 'error', 'not_allowed'); end if;
  update public.feedback_posts set approved = coalesce(p_approved, false) where id = p_post;
  return jsonb_build_object('ok', true);
end $$;

-- admins only: mark a post open / planned / done / declined
create or replace function public.feedback_status(p_post bigint, p_status text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if not public.feedback_is_admin() then return jsonb_build_object('ok', false, 'error', 'not_allowed'); end if;
  if p_status not in ('open', 'planned', 'done', 'declined') then return jsonb_build_object('ok', false, 'error', 'bad_status'); end if;
  update public.feedback_posts set status = p_status where id = p_post;
  return jsonb_build_object('ok', true);
end $$;

revoke all on function public.feedback_is_admin() from public, anon;
revoke all on function public.feedback_list(text) from public, anon;
revoke all on function public.feedback_post(text, text) from public, anon;
revoke all on function public.feedback_vote(bigint, int) from public, anon;
revoke all on function public.feedback_remove(bigint) from public, anon;
revoke all on function public.feedback_status(bigint, text) from public, anon;
revoke all on function public.feedback_approve(bigint, boolean) from public, anon;
grant execute on function public.feedback_is_admin() to authenticated;
grant execute on function public.feedback_list(text) to authenticated;
grant execute on function public.feedback_post(text, text) to authenticated;
grant execute on function public.feedback_vote(bigint, int) to authenticated;
grant execute on function public.feedback_remove(bigint) to authenticated;
grant execute on function public.feedback_status(bigint, text) to authenticated;
grant execute on function public.feedback_approve(bigint, boolean) to authenticated;
