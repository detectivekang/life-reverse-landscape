-- =====================================================================
-- 상점 "광고 보고 무료 아이템" — Supabase SQL Editor 에서 한 번 실행 (여러 번 실행해도 안전)
-- 먼저 supabase_admin_grants.sql / supabase_shop.sql 이 실행돼 있어야 한다.
--
-- 앱에서 보상형 광고를 끝까지 보면 shop_ad_claim() 을 호출 → 우편함(admin_grants)에 아이템이 생기고 게임이 바로 받는다.
-- ※ 서버는 "광고를 실제로 봤는지"까지는 확인할 수 없다(AdMob SSV 를 붙이면 가능). 그래서 하루 횟수와 최소 간격을
--   서버가 강제해서, 조작해도 얻을 수 있는 양에 상한을 둔다.
-- =====================================================================
create table if not exists public.shop_ad_settings (
  id              int primary key default 1 check (id = 1),   -- 설정은 한 줄만
  active          boolean not null default true,
  item_id         text    not null,                            -- shop_items.id (지급할 아이템. 수량은 그 상품의 grant_amount 1회분)
  daily_limit     int     not null default 3 check (daily_limit between 1 and 50),
  min_gap_seconds int     not null default 30 check (min_gap_seconds >= 0)
);
insert into public.shop_ad_settings (id, item_id) values (1, 'boost_x15') on conflict (id) do nothing;

create table if not exists public.shop_ad_claims (
  id         bigserial primary key,
  user_id    text not null,
  item_id    text not null,
  created_at timestamptz not null default now()
);
create index if not exists shop_ad_claims_user_idx on public.shop_ad_claims (user_id, created_at desc);
alter table public.shop_ad_settings enable row level security; revoke all on public.shop_ad_settings from anon, authenticated;
alter table public.shop_ad_claims   enable row level security; revoke all on public.shop_ad_claims   from anon, authenticated;

-- 오늘(한국 시간 0시~) 받은 횟수와 지급 아이템 정보
create or replace function public.shop_ad_status()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  uid text := auth.uid()::text;
  s public.shop_ad_settings%rowtype; it public.shop_items%rowtype;
  d0 timestamptz := date_trunc('day', now() at time zone 'Asia/Seoul') at time zone 'Asia/Seoul';
  n int;
begin
  if uid is null then return jsonb_build_object('error', 'login'); end if;
  select * into s from public.shop_ad_settings where id = 1 and active;
  if not found then return jsonb_build_object('enabled', false); end if;
  select * into it from public.shop_items where id = s.item_id and active;
  if not found then return jsonb_build_object('enabled', false); end if;
  select count(*) into n from public.shop_ad_claims where user_id = uid and created_at >= d0;
  return jsonb_build_object('enabled', true, 'item_id', it.id, 'name', it.name, 'desc', it.descr,
    'grant_item', it.grant_item, 'amount', it.grant_amount, 'claimed_today', n, 'daily_limit', s.daily_limit);
end $$;

-- 광고 시청 보상 받기
create or replace function public.shop_ad_claim()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  uid text := auth.uid()::text;
  s public.shop_ad_settings%rowtype; it public.shop_items%rowtype;
  d0 timestamptz := date_trunc('day', now() at time zone 'Asia/Seoul') at time zone 'Asia/Seoul';
  n int; last_at timestamptz; gid uuid;
begin
  if uid is null then raise exception 'shop_ad: login required'; end if;
  select * into s from public.shop_ad_settings where id = 1 and active;
  if not found then raise exception 'shop_ad: disabled'; end if;
  select * into it from public.shop_items where id = s.item_id and active;
  if not found then raise exception 'shop_ad: unknown item'; end if;
  perform pg_advisory_xact_lock(hashtext('shop_ad:' || uid));            -- 같은 사람의 동시 요청을 한 줄로 세운다
  select count(*), max(created_at) into n, last_at from public.shop_ad_claims where user_id = uid and created_at >= d0;
  if n >= s.daily_limit then raise exception 'shop_ad: daily limit'; end if;
  if last_at is not null and now() - last_at < make_interval(secs => s.min_gap_seconds) then raise exception 'shop_ad: too fast'; end if;
  insert into public.shop_ad_claims (user_id, item_id) values (uid, it.id);
  insert into public.admin_grants (user_id, item, amount, title, gift_name, message, note, expires_at)
  values (uid, it.grant_item, it.grant_amount, '📺 광고 보상', left(it.name, 40), '광고를 봐 주셔서 감사합니다!', 'shop_ad:' || it.id, now() + interval '365 days')
  returning id into gid;
  return jsonb_build_object('ok', true, 'grant_id', gid, 'name', it.name, 'claimed_today', n + 1, 'daily_limit', s.daily_limit);
end $$;

revoke all on function public.shop_ad_status() from public, anon;
revoke all on function public.shop_ad_claim()  from public, anon;
grant execute on function public.shop_ad_status() to authenticated;
grant execute on function public.shop_ad_claim()  to authenticated;

-- 운영:  update public.shop_ad_settings set item_id = 'revive', daily_limit = 5 where id = 1;   -- 아이템/횟수 바꾸기
--        update public.shop_ad_settings set active = false where id = 1;                       -- 기능 끄기
