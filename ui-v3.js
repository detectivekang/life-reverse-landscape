/* 인생역전 UI v3 — 표시 전용 보강. index.html 맨 아래 ui-v2.js 다음 줄에 이렇게 넣는다:
       <script src="ui-v3.js"></script>
   1) 상가·월드 탭에서도 가격 칩과 직원 버튼이 "살 수 있으면 초록 / 못 사면 빨강"으로 표시된다
      (ui-v2.js 는 거리 줄(data-idx)만 칠해서 상가(data-idx2)·월드(data-idx5)는 색이 안 바뀌었다).
   2) 상가·월드 탭 아래에도 "클릭 업그레이드" 카드가 생긴다. 누르면 거리 탭의 카드를 누른 것과 똑같이 구매된다.
   게임 상태(money 등)는 읽기만 하고, 구매는 원래 카드의 클릭을 그대로 실행한다. 실패해도 게임은 그대로 동작한다. */
(function () {
  "use strict";

  // ---------- 스타일 ----------
  try {
    var st = document.createElement("style");
    st.textContent =
      ".employee-btn.is-ready{background:linear-gradient(180deg,#5be0b6,var(--jade,#1fb98c));color:#05291d;border-color:transparent;box-shadow:0 2px 0 var(--jade-lo,#0f7a5c)}" +
      ".employee-btn.is-poor{color:#ff9aae;border-color:rgba(239,91,123,.35);background:rgba(239,91,123,.08)}" +
      ".employee-btn:disabled{opacity:.55}" +
      ".nhx-mirror-wrap{flex:1;min-width:0;display:flex;flex-direction:column;gap:6px;justify-content:center}" +
      ".nhx-mirror{cursor:pointer;display:flex;align-items:center;justify-content:space-between}" +
      ".nhx-mirror.disabled{cursor:default}";
    document.head.appendChild(st);
  } catch (e) {}

  // ---------- 1) 구매 가능/불가 표시 (상가·월드) ----------
  function paint(rowId, attr, costFn) {
    var row = document.getElementById(rowId);
    if (!row || typeof costFn !== "function" || typeof money !== "number") return;
    var cards = row.querySelectorAll(".stall[" + attr + "]");
    for (var i = 0; i < cards.length; i++) {
      var el = cards[i], idx = +el.getAttribute(attr), cost;
      try { cost = costFn(idx); } catch (e) { continue; }
      if (typeof cost !== "number") continue;
      var ok = money >= cost;
      el.classList.toggle("is-ready", ok);
      el.classList.toggle("is-poor", !ok);
    }
  }
  function paintEmployees() {
    if (typeof employeeCost2 !== "function" || typeof money !== "number") return;
    var btns = document.querySelectorAll("#stallRow2 .employee-btn[data-emp]");
    for (var i = 0; i < btns.length; i++) {
      var b = btns[i], cost;
      try { cost = employeeCost2(+b.getAttribute("data-emp")); } catch (e) { continue; }
      if (typeof cost !== "number") continue;
      var ok = !b.disabled && money >= cost;
      b.classList.toggle("is-ready", ok);
      b.classList.toggle("is-poor", !ok && !b.disabled);
    }
  }

  // ---------- 2) 클릭 업그레이드 카드를 상가·월드 탭에도 ----------
  function addMirror(screenId, summaryId) {
    var sc = document.getElementById(screenId);
    if (!sc) return;
    var bar = sc.querySelector(".bottom-bar");
    if (!bar || bar.querySelector(".nhx-mirror")) return;
    var sum = document.getElementById(summaryId);
    var wrap = document.createElement("div");
    wrap.className = "nhx-mirror-wrap";
    if (sum && sum.parentNode === bar) { bar.replaceChild(wrap, sum); wrap.appendChild(sum); }
    else bar.appendChild(wrap);
    var card = document.createElement("div");
    card.className = "upgrade-mini nhx-mirror";
    card.innerHTML = '<div><div class="upgrade-name"></div><div class="upgrade-meta"></div></div><div class="upgrade-cost"></div>';
    card.addEventListener("click", function () {
      var src = document.getElementById("upgradeCard");
      if (src) src.click(); // 원래 카드의 클릭 = 거리 탭에서 누른 것과 같은 구매
    });
    wrap.appendChild(card);
  }
  function syncMirrors() {
    var src = document.getElementById("upgradeCard");
    if (!src) return;
    var n = document.getElementById("upgradeName"), m = document.getElementById("upgradeMeta"), c = document.getElementById("upgradeCostText");
    var mirrors = document.querySelectorAll(".nhx-mirror");
    for (var i = 0; i < mirrors.length; i++) {
      var el = mirrors[i];
      var a = el.querySelector(".upgrade-name"), b = el.querySelector(".upgrade-meta"), d = el.querySelector(".upgrade-cost");
      if (a && n) a.textContent = n.textContent;
      if (b && m) b.textContent = m.textContent;
      if (d && c) d.textContent = c.textContent;
      el.classList.toggle("disabled", src.classList.contains("disabled"));
    }
  }

  function tick() {
    try {
      if (typeof jobCost2 === "function") paint("stallRow2", "data-idx2", jobCost2);
      if (typeof jobCost5 === "function") paint("stallRow5", "data-idx5", jobCost5);
      paintEmployees();
      addMirror("part2Screen", "map2Summary");
      addMirror("part5Screen", "map5Summary");
      syncMirrors();
    } catch (e) {}
  }
  setInterval(tick, 250);
  tick();
})();
