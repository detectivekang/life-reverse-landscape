// ============================================================================
// 리더보드 amount 필드 보정 스크립트 (관리자 전용, Node.js로 로컬에서 1회 실행)
//
// 왜 필요한가:
//   9e15(약 900조)를 넘는 금액은 클라이언트 코드가 "BN:" + 40자리 0-패딩 문자열로
//   바꿔서 저장한다 (Firestore가 큰 정수를 못 담아서). 그런데 예전 버전의 버그나,
//   중간에 뭔가 잘못 저장된 문서가 하나라도 섞여 있으면 - 형식이 다르거나(예: 자리수가
//   40자리가 아니거나), 여전히 숫자 타입으로 남아있거나 하면 - Firestore의
//   orderBy('amount')가 "값 크기"가 아니라 "타입/문자열 형태" 기준으로 갈라져서
//   순위가 완전히 뒤틀린다. (예: 훨씬 작은 금액이 1등으로 뜨는 현상)
//
//   클라이언트 코드는 이제 화면에 보여줄 때 방어적으로 다시 정렬하도록 고쳤지만,
//   Firestore에 실제로 저장된 값 자체가 여전히 지저분하면 근본적으로 찜찜하다.
//   이 스크립트는 leaderboard 관련 모든 컬렉션을 훑어서 amount를 전부
//   "올바른 형식(9e15 이하는 순수 숫자, 초과는 BN:+40자리)"으로 다시 써준다.
//
// 사용 방법:
//   1) Firebase 콘솔 > 프로젝트 설정 > 서비스 계정 > "새 비공개 키 생성"으로
//      JSON 키 파일을 받아서, 이 스크립트와 같은 폴더에 serviceAccountKey.json
//      이름으로 저장 (절대 깃허브 등에 커밋하지 말 것 - 관리자 권한 키입니다).
//   2) npm install firebase-admin
//   3) node fix-leaderboard-amounts.js
//        - 기본은 "미리보기(dry-run)" 모드: 뭘 고칠지만 로그로 보여주고 실제로는
//          안 씀.
//   4) 로그 확인하고 문제 없으면: node fix-leaderboard-amounts.js --apply
//        - 이번엔 실제로 Firestore에 고친 값을 씀.
// ============================================================================

const admin = require('firebase-admin');
const serviceAccount = require('./serviceAccountKey.json');

admin.initializeApp({ credential: admin.credential.cert(serviceAccount) });
const db = admin.firestore();

const FIRESTORE_INT64_SAFE_LIMIT = 9e15;
const BIG_STORABLE_PAD_WIDTH = 40;
const APPLY = process.argv.includes('--apply');

// 게임 코드(index.html)의 toBigStorable/fromBigStorable과 동일한 로직.
// 다만 여기서는 "이미 저장된 값이 뭐가 됐든" 최대한 실제 숫자를 복원해보려고
// 조금 더 관대하게(malformed 케이스도) 시도한다.
function decodeAmountRobust(v) {
  if (typeof v === 'number' && isFinite(v)) return { ok: true, value: v };

  if (typeof v === 'string') {
    let digits = v;
    if (digits.startsWith('BN:')) digits = digits.slice(3);
    // 순수 숫자 문자열(0-패딩 여부 상관없이)이면 BigInt로 정확히 해석
    if (/^[0-9]+$/.test(digits)) {
      try {
        return { ok: true, value: Number(BigInt(digits)) };
      } catch (e) {
        return { ok: false, raw: v };
      }
    }
    // 그 외(지수표기, 소수점 등 섞인 이상한 문자열) - Number()로 마지막 시도
    const n = Number(digits);
    if (isFinite(n)) return { ok: true, value: n };
    return { ok: false, raw: v };
  }

  return { ok: false, raw: v };
}

// 게임 코드와 동일한 재-인코딩 로직 (정상 케이스로 통일)
function encodeAmount(n) {
  if (!Number.isFinite(n)) return 0;
  if (Number.isInteger(n) && Math.abs(n) > FIRESTORE_INT64_SAFE_LIMIT) {
    const digits = BigInt(Math.round(n)).toString();
    if (digits.length > BIG_STORABLE_PAD_WIDTH) {
      // 40자리도 넘는 초초거대값(대략 10^39 이상) - 이 게임 단위표(무량대수=10^68)로는
      // 나올 수 있는 범위라 pad width 자체를 늘려야 함. 일단 그대로 표시만 해두고
      // 수동 확인이 필요하다고 로그를 남긴다.
      console.warn(`  ⚠️ 40자리를 초과하는 값 발견(${digits.length}자리) - pad width 확장 필요, 일단 그대로 저장:`, digits);
      return 'BN:' + digits;
    }
    return 'BN:' + digits.padStart(BIG_STORABLE_PAD_WIDTH, '0');
  }
  return Math.round(n);
}

async function fixCollection(collectionName) {
  const snap = await db.collection(collectionName).get();
  let fixedCount = 0;
  let okCount = 0;
  let unfixableCount = 0;

  for (const doc of snap.docs) {
    const data = doc.data();
    if (!('amount' in data)) continue;

    const decoded = decodeAmountRobust(data.amount);
    if (!decoded.ok) {
      unfixableCount++;
      console.error(`  ❌ [${collectionName}/${doc.id}] amount를 해석할 수 없음:`, JSON.stringify(data.amount));
      continue;
    }

    const correctValue = encodeAmount(decoded.value);
    const isAlreadyCorrect =
      typeof correctValue === typeof data.amount && correctValue === data.amount;

    if (isAlreadyCorrect) {
      okCount++;
      continue;
    }

    fixedCount++;
    console.log(
      `  🔧 [${collectionName}/${doc.id}] ${JSON.stringify(data.amount)} -> ${JSON.stringify(correctValue)} (실제 값: ${decoded.value.toLocaleString('ko-KR')})`
    );
    if (APPLY) {
      await doc.ref.update({ amount: correctValue });
    }
  }

  console.log(`[${collectionName}] 총 ${snap.size}개 중 정상 ${okCount} / 수정 ${fixedCount} / 해석불가 ${unfixableCount}`);
  return { fixedCount, okCount, unfixableCount };
}

async function main() {
  console.log(APPLY ? '=== 실제 적용 모드 ===' : '=== 미리보기(dry-run) 모드 - 실제로 쓰지 않음 ===');

  // 컬렉션 이름이 leaderboard_weekly_2026-W37 처럼 기간 키가 붙어서 동적으로 생기므로,
  // 프로젝트에 존재하는 전체 최상위 컬렉션 목록에서 관련된 것들을 다 찾는다.
  const allCollections = await db.listCollections();
  const targets = allCollections
    .map((c) => c.id)
    .filter(
      (id) =>
        id === 'leaderboard' ||
        id.startsWith('leaderboard_weekly_') ||
        id.startsWith('leaderboard_monthly_') ||
        id.startsWith('leaderboard_burn_monthly_')
    );

  console.log(`대상 컬렉션 ${targets.length}개:`, targets);

  let totalFixed = 0;
  let totalUnfixable = 0;
  for (const name of targets) {
    const result = await fixCollection(name);
    totalFixed += result.fixedCount;
    totalUnfixable += result.unfixableCount;
  }

  console.log('\n===== 전체 요약 =====');
  console.log(`수정${APPLY ? '됨' : ' 필요'}: ${totalFixed}건`);
  console.log(`해석 불가(수동 확인 필요): ${totalUnfixable}건`);
  if (!APPLY && totalFixed > 0) {
    console.log('\n실제로 반영하려면: node fix-leaderboard-amounts.js --apply');
  }
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error('스크립트 실행 중 오류:', err);
    process.exit(1);
  });
