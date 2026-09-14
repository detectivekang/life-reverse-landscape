# 리더보드 amount 보정 스크립트

`fix-leaderboard-amounts.js`는 `leaderboard`, `leaderboard_weekly_*`,
`leaderboard_monthly_*`, `leaderboard_burn_monthly_*` 컬렉션을 전부 훑어서
`amount` 필드가 올바른 형식(9e15 이하는 순수 숫자, 초과는 `BN:`+40자리
0-패딩 문자열)인지 확인하고, 아니면 고쳐줍니다.

일반 유저는 자기 자신 문서만 쓸 수 있어서(firestore.rules), 다른 사람의
잘못된 문서는 앱 코드로는 못 고칩니다. 이 스크립트는 관리자 키로 실행해서
규칙을 우회하는 방식입니다.

## 실행 방법

1. **서비스 계정 키 받기**
   Firebase 콘솔 → 프로젝트 설정(톱니바퀴) → 서비스 계정 탭 →
   "새 비공개 키 생성" → JSON 다운로드
   → 파일명을 `serviceAccountKey.json`으로 바꿔서 이 폴더(`admin-scripts/`)에 넣기
   → **이 파일은 절대 깃허브에 올리지 마세요** (관리자 권한 키라 유출되면
   전체 DB를 마음대로 읽고 쓸 수 있게 됩니다). `.gitignore`에 추가해두는 걸
   추천해요.

2. **패키지 설치**
   ```bash
   cd admin-scripts
   npm install firebase-admin
   ```

3. **미리보기 먼저** (아무것도 안 바꿈, 뭘 고칠지만 로그로 보여줌)
   ```bash
   node fix-leaderboard-amounts.js
   ```

4. **로그 확인하고 문제없으면 실제 적용**
   ```bash
   node fix-leaderboard-amounts.js --apply
   ```

## 로그 읽는 법

- `🔧 [컬렉션/문서ID] 이전값 -> 새값 (실제 값: ...)` — 형식이 잘못돼서 고친 문서
- `❌ [컬렉션/문서ID] amount를 해석할 수 없음` — 완전히 깨져서 자동으로 못
  고친 문서. 이런 게 나오면 Firestore 콘솔에서 그 문서를 직접 열어보고
  수동으로 정리하거나, 아예 삭제하는 게 나을 수 있어요 (해당 유저가 다음에
  게임 하면서 재화를 벌면 정상적인 코드 경로로 자동으로 다시 만들어집니다).

## 참고

이 스크립트를 돌린다고 "왜 이런 일이 생겼는지"까지 알 수 있는 건 아니에요.
대체로 이런 원인들이 흔합니다:
- 예전 버전 코드에서 만들어진 문서 (지금 코드로 고치기 전)
- 오프라인 상태에서 저장이 부분적으로 실패했던 경우
- 수동으로 Firestore 콘솔에서 값을 만지다가 실수한 경우

한 번 고쳐두면, 지금 배포된 최신 코드는 계속 올바른 형식으로만 쓰기 때문에
다시 깨지지 않습니다 (재발 방지는 `index.html`의 `fetchLeaderboard`/
`fetchMyRankInfo`를 방어적으로 재정렬하도록 고친 부분이 담당해요).
