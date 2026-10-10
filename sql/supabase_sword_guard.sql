-- =====================================================================
-- 검 랭킹 조작 방지 (Supabase SQL Editor에서 실행)
-- 아이디어: "이전에 서버가 인정한 값"과 비교해서, 게임 규칙상 불가능한 급상승은 저장 자체를 거부한다.
--   · +20강까지: 레벨 1개당 최소 시간이 필요 (기대 시도가 수십만 번이라 사실상 매우 느림)
--   · +20 → +21(합성): 직전에 +20강 기록이 있어야 하고 최소 간격 필요
--   · 각성: 한 번에 +1단계씩만, 단계 사이 최소 간격 + 하루 최대 횟수 제한
-- 대상: leaderboard_entries 의 'leaderboard_sword'(현재검, sword_level) 와
--       'leaderboard_sword_monthly_*'(월간 최고, amount)
-- ※ 기존 ranking_guard 트리거와 별개로 추가되는 트리거라 서로 충돌하지 않는다.
-- =====================================================================

-- 1) 서버가 인정한 "최고 검 단계" 기록 (클라이언트가 못 건드리는 테이블)
create table if not exists public.sword_guard (
  user_id   text primary key,
  power     int  not null default 0,          -- 서버가 인정한 역대 최고 (0~41)
  top_at    timestamptz not null default now(),-- 마지막으로 power가 오른 시각
  awk_log   timestamptz[] not null default '{}'-- 최근 24시간 각성 상승 시각들
);
alter table public.sword_guard enable row level security;   -- 정책을 만들지 않으므로 앱(anon/authenticated)은 접근 불가
revoke all on public.sword_guard from anon, authenticated;

-- 2) 검증 함수 (튜닝은 맨 위 상수만 바꾸면 된다)
create or replace function public.sword_progress_guard()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  c_first_max  constant int := 10;    -- 서버에 처음 기록되는 값의 상한 (신규 유저)
  c_low_sec    constant int := 30;    -- +20강 이하 구간: 레벨 1개당 최소 초
  c_low_burst  constant int := 2;     -- 한 번에 허용하는 여유 레벨
  c_fuse_sec   constant int := 600;   -- +20강 기록 후 +21강(합성)까지 최소 초
  c_awk_gap    constant int := 300;   -- 각성 1단계당 최소 초
  c_awk_day    constant int := 6;     -- 24시간 안에 올릴 수 있는 각성 단계 수
  p int; g public.sword_guard%rowtype; uid text; el numeric;
  n_low int := 0; n_awk int := 0; recent int;
begin
  uid := NEW.user_id::text;
  if NEW.board_key = 'leaderboard_sword' then
    p := NEW.sword_level;
  elsif NEW.board_key like 'leaderboard_sword_monthly_%' then
    p := (NEW.amount::text)::numeric::int;
  else
    return NEW;                                 -- 검과 무관한 랭킹판은 건드리지 않는다
  end if;
  if p is null or p < 0 then return NEW; end if; -- -1 = 검 없음
  if p > 41 then raise exception 'sword_guard: 범위 초과 (%)', p; end if;

  select * into g from public.sword_guard where user_id = uid for update;
  if not found then
    if p > c_first_max then raise exception 'sword_guard: 첫 기록이 너무 높음 (%)', p; end if;
    insert into public.sword_guard(user_id, power, top_at) values (uid, p, now());
    return NEW;
  end if;

  if p <= g.power then return NEW; end if;     -- 같거나 낮은 값은 통과 (검 파괴/시즌 초기화 등)

  el := extract(epoch from (now() - g.top_at));

  -- (가) +20강 이하 구간
  n_low := greatest(0, least(p, 20) - g.power);
  if n_low > c_low_burst + floor(el / c_low_sec) then
    raise exception 'sword_guard: 강화 속도 초과 (% -> %, %초)', g.power, p, round(el);
  end if;

  -- (나) +21강(합성): +20강을 먼저 기록했어야 하고 간격이 필요
  if p >= 21 and g.power < 21 then
    if g.power < 20 then raise exception 'sword_guard: +20강 기록 없이 +21강 (% -> %)', g.power, p; end if;
    if el < c_fuse_sec then raise exception 'sword_guard: 합성이 너무 빠름 (%초)', round(el); end if;
  end if;

  -- (다) 각성 구간 (22 이상 = 각성 1단계 이상)
  n_awk := greatest(0, p - greatest(g.power, 21));
  if n_awk > 0 then
    if g.power < 21 and p > 21 then raise exception 'sword_guard: 합성과 각성을 동시에 올림 (% -> %)', g.power, p; end if;
    if n_awk > 1 + floor(el / c_awk_gap) then
      raise exception 'sword_guard: 각성 속도 초과 (% -> %, %초)', g.power, p, round(el);
    end if;
    select count(*) into recent from unnest(g.awk_log) t where t > now() - interval '24 hours';
    if recent + n_awk > c_awk_day then
      raise exception 'sword_guard: 하루 각성 한도 초과 (오늘 %회)', recent;
    end if;
  end if;

  update public.sword_guard
     set power  = p,
         top_at = now(),
         awk_log = coalesce((select array_agg(t) from unnest(g.awk_log) t where t > now() - interval '24 hours'), '{}')
                   || (select coalesce(array_agg(now()), '{}') from generate_series(1, n_awk))
   where user_id = uid;
  return NEW;
end;
$$;

drop trigger if exists trg_sword_progress_guard on public.leaderboard_entries;
create trigger trg_sword_progress_guard
  before insert or update on public.leaderboard_entries
  for each row execute function public.sword_progress_guard();

-- =====================================================================
-- 3) 적용 순서 (중요!)
--   ① 먼저 조작 계정을 찾아 기록을 지운다  (user_id는 아래 조회로 확인)
--        select user_id, board_key, name, amount, sword_level, updated_at
--          from public.leaderboard_entries
--         where board_key like 'leaderboard_sword%'
--         order by coalesce((amount::text)::numeric, 0) desc nulls last limit 20;
--        delete from public.leaderboard_entries
--         where user_id = '<조작 계정 user_id>' and board_key like 'leaderboard_sword%';
--   ② 기존 정상 유저들의 현재 값을 기준선으로 등록(조작 계정은 ①에서 이미 지워졌으므로 제외됨)
--        insert into public.sword_guard(user_id, power, top_at)
--        select user_id::text, max(p), now() - interval '1 day'
--          from (
--            select user_id, sword_level as p from public.leaderboard_entries
--             where board_key = 'leaderboard_sword' and sword_level >= 0
--            union all
--            select user_id, (amount::text)::numeric::int from public.leaderboard_entries
--             where board_key like 'leaderboard_sword_monthly_%'
--          ) t group by user_id
--        on conflict (user_id) do nothing;
--   ③ 위 1)·2) 부분(테이블+함수+트리거)을 실행한다. (①②를 먼저 해도, 3)을 먼저 해도 상관없지만
--      ②는 반드시 ① 뒤에 실행해야 조작 값이 기준선으로 인정되지 않는다)
--   ④ 확인용:  select * from public.sword_guard order by power desc limit 20;
-- 되돌리기:  drop trigger trg_sword_progress_guard on public.leaderboard_entries;
-- =====================================================================
