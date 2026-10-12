-- =====================================================================
-- 상점 업데이트: ① 가격 인상 ② 10개 묶음 5% 할인(10개를 9.5개 값으로)
-- 이미 supabase_shop.sql 을 실행한 상태에서 이 파일을 한 번 실행하면 된다. (새로 설치하는 경우엔 supabase_shop.sql 만 실행)
-- =====================================================================
alter table public.shop_items add column if not exists bundle_qty int not null default 10;
alter table public.shop_items add column if not exists bundle_discount int not null default 5 check (bundle_discount between 0 and 50);

update public.shop_items set price = 50,  weekly_limit = 30 where id = 'revive';
update public.shop_items set price = 40,  weekly_limit = 20 where id = 'boost_x15';
update public.shop_items set price = 100, weekly_limit = 10 where id = 'boost_x20';
update public.shop_items set price = 200, weekly_limit = 5  where id = 'boost_x25';
update public.shop_items set price = 100, weekly_limit = 5  where id = 'shards20k';

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


revoke all on function public.shop_catalog() from public;
revoke all on function public.shop_buy(text, int) from public;
grant execute on function public.shop_catalog() to authenticated;
grant execute on function public.shop_buy(text, int) to authenticated;
