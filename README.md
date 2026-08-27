# 로그인 · 클라우드 저장 설정 가이드

게임(life-reverse-landscape.html)에는 구글/카카오 로그인 + 클라우드 저장 코드가
이미 심어져 있습니다. 아래 순서대로 키 값을 채우고 호스팅하면 실제로 작동합니다.

---

## 1. Firebase 프로젝트 만들기 (구글 로그인 + 데이터 저장소)

1. https://console.firebase.google.com 접속 → "프로젝트 추가"
2. 프로젝트 이름 아무거나 입력 (예: life-reverse)
3. 왼쪽 메뉴 **Authentication** → "시작하기" → 로그인 방법 탭에서 **Google** 사용 설정
4. 왼쪽 메뉴 **Firestore Database** → "데이터베이스 만들기" → 테스트 모드로 시작 (규칙은 4단계에서 다시 조정)
5. 왼쪽 메뉴 **프로젝트 설정(톱니바퀴) → 일반** → 아래로 스크롤 "내 앱" → 웹 앱(</>) 추가
6. 여기서 나오는 `firebaseConfig` 값을 복사해서
   `life-reverse-landscape.html` 안의 아래 부분에 그대로 붙여넣기:

```js
const firebaseConfig = {
  apiKey: "AIzaSyCsQpXhZF6q7L-gWgOd2NcKbA0ya-jikz0",
  authDomain: "life-reverse-d643d.firebaseapp.com",
  projectId: "life-reverse-d643d",
  storageBucket: "life-reverse-d643d.firebasestorage.app",
  messagingSenderId: "570917473549",
  appId: "1:570917473549:web:cc2dbdf9a83d1df591f444",
  measurementId: "G-NZ48LCTKZ6"
};
```

### Firestore 보안 규칙 (Firestore Database → 규칙 탭)

```
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {
    match /saves/{userId} {
      allow read: if request.auth != null && request.auth.uid == userId;

      // 최초 저장(계정 생성 직후)도 그냥 통과시키면 안 됨 — 비교할 "직전 값"이 없다는
      // 점을 노려서 처음부터 money/totalEarned를 조작해 로그인하는 걸 막기 위해,
      // "신규 계정은 아직 많이 못 벌었을 것"이라는 상한을 걸어둔다.
      allow create: if request.auth != null && request.auth.uid == userId
        && request.resource.data.serverSavedAt == request.time
        && request.resource.data.totalEarned is number
        && request.resource.data.money is number
        && request.resource.data.casinoTotalWinnings is number
        && request.resource.data.rebirthCount is number
        && request.resource.data.prestigePoints is number
        && request.resource.data.totalEarned <= 100000000.0   // 최초 저장은 1억원 이하만 허용 (클라이언트도 1억원에서 로그인 게이트로 막아둠 — 서버 쪽 이중 방어)
        && request.resource.data.money <= 100000000.0
        && request.resource.data.casinoTotalWinnings <= 100000000.0
        && request.resource.data.rebirthCount == 0   // 신규 계정이 환생을 미리 하고 시작할 순 없음
        && request.resource.data.prestigePoints == 0;

      // 이후 저장(덮어쓰기)은 "말이 되는 증가폭"인지 검사 후 허용.
      // 클라이언트가 값을 아무리 조작해서 보내도, 직전 저장 시각(서버 기준) 대비
      // 너무 큰 폭으로 뛰면 거부된다.
      allow update: if request.auth != null && request.auth.uid == userId
        && isPlausibleSave();
    }
    match /leaderboard/{userId} {
      allow read: if true;
      allow write: if request.auth != null && request.auth.uid == userId
        && request.resource.data.amount is number
        && request.resource.data.amount >= 0
        // 랭킹판에 올라가는 금액도 저장본(saves)의 casinoTotalWinnings를 벗어날 수 없게 이중 확인
        && request.resource.data.amount <= get(/databases/$(database)/documents/saves/$(userId)).data.casinoTotalWinnings + 1;
    }
    // 주간/월간 랭킹은 컬렉션 이름 자체에 기간이 들어가서(leaderboard_weekly_2026-W34 등)
    // 매번 새 컬렉션이 생기므로, 이름 패턴으로 와일드카드 매칭해서 같은 방식으로 검증한다.
    // (이 블록은 이름이 패턴에 안 맞으면 항상 false를 반환하므로 위 saves/leaderboard 규칙엔 영향 없음)
    match /{coll}/{userId} {
      allow read: if coll.matches('^leaderboard_weekly_.*$') || coll.matches('^leaderboard_monthly_.*$');
      allow write: if request.auth != null && request.auth.uid == userId
        && request.resource.data.amount is number
        && request.resource.data.amount >= 0
        && (
          (coll.matches('^leaderboard_weekly_.*$')
            && request.resource.data.amount <= get(/databases/$(database)/documents/saves/$(userId)).data.weeklyWinnings + 1)
          ||
          (coll.matches('^leaderboard_monthly_.*$')
            && request.resource.data.amount <= get(/databases/$(database)/documents/saves/$(userId)).data.monthlyWinnings + 1)
        );
    }
  }

  function isPlausibleSave() {
    let old = resource.data;
    let neu = request.resource.data;
    let elapsedSec = (request.time.toMillis() - old.serverSavedAt.toMillis()) / 1000.0;

    // 게임 내 이론상 최대 초당 수입(부스터·환생배율 등을 다 곱해도 절대 못 넘을
    // 값으로 넉넉하게 잡은 상한선). 밸런스를 바꾸면 이 값도 같이 올려줘야 함.
    let maxIncomePerSec = 50000000000000000000.0; // 5 x 10^19 / 초
    let maxCasinoGainPerSec = 5000000000000000000.0; // 카지노 누적 순수익 증가 상한(초당)
    let buffer = 1000000000000.0; // 오프라인 보정 등 자잘한 오차용 여유값

    // 환생(프레스티지)은 rebirthCount가 1 증가하면서 totalEarned/money가 0으로
    // 리셋되는 게 정상 동작이라, 일반 케이스와 분리해서 따로 허용해준다.
    let isRebirth = neu.rebirthCount == old.rebirthCount + 1;

    let normalCaseOk = !isRebirth
      && neu.totalEarned >= old.totalEarned
      && (neu.totalEarned - old.totalEarned) <= elapsedSec * maxIncomePerSec + buffer
      // 카지노에서 딴 돈은 totalEarned에는 안 잡히고 money에만 더해지므로,
      // money의 상한은 "totalEarned + 지금까지 카지노로 번 누적 수익"까지 허용
      && neu.money <= neu.totalEarned + neu.casinoTotalWinnings + buffer
      // 프레스티지 포인트는 환생 때가 아니어도 늘 수 있는 경로가 두 가지 있음:
      // 주간 랭킹 시즌 보상(최대 10P) + 카지노 상점의 특성 포인트 교환권(회당 1P, 코인만
      // 있으면 짧은 시간에 여러 번 살 수 있음). 정상적인 몰아사기까지 커버하도록
      // 넉넉하게 100P까지 허용하고, 그 이상은 조작으로 간주해 거부한다.
      && neu.prestigePoints >= old.prestigePoints
      && neu.prestigePoints <= old.prestigePoints + 100;

    let rebirthCaseOk = isRebirth
      && neu.totalEarned <= buffer
      && neu.money <= buffer
      && neu.prestigePoints >= old.prestigePoints
      && neu.prestigePoints <= old.prestigePoints + 1000000; // 환생 1회당 얻는 포인트 상한(넉넉하게)

    return neu.totalEarned is number && neu.money is number
      && neu.casinoTotalWinnings is number && neu.rebirthCount is number && neu.prestigePoints is number
      && neu.serverSavedAt == request.time  // 클라이언트가 시간 조작 못 하게 서버 시각 강제
      && neu.casinoTotalWinnings >= old.casinoTotalWinnings // 카지노 누적 수익은 줄어들 수 없음
      && (neu.casinoTotalWinnings - old.casinoTotalWinnings) <= elapsedSec * maxCasinoGainPerSec + buffer
      && (normalCaseOk || rebirthCaseOk);
  }
}
```

- `saves`: **최초 저장(create)도 검증합니다** — 신규 계정인데 `totalEarned`/`money`/`casinoTotalWinnings`가 1억원을 넘거나, 환생·프레스티지 포인트가 이미 있는 상태로 시작하면 거부됩니다(비교할 "직전 값"이 없다는 점을 악용해 처음부터 조작된 값으로 로그인하는 걸 막기 위함). 클라이언트도 `totalEarned`가 1억원을 넘으면 비로그인 상태에서는 더 이상 돈이 늘지 않고 구글 로그인 모달이 강제로 뜨도록 막아뒀고(로그인 전까지 닫기 불가), 첫 클라우드 업로드 시점에도 1억원 초과분은 클라이언트에서 잘라내고 올리므로, 이 서버 쪽 상한은 개발자도구 등으로 게이트를 우회한 경우를 잡아내는 이중 방어선입니다. 이후 덮어쓰기(update)는 **일반 진행(직전 저장 이후 경과 시간 × 이론상 최대 초당 수입을 넘지 않음, 프레스티지 포인트는 주간 랭킹 시즌 보상·카지노 상점 교환권으로 최대 100P까지만 늘 수 있음)** 이거나 **환생(총 수입·보유금이 0으로 리셋되고 프레스티지 포인트만 정상 범위로 늘어남)** 둘 중 하나일 때만 허용됩니다.
- 카지노로 딴 돈은 `totalEarned`엔 안 잡히고 `money`에만 더해지는 구조라, `money`의 상한은 `totalEarned + casinoTotalWinnings`까지 허용하고, `casinoTotalWinnings` 자체도 별도의 증가 속도 상한을 둡니다.
- `leaderboard`: 카지노 누적 수익금도 `saves` 문서의 값과 대조해서, 랭킹판 조작(saves는 안 건드리고 leaderboard 문서만 직접 조작)까지 함께 막습니다.
- `leaderboard_weekly_*` / `leaderboard_monthly_*`: 컬렉션 이름 자체가 기간별로 바뀌기 때문에 정규식 패턴(`coll.matches(...)`)으로 와일드카드 매칭해서, 마찬가지로 `saves` 문서의 `weeklyWinnings`/`monthlyWinnings`와 대조합니다. 이 블록이 없으면 이 두 컬렉션은 무방비이거나(테스트 모드) 아예 안 써질 수 있어요(엄격 모드).
- 위 `maxIncomePerSec` / `maxCasinoGainPerSec` 값은 게임 밸런스(특히 map5Jobs 최고 등급 수입, 부스터 배율, 환생 배율, 카지노 최고 배당)를 참고해서 "정상적으로 절대 넘을 수 없는" 값으로 넉넉히 잡아야 합니다. 너무 타이트하게 잡으면 정상 플레이도 막힐 수 있으니, 실제 최고 등급 수입 × 부스터 배율 × 환생 배율을 계산해 몇 배 여유를 둔 값으로 넣어주세요.
- 이 검증은 "잡레벨(jobLevels)을 실제로 돈 주고 산 게 맞는지"까지는 확인하지 않습니다(그건 구매 내역 전체를 서버가 재계산해야 해서 훨씬 큰 작업이에요). 다만 잡레벨을 조작해도 `totalEarned` 증가 속도 자체가 위 상한에 막히기 때문에, 실질적인 이득(돈 자체를 불리는 것)은 여전히 차단됩니다.
- 완화된 규칙은 "로그인만 하면 아무 문서나 접근 가능"이라 보안이 약해지니, 가능하면 2번을 진행하세요.)

---

## 2. (선택, 더 안전한 카카오 로그인) Cloud Function 배포

이 폴더의 `functions/index.js`가 그 역할을 합니다.

```bash
npm install -g firebase-tools     # 최초 1회
firebase login
cd (이 README가 있는 폴더)
firebase init functions           # 1번에서 만든 프로젝트 선택, 기존 index.js 있으면 "덮어쓰지 않음" 선택 후
                                   # functions/index.js, functions/package.json을 이 폴더 파일로 교체
firebase deploy --only functions
```

배포가 끝나면 콘솔에 함수 URL이 출력됩니다 (예: `https://asia-northeast3-프로젝트ID.cloudfunctions.net/kakaoLogin`).
이 URL을 게임 HTML의 `loginWithKakao()` 함수를 아래처럼 바꿔서 사용하세요:

```js
function loginWithKakao() {
  if (!window.Kakao || !Kakao.isInitialized()) { showToast('카카오 설정이 필요해요'); return; }
  Kakao.Auth.login({
    success: (authObj) => {
      fetch('여기에_배포된_함수_URL', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ accessToken: authObj.access_token })
      })
        .then(r => r.json())
        .then(data => auth.signInWithCustomToken(data.token))
        .then(() => {
          currentUser = { uid: 'kakao_' + data.uid, provider: 'kakao', name: data.name };
          onLoginSuccess();
        })
        .catch(() => showToast('카카오 연동에 실패했습니다.'));
    },
    fail: () => showToast('카카오 로그인에 실패했습니다.')
  });
}
```

---

## 3. 카카오 앱 만들기 (카카오 로그인용 JS 키)

1. https://developers.kakao.com → "내 애플리케이션" → 애플리케이션 추가
2. 앱 설정 → 앱 키에서 **JavaScript 키** 복사
3. 게임 HTML의 `const KAKAO_JS_KEY = "...";` 에 붙여넣기
4. 카카오 로그인 메뉴 → 활성화 설정 ON
5. **플랫폼 → Web 플랫폼 등록**에 실제로 게임을 올릴 도메인 주소 등록
   (예: `https://your-project.web.app`) — 이 등록 없이는 카카오 로그인이 막힙니다.
6. 동의항목에서 닉네임(프로필) 항목 사용 설정

---

## 4. 실제로 웹에 올리기 (호스팅)

`file://`로 그냥 열면 팝업 로그인이 막힙니다. Firebase Hosting이 가장 간단합니다:

```bash
firebase init hosting     # 1번 프로젝트 선택, public 폴더에 life-reverse-landscape.html을
                           # index.html 이름으로 넣기
firebase deploy --only hosting
```

배포 후 나오는 주소(`https://프로젝트ID.web.app`)로 접속하면 구글/카카오 로그인이 정상 동작합니다.
이 주소를 3번의 카카오 Web 플랫폼, 1번의 Firebase Authentication 승인된 도메인에도 추가해야 합니다.

---

## 요약 체크리스트

- [ ] Firebase 프로젝트 생성 + Google 로그인 활성화 + Firestore 생성
- [ ] `firebaseConfig` 값 게임 HTML에 붙여넣기
- [ ] (선택) Cloud Function 배포 + `loginWithKakao()` 교체
- [ ] 카카오 앱 생성 + JS 키 발급 + Web 플랫폼 도메인 등록
- [ ] `KAKAO_JS_KEY` 게임 HTML에 붙여넣기
- [ ] Firebase Hosting(또는 다른 https 호스팅)에 배포
#   l i f e - r e v e r s e - l a n d s c a p e  
 