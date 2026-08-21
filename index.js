/**
 * 카카오 로그인 → Firebase 커스텀 토큰 발급 Cloud Function
 * -------------------------------------------------------
 * 역할: 클라이언트(게임 HTML)가 카카오 로그인으로 받은 accessToken을 이 함수로 보내면,
 *      1) 카카오 서버에 그 토큰이 진짜인지 확인(/v2/user/me 호출)
 *      2) 확인되면 그 카카오 사용자 고유 ID로 Firebase 커스텀 토큰을 발급
 *      3) 클라이언트는 그 토큰으로 firebase.auth().signInWithCustomToken() 호출
 * 이렇게 하면 Firestore 보안 규칙에서 request.auth.uid 를 안전하게 신뢰할 수 있습니다.
 *
 * 배포 방법:
 *   1) npm i -g firebase-tools (한 번만)
 *   2) firebase login
 *   3) 이 functions 폴더가 있는 위치에서: firebase init functions (기존 프로젝트 선택)
 *   4) 이 index.js 내용을 그대로 덮어쓰기
 *   5) firebase deploy --only functions
 *   6) 배포되면 나오는 함수 URL을 게임 HTML의 KAKAO_TOKEN_EXCHANGE_URL 에 넣기
 */

const functions = require('firebase-functions');
const admin = require('firebase-admin');
const fetch = require('node-fetch');

admin.initializeApp();

exports.kakaoLogin = functions.https.onRequest(async (req, res) => {
  // 브라우저(게임)에서 바로 호출할 수 있도록 CORS 허용
  res.set('Access-Control-Allow-Origin', '*');
  res.set('Access-Control-Allow-Methods', 'POST');
  res.set('Access-Control-Allow-Headers', 'Content-Type');
  if (req.method === 'OPTIONS') { res.status(204).send(''); return; }
  if (req.method !== 'POST') { res.status(405).send('POST만 허용됩니다'); return; }

  const kakaoAccessToken = req.body.accessToken;
  if (!kakaoAccessToken) {
    res.status(400).json({ error: 'accessToken이 필요합니다' });
    return;
  }

  try {
    // 1) 카카오 서버에 진짜 사용자인지 확인
    const kakaoRes = await fetch('https://kapi.kakao.com/v2/user/me', {
      headers: { Authorization: `Bearer ${kakaoAccessToken}` }
    });
    if (!kakaoRes.ok) {
      res.status(401).json({ error: '유효하지 않은 카카오 토큰입니다' });
      return;
    }
    const kakaoUser = await kakaoRes.json();
    const uid = 'kakao_' + kakaoUser.id;
    const nickname =
      (kakaoUser.kakao_account && kakaoUser.kakao_account.profile && kakaoUser.kakao_account.profile.nickname) ||
      '카카오 사용자';

    // 2) Firebase 커스텀 토큰 발급 (uid를 카카오 고유ID 기반으로 고정)
    const customToken = await admin.auth().createCustomToken(uid, { provider: 'kakao', name: nickname });

    res.status(200).json({ token: customToken, uid, name: nickname });
  } catch (err) {
    console.error('kakaoLogin error:', err);
    res.status(500).json({ error: '서버 오류로 로그인 처리에 실패했습니다' });
  }
});
