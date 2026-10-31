-- =====================================================================
-- 검 랭킹이 안 오르는 문제 점검 + 상한 수정 (Supabase SQL Editor)
-- ranking_guard.sql 의 상한이 '합성 21강'에 멈춰 있었다. 게임은 각성(최대 41)까지 있어서
-- 각성한 검(22~41)은 lb_guard 가 오류 없이 조용히 저장을 건너뛰었다(= 랭킹이 안 오름).
-- 아래 ① 을 먼저 실행해서 원인을 확인하고, ② 를 실행하면 상한이 고쳐진다.
-- =====================================================================

-- ① 점검 (결과를 보내주세요)
--   a) 막힌 기록:      select * from public.lb_rejects order by id desc limit 30;
--   b) 서버 검 상태:   select user_id, season, lv, aw, best, updated_at from public.sword_state order by best desc limit 10;
--   c) 가드 기준선:    select * from public.sword_guard order by power desc limit 10;
--   d) 걸려 있는 트리거: select tgname from pg_trigger where tgrelid = 'public.leaderboard_entries'::regclass and not tgisinternal;

-- ② 상한 수정
create or replace function public.lb_cap(p_board text) returns numeric
language sql immutable as $$
  select case
    when starts_with(p_board, 'leaderboard_sword_monthly_') then 41::numeric   -- +20강 · 합성 21강 · 각성 최대 20단계 = 41
    when p_board = 'leaderboard_sword'                      then 20000000::numeric
    when starts_with(p_board, 'leaderboard_weekly_')        then 1e31::numeric
    when starts_with(p_board, 'leaderboard_monthly_')       then 1e32::numeric
    when starts_with(p_board, 'leaderboard_burn_monthly_')  then 1e32::numeric
    when p_board = 'leaderboard_hof_earn'                   then 1e45::numeric
    when p_board = 'leaderboard_hof_casino'                 then 1e32::numeric
    when p_board = 'leaderboard_hof_honor'                  then 1e12::numeric
    else null end
$$;

create or replace function public.lb_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_row jsonb := to_jsonb(new);
  v_cap numeric := public.lb_cap(new.board_key);
  v_amt numeric; v_lvl numeric; v_bad text;
begin
  if v_cap is not null and v_row -> 'amount' is not null and jsonb_typeof(v_row -> 'amount') <> 'null' then
    v_amt := public.lb_num(v_row -> 'amount');
    if v_amt is null or v_amt < 0 or v_amt > v_cap then v_bad := 'amount'; end if;
  end if;
  if v_bad is null and v_row ? 'sword_level' and jsonb_typeof(v_row -> 'sword_level') = 'number' then
    v_lvl := (v_row ->> 'sword_level')::numeric;
    if v_lvl < -1 or v_lvl > 41 then v_bad := 'sword_level'; end if;   -- 현재검 랭킹은 메인 검 기준, 각성(최대 41)까지 허용
  end if;
  if v_bad is not null then
    insert into public.lb_rejects (user_id, board_key, amount_text, reason)
    values (v_row ->> 'user_id', new.board_key, left((v_row -> 'amount')::text, 80), v_bad);
    return null;
  end if;
  return new;
exception when others then
  return new;   -- 검사 도중 문제가 생겨도 게임 저장은 막지 않는다
end $$;

create or replace function public.lb_bad_rows()
returns table (board_key text, user_id text, name text, amount text, sword_level text, cap numeric)
language sql stable security definer set search_path = public as $$
  select e.board_key, to_jsonb(e) ->> 'user_id', to_jsonb(e) ->> 'name', (to_jsonb(e) -> 'amount')::text,
         to_jsonb(e) ->> 'sword_level', public.lb_cap(e.board_key)
    from public.leaderboard_entries e
   where (public.lb_cap(e.board_key) is not null and jsonb_typeof(to_jsonb(e) -> 'amount') <> 'null'
          and (public.lb_num(to_jsonb(e) -> 'amount') is null
               or public.lb_num(to_jsonb(e) -> 'amount') < 0
               or public.lb_num(to_jsonb(e) -> 'amount') > public.lb_cap(e.board_key)))
      or (jsonb_typeof(to_jsonb(e) -> 'sword_level') = 'number'
          and ((to_jsonb(e) ->> 'sword_level')::numeric < -1 or (to_jsonb(e) ->> 'sword_level')::numeric > 41))   -- 현재검 랭킹: 각성(최대 41)까지 허용
$$;
