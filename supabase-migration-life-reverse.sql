-- ============================================================
-- 인생역전(life-reverse-landscape) Firebase -> Supabase 마이그레이션
-- Supabase 대시보드 > SQL Editor 에서 전체를 그대로 실행하세요.
-- 기존 firestore.rules와 최대한 동등한 보안 규칙을 RLS + 트리거로 구현했습니다.
-- ============================================================

-- ------------------------------------------------------------
-- 0. 공용 헬퍼 함수
-- ------------------------------------------------------------

-- 900조(9e15)를 넘는 값은 클라이언트가 "BN:" + 40자리 0패딩 문자열로 바꿔서 보내므로,
-- 여기서도 그 문자열을 다시 숫자로 되돌려서 비교할 수 있게 한다.
create or replace function public.bignum(v text)
returns numeric language plpgsql immutable as $$
begin
  if v is null then return 0; end if;
  if left(v, 3) = 'BN:' then
    return substring(v from 4)::numeric;
  else
    return v::numeric;
  end if;
end;
$$;

-- ------------------------------------------------------------
-- 1. saves 테이블 (유저별 게임 저장 데이터. 필드가 워낙 많아서 jsonb로 통째 저장)
-- ------------------------------------------------------------
create table if not exists public.saves (
  user_id uuid primary key references auth.users(id) on delete cascade,
  data jsonb not null,
  server_saved_at timestamptz not null default now()
);

alter table public.saves enable row level security;

drop policy if exists saves_select_own on public.saves;
create policy saves_select_own on public.saves
  for select using (auth.uid() = user_id);

-- 최초 저장(신규 계정): 아직 비교할 "직전 값"이 없으므로, 신규 계정은 1억원 이하만
-- 허용해서 처음부터 money/totalEarned를 조작해 로그인하는 걸 막는다.
drop policy if exists saves_insert_own on public.saves;
create policy saves_insert_own on public.saves
  for insert with check (
    auth.uid() = user_id
    and public.bignum(data->>'totalEarned') <= 100000000
    and public.bignum(data->>'money') <= 100000000
    and public.bignum(data->>'casinoTotalWinnings') <= 100000000
    and coalesce((data->>'rebirthCount')::numeric, 0) = 0
    and coalesce((data->>'prestigePoints')::numeric, 0) = 0
  );

-- 이후 저장(덮어쓰기)의 증가폭 검증은 UPDATE 트리거(아래)에서 처리한다.
drop policy if exists saves_update_own on public.saves;
create policy saves_update_own on public.saves
  for update using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- "말이 되는 증가폭"인지 검사하는 트리거. 클라이언트가 값을 아무리 조작해서 보내도
-- 직전 저장 시각(서버 기준) 대비 너무 큰 폭으로 뛰면 거부된다. (기존 Firestore 규칙의
-- isPlausibleSave()와 동일한 로직 + 동일한 버퍼값)
create or replace function public.saves_validate_growth()
returns trigger language plpgsql as $$
declare
  elapsed_sec numeric;
  is_rebirth boolean;
  is_version_reset boolean;
  buf numeric := 1e34; -- 오프라인 보정 등 자잘한 오차용 여유값
  max_income_per_sec numeric := 5e41;
  max_casino_gain_per_sec numeric := 5e40;
  old_total numeric; new_total numeric;
  new_money numeric;
  old_casino numeric; new_casino numeric;
  old_prestige numeric; new_prestige numeric;
  old_version numeric; new_version numeric;
begin
  -- 클라이언트가 보낸 시간은 신뢰하지 않고, 서버가 항상 지금 시각으로 강제한다.
  elapsed_sec := extract(epoch from (now() - old.server_saved_at));
  new.server_saved_at := now();

  old_total   := public.bignum(old.data->>'totalEarned');
  new_total   := public.bignum(new.data->>'totalEarned');
  new_money   := public.bignum(new.data->>'money');
  old_casino  := public.bignum(old.data->>'casinoTotalWinnings');
  new_casino  := public.bignum(new.data->>'casinoTotalWinnings');
  old_prestige := coalesce((old.data->>'prestigePoints')::numeric, 0);
  new_prestige := coalesce((new.data->>'prestigePoints')::numeric, 0);
  old_version := coalesce((old.data->>'gameVersion')::numeric, 0);
  new_version := coalesce((new.data->>'gameVersion')::numeric, 0);

  is_rebirth := (coalesce((new.data->>'rebirthCount')::numeric, 0) = coalesce((old.data->>'rebirthCount')::numeric, 0) + 1);
  is_version_reset := (new.data ? 'gameVersion') and (new_version > old_version);

  if is_version_reset then
    -- 밸런스를 크게 갈아엎을 때 GAME_VERSION을 올려서 기존 세이브를 강제 초기화시키는
    -- 경우. 새 계정을 만드는 것과 사실상 동일한 상태이므로 전부 0 근처로 리셋 허용.
    if not (new_total <= buf and new_money <= buf and new_prestige <= buf and new_casino <= buf) then
      raise exception '버전 리셋 저장 값이 허용 범위를 벗어났습니다';
    end if;
  elsif is_rebirth then
    -- 환생(프레스티지)은 totalEarned/money가 0으로 리셋되는 게 정상 동작.
    if not (
      new_total <= buf and new_money <= buf
      and new_prestige >= old_prestige and new_prestige <= old_prestige + 1000000
      and new_casino >= old_casino
      and (new_casino - old_casino) <= elapsed_sec * max_casino_gain_per_sec + buf
    ) then
      raise exception '환생 저장 값이 허용 범위를 벗어났습니다';
    end if;
  else
    if not (
      new_total >= old_total
      and (new_total - old_total) <= elapsed_sec * max_income_per_sec + buf
      -- money는 카지노에서 딴 돈만큼 totalEarned보다 더 많을 수 있다.
      and new_money <= new_total + new_casino + buf
      -- 프레스티지 포인트: 주간 랭킹 보상(최대 10P) + 카지노 상점 교환(회당 1P) 몰아사기 커버.
      and new_prestige >= old_prestige and new_prestige <= old_prestige + 100
      and new_casino >= old_casino
      and (new_casino - old_casino) <= elapsed_sec * max_casino_gain_per_sec + buf
    ) then
      raise exception '저장 값 증가폭이 비정상적으로 큽니다';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists saves_validate_growth_trigger on public.saves;
create trigger saves_validate_growth_trigger
  before update on public.saves
  for each row execute function public.saves_validate_growth();

-- ------------------------------------------------------------
-- 2. leaderboard_entries 테이블 (전체/주간/월간/검배틀 랭킹판을 board_key로 공유)
-- ------------------------------------------------------------
create table if not exists public.leaderboard_entries (
  board_key text not null,
  user_id uuid not null references auth.users(id) on delete cascade,
  name text,
  updated_at bigint,
  tier_name text,
  tier_icon text,
  amount numeric,
  name_color text,
  mansion_icon text,
  sword_level integer,
  primary key (board_key, user_id)
);

alter table public.leaderboard_entries enable row level security;

-- 랭킹은 다른 유저의 순위/이름/검배틀 상대 목록을 봐야 하므로 읽기는 전체 공개.
drop policy if exists leaderboard_read_all on public.leaderboard_entries;
create policy leaderboard_read_all on public.leaderboard_entries for select using (true);

-- amount가 saves 문서의 해당 값(예: casinoTotalWinnings)을 벗어날 수 없게 이중 확인.
create or replace function public.leaderboard_amount_ok(p_board_key text, p_user_id uuid, p_amount numeric)
returns boolean language plpgsql as $$
declare
  s record;
begin
  if p_amount is null or p_amount < 0 then return false; end if;
  select * into s from public.saves where user_id = p_user_id;
  if s is null then return false; end if;

  if p_board_key = 'leaderboard' then
    return p_amount <= public.bignum(s.data->>'casinoTotalWinnings') + 1;
  elsif p_board_key = 'leaderboard_sword' then
    -- 승패당 ±5점씩 바로 바뀌는데, saves는 자동저장 주기로만 갱신되니 버퍼를 넉넉히 30으로 둔다.
    return p_amount <= coalesce((s.data->>'swordBattleWins')::numeric, 0) + 30;
  elsif p_board_key like 'leaderboard_weekly_%' then
    return p_amount <= public.bignum(s.data->>'weeklyWinnings') + 1;
  elsif p_board_key like 'leaderboard_monthly_%' then
    return p_amount <= public.bignum(s.data->>'monthlyWinnings') + 1;
  elsif p_board_key like 'leaderboard_burn_monthly_%' then
    return p_amount <= public.bignum(s.data->>'burnedMonthly') + 1;
  elsif p_board_key like 'leaderboard_sword_monthly_%' then
    return p_amount <= coalesce((s.data->>'swordMonthlyBestLevel')::numeric, 0) + 1;
  else
    return false;
  end if;
end;
$$;

drop policy if exists leaderboard_insert_own on public.leaderboard_entries;
create policy leaderboard_insert_own on public.leaderboard_entries
  for insert with check (auth.uid() = user_id and public.leaderboard_amount_ok(board_key, user_id, amount));

drop policy if exists leaderboard_update_own on public.leaderboard_entries;
create policy leaderboard_update_own on public.leaderboard_entries
  for update using (auth.uid() = user_id)
  with check (auth.uid() = user_id and public.leaderboard_amount_ok(board_key, user_id, amount));

create index if not exists leaderboard_entries_amount_idx on public.leaderboard_entries (board_key, amount desc);
create index if not exists leaderboard_entries_updated_idx on public.leaderboard_entries (board_key, updated_at desc);

-- ------------------------------------------------------------
-- 3. referrals 테이블 (친구 초대 - 바이럴 성장 루프)
-- ------------------------------------------------------------
create table if not exists public.referrals (
  user_id uuid primary key references auth.users(id) on delete cascade, -- 초대받은 사람(신규 계정)
  referrer_uid uuid not null,        -- 초대한 사람
  claimed boolean not null default false,
  created_at timestamptz not null default now()
);

alter table public.referrals enable row level security;

-- "내가 초대한 사람 목록"을 조회해서 보상을 셀프 수령해야 하므로, 로그인한 사람이면
-- 누구나 읽을 수 있게 넉넉히 허용 (민감한 데이터가 아님).
drop policy if exists referrals_read_any on public.referrals;
create policy referrals_read_any on public.referrals for select using (auth.uid() is not null);

-- 최초 생성은 "초대받은 그 신규 계정 본인"만, 자기 자신을 초대할 순 없고 claimed는 false로 시작.
drop policy if exists referrals_insert_self on public.referrals;
create policy referrals_insert_self on public.referrals
  for insert with check (
    auth.uid() = user_id
    and referrer_uid <> user_id
    and claimed = false
  );

-- 이후 수정은 "초대한 사람이 본인 몫 보상을 셀프 수령"하는 경우만: claimed를 false -> true로.
drop policy if exists referrals_claim_by_referrer on public.referrals;
create policy referrals_claim_by_referrer on public.referrals
  for update using (auth.uid() = referrer_uid and claimed = false)
  with check (claimed = true);

-- ============================================================
-- 여기까지 실행한 뒤, Supabase 대시보드 > Authentication > Providers 에서
-- Google 로그인을 켜고(Google Cloud Console의 OAuth 클라이언트 ID/Secret 필요),
-- Authentication > URL Configuration의 Redirect URLs에 게임이 배포된 주소
-- (예: https://detectivekang.github.io/life-reverse-landscape/)를 추가해두세요.
-- ============================================================
