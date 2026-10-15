-- =====================================================================
-- 루비 충전(포트원 결제) — Supabase SQL Editor 에서 실행
-- 먼저 supabase_admin_grants.sql / supabase_shop.sql 이 실행되어 있어야 한다 (admin_add_ruby 사용).
-- 구조
--   · 루비 패키지(가격표)는 서버 테이블. 결제 금액은 클라이언트가 정하지 못한다.
--   · charge_prepare 가 "주문"(payment_id ↔ 유저 ↔ 패키지 ↔ 금액)을 서버에 먼저 만든다.
--   · 결제가 끝나면 Edge Function(portone-verify)이 포트원 API 로 결제를 확인하고 charge_complete 를 호출한다.
--   · charge_complete 는 같은 주문에 두 번 루비가 들어가지 않게 막는다 (주문 상태 + ruby_ledger.ref unique).
-- =====================================================================

-- 1) 루비 패키지 (가격은 자유롭게 바꿔도 됨. 아래는 초안)
create table if not exists public.ruby_packages (
  id         text primary key,
  name       text not null,
  price_krw  int  not null check (price_krw >= 1000),   -- 결제 금액(원)
  ruby       int  not null check (ruby > 0),             -- 기본 루비
  bonus_ruby int  not null default 0 check (bonus_ruby >= 0),
  active     boolean not null default true,
  sort       int  not null default 0
);
insert into public.ruby_packages (id, name, price_krw, ruby, bonus_ruby, sort) values
  ('ruby_1000',  '루비 100개',   1000,  100,   0, 10),
  ('ruby_3000',  '루비 300개',   3000,  300,  15, 20),
  ('ruby_5000',  '루비 500개',   5000,  500,  40, 30),
  ('ruby_10000', '루비 1,000개', 10000, 1000, 100, 40)
on conflict (id) do nothing;

-- 2) 주문
create table if not exists public.payment_orders (
  payment_id  text primary key,
  user_id     text not null,
  package_id  text not null,
  amount_krw  int  not null,
  ruby_total  int  not null,                      -- 기본 + 보너스 (주문 시점 값을 고정)
  status      text not null default 'ready' check (status in ('ready','paid','failed')),
  created_at  timestamptz not null default now(),
  paid_at     timestamptz,
  note        text
);
create index if not exists payment_orders_user_idx on public.payment_orders (user_id, created_at desc);

alter table public.ruby_packages enable row level security;   revoke all on public.ruby_packages from anon, authenticated;
alter table public.payment_orders enable row level security;  revoke all on public.payment_orders from anon, authenticated;

-- 3) 패키지 목록 (로그인한 유저)
create or replace function public.charge_catalog()
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return jsonb_build_object('error', 'login'); end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', name, 'price_krw', price_krw, 'ruby', ruby, 'bonus', bonus_ruby) order by sort, price_krw)
                     from public.ruby_packages where active), '[]'::jsonb);
end $$;

-- 4) 주문 만들기 (로그인한 유저). 반환: 결제번호/금액/상품명
create or replace function public.charge_prepare(p_package text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare uid text := auth.uid()::text; pk public.ruby_packages%rowtype; pid text;
begin
  if uid is null then raise exception 'charge: login required'; end if;
  select * into pk from public.ruby_packages where id = p_package and active;
  if not found then raise exception 'charge: unknown package'; end if;
  -- 결제창만 열고 안 끝낸 주문이 계속 쌓이는 것 방지: 같은 유저의 오래된 ready 주문 정리
  delete from public.payment_orders where user_id = uid and status = 'ready' and created_at < now() - interval '2 days';
  -- pid := 'lr-' || replace(gen_random_uuid()::text, '-', '');  -- [기존] 하이픈이 있으면 카카오페이가 결제 ID 를 거절한다
  pid := 'lr' || replace(gen_random_uuid()::text, '-', '');      -- [변경] 영문+숫자만 (카카오페이/카드 모두 통과)
  insert into public.payment_orders (payment_id, user_id, package_id, amount_krw, ruby_total)
  values (pid, uid, pk.id, pk.price_krw, pk.ruby + pk.bonus_ruby);
  return jsonb_build_object('payment_id', pid, 'amount', pk.price_krw, 'name', pk.name, 'ruby', pk.ruby + pk.bonus_ruby);
end $$;

-- 5) 결제 확정 (Edge Function 전용: service_role 만 호출 가능)
--    p_paid_amount 는 포트원 API 가 알려 준 실제 결제 금액. 주문 금액과 다르면 지급하지 않는다.
create or replace function public.charge_complete(p_payment_id text, p_paid_amount int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare o public.payment_orders%rowtype; bal int;
begin
  select * into o from public.payment_orders where payment_id = p_payment_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no_order'); end if;
  if o.status = 'paid' then
    select ruby into bal from public.wallets where user_id = o.user_id;
    return jsonb_build_object('ok', true, 'already', true, 'ruby', coalesce(bal, 0), 'granted', o.ruby_total);
  end if;
  if p_paid_amount <> o.amount_krw then
    update public.payment_orders set status = 'failed', note = 'amount mismatch: paid ' || p_paid_amount where payment_id = p_payment_id;
    return jsonb_build_object('ok', false, 'reason', 'amount_mismatch');
  end if;
  bal := public.admin_add_ruby(o.user_id, o.ruby_total, '충전 ' || o.package_id, p_payment_id);
  update public.payment_orders set status = 'paid', paid_at = now() where payment_id = p_payment_id;
  return jsonb_build_object('ok', true, 'ruby', bal, 'granted', o.ruby_total);
end $$;

-- 6) 권한
revoke all on function public.charge_catalog() from public, anon;
revoke all on function public.charge_prepare(text) from public, anon;
revoke all on function public.charge_complete(text, int) from public, anon, authenticated;
grant execute on function public.charge_catalog() to authenticated;
grant execute on function public.charge_prepare(text) to authenticated;
grant execute on function public.charge_complete(text, int) to service_role;
-- admin_add_ruby 는 charge_complete(security definer) 안에서 호출되므로 별도 권한 변경이 필요 없다.

-- =====================================================================
-- 운영 확인용
--   · 주문 내역:   select * from public.payment_orders order by created_at desc limit 50;
--   · 패키지 수정: update public.ruby_packages set price_krw = 3300, ruby = 330 where id = 'ruby_3000';
--   · 환불 시:     포트원 콘솔에서 결제 취소 후, select public.admin_add_ruby('<user_id>', -<루비>, '환불', 'refund:<payment_id>');
-- =====================================================================
