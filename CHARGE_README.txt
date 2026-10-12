[루비 충전(포트원 결제) 적용 순서]

0) 포트원 콘솔에서 값 확인
   - 스토어 ID : 결제 연동 > 연동 정보 > 식별코드 탭 (store-... 로 시작)
   - V2 API Secret : 같은 화면의 API Keys 탭에서 발급 (절대 index.html/GitHub/채팅에 올리지 말 것)
   - 채널 키 : "인생역전 테스트" 채널의 키 (index.html 에 이미 넣어 둠)

1) Supabase SQL Editor 에서 실행
   sql/supabase_shop_charge.sql   (supabase_shop.sql 이 이미 실행돼 있어야 함. 다시 실행해도 안전)

2) Edge Function 배포 (둘 중 편한 방법)
   [A] 대시보드: Supabase > Edge Functions > 새 함수 만들기(에디터) > 이름 portone-verify
       supabase/functions/portone-verify/index.ts 내용을 붙여넣고 배포
       → 함수 설정에서 "Verify JWT" 를 꺼야 한다 (포트원 웹훅은 로그인 토큰이 없음. 함수가 결제를 포트원에 다시 조회해서 검증하므로 안전)
   [B] CLI: supabase functions deploy portone-verify --no-verify-jwt

3) 시크릿 등록: Supabase > Edge Functions > Secrets 에 PORTONE_API_SECRET = (0번에서 발급한 V2 API Secret)
   (SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY 는 자동으로 제공됨)

4) index.html 상단 근처 PORTONE_STORE_ID 의 'store-여기에-스토어ID' 를 실제 스토어 ID 로 바꾸고 배포(git push)

5) 테스트: https://detectivekang.github.io/life-reverse-landscape/?chargetest=1
   로그인 → 상점 → 충전하기 → 패키지 선택 → 테스트 결제 → 루비 지급 확인
   확인용 SQL: select * from public.payment_orders order by created_at desc limit 20;

6) 웹훅 등록(권장): 포트원 콘솔 > 결제알림(Webhook) 관리 에서 URL 에
   https://jwtcvvjswvyvevveokyq.supabase.co/functions/v1/portone-verify 등록
   (결제창을 중간에 닫거나 네트워크가 끊겨도 루비가 들어가게 하는 안전장치)

7) 실서비스 전환: 사업자 정보로 실연동 채널을 만들고 index.html 의 PORTONE_CHANNEL_KEY 만 교체
   → 준비가 끝나면 SHOP_CHARGE_OPEN = true 로 바꾸고 배포

[참고]
- 루비 패키지/가격은 sql 의 ruby_packages 표가 기준 (초안: 1,000원=100루비 ... ). update 문으로 언제든 수정 가능.
- 환불: 포트원 콘솔에서 결제 취소 후, 지급된 루비를 admin_add_ruby 로 음수 처리 (SQL 파일 맨 아래 참고)
- CORS 는 detectivekang.github.io 에서만 허용되어 있다 (로컬 파일에서 테스트하면 막힘).
