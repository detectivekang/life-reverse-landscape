-- =====================================================================
-- 상점(루비) — Supabase SQL Editor에서 실행 (supabase_admin_grants.sql 을 먼저 실행해 두세요)
-- 구조
--   · 루비 잔액/내역/상품/구매기록은 전부 서버 테이블. 앱(브라우저)은 아래 함수(RPC)로만 접근한다.
--   · 가격·지급량·주간 한도는 서버가 정한다 → 클라이언트가 값을 조작해도 소용없다.
--   · 구매하면 admin_grants(우편함)에 지급이 생기고, 게임이 바로 받아서 반영한다.
--   · 루비 충전은 아래 admin_add_ruby() 로 운영자가 직접 넣거나(테스트/이벤트),
--     나중에 결제 서버 함수(웹훅)가 같은 함수를 호출하도록 연결한다.
-- =====================================================================

-- 1) 테이블
create table if not exists public.wallets (
  user_id       text primary key,
  ruby          int  not null default 0 check (ruby >= 0),
  total_charged int  not null default 0,          -- 지금까지 충전한 루비 합계
  updated_at    timestamptz not null default now()
);
create table if not exists public.ruby_ledger (    -- 루비가 들어오고 나간 모든 내역
  id         bigserial primary key,
  user_id    text not null,
  delta      int  not null,                        -- +충전/지급, -사용
  reason     text not null,
  ref        text unique,                          -- 결제번호 등: 같은 번호로 두 번 충전되지 않게
  created_at timestamptz not null default now()
);
create index if not exists ruby_ledger_user_idx on public.ruby_ledger (user_id, created_at desc);
create table if not exists public.shop_items (
  id           text primary key,
  name         text not null,
  descr        text,
  category     text not null default 'item',
  price        int  not null check (price > 0),    -- 루비
  grant_item   text not null,                      -- admin_grants.item 과 같은 종류
  grant_amount int  not null check (grant_amount > 0),
  weekly_limit int,                                -- 주간(월요일 0시, 한국 시간 기준) 구매 한도. null 이면 무제한
  max_qty      int  not null default 10,           -- 한 번에 살 수 있는 최대 수량
  bundle_qty      int not null default 10,        -- 이 수량 이상 사면 묶음 할인
  bundle_discount int not null default 5 check (bundle_discount between 0 and 50),   -- 묶음 할인율(%) : 10개를 9.5개 값으로
  active       boolean not null default true,
  sort         int  not null default 0
);
create table if not exists public.shop_purchases (
  id          bigserial primary key,
  user_id     text not null,
  item_id     text not null,
  qty         int  not null,
  price_total int  not null,
  created_at  timestamptz not null default now()
);
create index if not exists shop_purchases_user_idx on public.shop_purchases (user_id, item_id, created_at desc);
alter table public.wallets enable row level security;        revoke all on public.wallets from anon, authenticated;
alter table public.ruby_ledger enable row level security;    revoke all on public.ruby_ledger from anon, authenticated;
alter table public.shop_items enable row level security;     revoke all on public.shop_items from anon, authenticated;
alter table public.shop_purchases enable row level security; revoke all on public.shop_purchases from anon, authenticated;

-- 우편 지급 수량 상한을 늘린다 (차원 조각 같은 큰 수량 때문)
alter table public.admin_grants drop constraint if exists admin_grants_amount_check;
alter table public.admin_grants add constraint admin_grants_amount_check check (amount between 1 and 1000000);

-- 2) 기본 상품 (가격/한도는 나중에 update 로 자유롭게 조정)
insert into public.shop_items (id, name, descr, category, price, grant_item, grant_amount, weekly_limit, max_qty, sort) values
  ('revive',     '되돌리기',            '검 강화 실패로 파괴될 때 막아 줘요',        'item',  50, 'revive',      1,     30, 10, 10),
  ('boost_x15',  '강화 주문서 ×1.5',    '다음 강화 1회 성공률 ×1.5',                  'item',  40, 'boost_x15',   1,     20, 10, 20),
  ('boost_x20',  '강화 주문서 ×2',      '다음 강화 1회 성공률 ×2',                    'item', 100, 'boost_x20',   1,     10, 10, 30),
  ('boost_x25',  '강화 주문서 ×2.5',    '다음 강화 1회 성공률 ×2.5',                  'item', 200, 'boost_x25',   1,      5, 10, 40),
  ('shards20k',  '차원 조각 20,000개',  '공허 상점 강화에 쓰는 조각',                 'item', 100, 'void_shards', 20000,  5,  5, 50)
on conflict (id) do nothing;

-- 3) 카탈로그 + 내 루비 잔액 + 이번 주 구매량
create or replace function public.shop_catalog()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  uid text := auth.uid()::text;
  wk timestamptz := date_trunc('week', now() at time zone 'Asia/Seoul') at time zone 'Asia/Seoul';
  bal int; res jsonb;
begin
  if uid is null then return jsonb_build_object('error', 'login'); end if;
  select ruby into bal from public.wallets where user_id = uid;
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', i.id, 'name', i.name, 'desc', i.descr, 'category', i.category, 'price', i.price,
           'grant_item', i.grant_item, 'grant_amount', i.grant_amount, 'weekly_limit', i.weekly_limit, 'max_qty', i.max_qty,
           'bundle_qty', i.bundle_qty, 'bundle_discount', i.bundle_discount,
           'bought_week', coalesce((select sum(p.qty) from public.shop_purchases p where p.user_id = uid and p.item_id = i.id and p.created_at >= wk), 0)
         ) order by i.sort, i.id), '[]'::jsonb)
    into res from public.shop_items i where i.active;
  return jsonb_build_object('ruby', coalesce(bal, 0), 'items', res);
end $$;

-- 4) 구매 (루비 차감 → 구매기록 → 우편 지급 생성). 한 번에 처리되고, 중간에 실패하면 전부 취소된다.
create or replace function public.shop_buy(p_item text, p_qty int default 1)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  uid text := auth.uid()::text;
  it public.shop_items%rowtype; w public.wallets%rowtype;
  wk timestamptz := date_trunc('week', now() at time zone 'Asia/Seoul') at time zone 'Asia/Seoul';
  bought int; total int; gid uuid;
begin
  if uid is null then raise exception 'shop: login required'; end if;
  if p_qty is null or p_qty < 1 then raise exception 'shop: bad quantity'; end if;
  select * into it from public.shop_items where id = p_item and active;
  if not found then raise exception 'shop: unknown item'; end if;
  if p_qty > it.max_qty then raise exception 'shop: quantity too large'; end if;
  insert into public.wallets (user_id) values (uid) on conflict do nothing;
  select * into w from public.wallets where user_id = uid for update;     -- 같은 사람의 동시 구매를 한 줄로 세운다
  if it.weekly_limit is not null then
    select coalesce(sum(qty), 0) into bought from public.shop_purchases where user_id = uid and item_id = it.id and created_at >= wk;
    if bought + p_qty > it.weekly_limit then raise exception 'shop: weekly limit (% of %)', bought, it.weekly_limit; end if;
  end if;
  -- 묶음 할인: bundle_qty 개 이상 한 번에 사면 (100 - 할인율)% 만 낸다. 소수는 올림.
  total := case when p_qty >= it.bundle_qty then ceil(it.price::numeric * p_qty * (100 - it.bundle_discount) / 100)::int else it.price * p_qty end;
  if w.ruby < total then raise exception 'shop: not enough ruby'; end if;
  update public.wallets set ruby = ruby - total, updated_at = now() where user_id = uid;
  insert into public.ruby_ledger (user_id, delta, reason) values (uid, -total, 'buy:' || it.id || ' x' || p_qty);
  insert into public.shop_purchases (user_id, item_id, qty, price_total) values (uid, it.id, p_qty, total);
  insert into public.admin_grants (user_id, item, amount, title, gift_name, message, note, expires_at)
  values (uid, it.grant_item, it.grant_amount * p_qty, '🛒 상점 구매', left(it.name || ' ×' || p_qty, 40), '구매해 주셔서 감사합니다!', 'shop:' || it.id, now() + interval '365 days')
  returning id into gid;
  return jsonb_build_object('ok', true, 'ruby', w.ruby - total, 'grant_id', gid);
end $$;

-- 5) 루비 넣기 (운영자 전용: 앱에서는 호출 불가). 결제 서버 함수(웹훅)도 이 함수를 쓰게 된다.
--    p_ref 에 결제번호를 넣으면 같은 번호로는 한 번만 들어간다.
create or replace function public.admin_add_ruby(p_user text, p_amount int, p_reason text default 'admin', p_ref text default null)
returns int language plpgsql security definer set search_path = public as $$
declare bal int; n int;
begin
  if p_amount = 0 then raise exception 'amount must not be 0'; end if;
  insert into public.wallets (user_id) values (p_user) on conflict do nothing;
  insert into public.ruby_ledger (user_id, delta, reason, ref) values (p_user, p_amount, p_reason, p_ref) on conflict (ref) do nothing;
  get diagnostics n = row_count;
  if n = 0 then select ruby into bal from public.wallets where user_id = p_user; return bal; end if;   -- 이미 처리된 결제번호
  update public.wallets set ruby = ruby + p_amount, total_charged = total_charged + greatest(p_amount, 0), updated_at = now()
   where user_id = p_user returning ruby into bal;
  return bal;
end $$;

-- 6) 권한: 앱(로그인한 유저)은 카탈로그/구매만, 루비 넣기는 운영자(SQL Editor)만
revoke all on function public.shop_catalog() from public;
revoke all on function public.shop_buy(text, int) from public;
revoke all on function public.admin_add_ruby(text, int, text, text) from public, anon, authenticated;
grant execute on function public.shop_catalog() to authenticated;
grant execute on function public.shop_buy(text, int) to authenticated;

-- =====================================================================
-- 운영 방법
--  · 테스트용으로 루비 넣기:   select public.admin_add_ruby('<user_id>', 500, '테스트 지급');
--  · 잔액/내역 확인:          select * from public.wallets order by updated_at desc;
--                              select * from public.ruby_ledger where user_id = '<user_id>' order by id desc;
--  · 가격/한도 바꾸기:         update public.shop_items set price = 15, weekly_limit = 40 where id = 'revive';
--  · 상품 내리기/올리기:       update public.shop_items set active = false where id = 'boost_x25';
--  · 새 상품 추가:             insert into public.shop_items (id, name, descr, price, grant_item, grant_amount, weekly_limit, sort)
--                              values ('revive10', '되돌리기 10개 묶음', '10% 할인', 180, 'revive', 10, 10, 15);
-- =====================================================================
