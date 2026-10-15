/* 인생역전 UI v2 — 표시 전용 보조 스크립트.
   게임 상태를 "읽기만" 하고(money, jobCost 등) 절대 바꾸지 않는다. 실패해도 게임은 그대로 동작한다. */
(function () {
  "use strict";

  // ---- 1) 재화 SVG 아이콘 (외부 의존 없음) ----
  var COIN =
    '<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="9" fill="none" stroke="#7a4e00" stroke-width="1.6"/>' +
    '<path d="M7.2 8.2l1.9 7.6 2.9-6.4 2.9 6.4 1.9-7.6M6.4 11h11.2M6.4 13.4h11.2" fill="none" stroke="#7a4e00" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/></svg>';
  try {
    var ic = document.querySelector(".money-row .icon");
    if (ic) {
      ic.innerHTML = COIN;
      ic.setAttribute("role", "img");
      ic.setAttribute("aria-label", "돈");
    }
  } catch (e) {}

  // ---- 2) 구매 가능/불가 상태 표시 ----
  function afford(rowId, costFn, levelsName) {
    var row = document.getElementById(rowId);
    if (!row || typeof costFn !== "function") return;
    var m = typeof money === "number" ? money : null;
    if (m === null) return;
    var cards = row.querySelectorAll(".stall[data-idx]");
    for (var i = 0; i < cards.length; i++) {
      var el = cards[i];
      var idx = +el.dataset.idx;
      var cost;
      try { cost = costFn(idx); } catch (e) { continue; }
      if (typeof cost !== "number") continue;
      var ok = m >= cost;
      el.classList.toggle("is-ready", ok);
      el.classList.toggle("is-poor", !ok);
    }
  }
  function tick() {
    try {
      if (typeof jobCost === "function") afford("stallRow", jobCost);
      if (typeof jobCost2 === "function") afford("stallRow2", jobCost2);
      if (typeof jobCost5 === "function") afford("stallRow5", jobCost5);
    } catch (e) {}
  }
  setInterval(tick, 250);

  // ---- 3) 레벨업 피드백: Lv 텍스트가 올라가면 카드에 짧은 효과 ----
  var lastLv = new WeakMap();
  function pulse(el, cls) {
    el.classList.remove(cls);
    void el.offsetWidth;
    el.classList.add(cls);
    setTimeout(function () { el.classList.remove(cls); }, 800);
  }
  function watchLevels() {
    document.querySelectorAll(".stall .stall-lv").forEach(function (lv) {
      var n = parseInt(lv.textContent.replace(/\D/g, ""), 10) || 0;
      var prev = lastLv.get(lv);
      lastLv.set(lv, n);
      if (prev !== undefined && n > prev) {
        var card = lv.closest(".stall");
        if (card) { pulse(card, "fx-pop"); pulse(lv, "fx-lvup"); }
      }
    });
  }
  setInterval(watchLevels, 200);

  // ---- 4) 탭 버튼 / 업그레이드 / 독 눌림 피드백 + 떠오르는 숫자 ----
  document.addEventListener("pointerdown", function (e) {
    var t = e.target.closest && e.target.closest("#tapBtn, #buskBtn, #busk5Btn, .upgrade-mini:not(.disabled), .dock-btn");
    if (!t) return;
    pulse(t, "fx-pop");
  }, { passive: true });
})();
