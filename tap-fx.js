/* 인생역전 탭 연출 — "폐지 줍기 광란".
   클릭 버튼(야근하기·영업 뛰기·월드 버튼 포함)을 누르면 지금 단계의 아이템(📦 폐지, 🥫 깡통 ... 단계가 바뀌면 그 단계의 직업 아이콘)이
   사방에서 버튼 쪽으로 빨려 들어간다. 피버 중에는 훨씬 많이, 화면 위에서 쏟아지듯 몰려든다.
   - 게임 코드는 건드리지 않고(stages, stageIndex, feverActive 를 읽기만 한다) 화면 위에 덮는 레이어에만 그린다.
   - 한 번에 떠 있는 아이템은 보통 36개, 피버 때 80개까지로 제한하고, 끝나면 바로 지운다.
   - 더보기 메뉴의 "✨ 탭 연출" 버튼으로 끌 수 있다. 기기에서 "동작 줄이기"를 켰거나 화면이 숨겨져 있으면 아무것도 하지 않는다. */
(function () {
  "use strict";
  var KEY = "nhx_tapfx"; // "off" 이면 끈다
  var MAX_NORMAL = 36, MAX_FRENZY = 80;
  var layer = null, live = 0, lastTap = 0, combo = 0, lastRain = 0;

  try {
    var st = document.createElement("style");
    st.textContent =
      "#nhxTapFx{position:fixed;left:0;top:0;width:100%;height:100%;pointer-events:none;z-index:500;overflow:hidden}" +
      ".nhx-fx{position:absolute;margin:-12px 0 0 -12px;line-height:1;opacity:0;will-change:transform,opacity;" +
      "transform:translate(var(--sx),var(--sy)) rotate(var(--r0));animation:nhxIn var(--dur) cubic-bezier(.3,.6,.4,1) forwards}" +
      "@keyframes nhxIn{0%{opacity:0;transform:translate(var(--sx),var(--sy)) rotate(var(--r0)) scale(.7)}" +
      "15%{opacity:1}85%{opacity:1}100%{opacity:0;transform:translate(0,0) rotate(var(--r1)) scale(.45)}}";
    document.head.appendChild(st);
  } catch (e) {}

  function enabled() {
    try { if (localStorage.getItem(KEY) === "off") return false; } catch (e) {}
    try { if (window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches) return false; } catch (e) {}
    return !document.hidden;
  }
  function icons() {
    try {
      var s = stages[stageIndex], arr = [s.icon];
      (s.jobs || []).forEach(function (j) { if (j && j.icon && arr.indexOf(j.icon) < 0) arr.push(j.icon); });
      return arr;
    } catch (e) { return ["📦", "🥫"]; }
  }
  function frenzy() { try { return !!feverActive; } catch (e) { return false; } }
  function getLayer() {
    if (layer && layer.parentNode) return layer;
    layer = document.createElement("div");
    layer.id = "nhxTapFx";
    document.body.appendChild(layer);
    return layer;
  }

  function spawn(cx, cy, sx, sy, set, big) {
    var el = document.createElement("span");
    el.className = "nhx-fx";
    el.textContent = set[Math.floor(Math.random() * set.length)];
    el.style.cssText =
      "left:" + cx.toFixed(0) + "px;top:" + cy.toFixed(0) + "px;" +
      "--sx:" + sx.toFixed(0) + "px;--sy:" + sy.toFixed(0) + "px;" +
      "--r0:" + (Math.random() * 360 - 180).toFixed(0) + "deg;--r1:" + (Math.random() * 720 - 360).toFixed(0) + "deg;" +
      "--dur:" + (0.45 + Math.random() * 0.35 + (big ? 0.12 : 0)).toFixed(2) + "s;" +
      "font-size:" + (big ? 20 + Math.random() * 16 : 17 + Math.random() * 10).toFixed(0) + "px";
    getLayer().appendChild(el);
    live++;
    var done = false;
    function end() {
      if (done) return;
      done = true;
      live = Math.max(0, live - 1);
      if (el.parentNode) el.parentNode.removeChild(el);
    }
    el.addEventListener("animationend", end);
    setTimeout(end, 1500);
  }

  function burst(btn) {
    if (!enabled()) return;
    var r = btn.getBoundingClientRect(), cx = r.left + r.width / 2, cy = r.top + r.height / 2;
    var now = Date.now();
    combo = now - lastTap < 700 ? combo + 1 : 1;
    lastTap = now;
    var fr = frenzy(), cap = fr ? MAX_FRENZY : MAX_NORMAL, set = icons();
    var n = fr ? 6 + Math.min(6, combo >> 2) : 1 + Math.min(4, combo >> 3);
    for (var i = 0; i < n && live < cap; i++) {
      var ang = Math.random() * 6.2832, dist = (fr ? 170 : 110) + Math.random() * (fr ? 260 : 140);
      spawn(cx, cy, Math.cos(ang) * dist, Math.sin(ang) * dist, set, fr);
    }
    // 피버: 화면 위쪽에서 폐지 더미가 쏟아져 내려온다
    if (fr && now - lastRain > 300) {
      lastRain = now;
      var w = window.innerWidth || 360;
      for (var k = 0; k < 5 && live < cap; k++) spawn(cx, cy, (Math.random() - 0.5) * w, -(cy + 30), set, true);
    }
  }

  document.addEventListener("pointerdown", function (e) {
    try {
      var t = e.target && e.target.closest ? e.target.closest("#tapBtn,#buskBtn,#busk5Btn") : null;
      if (t) burst(t);
    } catch (err) {}
  }, true);

  // ---------- 더보기 메뉴의 끄기/켜기 버튼 ----------
  function label() {
    var off = false;
    try { off = localStorage.getItem(KEY) === "off"; } catch (e) {}
    return "✨ 탭 연출: " + (off ? "꺼짐" : "켜짐");
  }
  function inject() {
    try {
      var anchor = document.getElementById("noticeBtn");
      if (!anchor || document.getElementById("nhxFxBtn")) return;
      var b = document.createElement("button");
      b.className = "close-btn more-menu-item";
      b.id = "nhxFxBtn";
      b.style.textAlign = "left";
      b.textContent = label();
      b.onclick = function () {
        try { localStorage.setItem(KEY, localStorage.getItem(KEY) === "off" ? "on" : "off"); } catch (e) {}
        b.textContent = label();
      };
      anchor.parentNode.insertBefore(b, anchor.nextSibling);
    } catch (e) {}
  }
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", inject);
  else inject();
})();
