-- =====================================================================
-- 인생역전 × 네온 호드 콜라보 (Supabase SQL Editor에서 "한 번에 전체" 실행)
--   · 네온 호드 클라우드 세이브 (nh_saves)
--   · 판(런) 결과 서버 검증 → 시즌(월) 누적 점수 랭킹 (nh_runs / nh_season_scores)
--   · 서버가 인정한 골드만 환전 가능 (nh_wallet) → 1골드 = 차원 조각 1개를 "우편"으로 지급
-- 전제: saves / admin_grants 테이블과 admin_grants_claim 함수가 이미 있어야 한다
--       (supabase_admin_grants.sql, supabase_security_hardening.sql 적용 완료 상태).
-- 여러 번 실행해도 안전하다 (create ... if not exists / create or replace).
--
-- ★ 튜닝 상수는 아래 각 함수 맨 위 constant 값만 바꾸면 된다.
--   nh_finish_run : c_max_kps(초당 최대 처치수), c_gold_run_cap(한 판 최대 골드) ...
--   nh_exchange   : c_rate(환전 비율), c_daily_cap(하루 환전 한도)
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0. 공통
-- ---------------------------------------------------------------------
-- 시즌 키: 인생역전과 같은 "월 단위"(한국시간 기준) 예) 2026-10
create or replace function public.nh_season_key(p_at timestamptz default now())
returns text language sql stable as $$
  select to_char(p_at at time zone 'Asia/Seoul', 'YYYY-MM')
$$;

-- 차단된 계정인지 (banned_users 테이블이 없으면 항상 false)
create or replace function public.nh_is_banned(p_uid text)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare b boolean := false;
begin
  if to_regclass('public.banned_users') is null then return false; end if;
  execute 'select exists(select 1 from public.banned_users where user_id = $1)' into b using p_uid;
  return coalesce(b, false);
end $$;
revoke all on function public.nh_is_banned(text) from public, anon, authenticated;

-- 이름 정리 (HTML 특수문자/제어문자 제거, 20자)
create or replace function public.nh_clean_name(p_name text)
returns text language sql immutable as $$
  select coalesce(nullif(left(btrim(regexp_replace(coalesce(p_name, ''), '[<>&"''`\\[:cntrl:]]', '', 'g')), 20), ''), 'Player')
$$;

-- ---------------------------------------------------------------------
-- 1. 클라우드 세이브 (앱이 RLS로 "내 것만" 직접 읽고 쓴다)
--    ※ 골드 환전은 이 세이브를 믿지 않는다. 아래 nh_wallet(서버 검증 골드)만 믿는다.
-- ---------------------------------------------------------------------
create table if not exists public.nh_saves (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  data       jsonb not null,
  updated_at timestamptz not null default now(),
  constraint nh_saves_size check (pg_column_size(data) < 60000)
);
alter table public.nh_saves enable row level security;

drop policy if exists nh_saves_select_own on public.nh_saves;
create policy nh_saves_select_own on public.nh_saves for select using (auth.uid() = user_id);
drop policy if exists nh_saves_insert_own on public.nh_saves;
create policy nh_saves_insert_own on public.nh_saves for insert with check (auth.uid() = user_id and not public.nh_is_banned(user_id::text));
drop policy if exists nh_saves_update_own on public.nh_saves;
create policy nh_saves_update_own on public.nh_saves for update using (auth.uid() = user_id)
  with check (auth.uid() = user_id and not public.nh_is_banned(user_id::text));

create or replace function public.nh_saves_touch() returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end $$;
drop trigger if exists nh_saves_touch_trg on public.nh_saves;
create trigger nh_saves_touch_trg before insert or update on public.nh_saves
  for each row execute function public.nh_saves_touch();

-- ---------------------------------------------------------------------
-- 2. 서버 전용 테이블 (앱은 접근 불가, 아래 함수로만 다룬다)
-- ---------------------------------------------------------------------
-- 2-1. 판(런) 기록: 시작 시각을 서버가 찍는다 → 게임 시간이 실제 시간을 넘을 수 없게 검증
create table if not exists public.nh_runs (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users(id) on delete cascade,
  stage       int  not null,
  started_at  timestamptz not null default now(),
  finished_at timestamptz,
  -- 아래는 검증 후 인정된 값 + 클라이언트가 주장한 값(점검용)
  time_s      numeric, kills int, boss_kills int, win boolean, asc_lv int,
  claim_gold  bigint, credited_gold bigint, score bigint
);
create index if not exists nh_runs_user_idx on public.nh_runs (user_id, started_at desc);
alter table public.nh_runs enable row level security;
revoke all on public.nh_runs from anon, authenticated;

-- 2-2. 지갑: 서버가 인정한 "번 골드"와 "환전한 골드"
create table if not exists public.nh_wallet (
  user_id        uuid primary key references auth.users(id) on delete cascade,
  earned_gold    bigint not null default 0,
  exchanged_gold bigint not null default 0,
  ex_day         date,
  ex_day_gold    bigint not null default 0,
  updated_at     timestamptz not null default now()
);
alter table public.nh_wallet enable row level security;
revoke all on public.nh_wallet from anon, authenticated;

-- 2-3. 시즌 누적 점수
create table if not exists public.nh_season_scores (
  season     text   not null,
  user_id    uuid   not null references auth.users(id) on delete cascade,
  name       text,
  score      bigint not null default 0,
  runs       int    not null default 0,
  best_time  int    not null default 0,
  updated_at timestamptz not null default now(),
  primary key (season, user_id)
);
create index if not exists nh_season_scores_rank_idx on public.nh_season_scores (season, score desc, updated_at);
alter table public.nh_season_scores enable row level security;
revoke all on public.nh_season_scores from anon, authenticated;

-- ---------------------------------------------------------------------
-- 3. 판 시작 / 판 종료
-- ---------------------------------------------------------------------
create or replace function public.nh_start_run(p_stage int)
returns uuid language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); rid uuid;
begin
  if uid is null then raise exception 'NH_LOGIN'; end if;
  if public.nh_is_banned(uid::text) then raise exception 'NH_BANNED'; end if;
  if p_stage is null or p_stage not between 0 and 3 then raise exception 'NH_BAD_STAGE'; end if;
  -- 끝나지 않은 이전 판은 버린다 (한 번에 한 판만 인정)
  delete from public.nh_runs where user_id = uid and finished_at is null;
  insert into public.nh_runs (user_id, stage) values (uid, p_stage) returning id into rid;
  return rid;
end $$;
revoke all on function public.nh_start_run(int) from public, anon;
grant execute on function public.nh_start_run(int) to authenticated;

-- 점수 = 처치 + 생존초/2 + 승리 300 + 보스처치×100   (바꾸고 싶으면 아래 score := 줄만 수정)
create or replace function public.nh_finish_run(
  p_run uuid, p_time numeric, p_kills int, p_win boolean, p_asc int,
  p_bosskills int, p_coins int, p_gold bigint, p_name text
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  -- ===== 튜닝 상수 =====
  c_max_kps      constant numeric := 12;      -- 초당 최대 처치 수(이 이상은 인정 안 함 · 실제 플레이 데이터를 보고 조정)
  c_kill_base    constant numeric := 100;     -- 기본 여유 처치 수
  c_min_run_sec  constant numeric := 15;      -- 이보다 짧은 판은 점수/골드 없음
  c_gold_run_cap constant bigint  := 20000;   -- 한 판에서 인정하는 최대 골드
  c_mult_greed   constant numeric := 1.5;     -- 탐욕 5단계 최대 배율
  c_mult_relic   constant numeric := 1.5;     -- 탐욕의 주머니 유물
  c_mult_mut     constant numeric := 2.5;     -- 변형 규칙 골드 배율 최대치(보수적으로 넉넉히)
  -- =====================
  uid uuid := auth.uid(); r public.nh_runs%rowtype;
  real_s numeric; t numeric; k int; bk int; coins int; a int; won boolean;
  base numeric; g_max numeric; g_ok bigint; sc bigint; sk text := public.nh_season_key();
  nm text := public.nh_clean_name(p_name); sscore bigint; swallet bigint;
begin
  if uid is null then raise exception 'NH_LOGIN'; end if;
  if public.nh_is_banned(uid::text) then raise exception 'NH_BANNED'; end if;

  select * into r from public.nh_runs where id = p_run and user_id = uid for update;
  if not found or r.finished_at is not null then raise exception 'NH_BAD_RUN'; end if;

  real_s := extract(epoch from (now() - r.started_at));
  -- 게임 시간은 실제 흐른 시간을 넘을 수 없다 (일시정지가 있으면 실제 시간이 더 길다)
  t := least(greatest(coalesce(p_time, 0), 0), real_s + 3);
  if r.stage < 3 then t := least(t, 660); end if;   -- 일반 스테이지는 10분 + 보스전 여유
  k  := least(greatest(coalesce(p_kills, 0), 0), floor(c_kill_base + t * c_max_kps))::int;
  bk := least(greatest(coalesce(p_bosskills, 0), 0), case when r.stage = 3 then 1 + floor(t / 300) else 0 end)::int;
  coins := least(greatest(coalesce(p_coins, 0), 0), floor(60 + t * 3))::int;
  a := least(greatest(coalesce(p_asc, 0), 0), 10);
  -- 일반 스테이지의 승리 = 보스 처치(보스는 약 10분에 등장) → 짧은 판의 승리는 인정하지 않는다
  won := coalesce(p_win, false) and r.stage < 3 and t >= 540;

  if real_s < c_min_run_sec or t < c_min_run_sec then
    update public.nh_runs set finished_at = now(), time_s = t, kills = 0, boss_kills = 0, win = false,
           asc_lv = a, claim_gold = p_gold, credited_gold = 0, score = 0 where id = r.id;
    return jsonb_build_object('ok', true, 'credited_gold', 0, 'score_added', 0, 'season', sk, 'too_short', true);
  end if;

  -- 클라이언트의 골드 공식: (처치*.15 + 시간*.1 + 승리150 + 코인 + 보스*25) × 탐욕 × 유물 × 변형 × 스테이지 × 승급
  base  := k * 0.15 + t * 0.1 + (case when won then 150 else 0 end) + coins + bk * 25;
  g_max := floor(base * c_mult_greed * c_mult_relic * c_mult_mut
                 * (1 + least(r.stage, 2) * 0.5) * (1 + 0.25 * a));
  g_ok  := least(greatest(coalesce(p_gold, 0), 0), g_max::bigint, c_gold_run_cap);

  sc := k + floor(t / 2)::bigint + (case when won then 300 else 0 end) + bk * 100;

  update public.nh_runs set finished_at = now(), time_s = t, kills = k, boss_kills = bk, win = won,
         asc_lv = a, claim_gold = p_gold, credited_gold = g_ok, score = sc where id = r.id;

  insert into public.nh_wallet as w (user_id, earned_gold) values (uid, g_ok)
  on conflict (user_id) do update set earned_gold = w.earned_gold + excluded.earned_gold, updated_at = now()
  returning w.earned_gold - w.exchanged_gold into swallet;

  insert into public.nh_season_scores as s (season, user_id, name, score, runs, best_time)
  values (sk, uid, nm, sc, 1, t::int)
  on conflict (season, user_id) do update
    set score = s.score + excluded.score, runs = s.runs + 1, name = excluded.name,
        best_time = greatest(s.best_time, excluded.best_time), updated_at = now()
  returning s.score into sscore;

  return jsonb_build_object('ok', true, 'credited_gold', g_ok, 'score_added', sc, 'season', sk,
                            'season_score', sscore, 'exchangeable', swallet);
end $$;
revoke all on function public.nh_finish_run(uuid, numeric, int, boolean, int, int, int, bigint, text) from public, anon;
grant execute on function public.nh_finish_run(uuid, numeric, int, boolean, int, int, int, bigint, text) to authenticated;

-- ---------------------------------------------------------------------
-- 4. 시즌 랭킹 / 내 환전 현황
-- ---------------------------------------------------------------------
create or replace function public.nh_ranking(p_season text default null, p_limit int default 50)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  uid uuid := auth.uid(); sk text := coalesce(nullif(p_season, ''), public.nh_season_key());
  n int := least(greatest(coalesce(p_limit, 50), 1), 100);
  lst jsonb; tot int; me jsonb;
begin
  if uid is null then return jsonb_build_object('ok', false); end if;
  select count(*) into tot from public.nh_season_scores where season = sk;
  select coalesce(jsonb_agg(jsonb_build_object('rank', x.rk, 'uid', x.user_id, 'name', x.name,
                                               'score', x.score, 'runs', x.runs) order by x.rk), '[]'::jsonb)
    into lst
    from (select row_number() over (order by s.score desc, s.updated_at asc) as rk, s.*
            from public.nh_season_scores s where s.season = sk
           order by s.score desc, s.updated_at asc limit n) x;
  select jsonb_build_object('rank', (select count(*) + 1 from public.nh_season_scores o
                                      where o.season = sk and (o.score > m.score or (o.score = m.score and o.updated_at < m.updated_at))),
                            'score', m.score, 'runs', m.runs)
    into me from public.nh_season_scores m where m.season = sk and m.user_id = uid;
  return jsonb_build_object('ok', true, 'season', sk, 'total', tot, 'list', lst, 'me', me);
end $$;
revoke all on function public.nh_ranking(text, int) from public, anon;
grant execute on function public.nh_ranking(text, int) to authenticated;

-- 환전 규칙/현황 (화면 표시용). 상수는 nh_exchange 와 같은 값으로 유지할 것.
create or replace function public.nh_wallet_info()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  c_rate constant numeric := 1; c_daily_cap constant bigint := 5000;
  uid uuid := auth.uid(); w public.nh_wallet%rowtype; today date := (now() at time zone 'Asia/Seoul')::date; used bigint := 0;
begin
  if uid is null then return jsonb_build_object('ok', false); end if;
  select * into w from public.nh_wallet where user_id = uid;
  if found and w.ex_day = today then used := w.ex_day_gold; end if;
  return jsonb_build_object('ok', true, 'rate', c_rate, 'daily_cap', c_daily_cap,
    'day_used', used, 'day_left', greatest(c_daily_cap - used, 0),
    'exchangeable', coalesce(w.earned_gold - w.exchanged_gold, 0),
    'season', public.nh_season_key());
end $$;
revoke all on function public.nh_wallet_info() from public, anon;
grant execute on function public.nh_wallet_info() to authenticated;

-- ---------------------------------------------------------------------
-- 5. 환전: 골드 → 차원 조각 (인생역전 우편함으로 지급, 받기를 눌러야 반영)
-- ---------------------------------------------------------------------
create or replace function public.nh_exchange(p_gold int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  -- ===== 튜닝 상수 =====
  c_rate      constant numeric := 1;      -- 1골드 = 차원 조각 1개
  c_daily_cap constant bigint  := 5000;   -- 하루(한국시간 0시 기준) 환전 가능 골드
  -- =====================
  uid uuid := auth.uid(); w public.nh_wallet%rowtype;
  today date := (now() at time zone 'Asia/Seoul')::date;
  shards bigint; left_ bigint; chunk int; used bigint;
begin
  if uid is null then raise exception 'NH_LOGIN'; end if;
  if public.nh_is_banned(uid::text) then raise exception 'NH_BANNED'; end if;
  if p_gold is null or p_gold < 1 then raise exception 'NH_BAD_AMOUNT'; end if;

  select * into w from public.nh_wallet where user_id = uid for update;
  if not found then raise exception 'NH_NOT_ENOUGH'; end if;
  if w.ex_day is distinct from today then w.ex_day := today; w.ex_day_gold := 0; end if;
  if w.earned_gold - w.exchanged_gold < p_gold then raise exception 'NH_NOT_ENOUGH'; end if;
  if w.ex_day_gold + p_gold > c_daily_cap then raise exception 'NH_DAILY_LIMIT'; end if;

  shards := floor(p_gold * c_rate)::bigint;
  if shards < 1 then raise exception 'NH_BAD_AMOUNT'; end if;

  update public.nh_wallet
     set exchanged_gold = exchanged_gold + p_gold, ex_day = w.ex_day,
         ex_day_gold = w.ex_day_gold + p_gold, updated_at = now()
   where user_id = uid;

  -- admin_grants 는 한 건에 최대 9999개 → 나눠서 우편으로 지급
  left_ := shards;
  while left_ > 0 loop
    chunk := least(left_, 9999)::int;
    insert into public.admin_grants (user_id, item, amount, title, gift_name, message, note, expires_at)
    values (uid::text, 'void_shards', chunk, '🛸 네온 호드 환전',
            '차원 조각 ' || chunk || '개',
            '네온 호드에서 골드를 차원 조각으로 환전했어요.', 'nh_exchange', now() + interval '90 days');
    left_ := left_ - chunk;
  end loop;

  used := w.ex_day_gold + p_gold;
  return jsonb_build_object('ok', true, 'gold', p_gold, 'shards', shards,
    'exchangeable', w.earned_gold - w.exchanged_gold - p_gold,
    'day_left', greatest(c_daily_cap - used, 0));
end $$;
revoke all on function public.nh_exchange(int) from public, anon;
grant execute on function public.nh_exchange(int) to authenticated;

-- ---------------------------------------------------------------------
-- 점검용 쿼리 (필요할 때만 실행)
--   이번 시즌 상위:  select * from nh_season_scores where season = nh_season_key() order by score desc limit 20;
--   의심 판 찾기:    select user_id, stage, time_s, kills, claim_gold, credited_gold, score from nh_runs
--                     where claim_gold > credited_gold or kills > time_s * 12 order by started_at desc limit 50;
--   환전 내역:       select user_id, amount, created_at, claimed_at from admin_grants where note = 'nh_exchange' order by created_at desc;
-- =====================================================================
