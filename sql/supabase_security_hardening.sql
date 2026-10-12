-- =====================================================================
-- 보안 보강 (Supabase SQL Editor) — 유료화 대비
--   · 우편 1회 수령을 서버가 보장 (admin_grants_claim)  → 새 index.html 과 한 세트
--   · 공허 랭킹 서버 검증 (void_guard 트리거)            → 위조 웨이브/시즌 보상 탈취 차단
-- ★ 이 파일은 "한 번에 전부 실행하지 말고" PART 1 → 2 → 3 순서로 나눠서 각각 실행하세요.
--   (PART 2 는 조작 계정을 먼저 지운 다음에 실행해야 합니다)
-- ※ 튜닝 상수는 PART 3 함수 맨 위 constant 만 바꾸면 된다.
-- =====================================================================


-- ############### PART 1 : 우편 수령 함수 + 공허 검증 테이블 (먼저 실행) ###############

-- 우편 1회 수령: 서버가 먼저 '받음' 처리에 성공해야 게임이 지급한다.
--  · 이미 받았거나 기한이 지난 우편이면 null → 같은 우편을 여러 번 받을 수 없다
--  · 지급 종류/수량은 서버 값만 쓴다 (클라이언트가 수량을 바꿀 수 없다)
create or replace function public.admin_grants_claim(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare uid text := auth.uid()::text; r public.admin_grants%rowtype;
begin
  if uid is null then return null; end if;
  update public.admin_grants
     set claimed_at = now()
   where id = p_id and user_id = uid and claimed_at is null and expires_at > now()
   returning * into r;
  if not found then return null; end if;
  return jsonb_build_object('id', r.id, 'item', r.item, 'amount', r.amount);
end $$;
revoke all on function public.admin_grants_claim(uuid) from public, anon;
grant execute on function public.admin_grants_claim(uuid) to authenticated;

-- 서버가 인정한 공허 최고 웨이브 기록 (앱은 접근 불가)
create table if not exists public.void_guard (
  user_id   text not null,
  board_key text not null,
  wave      int  not null default 0,            -- 서버가 인정한 최고 웨이브
  top_at    timestamptz not null default now(), -- 마지막으로 wave 가 오른 시각
  day_start timestamptz not null default now(), -- 24시간 집계 시작
  day_gain  int  not null default 0,            -- 이 24시간 동안 오른 웨이브 합
  primary key (user_id, board_key)
);
alter table public.void_guard enable row level security;      -- 정책 없음: 앱은 접근 불가
revoke all on public.void_guard from anon, authenticated;


-- ############### PART 2 : 조작 계정 정리 → 기준선 등록 (PART 1 다음, PART 3 전에 실행) ###############

-- (가) 먼저 현재 공허 랭킹 상위를 읽기 전용으로 확인한다. 말이 안 되는 값(수백 웨이브 등)이 있는지 본다.
select user_id, board_key, name, amount, updated_at
  from public.leaderboard_entries
 where board_key like 'leaderboard_void_monthly_%'
 order by (amount::text)::numeric desc nulls last
 limit 20;

-- (나) 조작 계정이 있으면 기록을 지운다 (user_id 를 바꿔서 실행. 없으면 건너뛴다):
-- delete from public.leaderboard_entries
--  where user_id = '<조작 계정 user_id>' and board_key like 'leaderboard_void_monthly_%';

-- (다) 남은 정상 유저의 현재 값을 기준선으로 등록한다. ※ (나)까지 끝낸 뒤에 실행!
insert into public.void_guard(user_id, board_key, wave, top_at, day_start, day_gain)
select user_id::text, board_key, floor((amount::text)::numeric)::int, now() - interval '1 day', now(), 0
  from public.leaderboard_entries
 where board_key like 'leaderboard_void_monthly_%'
   and (amount::text) ~ '^[0-9]+(\.[0-9]+)?$'
   and (amount::text)::numeric >= 1
on conflict do nothing;


-- ############### PART 3 : 공허 랭킹 검증 트리거 (마지막에 실행) ###############
--   · 이번 시즌 첫 기록은 c_first_max 이하 (시즌마다 1웨이브부터 다시 시작하므로)
--   · 웨이브 상승은 "직전에 서버가 인정한 시각 이후 흐른 시간"만큼만 허용: c_burst + 경과초 / c_wave_sec
--     (오래 꺼뒀다가 오프라인 진행으로 한꺼번에 오른 경우는 경과 시간이 길어서 정상 통과한다)
--   · 24시간 안에 오를 수 있는 총 웨이브 수 상한 c_day_max
--   · 거절돼도 게임이 2분마다 다시 시도하므로, 정상 유저는 시간이 지나면 자동으로 통과한다
create or replace function public.void_progress_guard()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  c_first_max  constant int := 60;     -- 이번 시즌 서버에 처음 기록되는 웨이브 상한
  c_burst      constant int := 25;     -- 한 번에 허용하는 여유 웨이브 (차원 조각 구매 직후 급상승 등)
  c_wave_sec   constant int := 4;      -- 경과 시간 N초당 +1웨이브 허용
  c_day_max    constant int := 400;    -- 24시간 안에 오를 수 있는 총 웨이브
  c_abs_max    constant int := 1000;   -- 절대 상한 (적 체력이 웨이브마다 ×1.12)
  p int; g public.void_guard%rowtype; uid text; el numeric; gain int; dgain int; dstart timestamptz;
begin
  if NEW.board_key is null or NEW.board_key not like 'leaderboard_void_monthly_%' then
    return NEW;                                  -- 공허와 무관한 랭킹판은 건드리지 않는다
  end if;
  begin
    p := floor((NEW.amount::text)::numeric)::int;
  exception when others then
    raise exception 'void_guard: 잘못된 값';
  end;
  if p is null or p = 0 then return NEW; end if;   -- 값 없음/0(시즌 초기화)은 그대로 통과
  if p < 0 then raise exception 'void_guard: 잘못된 값 (%)', p; end if;
  if p > c_abs_max then raise exception 'void_guard: 범위 초과 (%)', p; end if;
  uid := NEW.user_id::text;

  insert into public.void_guard(user_id, board_key, wave, top_at, day_start, day_gain)
  values (uid, NEW.board_key, -1, now(), now(), 0)
  on conflict do nothing;
  select * into g from public.void_guard where user_id = uid and board_key = NEW.board_key for update;

  if g.wave = -1 then                            -- 이 시즌 첫 기록
    if p > c_first_max then
      raise exception 'void_guard: 첫 기록이 너무 높음 (%)', p;
    end if;
    update public.void_guard set wave = p, top_at = now(), day_start = now(), day_gain = p
     where user_id = uid and board_key = NEW.board_key;
    return NEW;
  end if;

  if p <= g.wave then return NEW; end if;        -- 같거나 낮은 값은 통과

  el := extract(epoch from (now() - g.top_at));
  gain := p - g.wave;
  if gain > c_burst + floor(el / c_wave_sec) then
    raise exception 'void_guard: 상승 속도 초과 (% -> %, %초)', g.wave, p, round(el);
  end if;

  dstart := g.day_start; dgain := g.day_gain;
  if now() - dstart > interval '24 hours' then dstart := now(); dgain := 0; end if;
  if dgain + gain > c_day_max then
    raise exception 'void_guard: 하루 상승 한도 초과 (오늘 %)', dgain;
  end if;

  update public.void_guard
     set wave = p, top_at = now(), day_start = dstart, day_gain = dgain + gain
   where user_id = uid and board_key = NEW.board_key;
  return NEW;
end;
$$;

drop trigger if exists trg_void_progress_guard on public.leaderboard_entries;
create trigger trg_void_progress_guard
  before insert or update on public.leaderboard_entries
  for each row execute function public.void_progress_guard();
-- ※ 기존 ranking_guard / sword_progress_guard 트리거와 별개라 서로 충돌하지 않는다.
-- 확인:    select * from public.void_guard order by wave desc limit 20;
-- 되돌리기: drop trigger trg_void_progress_guard on public.leaderboard_entries;


-- ############### 참고 : 점검용 조회 모음 (읽기 전용, 유료화 후 가끔 실행) ###############
--   [가] 차원 조각 보유량 vs 실제 구매량 (세이브 조작 의심):
--        select s.user_id, (s.data->>'voidShards')::numeric as shards,
--               coalesce((select sum(p.qty) from public.shop_purchases p where p.user_id = s.user_id and p.item_id = 'shards20k'), 0) as bought_units,
--               (s.data->>'voidBestWave')::int as best_wave
--          from public.saves s
--         where (s.data->>'voidShards') ~ '^[0-9.]+$'
--         order by shards desc limit 20;
--   [나] 루비 지갑:   select user_id, ruby, total_charged, updated_at from public.wallets order by ruby desc limit 20;
--   [다] 최근 구매:   select user_id, item_id, qty, price_total, created_at from public.shop_purchases order by id desc limit 50;
--   [라] 받지 않은 구매 우편:
--        select user_id, item, amount, created_at from public.admin_grants
--         where note like 'shop:%' and claimed_at is null order by created_at limit 50;
