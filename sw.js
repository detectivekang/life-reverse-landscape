// ===== 인생역전 랜드스케이프 서비스워커 =====
// 여기서 하는 일 두 가지:
// 1) PWA 오프라인 셸 캐싱 (홈 화면에 추가했을 때 앱처럼 열리게)
// 2) 로컬(기기 내) 알림 예약 — 진짜 서버 푸시가 아니라, 페이지에서 요청한 시간이 되면
//    이 서비스워커가 스스로 알림을 띄우는 방식. 브라우저/기기가 완전히 꺼지지 않고
//    떠 있는 동안만 신뢰할 수 있다 (며칠 뒤까지 100% 보장되는 방식은 아님 — 그건
//    FCM + 서버(Cloud Functions)가 있어야 함).
const CACHE_NAME = 'life-reverse-shell-v1';
const SHELL_FILES = ['./', './index.html', './manifest.json', './icon-192.png', './icon-512.png'];

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
  event.respondWith(
    caches.match(event.request).then((cached) => {
      if (cached) return cached;
      return fetch(event.request).catch(() => cached);
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
