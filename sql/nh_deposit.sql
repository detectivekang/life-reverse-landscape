-- =====================================================================
-- 인생역전 돈 -> 네온 호드 골드 환전 (1조 = 1골드, 1경 = 1만 골드)
--   Supabase SQL Editor에서 "한 번에 전체" 실행. 여러 번 실행해도 안전하다.
-- 전제: nh_collab.sql 이 이미 적용되어 있어야 한다 (nh_is_banned 사용).
--
-- 흐름
--   1) 인생역전(nh-exchange.js)이 nh_deposit(골드)를 부르면 서버가 "오늘 한도" 안에서 입금 기록을 만든다.
--   2) 인생역전은 서버가 OK 를 준 다음에만 돈을 깎는다.
--   3) 네온 호드가 메뉴에서 nh_claim_deposits()를 불러 쌓인 입금을 한 번에 받아 meta.gold 에 더한다.
-- 주의
--   · 인생역전의 돈은 클라이언트 값이라 서버가 진짜인지 검증할 수 없다. 그래서 "하루 한도"가 유일한 방어선이다.
--   · 이 골드는 호드 안에서 쓰는 골드(영구 강화·해금 등)로만 들어간다.
--     서버 지갑(nh_wallet, 환전 가능 골드)에는 들어가지 않아서 유료템(되돌리기·주문서 등)을 살 수 없다.
-- 튜닝: 하루 한도 c_cap(골드)은 nh_deposit_info 와 nh_deposit 두 함수에 있다. 둘을 같은 값으로 바꿔야 한다.
-- 하루 기준은 한국시간 0시.
-- =====================================================================

create table if not exists public.nh_deposits (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references auth.users(id) on delete cascade,
  gold       int  not null check (gold > 0),
  day        date not null,
  created_at timestamptz not null default now(),
  claimed_at timestamptz
);
create index if not exists nh_deposits_user_claim_idx on public.nh_deposits (user_id, claimed_at);
create index if not exists nh_deposits_user_day_idx   on public.nh_deposits (user_id, day);
alter table public.nh_deposits enable row level security;
revoke all on public.nh_deposits from anon, authenticated;

-- 오늘 얼마나 입금했고 얼마나 남았는지
create or replace function public.nh_deposit_info()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  c_cap constant int := 50000;   -- 하루 최대 입금 골드 (50,000골드 = 인생역전 돈 5경: 1조=1골드, 1경=1만골드)
  uid uuid := auth.uid();
  today date := (now() at time zone 'Asia/Seoul')::date;
  used int;
begin
  if uid is null then return jsonb_build_object('ok', false, 'error', 'NH_LOGIN'); end if;
  select coalesce(sum(gold), 0)::int into used from public.nh_deposits where user_id = uid and day = today;
  return jsonb_build_object('ok', true, 'cap', c_cap, 'used', used, 'left', greatest(c_cap - used, 0));
end $$;

-- 입금 (한도 초과면 NH_LIMIT)
create or replace function public.nh_deposit(p_gold int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  c_cap constant int := 50000;
  uid uuid := auth.uid();
  today date := (now() at time zone 'Asia/Seoul')::date;
  used int;
begin
  if uid is null then raise exception 'NH_LOGIN'; end if;
  if public.nh_is_banned(uid::text) then raise exception 'NH_BANNED'; end if;
  if p_gold is null or p_gold < 1 or p_gold > c_cap then raise exception 'NH_BAD_AMOUNT'; end if;

  perform pg_advisory_xact_lock(hashtext('nh_deposit:' || uid::text));   -- 동시에 여러 번 눌러도 한도를 못 넘게
  select coalesce(sum(gold), 0)::int into used from public.nh_deposits where user_id = uid and day = today;
  if used + p_gold > c_cap then raise exception 'NH_LIMIT'; end if;

  insert into public.nh_deposits (user_id, gold, day) values (uid, p_gold, today);
  return jsonb_build_object('ok', true, 'gold', p_gold, 'left', c_cap - used - p_gold);
end $$;

-- 네온 호드가 쌓인 입금을 받아간다 (받은 건은 claimed_at 이 찍혀서 두 번 받을 수 없다)
create or replace function public.nh_claim_deposits()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  total bigint;
begin
  if uid is null then return jsonb_build_object('ok', false, 'error', 'NH_LOGIN'); end if;
  with c as (
    update public.nh_deposits set claimed_at = now()
     where user_id = uid and claimed_at is null
     returning gold
  )
  select coalesce(sum(gold), 0) into total from c;
  return jsonb_build_object('ok', true, 'gold', total);
end $$;

revoke all on function public.nh_deposit_info()    from public, anon;
revoke all on function public.nh_deposit(int)      from public, anon;
revoke all on function public.nh_claim_deposits()  from public, anon;
grant execute on function public.nh_deposit_info()   to authenticated;
grant execute on function public.nh_deposit(int)     to authenticated;
grant execute on function public.nh_claim_deposits() to authenticated;

-- ---------------------------------------------------------------------
-- 점검용 쿼리 (필요할 때만 실행)
--   오늘 입금 현황:  select user_id, sum(gold) from nh_deposits where day = (now() at time zone 'Asia/Seoul')::date group by 1 order by 2 desc;
--   아직 안 받은 건:  select user_id, sum(gold) from nh_deposits where claimed_at is null group by 1;
-- =====================================================================
