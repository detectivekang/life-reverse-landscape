-- =====================================================================
-- 계정 삭제 (구글 플레이 "계정 삭제" 정책용)  — Supabase SQL Editor 에서 한 번 실행 (여러 번 실행해도 안전)
--
-- 앱의 "계정 삭제" 버튼이 supabase.rpc('delete_my_account') 로 호출한다.
-- * public 스키마에서 user_id / uid / owner_id (uuid 또는 text) 컬럼으로 이 유저 행을 전부 지운다.
--   (저장 데이터, 랭킹, 네온 호드, 로또 티켓, 추천 기록 등)
-- * 결제·루비 거래 기록(payment_orders, ruby_ledger, shop_purchases)은 전자상거래법상 보관 대상이라 지우지 않는다.
--   그 기록이 auth.users 를 참조하고 있어 계정 행 삭제가 막히면, 이메일·이름 등을 비식별화하고 로그인을 막는다.
-- * 제재 기록(banned_users 등)은 재가입으로 제재를 피하지 못하게 남긴다.
-- =====================================================================
create or replace function public.delete_my_account()
returns void
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_uid uuid := auth.uid();
  r record;
begin
  if v_uid is null then
    raise exception 'not authenticated';
  end if;

  for r in
    select c.table_name, c.column_name
    from information_schema.columns c
    join information_schema.tables t
      on t.table_schema = c.table_schema and t.table_name = c.table_name and t.table_type = 'BASE TABLE'
    where c.table_schema = 'public'
      and c.data_type in ('uuid', 'text', 'character varying')
      and c.column_name in ('user_id', 'uid', 'owner_id')
      and c.table_name not in ('payment_orders', 'ruby_ledger', 'shop_purchases', 'banned_users', 'banned_user_backup')
  loop
    execute format('delete from public.%I where %I::text = $1::text', r.table_name, r.column_name) using v_uid;
  end loop;

  begin
    delete from auth.users where id = v_uid;
  exception when others then
    -- 결제 기록 등이 계정을 참조해서 지울 수 없으면 개인정보만 비식별화하고 로그인을 막는다
    update auth.users
       set email = 'deleted-' || v_uid || '@deleted.invalid',
           phone = null,
           raw_user_meta_data = '{}'::jsonb,
           raw_app_meta_data = '{}'::jsonb,
           banned_until = 'infinity'
     where id = v_uid;
    delete from auth.identities where user_id = v_uid;
  end;
end;
$$;

revoke all on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated;
