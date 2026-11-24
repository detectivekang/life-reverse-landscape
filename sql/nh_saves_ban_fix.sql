-- 네온 호드 동기화 오류 수정: "permission denied for function nh_is_banned"
--
-- 원인: nh_saves 의 쓰기 정책(RLS)이 nh_is_banned() 를 호출하는데,
--       nh_collab.sql 에서 이 함수의 실행 권한을 authenticated 에서 회수(revoke)해 둬서
--       로그인한 유저가 세이브를 올릴 때 권한 오류가 난다.
--       (RLS 정책 안의 함수는 호출한 유저 권한으로 실행되기 때문)
--
-- 해결: 인자 없이 "내 계정만" 확인하는 래퍼 함수를 만들어 그 함수에만 실행 권한을 주고,
--       정책이 그 래퍼를 쓰게 바꾼다. (남의 uid 가 차단됐는지 조회하는 길은 계속 막혀 있음)
-- 적용: Supabase 대시보드 > SQL Editor 에 붙여 넣고 Run. 여러 번 실행해도 안전하다.

create or replace function public.nh_me_banned()
returns boolean language sql stable security definer set search_path = public as $$
  select public.nh_is_banned(auth.uid()::text)
$$;
revoke all on function public.nh_me_banned() from public, anon;
grant execute on function public.nh_me_banned() to authenticated;

drop policy if exists nh_saves_insert_own on public.nh_saves;
create policy nh_saves_insert_own on public.nh_saves for insert
  with check (auth.uid() = user_id and not public.nh_me_banned());

drop policy if exists nh_saves_update_own on public.nh_saves;
create policy nh_saves_update_own on public.nh_saves for update
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id and not public.nh_me_banned());
