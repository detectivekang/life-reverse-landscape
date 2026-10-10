-- =====================================================================
-- 특정 유저 차단 + 기록 삭제 (Supabase SQL Editor에서 위에서부터 순서대로 실행)
-- 대상 user_id: 2d535c86-4358-4700-87a6-42d2fb13f535
--  · 이 id의 DB 쓰기(insert/update)를 서버 트리거로 전부 막는다  (RPC 함수 안의 쓰기도 막힘)
--  · 이 id의 행을 public 스키마의 모든 테이블에서 삭제한다 (삭제 전 백업 테이블에 복사)
--  · 로그인 자체도 막는다 (auth 밴 + 세션 삭제)
-- ※ auth.users 행은 지우지 말고 "밴"만 한다. 지우면 같은 소셜 계정으로 다시 로그인할 때
--   새 id가 생겨 차단이 풀린다.
-- =====================================================================

-- [0] 미리보기: 어떤 테이블에 몇 줄 있는지 확인 (아무것도 바꾸지 않음)
do $$
declare r record; n bigint;
begin
  for r in
    select c.table_name from information_schema.columns c
    join information_schema.tables t on t.table_schema = c.table_schema and t.table_name = c.table_name and t.table_type = 'BASE TABLE'
    where c.table_schema = 'public' and c.column_name = 'user_id'
  loop
    execute format('select count(*) from public.%I where user_id::text = %L', r.table_name, '2d535c86-4358-4700-87a6-42d2fb13f535') into n;
    raise notice '% : % rows', r.table_name, n;
  end loop;
end $$;
-- user_id 말고 다른 이름(uid, player_id 등)으로 유저를 저장하는 테이블이 있는지 확인:
select table_name, column_name from information_schema.columns
 where table_schema = 'public' and (column_name ilike '%uid%' or column_name ilike '%user%' or column_name ilike '%owner%')
   and column_name <> 'user_id' order by 1, 2;

-- [1] 차단 목록 + 쓰기 차단 트리거
create table if not exists public.banned_users (
  user_id text primary key, reason text, banned_at timestamptz not null default now()
);
alter table public.banned_users enable row level security;
revoke all on public.banned_users from anon, authenticated;
insert into public.banned_users(user_id, reason)
values ('2d535c86-4358-4700-87a6-42d2fb13f535', '랭킹 조작') on conflict (user_id) do nothing;

create or replace function public.block_banned_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from public.banned_users b where b.user_id = NEW.user_id::text) then
    raise exception 'banned_user: 이 계정은 저장할 수 없어요';
  end if;
  return NEW;
end $$;

do $$
declare r record;
begin
  for r in
    select c.table_name from information_schema.columns c
    join information_schema.tables t on t.table_schema = c.table_schema and t.table_name = c.table_name and t.table_type = 'BASE TABLE'
    where c.table_schema = 'public' and c.column_name = 'user_id'
      and c.table_name not in ('banned_users', 'banned_user_backup')
  loop
    execute format('drop trigger if exists trg_block_banned on public.%I', r.table_name);
    execute format('create trigger trg_block_banned before insert or update on public.%I for each row execute function public.block_banned_user()', r.table_name);
  end loop;
end $$;

-- [2] 백업 후 삭제 (되돌릴 수 없는 작업 — [0] 미리보기를 확인한 뒤 실행)
create table if not exists public.banned_user_backup (
  id bigserial primary key, user_id text, table_name text, row_data jsonb, backed_up_at timestamptz not null default now()
);
alter table public.banned_user_backup enable row level security;
revoke all on public.banned_user_backup from anon, authenticated;

do $$
declare r record; n bigint; uid constant text := '2d535c86-4358-4700-87a6-42d2fb13f535';
begin
  for r in
    select c.table_name from information_schema.columns c
    join information_schema.tables t on t.table_schema = c.table_schema and t.table_name = c.table_name and t.table_type = 'BASE TABLE'
    where c.table_schema = 'public' and c.column_name = 'user_id'
      and c.table_name not in ('banned_users', 'banned_user_backup')
  loop
    execute format('insert into public.banned_user_backup(user_id, table_name, row_data) select %L, %L, to_jsonb(t) from public.%I t where t.user_id::text = %L', uid, r.table_name, r.table_name, uid);
    execute format('delete from public.%I where user_id::text = %L', r.table_name, uid);
    get diagnostics n = row_count;
    raise notice '% : % rows deleted', r.table_name, n;
  end loop;
end $$;

-- [3] 로그인 차단 + 이미 로그인된 기기 끊기
update auth.users set banned_until = 'infinity' where id = '2d535c86-4358-4700-87a6-42d2fb13f535'::uuid;
delete from auth.sessions where user_id = '2d535c86-4358-4700-87a6-42d2fb13f535'::uuid;
delete from auth.refresh_tokens where user_id::text = '2d535c86-4358-4700-87a6-42d2fb13f535';

-- [4] 확인 (모두 0줄이어야 함) / 백업까지 완전히 지우려면 마지막 줄 실행
select table_name, count(*) as backed_up_rows from public.banned_user_backup group by 1;
-- drop table public.banned_user_backup;   -- 백업이 필요 없다고 확정되면 실행

-- 차단 해제하려면:
--   delete from public.banned_users where user_id = '2d535c86-4358-4700-87a6-42d2fb13f535';
--   update auth.users set banned_until = null where id = '2d535c86-4358-4700-87a6-42d2fb13f535'::uuid;
