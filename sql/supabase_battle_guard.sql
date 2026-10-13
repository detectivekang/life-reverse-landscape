-- =====================================================================
-- 검 배틀 승점 조작 방지 (Supabase SQL Editor에서 실행)
-- 먼저 supabase_shop.sql / supabase_shop_starter_pack.sql 이 실행되어 있어야 한다 (shop_purchases, shop_pack_contents 를 읽는다).
-- 아이디어
--   · 배틀 1회 = 승점 최대 ±5. 그래서 "승점이 오른 만큼 / 5" 이하의 배틀 횟수가 있었어야 한다.
--   · 서버가 "이 사람이 쓸 수 있었던 배틀 횟수"를 장부(예산)로 따로 센다:
--       자연 충전   : 6분에 1회씩 쌓임 (공허 주문서로 얻는 횟수까지 넉넉히 봐서 최대 200회까지만 쌓임)
--       유료 구매   : shop_purchases 에서 읽음 (검 배틀 횟수 상품 + 스타터 패키지에 들어 있는 횟수)
--   · 승점이 장부보다 빨리 오르면 에러를 내지 않고 "가능한 만큼만" 올려서 저장한다 (클램프).
--     → 정상 유저의 동기화가 실패해서 다른 랭킹(카지노 등)까지 같이 안 올라가는 일이 없다.
--   · 승점이 내려가면(패배) 그만큼 횟수를 쓴 걸로 장부에서 뺀다.
-- 대상: leaderboard_entries 의 'leaderboard_sword_battle_<월>' (검배틀 월간 승점판)
-- ※ 기존 ranking_guard / sword_progress_guard 와 별개 트리거라 서로 충돌하지 않는다.
-- ※ 튜닝은 함수 맨 위 constant 만 바꾸면 된다.
-- =====================================================================

-- 1) 서버가 인정한 승점/장부 (앱은 접근 불가)
create table if not exists public.battle_guard (
  user_id   text not null,
  board_key text not null,
  pts       int  not null default -1,        -- 서버가 인정한 승점 (-1 = 이 시즌 첫 기록 전)
  nat       numeric not null default 0,      -- 자연 충전으로 쓸 수 있는 횟수
  paid      numeric not null default 0,      -- 유료로 산 횟수 중 아직 안 쓴 것
  at        timestamptz not null default now(),
  primary key (user_id, board_key)
);
alter table public.battle_guard enable row level security;
revoke all on public.battle_guard from anon, authenticated;

-- 2) 검증 함수
create or replace function public.battle_points_guard()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  c_sec      constant int := 360;    -- 자연 충전: N초에 1회
  c_nat_cap  constant int := 200;    -- 자연 충전분(+공허 주문서 등)으로 쌓일 수 있는 최대 횟수
  c_first    constant int := 60;     -- 이 시즌에 처음 기록될 때 기본으로 인정하는 횟수
  c_paid_cap constant int := 1500;   -- 유료 장부 상한 (게임 쪽 보관 한도 1000 + 여유)
  uid text; p int; p0 int; g public.battle_guard%rowtype; is_first boolean;
  since timestamptz; v_nat numeric; v_paid numeric; bought numeric; need int; use_nat numeric;
begin
  if NEW.board_key is null or NEW.board_key not like 'leaderboard_sword_battle_%' then
    return NEW;                                  -- 배틀 승점판이 아니면 건드리지 않는다
  end if;
  begin
    p := floor((NEW.amount::text)::numeric)::int;
  exception when others then
    raise exception 'battle_guard: 잘못된 값';
  end;
  if p is null or p < 0 then raise exception 'battle_guard: 잘못된 값 (%)', p; end if;
  p0 := p;
  uid := NEW.user_id::text;

  insert into public.battle_guard(user_id, board_key, pts, nat, paid, at)
  values (uid, NEW.board_key, -1, 0, 0, now())
  on conflict do nothing;
  select * into g from public.battle_guard where user_id = uid and board_key = NEW.board_key for update;

  is_first := (g.pts = -1);
  if is_first then
    -- 이 시즌 첫 기록: 기본 횟수 + 최근 90일 동안 산 횟수(안 쓰고 모아둔 것 포함)까지 인정
    since := now() - interval '90 days';
    v_nat := c_first;
    g.pts := 0;
    g.paid := 0;
  else
    since := g.at;
    v_nat := least(c_nat_cap, g.nat + extract(epoch from (now() - g.at)) / c_sec);
  end if;

  select coalesce(sum(q), 0) into bought from (
    select p2.qty::numeric as q from public.shop_purchases p2
     where p2.user_id = uid and p2.item_id = 'battle_tickets' and p2.created_at > since
    union all
    select p2.qty::numeric * c.grant_amount from public.shop_purchases p2
      join public.shop_pack_contents c on c.pack_id = p2.item_id and c.grant_item = 'battle_tickets'
     where p2.user_id = uid and p2.created_at > since
  ) t;
  v_paid := least(c_paid_cap, g.paid + bought);

  if p > g.pts then
    need := ceil((p - g.pts) / 5.0)::int;        -- 이만큼의 배틀 횟수가 필요하다
    if need > floor(v_nat + v_paid) then             -- 장부보다 빨리 올랐다 → 가능한 만큼만 인정
      need := floor(v_nat + v_paid)::int;
      p := g.pts + need * 5;
    end if;
  else
    need := ceil((g.pts - p) / 5.0)::int;        -- 패배로 내려간 만큼도 횟수를 쓴 것
  end if;
  use_nat := least(v_nat, need);
  v_nat := v_nat - use_nat;
  v_paid := greatest(0, v_paid - (need - use_nat));

  update public.battle_guard set pts = p, nat = v_nat, paid = v_paid, at = now()
   where user_id = uid and board_key = NEW.board_key;

  if p <> p0 then
    NEW := jsonb_populate_record(NEW, jsonb_build_object('amount', p));   -- amount 컬럼 타입에 맞춰 낮춘 값으로 바꿔 저장
  end if;
  return NEW;
end;
$$;

-- =====================================================================
-- 3) 적용 순서 (중요!)
--   ① 조작이 의심되는 계정이 있으면 먼저 기록을 지운다 (user_id는 아래 조회로 확인)
--        select user_id, board_key, name, amount, updated_at
--          from public.leaderboard_entries
--         where board_key like 'leaderboard_sword_battle_%'
--         order by (amount::text)::numeric desc nulls last limit 20;
--        delete from public.leaderboard_entries
--         where user_id = '<조작 계정 user_id>' and board_key like 'leaderboard_sword_battle_%';
--   ② 지금 정상 유저들의 현재 승점을 기준선으로 등록한다 (※ ①을 끝낸 뒤에 실행)
--        insert into public.battle_guard(user_id, board_key, pts, nat, paid, at)
--        select user_id::text, board_key, floor((amount::text)::numeric)::int, 60, 0, now() - interval '1 day'
--          from public.leaderboard_entries
--         where board_key like 'leaderboard_sword_battle_%'
--           and (amount::text) ~ '^[0-9]+(\.[0-9]+)?$'
--        on conflict do nothing;
--   ③ 위 1)·2) 를 실행하고 아래 트리거를 만든다
--   ④ 확인:  select * from public.battle_guard order by pts desc limit 20;
-- 되돌리기:  drop trigger trg_battle_points_guard on public.leaderboard_entries;
-- =====================================================================
drop trigger if exists trg_battle_points_guard on public.leaderboard_entries;
create trigger trg_battle_points_guard
  before insert or update on public.leaderboard_entries
  for each row execute function public.battle_points_guard();
