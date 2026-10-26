-- =====================================================================
-- 네온 호드 "오늘의 상점" (Supabase SQL Editor에서 "한 번에 전체" 실행)
--   서버가 인정한 골드(nh_wallet)로 하루 한도가 있는 상품을 사고, 인생역전 우편함(admin_grants)으로 받는다.
-- 전제: nh_collab.sql 이 이미 적용되어 있어야 한다. 여러 번 실행해도 안전하다.
--
-- ★ 실행 전에 꼭 확인할 것 (아래 nh_buy 맨 위 "우편 item 코드")
--   · 차원 조각은 nh_exchange 에서 쓰던 'void_shards' 라서 바로 동작한다.
--   · 되돌리기 / 강화 주문서(x1.5, x2, x2.5)는 admin_grants_claim 이 받아 주는 item 코드를 몰라서
--     null 로 비워 뒀다. null 인 상품은 'NH_ITEM_UNAVAILABLE' 오류로 막히므로 골드가 빠지지 않는다.
--     올바른 코드를 채운 뒤 다시 실행하면 그 상품이 열린다.
-- 튜닝: 가격 / 하루 한도 / 지급 수량은 nh_buy 의 case 문에서만 바꾸면 된다.
--       (네온 호드 화면의 가격·한도 표시는 index.html 의 OFFERS 와 같은 값으로 맞출 것)
-- 하루 기준은 한국시간 0시.
-- =====================================================================

-- 1. 오늘 산 개수 기록 (앱은 접근 불가, 함수로만 다룬다)
create table if not exists public.nh_shop_daily (
  user_id uuid not null references auth.users(id) on delete cascade,
  day     date not null,
  item    text not null,
  qty     int  not null default 0,
  primary key (user_id, day, item)
);
alter table public.nh_shop_daily enable row level security;
revoke all on public.nh_shop_daily from anon, authenticated;

-- 2. 구매
create or replace function public.nh_buy(p_item text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  -- ===== 우편 item 코드 (null = 아직 미확인, 구매 막힘) =====
  c_item_undo constant text := 'revive';      -- 되돌리기
  c_item_s15  constant text := 'boost_x15';   -- 강화 주문서 x1.5
  c_item_s2   constant text := 'boost_x20';   -- 강화 주문서 x2
  c_item_s25  constant text := 'boost_x25';   -- 강화 주문서 x2.5
  -- ===== 우편 한 건당 최대 수량 =====
  c_chunk     constant int  := 5000;
  -- ==========================================================
  uid uuid := auth.uid(); w public.nh_wallet%rowtype;
  today date := (now() at time zone 'Asia/Seoul')::date;
  price bigint; lim int; g_item text; amt int; gname text;
  bought int; left_ int; chunk int; sh jsonb;
begin
  if uid is null then raise exception 'NH_LOGIN'; end if;
  if public.nh_is_banned(uid::text) then raise exception 'NH_BANNED'; end if;

  -- 상품표: 가격(골드) / 하루 한도 / 우편 item / 지급 수량 / 우편 이름
  case p_item
    when 'shard' then price := 10000; lim := 1; g_item := 'void_shards'; amt := 10000; gname := null;
    when 'undo'  then price := 5000;  lim := 2; g_item := c_item_undo;   amt := 1;     gname := '되돌리기 1개';
    when 's15'   then price := 5000;  lim := 1; g_item := c_item_s15;    amt := 1;     gname := '강화 주문서 x1.5';
    when 's2'    then price := 10000; lim := 1; g_item := c_item_s2;     amt := 1;     gname := '강화 주문서 x2';
    when 's25'   then price := 20000; lim := 1; g_item := c_item_s25;    amt := 1;     gname := '강화 주문서 x2.5';
    when 'bt'    then price := 500;   lim := 10; g_item := 'battle_tickets'; amt := 1;   gname := '검 배틀 1회';
    else raise exception 'NH_BAD_ITEM';
  end case;
  if g_item is null then raise exception 'NH_ITEM_UNAVAILABLE'; end if;

  -- 같은 계정의 동시 구매를 한 줄로 세운다
  select * into w from public.nh_wallet where user_id = uid for update;
  if not found then raise exception 'NH_NOT_ENOUGH'; end if;

  select d.qty into bought from public.nh_shop_daily d where d.user_id = uid and d.day = today and d.item = p_item;
  bought := coalesce(bought, 0);
  if bought >= lim then raise exception 'NH_DAILY_LIMIT'; end if;
  if w.earned_gold - w.exchanged_gold < price then raise exception 'NH_NOT_ENOUGH'; end if;

  update public.nh_wallet set exchanged_gold = exchanged_gold + price, updated_at = now() where user_id = uid;
  insert into public.nh_shop_daily as d (user_id, day, item, qty) values (uid, today, p_item, 1)
    on conflict (user_id, day, item) do update set qty = d.qty + 1;

  left_ := amt;
  while left_ > 0 loop
    chunk := least(left_, c_chunk);
    insert into public.admin_grants (user_id, item, amount, title, gift_name, message, note, expires_at)
    values (uid::text, g_item, chunk, '🛸 네온 호드 상점',
            coalesce(gname, '차원 조각 ' || chunk || '개'),
            '네온 호드 상점에서 골드로 구매했어요.', 'nh_buy:' || p_item, now() + interval '90 days');
    left_ := left_ - chunk;
  end loop;

  select coalesce(jsonb_object_agg(d.item, d.qty), '{}'::jsonb) into sh
    from public.nh_shop_daily d where d.user_id = uid and d.day = today;
  return jsonb_build_object('ok', true, 'item', p_item, 'gold', price,
    'exchangeable', w.earned_gold - w.exchanged_gold - price, 'bought', sh);
end $$;
revoke all on function public.nh_buy(text) from public, anon;
grant execute on function public.nh_buy(text) to authenticated;

-- 3. 화면 표시용 현황에 "오늘 산 개수(shop)" 추가
create or replace function public.nh_wallet_info()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  c_rate constant numeric := 1; c_daily_cap constant bigint := 5000;
  uid uuid := auth.uid(); w public.nh_wallet%rowtype; today date := (now() at time zone 'Asia/Seoul')::date;
  used bigint := 0; sh jsonb;
begin
  if uid is null then return jsonb_build_object('ok', false); end if;
  select * into w from public.nh_wallet where user_id = uid;
  if found and w.ex_day = today then used := w.ex_day_gold; end if;
  select coalesce(jsonb_object_agg(d.item, d.qty), '{}'::jsonb) into sh
    from public.nh_shop_daily d where d.user_id = uid and d.day = today;
  return jsonb_build_object('ok', true, 'rate', c_rate, 'daily_cap', c_daily_cap,
    'day_used', used, 'day_left', greatest(c_daily_cap - used, 0),
    'exchangeable', coalesce(w.earned_gold - w.exchanged_gold, 0),
    'season', public.nh_season_key(), 'shop', sh);
end $$;
revoke all on function public.nh_wallet_info() from public, anon;
grant execute on function public.nh_wallet_info() to authenticated;

-- 4. 예전 자유 금액 환전(nh_exchange) 닫기
--    상점의 "차원 조각 10,000개"와 겹쳐 하루에 조각을 이중으로 받는 걸 막는다.
--    (되살리고 싶으면: grant execute on function public.nh_exchange(int) to authenticated;)
revoke execute on function public.nh_exchange(int) from authenticated;

-- ---------------------------------------------------------------------
-- 점검용 쿼리 (필요할 때만 실행)
--   상점 구매 내역:  select user_id, item, amount, note, created_at from admin_grants where note like 'nh_buy:%' order by created_at desc;
--   오늘 구매 현황:  select * from nh_shop_daily where day = (now() at time zone 'Asia/Seoul')::date;
-- =====================================================================
