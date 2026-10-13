-- =====================================================================
-- 스타터 패키지(3,000루비 · 시즌당 1회) + 검 배틀 횟수 상품 — Supabase SQL Editor 에서 한 번 실행 (이전 버전을 이미 실행했어도 다시 실행하면 최신으로 맞춰진다)
-- 먼저 supabase_admin_grants.sql / supabase_shop.sql / supabase_shop_update.sql / supabase_shop_shards_update.sql 이 적용돼 있어야 한다.
-- 바뀌는 것
--   0) 우편(admin_grants) 지급 종류에 'battle_tickets'(검 배틀 횟수) 추가
--   1) shop_items 에 season_limit(시즌 구매 한도), tiers(수량별 가격표) 컬럼 추가
--   2) shop_pack_contents(패키지 구성품) 테이블 추가 + 스타터 패키지 등록
--   3) shop_catalog : season_limit / bought_season / pack(구성품) / list_value(단품 정가 합계) 를 함께 내려준다
--   4) shop_buy     : 시즌 한도 검사 + 패키지는 구성품마다 우편(admin_grants)을 한 건씩 만들고 grant_ids 로 돌려준다
-- 기존 상품(되돌리기/주문서/차원 조각)은 동작이 그대로다. 같은 파일을 다시 실행해도 안전하다.
-- =====================================================================

-- 0) 우편 지급 종류에 검 배틀 횟수 추가
alter table public.admin_grants drop constraint if exists admin_grants_item_check;
alter table public.admin_grants add constraint admin_grants_item_check
  check (item in ('revive', 'revive_floor', 'boost_x15', 'boost_x20', 'boost_x25', 'void_shards', 'talent_points', 'battle_tickets'));

-- 1) 컬럼
alter table public.shop_items add column if not exists season_limit int;   -- 시즌(월, 한국 시간) 구매 한도. null 이면 제한 없음
alter table public.shop_items add column if not exists tiers jsonb;        -- 수량별 가격표 [{"qty":10,"price":80},...]. 있으면 이 수량으로만 살 수 있고 가격도 표대로

-- 2) 패키지 구성품
create table if not exists public.shop_pack_contents (
  pack_id      text not null,
  grant_item   text not null,                       -- admin_grants.item 과 같은 종류
  grant_amount int  not null check (grant_amount > 0),
  label        text not null,                       -- 유저에게 보이는 이름
  sort         int  not null default 0,
  primary key (pack_id, grant_item)
);
alter table public.shop_pack_contents enable row level security;
revoke all on public.shop_pack_contents from anon, authenticated;

-- 검 배틀 횟수 (단가 8루비 → 많이 살수록 싸짐: 10회 80 / 30회 210 / 50회 300 / 100회 500). 게임 쪽 보관 한도(SWORD_BATTLE_BANK_CAP)는 1,000회.
--   주간 구매 한도는 두지 않는다(null). 배틀은 내 승점만 바뀌고 상대 점수는 건드리지 않기 때문. 상한을 두려면 아래 update 에서 숫자로.
insert into public.shop_items (id, name, descr, category, price, grant_item, grant_amount, weekly_limit, season_limit, max_qty, tiers, sort)
values ('battle_tickets', '검 배틀 횟수', '검 배틀 참여 횟수를 충전해요 (최대 1,000회까지 보관)', 'item', 8, 'battle_tickets', 1, null, null, 100,
        '[{"qty":10,"price":80},{"qty":30,"price":210},{"qty":50,"price":300},{"qty":100,"price":500}]'::jsonb, 45)
on conflict (id) do update
   set name = excluded.name, descr = excluded.descr, price = excluded.price, grant_item = excluded.grant_item,
       grant_amount = excluded.grant_amount, weekly_limit = excluded.weekly_limit, max_qty = excluded.max_qty,
       tiers = excluded.tiers, sort = excluded.sort, active = true;

-- 스타터 패키지 (단품 정가 합계 약 4,310루비 → 3,000루비 = 약 30% 할인)
insert into public.shop_items (id, name, descr, category, price, grant_item, grant_amount, weekly_limit, season_limit, max_qty, sort)
values ('starter_pack', '스타터 패키지', '시즌마다 1회 한정 · 단품보다 훨씬 저렴해요', 'pack', 3000, 'starter_pack', 1, null, 1, 1, 5)
on conflict (id) do update
   set name = excluded.name, descr = excluded.descr, category = excluded.category, price = excluded.price,
       grant_item = excluded.grant_item, grant_amount = excluded.grant_amount, weekly_limit = excluded.weekly_limit,
       season_limit = excluded.season_limit, max_qty = excluded.max_qty, sort = excluded.sort, active = true;

delete from public.shop_pack_contents where pack_id = 'starter_pack';
insert into public.shop_pack_contents (pack_id, grant_item, grant_amount, label, sort) values
  ('starter_pack', 'boost_x15',      30,    '강화 주문서 ×1.5', 10),
  ('starter_pack', 'boost_x20',       8,    '강화 주문서 ×2',   20),
  ('starter_pack', 'boost_x25',       4,    '강화 주문서 ×2.5', 30),
  ('starter_pack', 'revive',         15,    '되돌리기',         40),
  ('starter_pack', 'battle_tickets', 20,    '검 배틀 횟수',     45),
  ('starter_pack', 'void_shards',  30000,   '차원 조각',        50);
-- (덤으로 특성 포인트를 넣고 싶으면:  insert into public.shop_pack_contents values ('starter_pack','talent_points',3,'특성 포인트',60);  ← 정가 합계에는 안 들어간다)

-- 3) 카탈로그
create or replace function public.shop_catalog()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  uid text := auth.uid()::text;
  wk timestamptz := date_trunc('week',  now() at time zone 'Asia/Seoul') at time zone 'Asia/Seoul';
  sk timestamptz := date_trunc('month', now() at time zone 'Asia/Seoul') at time zone 'Asia/Seoul';
  bal int; res jsonb;
begin
  if uid is null then return jsonb_build_object('error', 'login'); end if;
  select ruby into bal from public.wallets where user_id = uid;
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', i.id, 'name', i.name, 'desc', i.descr, 'category', i.category, 'price', i.price,
           'grant_item', i.grant_item, 'grant_amount', i.grant_amount, 'weekly_limit', i.weekly_limit, 'max_qty', i.max_qty,
           'bundle_qty', i.bundle_qty, 'bundle_discount', i.bundle_discount,
           'bought_week', coalesce((select sum(p.qty) from public.shop_purchases p where p.user_id = uid and p.item_id = i.id and p.created_at >= wk), 0),
           'season_limit', i.season_limit, 'tiers', i.tiers,
           'bought_season', coalesce((select sum(p.qty) from public.shop_purchases p where p.user_id = uid and p.item_id = i.id and p.created_at >= sk), 0),
           'pack', (select jsonb_agg(jsonb_build_object('item', c.grant_item, 'amount', c.grant_amount, 'label', c.label) order by c.sort)
                      from public.shop_pack_contents c where c.pack_id = i.id),
           -- 구성품을 전부 단품으로 샀을 때의 정가 합계 (같은 grant_item 의 일반 상품 가격 기준, 묶음 할인 제외)
           'list_value', (select ceil(sum(s.price::numeric * c.grant_amount / s.grant_amount))::int
                            from public.shop_pack_contents c
                            join public.shop_items s on s.grant_item = c.grant_item and s.category <> 'pack' and s.active
                           where c.pack_id = i.id)
         ) order by i.sort, i.id), '[]'::jsonb)
    into res from public.shop_items i where i.active;
  return jsonb_build_object('ruby', coalesce(bal, 0), 'items', res);
end $$;

-- 4) 구매
create or replace function public.shop_buy(p_item text, p_qty int default 1)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  uid text := auth.uid()::text;
  it public.shop_items%rowtype; w public.wallets%rowtype; c record;
  wk timestamptz := date_trunc('week',  now() at time zone 'Asia/Seoul') at time zone 'Asia/Seoul';
  sk timestamptz := date_trunc('month', now() at time zone 'Asia/Seoul') at time zone 'Asia/Seoul';
  bought int; bought_s int; total int; tier_price int; gid uuid; gids uuid[] := '{}';
begin
  if uid is null then raise exception 'shop: login required'; end if;
  if p_qty is null or p_qty < 1 then raise exception 'shop: bad quantity'; end if;
  select * into it from public.shop_items where id = p_item and active;
  if not found then raise exception 'shop: unknown item'; end if;
  if p_qty > it.max_qty then raise exception 'shop: quantity too large'; end if;
  insert into public.wallets (user_id) values (uid) on conflict do nothing;
  select * into w from public.wallets where user_id = uid for update;     -- 같은 사람의 동시 구매를 한 줄로 세운다 (시즌 1회 제한도 이 잠금으로 안전)
  if it.weekly_limit is not null then
    select coalesce(sum(qty), 0) into bought from public.shop_purchases where user_id = uid and item_id = it.id and created_at >= wk;
    if bought + p_qty > it.weekly_limit then raise exception 'shop: weekly limit (% of %)', bought, it.weekly_limit; end if;
  end if;
  if it.season_limit is not null then
    select coalesce(sum(qty), 0) into bought_s from public.shop_purchases where user_id = uid and item_id = it.id and created_at >= sk;
    if bought_s + p_qty > it.season_limit then raise exception 'shop: season limit (% of %)', bought_s, it.season_limit; end if;
  end if;
  if it.tiers is not null then
    -- 수량별 가격표가 있는 상품: 표에 있는 수량으로만 살 수 있고, 가격도 표대로
    select (t->>'price')::int into tier_price from jsonb_array_elements(it.tiers) t where (t->>'qty')::int = p_qty;
    if tier_price is null then raise exception 'shop: bad quantity'; end if;
    total := tier_price;
  else
    total := case when p_qty >= it.bundle_qty then ceil(it.price::numeric * p_qty * (100 - it.bundle_discount) / 100)::int else it.price * p_qty end;
  end if;
  if w.ruby < total then raise exception 'shop: not enough ruby'; end if;
  update public.wallets set ruby = ruby - total, updated_at = now() where user_id = uid;
  insert into public.ruby_ledger (user_id, delta, reason) values (uid, -total, 'buy:' || it.id || ' x' || p_qty);
  insert into public.shop_purchases (user_id, item_id, qty, price_total) values (uid, it.id, p_qty, total);

  if exists (select 1 from public.shop_pack_contents where pack_id = it.id) then
    -- 패키지: 구성품마다 우편 1건 (우편 1건 = 보상 1종류)
    for c in select * from public.shop_pack_contents where pack_id = it.id order by sort loop
      insert into public.admin_grants (user_id, item, amount, title, gift_name, message, note, expires_at)
      values (uid, c.grant_item, c.grant_amount * p_qty, left('🎁 ' || it.name, 40), left(c.label || ' ×' || (c.grant_amount * p_qty), 40),
              '구매해 주셔서 감사합니다!', 'shop:' || it.id, now() + interval '365 days')
      returning id into gid;
      gids := gids || gid;
    end loop;
  else
    insert into public.admin_grants (user_id, item, amount, title, gift_name, message, note, expires_at)
    values (uid, it.grant_item, it.grant_amount * p_qty, '🛒 상점 구매', left(it.name || ' ×' || p_qty, 40), '구매해 주셔서 감사합니다!', 'shop:' || it.id, now() + interval '365 days')
    returning id into gid;
    gids := array[gid];
  end if;
  return jsonb_build_object('ok', true, 'ruby', w.ruby - total, 'grant_id', gids[1], 'grant_ids', to_jsonb(gids));
end $$;

revoke all on function public.shop_catalog() from public;
revoke all on function public.shop_buy(text, int) from public;
grant execute on function public.shop_catalog() to authenticated;
grant execute on function public.shop_buy(text, int) to authenticated;

-- 확인용:
--   select id, name, price, weekly_limit, season_limit, max_qty, tiers from public.shop_items order by sort;
--   select * from public.shop_pack_contents where pack_id = 'starter_pack' order by sort;
--   (테스트) select public.admin_add_ruby('<user_id>', 3000, '스타터 테스트');
--   (테스트 후 다시 사게 하려면)  delete from public.shop_purchases where user_id = '<user_id>' and item_id = 'starter_pack';
-- 배틀 횟수 주간 한도 바꾸기:  update public.shop_items set weekly_limit = 300 where id = 'battle_tickets';  -- 주간 구매 한도 걸기 (null 이면 무제한)
-- 가격/구성 바꾸기:  update public.shop_items set price = 2800 where id = 'starter_pack';
--                    update public.shop_pack_contents set grant_amount = 10 where pack_id = 'starter_pack' and grant_item = 'revive';
