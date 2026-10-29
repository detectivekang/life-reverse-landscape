-- =====================================================================
-- 검 / 각성 / 되돌리기 / 강화 주문서 서버 판정 (Supabase SQL Editor에서 한 번에 실행)
--
-- 목적: 검 레벨·각성 단계·유료 아이템(되돌리기, 강화 주문서)을 "서버가 주인"이 되게 한다.
--   · 값은 sword_state 테이블에만 있고, 앱(브라우저)은 이 테이블을 직접 읽거나 쓸 수 없다.
--   · 값은 아래 sw_* 함수로만 바뀐다. 클라이언트는 "강화해줘" 같은 요청만 보내고, 확률 판정·소모는 서버가 한다.
--     → 저장 파일(saves)을 고치거나 랭킹 값을 직접 보내서 "1검 → 21검", "각성 20" 으로 만드는 조작이 통하지 않는다.
--   · 응답은 아주 작은 JSON(약 100바이트)만 돌려준다. saves 전체를 주고받지 않는다.
--   · 랭킹 값(leaderboard_entries)도 서버가 인정한 값을 넘지 못하게 트리거로 막는다.
--
-- 적용 순서
--   ① supabase_sword_guard.sql, supabase_security_hardening.sql 이 이미 적용돼 있어야 한다 (기존 그대로 둔다).
--   ② 이 파일 전체 실행
--   ③ 새 index.html 배포
--   ④ (선택) 아래 "운영 방법" 의 조회문으로 시작값이 깎인 계정(sword_flags)을 확인
--
-- 튜닝: 맨 아래 함수들의 c_* 상수만 바꾸면 된다.
-- =====================================================================

-- 1) 테이블 -------------------------------------------------------------
create table if not exists public.sword_state (
  user_id   text primary key,
  inited    boolean not null default false,   -- 클라이언트 값으로 "시작값"을 최초 1회 받았는지
  own       boolean not null default false,   -- 메인 검 보유
  lv        int     not null default 0,       -- 메인 검 강화 단계 (0~21, 21 = 전설)
  aw        int     not null default 0,       -- 메인 검 각성 단계 (0~20, 21강일 때만 의미)
  s_own     boolean not null default false,   -- 보관함 검 보유
  s_lv      int     not null default 0,       -- 보관함 검 강화 단계 (0~21)
  s_aw      int     not null default 0,       -- 보관함 검 각성 단계 (0~20, 21강일 때만 의미)
  rv        int     not null default 0,       -- 되돌리기 보유 횟수
  b15       int     not null default 0,       -- 강화 주문서 ×1.5 개수
  b20       int     not null default 0,       -- 강화 주문서 ×2 개수
  b25       int     not null default 0,       -- 강화 주문서 ×2.5 개수
  best      int     not null default 0,       -- 이번 시즌 서버가 인정한 최고 power (랭킹 상한)
  season    text    not null default '',      -- 검 상태가 속한 시즌(월, 한국시간) - 달이 바뀌면 검만 초기화
  win_start timestamptz not null default now(),  -- 분당 강화 횟수 집계 시작
  win_cnt   int     not null default 0,
  hr_start  timestamptz not null default now(),  -- 시간당 강화 횟수 집계 시작
  hr_cnt    int     not null default 0,
  gd        date    not null default '1970-01-01',          -- 무료 획득(공허 드롭 등) 일일 집계일
  gdn       int[]   not null default '{0,0,0,0}',            -- 오늘 받은 [되돌리기, x1.5, x2, x2.5]
  gm        text    not null default '',                    -- 우편 보상 월 집계월
  gmn       int[]   not null default '{0,0,0,0}',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint sword_state_range check (
    lv between 0 and 21 and aw between 0 and 20 and s_lv between 0 and 21 and s_aw between 0 and 20
    and (aw = 0 or lv = 21) and (s_aw = 0 or s_lv = 21)
    and rv between 0 and 9999 and b15 between 0 and 9999 and b20 between 0 and 9999 and b25 between 0 and 9999
    and best between 0 and 41
  )
);
alter table public.sword_state enable row level security;     -- 정책을 만들지 않으므로 앱은 접근 불가
revoke all on public.sword_state from anon, authenticated;

create table if not exists public.sword_flags (               -- 시작값이 깎였거나 의심스러운 기록 (운영자 확인용)
  id      bigserial primary key,
  user_id text not null,
  kind    text not null,
  detail  jsonb,
  at      timestamptz not null default now()
);
alter table public.sword_flags enable row level security;
revoke all on public.sword_flags from anon, authenticated;

-- 2) 내부 도우미 ----------------------------------------------------------
create or replace function public._sw_season()
returns text language sql stable as $$
  select to_char(now() at time zone 'Asia/Seoul', 'YYYY-MM')
$$;

create or replace function public._sw_power(p_lv int, p_aw int)
returns int language sql immutable as $$
  select case when p_lv >= 21 then 21 + p_aw else p_lv end
$$;

-- 응답용 작은 JSON: o/l/a = 메인(보유,강화,각성) so/sl/sa = 보관함 rv = 되돌리기 b = [x1.5, x2, x2.5]
create or replace function public._sw_json(r public.sword_state)
returns jsonb language plpgsql immutable as $$
begin
  return jsonb_build_object(
    'o', case when r.own then 1 else 0 end, 'l', r.lv, 'a', r.aw,
    'so', case when r.s_own then 1 else 0 end, 'sl', r.s_lv, 'sa', r.s_aw,
    'rv', r.rv, 'b', jsonb_build_array(r.b15, r.b20, r.b25));
end $$;

-- 내 행을 잠그고 가져온다(없으면 만든다). 새 시즌(월)이 되면 검만 초기화하고 되돌리기·주문서는 보존한다.
create or replace function public._sw_lock(p_uid text)
returns public.sword_state language plpgsql security definer set search_path = public as $$
declare r public.sword_state; cur text := public._sw_season();
begin
  insert into public.sword_state (user_id, season) values (p_uid, cur) on conflict (user_id) do nothing;
  select * into r from public.sword_state where user_id = p_uid for update;
  if r.season <> cur then
    update public.sword_state
       set own = false, lv = 0, aw = 0, s_own = false, s_lv = 0, s_aw = 0, best = 0, season = cur, updated_at = now()
     where user_id = p_uid
     returning * into r;
  end if;
  return r;
end $$;

-- 3) 내 상태 조회 (없으면 {"n":1} → 클라이언트가 sw_init 으로 시작값을 등록) -----------
create or replace function public.sw_get()
returns jsonb language plpgsql security definer set search_path = public as $$
declare uid text := auth.uid()::text; r public.sword_state;
begin
  if uid is null then raise exception 'sw: login required'; end if;
  r := public._sw_lock(uid);
  if not r.inited then return jsonb_build_object('n', 1); end if;
  return public._sw_json(r);
end $$;

-- 4) 시작값 등록 (계정당 최초 1회. 이미 등록돼 있으면 무시하고 서버 값을 돌려준다) -------------
--    기존 플레이어를 옮겨 오는 용도라서 "서버가 이미 인정한 최고치(sword_guard)" 를 넘는 값은 깎는다.
create or replace function public.sw_init(
  p_o boolean, p_l int, p_a int, p_so boolean, p_sl int, p_sa int,
  p_rv int, p_b15 int, p_b20 int, p_b25 int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  c_first_max  constant int := 10;     -- 서버 기록이 전혀 없는 계정의 시작 검 상한
  c_item_init  constant int := 300;    -- 되돌리기/주문서 시작 보유량 상한 (종류별)
  uid text := auth.uid()::text; r public.sword_state;
  cap int; v_lv int; v_aw int; v_slv int; v_saw int; pw int; spw int; cut jsonb := '{}'::jsonb;
  v_rv int; v_15 int; v_20 int; v_25 int;
begin
  if uid is null then raise exception 'sw: login required'; end if;
  r := public._sw_lock(uid);
  if r.inited then return public._sw_json(r); end if;

  select coalesce((select power from public.sword_guard where user_id = uid), c_first_max) into cap;
  cap := least(cap, 41);

  v_lv  := least(greatest(coalesce(p_l, 0), 0), 21);
  v_aw  := case when v_lv = 21 then least(greatest(coalesce(p_a, 0), 0), 20) else 0 end;
  v_slv := least(greatest(coalesce(p_sl, 0), 0), 21);
  v_saw := case when v_slv = 21 then least(greatest(coalesce(p_sa, 0), 0), 20) else 0 end;
  if not coalesce(p_o, false) then v_lv := 0; v_aw := 0; end if;
  if not coalesce(p_so, false) then v_slv := 0; v_saw := 0; end if;

  pw := public._sw_power(v_lv, v_aw);
  if pw > cap then                                   -- 서버가 인정한 값보다 높으면 인정된 값까지만
    cut := cut || jsonb_build_object('main', pw, 'cap', cap);
    if cap >= 21 then v_lv := 21; v_aw := cap - 21; else v_lv := cap; v_aw := 0; end if;
  end if;
  spw := public._sw_power(v_slv, v_saw);
  if spw > cap then
    cut := cut || jsonb_build_object('store', spw, 'cap', cap);
    if cap >= 21 then v_slv := 21; v_saw := cap - 21; else v_slv := cap; v_saw := 0; end if;
  end if;

  v_rv := least(greatest(coalesce(p_rv, 0), 0), c_item_init);
  v_15 := least(greatest(coalesce(p_b15, 0), 0), c_item_init);
  v_20 := least(greatest(coalesce(p_b20, 0), 0), c_item_init);
  v_25 := least(greatest(coalesce(p_b25, 0), 0), c_item_init);
  if coalesce(p_rv,0) > c_item_init or coalesce(p_b15,0) > c_item_init
     or coalesce(p_b20,0) > c_item_init or coalesce(p_b25,0) > c_item_init then
    cut := cut || jsonb_build_object('items', jsonb_build_array(p_rv, p_b15, p_b20, p_b25));
  end if;
  if cut <> '{}'::jsonb then
    insert into public.sword_flags (user_id, kind, detail) values (uid, 'init_cut', cut);
  end if;

  update public.sword_state
     set inited = true,
         own = coalesce(p_o, false), lv = v_lv, aw = v_aw,
         s_own = coalesce(p_so, false), s_lv = v_slv, s_aw = v_saw,
         rv  = least(9999, rv  + v_rv),     -- 이미 우편 등으로 서버에 쌓인 개수에 더한다
         b15 = least(9999, b15 + v_15),
         b20 = least(9999, b20 + v_20),
         b25 = least(9999, b25 + v_25),
         best = greatest(public._sw_power(v_lv, v_aw), public._sw_power(v_slv, v_saw)),
         updated_at = now()
   where user_id = uid
   returning * into r;
  return public._sw_json(r);
end $$;

-- 5) 새 검 만들기 (슬롯: 'm' 메인, 's' 보관함) ---------------------------------------
create or replace function public.sw_craft(p_slot text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare uid text := auth.uid()::text; r public.sword_state;
begin
  if uid is null then raise exception 'sw: login required'; end if;
  r := public._sw_lock(uid);
  if not r.inited then raise exception 'sw: not initialized'; end if;
  if p_slot = 'm' then
    if r.own then raise exception 'sw: already owned'; end if;
    update public.sword_state set own = true, lv = 0, aw = 0, updated_at = now() where user_id = uid returning * into r;
  elsif p_slot = 's' then
    if r.s_own then raise exception 'sw: already owned'; end if;
    update public.sword_state set s_own = true, s_lv = 0, s_aw = 0, updated_at = now() where user_id = uid returning * into r;
  else
    raise exception 'sw: bad slot';
  end if;
  return public._sw_json(r);
end $$;

-- 6) 메인 ↔ 보관함 교체 (두 검이 레벨·각성째로 서로 자리만 바뀐다. 새로 생기는 검은 없다) ---------------------
create or replace function public.sw_swap()
returns jsonb language plpgsql security definer set search_path = public as $$
declare uid text := auth.uid()::text; r public.sword_state;
begin
  if uid is null then raise exception 'sw: login required'; end if;
  r := public._sw_lock(uid);
  if not r.inited then raise exception 'sw: not initialized'; end if;
  if not r.own and not r.s_own then raise exception 'sw: nothing to swap'; end if;
  update public.sword_state
     set own = r.s_own, lv = case when r.s_own then r.s_lv else 0 end, aw = case when r.s_own then r.s_aw else 0 end,
         s_own = r.own, s_lv = case when r.own then r.lv else 0 end, s_aw = case when r.own then r.aw else 0 end,
         updated_at = now()
   where user_id = uid returning * into r;
  return public._sw_json(r);
end $$;

-- 7) 합성: 메인 +20 & 보관함 +20 → 메인 +21 (보관함은 빈다) ----------------------------------
create or replace function public.sw_fuse()
returns jsonb language plpgsql security definer set search_path = public as $$
declare uid text := auth.uid()::text; r public.sword_state;
begin
  if uid is null then raise exception 'sw: login required'; end if;
  r := public._sw_lock(uid);
  if not r.inited then raise exception 'sw: not initialized'; end if;
  if not (r.own and r.lv = 20 and r.s_own and r.s_lv = 20) then raise exception 'sw: fuse not allowed'; end if;
  update public.sword_state
     set lv = 21, aw = 0, s_own = false, s_lv = 0, s_aw = 0, best = greatest(best, 21), updated_at = now()
   where user_id = uid returning * into r;
  return public._sw_json(r);
end $$;

-- 8) 각성: 메인 +21 & 보관함 +20(제물) → 확률로 각성 +1. 제물은 성공/실패와 상관없이 사라진다 ------
create or replace function public.sw_awaken()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  rates constant int[] := array[100,100,100,100,100, 50,50,50,50,50, 30,30,30,30,30, 25,20,15,10,5];
  uid text := auth.uid()::text; r public.sword_state; ok boolean;
begin
  if uid is null then raise exception 'sw: login required'; end if;
  r := public._sw_lock(uid);
  if not r.inited then raise exception 'sw: not initialized'; end if;
  if not (r.own and r.lv = 21 and r.aw < 20 and r.s_own and r.s_lv = 20) then raise exception 'sw: awaken not allowed'; end if;
  ok := random() * 100 < rates[r.aw + 1];
  update public.sword_state
     set s_own = false, s_lv = 0, s_aw = 0,
         aw = case when ok then aw + 1 else aw end,
         best = greatest(best, case when ok then 21 + aw + 1 else 21 + aw end),
         updated_at = now()
   where user_id = uid returning * into r;
  return public._sw_json(r) || jsonb_build_object('r', case when ok then 1 else 0 end);
end $$;

-- 9) 강화 1회: r = 1 성공 / 2 유지 / 3 파괴 / 4 되돌리기로 파괴 막음, ub = 주문서 사용 여부 -----------
--    확률표는 index.html 의 SWORD_STAGES / SWORD_BOOST 와 같다.
--    강화 "비용(게임 속 돈)"은 클라이언트가 계산하는 값이라 서버가 검증하지 못한다 →
--    대신 분당/시간당 시도 횟수를 제한해서, 돈 조작으로 무한 강화하는 것을 막는다.
create or replace function public.sw_enhance(p_boost text default '', p_revive boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  c_per_min  constant int := 150;     -- 1분에 허용하는 강화 횟수
  c_per_hour constant int := 3000;    -- 1시간에 허용하는 강화 횟수
  s_succ constant numeric[] := array[100,95,90,85,80,75,70,65,60,55,50,45,40,35,30,25,20,15,10,5];
  s_mnt  constant numeric[] := array[99,2,5,8,11,14,17,20,23,26,29,32,35,38,41,44,47,50,53,56];
  s_des  constant numeric[] := array[1,3,5,7,9,11,13,15,17,19,21,23,25,27,29,31,33,35,37,39];
  uid text := auth.uid()::text; r public.sword_state; stage int;
  succ numeric; mnt numeric; des numeric; rem numeric; md numeric; mult numeric;
  used boolean := false; roll numeric; res int; w_start timestamptz; w_cnt int; h_start timestamptz; h_cnt int;
begin
  if uid is null then raise exception 'sw: login required'; end if;
  r := public._sw_lock(uid);
  if not r.inited then raise exception 'sw: not initialized'; end if;
  if not r.own then raise exception 'sw: no sword'; end if;
  if r.lv >= 20 then raise exception 'sw: max level'; end if;

  -- 시도 횟수 제한
  w_start := r.win_start; w_cnt := r.win_cnt; h_start := r.hr_start; h_cnt := r.hr_cnt;
  if now() - w_start >= interval '1 minute' then w_start := now(); w_cnt := 0; end if;
  if now() - h_start >= interval '1 hour'   then h_start := now(); h_cnt := 0; end if;
  if w_cnt >= c_per_min or h_cnt >= c_per_hour then raise exception 'sw: too fast'; end if;

  stage := r.lv + 1;
  succ := s_succ[stage]; mnt := s_mnt[stage]; des := s_des[stage];

  -- 주문서: 성공률이 100%인 단계에서는 쓰지 않는다(아이템 보존). 쓰면 성공률이 배수만큼 오르고 남는 확률은 유지:파괴 비율대로 나눈다.
  mult := case p_boost when 'x15' then 1.5 when 'x20' then 2 when 'x25' then 2.5 else null end;
  if mult is not null and succ < 100 then
    if (p_boost = 'x15' and r.b15 > 0) or (p_boost = 'x20' and r.b20 > 0) or (p_boost = 'x25' and r.b25 > 0) then
      used := true;
      succ := least(100, succ * mult);
      rem := greatest(0, 100 - succ);
      md := mnt + des;
      if md > 0 then mnt := rem * mnt / md; des := rem * des / md; else mnt := 0; des := 0; end if;
    end if;
  end if;

  roll := random() * 100;
  if roll < succ then
    res := 1;
    update public.sword_state set lv = lv + 1, best = greatest(best, lv + 1) where user_id = uid;
  elsif roll < succ + mnt then
    res := 2;
  elsif coalesce(p_revive, false) and r.rv > 0 then
    res := 4;
    update public.sword_state set rv = rv - 1 where user_id = uid;
  else
    res := 3;
    update public.sword_state set own = false, lv = 0, aw = 0 where user_id = uid;
  end if;

  update public.sword_state
     set b15 = b15 - case when used and p_boost = 'x15' then 1 else 0 end,
         b20 = b20 - case when used and p_boost = 'x20' then 1 else 0 end,
         b25 = b25 - case when used and p_boost = 'x25' then 1 else 0 end,
         win_start = w_start, win_cnt = w_cnt + 1, hr_start = h_start, hr_cnt = h_cnt + 1,
         updated_at = now()
   where user_id = uid returning * into r;
  return public._sw_json(r) || jsonb_build_object('r', res, 'ub', case when used then 1 else 0 end);
end $$;

-- 10) 무료로 얻는 되돌리기/주문서 (공허 드롭, 운명 카드, 시즌 우편 보상 같은 "클라이언트가 만드는" 지급) ----------
--     서버가 만들어 주는 지급(상점 구매·운영자 우편)과 달리 서버가 검증할 수 없으므로 "하루/한 달 상한"을 둔다.
--     p_src = 'd' (드롭 등, 하루 상한) / 'm' (시즌 우편 보상, 한 달 상한). 상한을 넘는 만큼은 조용히 버린다.
create or replace function public.sw_gain(p_rv int, p_b15 int, p_b20 int, p_b25 int, p_src text default 'd')
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  caps_d constant int[] := array[60, 60, 30, 15];   -- 하루 상한 [되돌리기, x1.5, x2, x2.5]
  caps_m constant int[] := array[60, 40, 40, 40];   -- 한 달 상한
  uid text := auth.uid()::text; r public.sword_state;
  add int[]; used int[]; caps int[]; got int[] := array[0,0,0,0]; i int;
  today date := (now() at time zone 'Asia/Seoul')::date;
  mon text := public._sw_season();
begin
  if uid is null then raise exception 'sw: login required'; end if;
  r := public._sw_lock(uid);
  if not r.inited then raise exception 'sw: not initialized'; end if;
  add := array[least(greatest(coalesce(p_rv,0),0),1000), least(greatest(coalesce(p_b15,0),0),1000),
               least(greatest(coalesce(p_b20,0),0),1000), least(greatest(coalesce(p_b25,0),0),1000)];
  if p_src = 'm' then
    caps := caps_m; used := case when r.gm = mon then r.gmn else array[0,0,0,0] end;
  else
    caps := caps_d; used := case when r.gd = today then r.gdn else array[0,0,0,0] end;
  end if;
  for i in 1..4 loop
    got[i] := least(add[i], greatest(caps[i] - used[i], 0));
    used[i] := used[i] + got[i];
  end loop;
  update public.sword_state
     set rv  = least(9999, rv  + got[1]), b15 = least(9999, b15 + got[2]),
         b20 = least(9999, b20 + got[3]), b25 = least(9999, b25 + got[4]),
         gd  = case when p_src = 'm' then gd  else today end, gdn = case when p_src = 'm' then gdn else used end,
         gm  = case when p_src = 'm' then mon else gm  end,  gmn = case when p_src = 'm' then used else gmn end,
         updated_at = now()
   where user_id = uid returning * into r;
  return public._sw_json(r);
end $$;

-- 11) 우편 수령: 서버가 만든 지급(상점 구매·운영자 우편)이 되돌리기/주문서면 서버가 바로 넣어 준다 --------------
--     (기존 admin_grants_claim 을 대체한다. 수령 1회 보장은 그대로)
create or replace function public.admin_grants_claim(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare uid text := auth.uid()::text; g public.admin_grants%rowtype; s public.sword_state; res jsonb;
begin
  if uid is null then return null; end if;
  update public.admin_grants set claimed_at = now()
   where id = p_id and user_id = uid and claimed_at is null and expires_at > now()
   returning * into g;
  if not found then return null; end if;
  res := jsonb_build_object('id', g.id, 'item', g.item, 'amount', g.amount);
  if g.item in ('revive', 'revive_floor', 'boost_x15', 'boost_x20', 'boost_x25') then
    s := public._sw_lock(uid);
    update public.sword_state
       set rv  = case g.item when 'revive' then least(9999, rv + g.amount)
                             when 'revive_floor' then greatest(rv, least(9999, g.amount)) else rv end,
           b15 = case when g.item = 'boost_x15' then least(9999, b15 + g.amount) else b15 end,
           b20 = case when g.item = 'boost_x20' then least(9999, b20 + g.amount) else b20 end,
           b25 = case when g.item = 'boost_x25' then least(9999, b25 + g.amount) else b25 end,
           updated_at = now()
     where user_id = uid returning * into s;
    res := res || jsonb_build_object('sw', public._sw_json(s));     -- 클라이언트는 이 값으로 보유량을 맞춘다(따로 더하지 않음)
  end if;
  return res;
end $$;
revoke all on function public.admin_grants_claim(uuid) from public, anon;
grant execute on function public.admin_grants_claim(uuid) to authenticated;

-- 12) 랭킹 값 상한: 서버가 인정한 검 단계(best)를 넘는 값은 랭킹에 못 올라간다 ------------------------
--     서버 검 데이터가 없는 계정은 +10강까지만 랭킹에 올릴 수 있다(새 index.html 접속 시 자동 등록).
create or replace function public.sword_state_cap()
returns trigger language plpgsql security definer set search_path = public as $$
declare p int; s public.sword_state%rowtype; cap int; c_free constant int := 10;
begin
  if NEW.board_key = 'leaderboard_sword' then
    p := NEW.sword_level;
  elsif NEW.board_key like 'leaderboard_sword_monthly_%' then
    p := (NEW.amount::text)::numeric::int;
  else
    return NEW;
  end if;
  if p is null or p <= 0 then return NEW; end if;
  select * into s from public.sword_state where user_id = NEW.user_id::text;
  if not found or not s.inited then cap := c_free;
  elsif s.season <> public._sw_season() then cap := 0;       -- 아직 새 시즌 첫 접속 전
  else cap := s.best;
  end if;
  if p > cap then raise exception 'sword_state_cap: 서버가 인정한 검 단계를 넘음 (% > %)', p, cap; end if;
  return NEW;
end $$;
drop trigger if exists trg_sword_state_cap on public.leaderboard_entries;
create trigger trg_sword_state_cap
  before insert or update on public.leaderboard_entries
  for each row execute function public.sword_state_cap();

-- 13) 권한: 앱(로그인한 유저)은 sw_* 함수만 호출 가능 ------------------------------------------
revoke all on function public._sw_season()                       from public, anon, authenticated;
revoke all on function public._sw_power(int, int)                from public, anon, authenticated;
revoke all on function public._sw_json(public.sword_state)       from public, anon, authenticated;
revoke all on function public._sw_lock(text)                     from public, anon, authenticated;
revoke all on function public.sword_state_cap()                  from public, anon, authenticated;
revoke all on function public.sw_get()                           from public, anon;
revoke all on function public.sw_init(boolean,int,int,boolean,int,int,int,int,int,int) from public, anon;
revoke all on function public.sw_craft(text)                     from public, anon;
revoke all on function public.sw_swap()                          from public, anon;
revoke all on function public.sw_fuse()                          from public, anon;
revoke all on function public.sw_awaken()                        from public, anon;
revoke all on function public.sw_enhance(text, boolean)          from public, anon;
revoke all on function public.sw_gain(int,int,int,int,text)      from public, anon;
grant execute on function public.sw_get()                        to authenticated;
grant execute on function public.sw_init(boolean,int,int,boolean,int,int,int,int,int,int) to authenticated;
grant execute on function public.sw_craft(text)                  to authenticated;
grant execute on function public.sw_swap()                       to authenticated;
grant execute on function public.sw_fuse()                       to authenticated;
grant execute on function public.sw_awaken()                     to authenticated;
grant execute on function public.sw_enhance(text, boolean)       to authenticated;
grant execute on function public.sw_gain(int,int,int,int,text)   to authenticated;

-- 14) 운영자 전용: 계정 값 직접 고치기 (앱에서는 호출 불가) -----------------------------------------
create or replace function public.admin_sw_set(
  p_user text, p_o boolean, p_l int, p_a int, p_so boolean, p_sl int,
  p_rv int default null, p_b15 int default null, p_b20 int default null, p_b25 int default null, p_sa int default 0)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r public.sword_state;
begin
  r := public._sw_lock(p_user);
  update public.sword_state
     set inited = true, own = p_o, lv = p_l, aw = case when p_l = 21 then p_a else 0 end, s_own = p_so, s_lv = p_sl, s_aw = case when p_sl = 21 then p_sa else 0 end,
         rv = coalesce(p_rv, rv), b15 = coalesce(p_b15, b15), b20 = coalesce(p_b20, b20), b25 = coalesce(p_b25, b25),
         best = greatest(best, public._sw_power(p_l, case when p_l = 21 then p_a else 0 end), public._sw_power(p_sl, case when p_sl = 21 then p_sa else 0 end)),
         updated_at = now()
   where user_id = p_user returning * into r;
  return public._sw_json(r);
end $$;
revoke all on function public.admin_sw_set(text,boolean,int,int,boolean,int,int,int,int,int,int) from public, anon, authenticated;

-- =====================================================================
-- 운영 방법
--  · 시작값이 깎인 계정 보기:   select * from public.sword_flags order by id desc limit 50;
--  · 내 검/아이템 보기:         select * from public.sword_state where user_id = '<user_id>';
--  · 값 직접 고치기(복구 등):   select public.admin_sw_set('<user_id>', true, 21, 3, false, 0, 10, 0, 0, 0, 0);
--                               (사용자, 보유, 메인강화, 각성, 보관함보유, 보관함강화, 되돌리기, x1.5, x2, x2.5, 보관함각성)
--  · 비정상 계정 찾기(참고):    select user_id, lv, aw, best, updated_at from public.sword_state order by best desc limit 30;
--  · 시도 제한/획득 상한 조정:  sw_enhance 의 c_per_min/c_per_hour, sw_gain 의 caps_d/caps_m 숫자만 바꿔서 다시 실행
-- =====================================================================
