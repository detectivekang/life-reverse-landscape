// ===== 인생역전 랜드스케이프 서비스워커 =====
// 여기서 하는 일 두 가지:
// 1) PWA 오프라인 셸 캐싱 (홈 화면에 추가했을 때 앱처럼 열리게)
// 2) 로컬(기기 내) 알림 예약 — 진짜 서버 푸시가 아니라, 페이지에서 요청한 시간이 되면
//    이 서비스워커가 스스로 알림을 띄우는 방식. 브라우저/기기가 완전히 꺼지지 않고
//    떠 있는 동안만 신뢰할 수 있다 (며칠 뒤까지 100% 보장되는 방식은 아님 — 그건
//    FCM + 서버(Cloud Functions)가 있어야 함).
// v1 -> v2: index.html을 캐시 우선으로 서빙하던 게 원인이 되어, 배포한 새 코드가
// 브라우저에 계속 반영되지 않는 버그(예: 이름 색상 뽑기가 리더보드에 적용 안 되는 것처럼
// 보이던 문제)가 있었다. 이제 HTML/JS 문서는 "네트워크 우선"으로 바꿔서, 새로 배포하면
// 바로 반영되고, 오프라인일 때만 캐시로 대체되게 한다. 아이콘 등 진짜 안 바뀌는 정적
// 파일만 캐시 우선으로 남겨 오프라인 PWA 셸을 유지한다.
const CACHE_NAME = 'life-reverse-shell-v2';
const SHELL_FILES = ['./', './index.html', './manifest.json', './icon-192.png', './icon-512.png'];
// 이 목록에 해당하는 요청만 "캐시 우선" (자주 안 바뀌는 정적 리소스)
const CACHE_FIRST_PATTERNS = [/icon-192\.png$/, /icon-512\.png$/, /manifest\.json$/];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) => cache.addAll(SHELL_FILES)).catch(() => {})
  );
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(keys.filter((k) => k !== CACHE_NAME).map((k) => caches.delete(k)))
    )
  );
  self.clients.claim();
});

self.addEventListener('fetch', (event) => {
  if (event.request.method !== 'GET') return;
  const isCacheFirst = CACHE_FIRST_PATTERNS.some((re) => re.test(event.request.url));

  if (isCacheFirst) {
    // 정적 리소스: 캐시 우선, 없으면 네트워크
    event.respondWith(
      caches.match(event.request).then((cached) => cached || fetch(event.request))
    );
    return;
  }

  // HTML/JS 등 앱 본체: 네트워크 우선 (항상 최신 배포 반영), 오프라인일 때만 캐시로 대체.
  // 네트워크도 실패하고 캐시에도 없는 경우(방문한 적 없는 페이지를 완전 오프라인 상태에서
  // 여는 등) undefined를 그대로 respondWith에 넘기면 "Failed to convert value to 'Response'"
  // 에러가 나기 때문에, 그 경우엔 명시적인 에러 Response를 만들어서 반환한다.
  event.respondWith(
    fetch(event.request)
      .then((response) => {
        const clone = response.clone();
        caches.open(CACHE_NAME).then((cache) => cache.put(event.request, clone)).catch(() => {});
        return response;
      })
      .catch(async () => {
        const cached = await caches.match(event.request);
        return cached || new Response('오프라인 상태이고 캐시된 페이지도 없습니다.', {
          status: 503,
          statusText: 'Offline',
          headers: { 'Content-Type': 'text/plain; charset=utf-8' }
        });
      })
  );
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  event.waitUntil(
    self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then((clientList) => {
      for (const client of clientList) {
        if ('focus' in client) return client.focus();
      }
      if (self.clients.openWindow) return self.clients.openWindow('./');
    })
  );
});

// 페이지 쪽에서 { type: 'scheduleNotification', title, body, delayMs, tag } 형태로 보내면
// delayMs 뒤에 알림을 띄운다. 같은 tag로 다시 예약하면 이전 예약은 자동으로 대체된다.
const pendingTimers = {};
self.addEventListener('message', (event) => {
  const data = event.data || {};
  if (data.type === 'scheduleNotification') {
    const tag = data.tag || 'default';
    if (pendingTimers[tag]) clearTimeout(pendingTimers[tag]);
    pendingTimers[tag] = setTimeout(() => {
      self.registration.showNotification(data.title || '인생역전 랜드스케이프', {
        body: data.body || '',
        icon: './icon-192.png',
        badge: './icon-192.png',
        tag
      });
    }, Math.max(0, data.delayMs || 0));
  } else if (data.type === 'cancelNotification') {
    const tag = data.tag || 'default';
    if (pendingTimers[tag]) { clearTimeout(pendingTimers[tag]); delete pendingTimers[tag]; }
  }
});
