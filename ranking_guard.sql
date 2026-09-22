-- =====================================================================
-- 랭킹 값 검증 — Supabase SQL Editor에서 한 번 실행 (여러 번 실행해도 안전)
--
-- 문제: 랭킹판(leaderboard_entries)의 값은 클라이언트가 직접 써 넣기 때문에, 개발자도구로 아무 숫자나
--       올릴 수 있어요. 게임 구조상 나올 수 없는 값(예: 미니게임 수익 1e52)이 1등이 되면 정직한 유저는
--       경쟁을 포기하고, 주간/월간 보상(특성 포인트, 검 되돌리기 등)도 그 사람이 가져가요.
--
-- 이 파일이 하는 일
--   1) leaderboard_entries 에 트리거를 달아서, 판별 가능한 "불가능한 값"은 저장 자체를 조용히 건너뜁니다.
--      (정상 유저는 영향 없음 · 오류를 내지 않으니 게임 동기화 흐름은 그대로 · 막힌 기록은 lb_rejects 에 남김)
--   2) 이미 들어가 있는 불가능한 값을 찾고(lb_bad_rows) 지우는 방법을 제공합니다.
--
-- 한도는 게임 수식으로 잡은 "절대 넘을 수 없는" 값이에요 (클라이언트 index.html 의 RANK_LIMITS 와 같은 값).
--   * 검 강화 레벨:      최대 20 (SWORD_MAX_LEVEL)
--   * 검배틀 누적 승점:   2천만 (승리 +5점, 검배틀 티켓이 시간당 10장 → 한 달 최대 약 37만점)
--   * 미니게임 수익 주간 1e31 / 월간 1e32, 소각 월간 1e32
--       (한 판 이익 ≤ 판돈 ≤ 보유금(소프트캡으로 사실상 1e23 이하) × 배당 8배, 초당 2~3판 × 한 달)
--   * 명예의 전당: 최고 시즌 수입 1e45, 최고 월간 카지노 수익 1e32, 명예 점수 1e12
-- 이 한도 안에서 조금씩 올리는 "그럴듯한" 조작은 클라이언트가 계산하는 구조상 서버가 알 수 없어요.
-- (그건 게임 계산을 서버로 옮겨야만 막을 수 있어요.)
-- =====================================================================

-- 세이브/랭킹에 들어가는 큰 숫자 읽기: 숫자 그대로, 또는 'BN:0000…'(40자리 0-패딩 문자열)
create or replace function public.lb_num(j jsonb) returns numeric
language sql immutable as $$
  select case jsonb_typeof(j)
    when 'number' then (j #>> '{}')::numeric
    when 'string' then case
      when (j #>> '{}') ~ '^BN:[0-9]+$'         then substr(j #>> '{}', 4)::numeric
      when (j #>> '{}') ~ '^[0-9]+(\.[0-9]+)?$' then (j #>> '{}')::numeric
      else null end
    else null end
$$;

-- 랭킹판(board_key)별 amount 한도. 모르는 판이면 null(검사 안 함).
create or replace function public.lb_cap(p_board text) returns numeric
language sql immutable as $$
  select case
    when starts_with(p_board, 'leaderboard_sword_monthly_') then 21::numeric   -- 검 강화 최대 20강 + 합성(메인·보관 둘 다 20강)으로 만드는 전설 21강
    when p_board = 'leaderboard_sword'                      then 20000000::numeric
    when starts_with(p_board, 'leaderboard_weekly_')        then 1e31::numeric
    when starts_with(p_board, 'leaderboard_monthly_')       then 1e32::numeric
    when starts_with(p_board, 'leaderboard_burn_monthly_')  then 1e32::numeric
    when p_board = 'leaderboard_hof_earn'                   then 1e45::numeric
    when p_board = 'leaderboard_hof_casino'                 then 1e32::numeric
    when p_board = 'leaderboard_hof_honor'                  then 1e12::numeric
    else null end
$$;

-- 막은 기록 (SQL Editor에서만 볼 수 있음)
create table if not exists public.lb_rejects (
  id          bigserial primary key,
  at          timestamptz not null default now(),
  user_id     text,
  board_key   text,
  amount_text text,
  reason      text
);
alter table public.lb_rejects enable row level security;
revoke all on public.lb_rejects from anon, authenticated;

-- 트리거: 불가능한 값이면 그 행의 저장을 건너뛴다 (NULL 반환 = 이 행 무시, 오류 없음).
-- 컬럼 이름/타입에 의존하지 않도록 to_jsonb(new)로 읽고, 이 함수 자체에 문제가 생기면 저장을 막지 않고 통과시킨다.
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
    if v_lvl < -1 or v_lvl > 21 then v_bad := 'sword_level'; end if;   -- 현재검 랭킹은 메인 검 기준, 합성한 전설(21강)까지 허용
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

drop trigger if exists lb_guard_trg on public.leaderboard_entries;
create trigger lb_guard_trg before insert or update on public.leaderboard_entries
  for each row execute function public.lb_guard();

-- ---------- 이미 들어가 있는 불가능한 값 찾기 ----------
-- SQL Editor에서:   select * from public.lb_bad_rows();
-- 확인 후 지우기:   delete from public.leaderboard_entries e using public.lb_bad_rows() b
--                    where e.board_key = b.board_key and e.user_id::text = b.user_id;
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
          and ((to_jsonb(e) ->> 'sword_level')::numeric < -1 or (to_jsonb(e) ->> 'sword_level')::numeric > 21))   -- 현재검 랭킹: 합성 전설(21강)까지 허용
$$;
revoke all on function public.lb_bad_rows() from public, anon, authenticated;

-- (참고) 세이브 자체에 말도 안 되는 값이 들어간 계정 찾기 — 재산 랭킹은 이런 값을 알아서 제외해요:
--   select user_id, data->>'money' as money, data->>'totalEarned' as earned from public.saves
--    where public.lb_num(data->'money') > 1e30 or public.lb_num(data->'totalEarned') > 1e45;
