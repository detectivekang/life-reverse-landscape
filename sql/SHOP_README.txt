[상점(루비) 적용 순서]
1) 새 index.html + assets/ 배포 (assets/icons/ruby.svg 포함)
2) Supabase SQL Editor 에서 순서대로 실행
     ① sql/supabase_admin_grants.sql   (우편함 — 이미 실행했다면 생략 가능, 다시 실행해도 안전)
     ② sql/supabase_shop.sql           (루비 지갑·상품·구매 함수)
3) 테스트: select public.admin_add_ruby('<내 user_id>', 500, '테스트 지급');  → 게임에서 🔶(루비) 버튼으로 구매 확인
3-1) 이미 supabase_shop.sql 을 실행한 적이 있다면 → sql/supabase_shop_update.sql 만 한 번 더 실행 (가격 인상 + 10개 묶음 5% 할인)
4) 가격/한도 조정: update public.shop_items set price=.., weekly_limit=.. where id='...';

[아직 연결 안 된 것]
- 루비 충전(결제): index.html 의 SHOP_CHARGE_OPEN=false. 결제 대행(PG) 가입·연동이 끝나면 켠다.
  결제 서버 함수는 결제를 검증한 뒤 public.admin_add_ruby(user_id, 루비, '충전', 결제번호) 를 호출하면 된다.
