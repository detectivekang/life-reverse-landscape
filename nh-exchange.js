/* 인생역전 -> 네온 호드 골드 환전 (1조 = 1골드, 1경 = 1만 골드)
   ui-v2.js 와 같은 방식의 추가 스크립트다. index.html 맨 아래 ui-v2.js 다음 줄에 이렇게 넣으면 된다:
       <script src="nh-exchange.js"></script>
   서버: sql/nh_deposit.sql 을 먼저 실행해야 한다.
   하는 일: 더보기 메뉴에 "네온 호드 환전" 버튼을 붙이고, 업데이트 공지(v2026111501)를 patchNotes 에 추가하고, 서버가 입금을 승인(OK)해 준 뒤에만 money 를 깎는다.
   실패하면 돈은 그대로다. 게임 코드는 건드리지 않는다. */
(function () {
  "use strict";
  var RATE = 1e12; // 인생역전 돈 1조 = 호드 골드 1
  var busy = false, left = null, cap = null;

  function fmtKR(n) {
    if (!isFinite(n)) return "0";
    n = Math.max(0, n);
    var U = [[1e24, "자"], [1e20, "해"], [1e16, "경"], [1e12, "조"], [1e8, "억"], [1e4, "만"]];
    for (var i = 0; i < U.length; i++) {
      if (n >= U[i][0]) {
        var v = n / U[i][0];
        var t = v >= 100 ? v.toFixed(0) : v >= 10 ? v.toFixed(1) : v.toFixed(2);
        if (t.indexOf(".") >= 0) t = t.replace(/\.?0+$/, "");
        return t + U[i][1];
      }
    }
    return Math.floor(n).toLocaleString("ko-KR");
  }
  function num(n) { return Math.floor(n).toLocaleString("ko-KR"); }
  function $(id) { return document.getElementById(id); }
  function toastMsg(t) { try { if (typeof showToast === "function") showToast(t); } catch (e) {} }

  function build() {
    if ($("nhxModal")) return;
    var d = document.createElement("div");
    d.className = "modal-overlay";
    d.id = "nhxModal";
    d.innerHTML =
      '<div class="modal-box">' +
      "<h2>💱 네온 호드 환전</h2>" +
      '<div style="font-size:13px;line-height:1.55;margin:8px 0;opacity:.9">인생역전 돈을 네온 호드 골드로 바꿔요.<br><b>1조 = 1골드</b> (1경 = 1만 골드)<br>바꾼 골드는 네온 호드를 열면 받아져요.</div>' +
      '<div style="font-size:13px;margin:6px 0">내 돈: <b id="nhxMoney">-</b></div>' +
      '<div style="font-size:13px;margin:6px 0">오늘 남은 한도: <b id="nhxLeft">-</b> 골드</div>' +
      '<div style="margin:10px 0;display:flex;gap:6px;align-items:center">' +
      '<input id="nhxAmt" type="number" inputmode="numeric" min="1" step="1" value="100" style="flex:1;padding:10px;border-radius:10px;border:1px solid var(--gold-dim);background:rgba(0,0,0,.35);color:inherit;font-size:16px;min-width:0" />' +
      '<span style="font-size:13px">골드</span></div>' +
      '<div style="display:flex;gap:6px;margin-bottom:8px">' +
      '<button class="close-btn" id="nhxQ1" style="flex:1">100</button>' +
      '<button class="close-btn" id="nhxQ2" style="flex:1">1,000</button>' +
      '<button class="close-btn" id="nhxQ3" style="flex:1">최대</button></div>' +
      '<div style="font-size:13px;margin:6px 0">필요한 돈: <b id="nhxCost">-</b></div>' +
      '<div id="nhxMsg" style="font-size:12px;min-height:18px;margin:6px 0;color:#ffb08a"></div>' +
      '<button class="close-btn" id="nhxGo" style="width:100%;margin-bottom:8px">환전하기</button>' +
      '<button class="close-btn" id="nhxClose" style="width:100%">닫기</button></div>';
    document.body.appendChild(d);
    $("nhxClose").onclick = close;
    d.addEventListener("click", function (e) { if (e.target === d) close(); });
    $("nhxAmt").oninput = refresh;
    $("nhxQ1").onclick = function () { $("nhxAmt").value = 100; refresh(); };
    $("nhxQ2").onclick = function () { $("nhxAmt").value = 1000; refresh(); };
    $("nhxQ3").onclick = function () { $("nhxAmt").value = maxGold(); refresh(); };
    $("nhxGo").onclick = doExchange;
  }
  function curMoney() { return typeof money === "number" ? money : 0; }
  function maxGold() {
    var byMoney = Math.floor(curMoney() / RATE);
    var byLeft = left == null ? byMoney : left;
    return Math.max(0, Math.min(byMoney, byLeft));
  }
  function setMsg(t) { var m = $("nhxMsg"); if (m) m.textContent = t || ""; }
  function refresh() {
    if (!$("nhxModal")) return;
    $("nhxMoney").textContent = fmtKR(curMoney());
    $("nhxLeft").textContent = left == null ? "-" : num(left);
    var g = Math.floor(+$("nhxAmt").value || 0);
    $("nhxCost").textContent = g > 0 ? fmtKR(g * RATE) : "-";
  }
  async function loadInfo() {
    left = null;
    try {
      if (typeof db === "undefined" || !db || typeof currentUser === "undefined" || !currentUser) {
        setMsg("구글 로그인이 필요해요.");
        return;
      }
      var r = await db.rpc("nh_deposit_info");
      if (r.error || !r.data || !r.data.ok) throw r.error || new Error("info");
      left = r.data.left; cap = r.data.cap;
      setMsg("");
    } catch (e) {
      setMsg("한도를 불러오지 못했어요. 잠시 후 다시 열어 주세요.");
    }
    refresh();
  }
  async function doExchange() {
    if (busy) return;
    var g = Math.floor(+$("nhxAmt").value || 0);
    if (g < 1) return setMsg("환전할 골드를 입력해 주세요.");
    if (typeof db === "undefined" || !db || typeof currentUser === "undefined" || !currentUser) return setMsg("구글 로그인이 필요해요.");
    if (typeof deviceDisplaced !== "undefined" && deviceDisplaced) return setMsg("다른 기기에서 플레이 중이라 지금은 환전할 수 없어요.");
    var cost = g * RATE;
    if (curMoney() < cost) return setMsg("돈이 부족해요. 필요한 돈: " + fmtKR(cost));
    if (left != null && g > left) return setMsg("오늘 한도(" + num(left) + "골드)를 넘었어요.");
    busy = true; $("nhxGo").disabled = true;
    try {
      var r = await db.rpc("nh_deposit", { p_gold: g });
      if (r.error) throw r.error;
      if (!r.data || !r.data.ok) throw new Error("fail");
      // 서버가 승인했을 때만 돈을 깎는다
      money = Math.max(0, curMoney() - cost);
      try { if (typeof saveGame === "function") saveGame({ forceCloud: true }); } catch (e) {}
      left = r.data.left;
      toastMsg("호드 골드 " + num(g) + " 환전 완료! 네온 호드를 열면 받아요");
      setMsg("완료! 네온 호드 메뉴를 열면 골드가 들어와요.");
    } catch (e) {
      var m = String((e && (e.message || e.details)) || "");
      if (m.indexOf("NH_LIMIT") >= 0) { await loadInfo(); setMsg("오늘 환전 한도에 도달했어요."); }
      else if (m.indexOf("NH_LOGIN") >= 0) setMsg("구글 로그인이 필요해요.");
      else if (m.indexOf("NH_BANNED") >= 0) setMsg("환전을 사용할 수 없는 계정이에요.");
      else setMsg("환전에 실패했어요. 돈은 그대로예요. 잠시 후 다시 시도해 주세요.");
    }
    busy = false; $("nhxGo").disabled = false; refresh();
  }
  function open() {
    build();
    var mm = $("moreMenuModal"); if (mm) mm.classList.remove("show");
    $("nhxModal").classList.add("show");
    setMsg(""); refresh(); loadInfo();
  }
  function close() { var m = $("nhxModal"); if (m) m.classList.remove("show"); }

  /* ---- 공지: 이 파일이 로드되면 patchNotes 맨 앞에 한 번만 추가한다 (같은 version 이 이미 있으면 건너뛴다) ---- */
  var NOTICE_VERSION = "2026111501";
  var NOTICE = { version: NOTICE_VERSION, date: "2026-11-15", items: [
    "🛸 <b>네온 호드 2 업데이트!</b> 새 스테이지 2곳(🧊 빙하 핵 · ☣️ 독성 제련소), 새 보스 4종, 새 무기 6종(총 18종), 새 캐릭터 10명(총 20명), 유물 28종, 업적 41개가 추가됐어요",
    "⚔️ <b>더 어려워진 도전!</b> 승급이 25단계까지 열리고, 정예 적과 변이 18종이 생겼어요. 매일 바뀌는 🗓️ <b>일일 도전</b>은 하루 첫 클리어에 보너스 골드를 줘요",
    "📈 <b>성장 요소가 늘었어요!</b> 능력치 강화가 16종으로 늘고 최대 20레벨까지 올릴 수 있어요(후반일수록 비싸요). 캐릭터별 <b>마스터리</b>(10레벨, 공격력·체력 최대 +10%)도 생겼어요",
    "💱 <b>인생역전 돈을 네온 호드 골드로 바꿀 수 있어요!</b> 더보기 메뉴의 '💱 네온 호드 환전'에서 <b>1조 = 1골드</b> (1경 = 1만 골드)로 환전해요. 하루 최대 50,000골드(= 5경)까지, 바꾼 골드는 네온 호드를 열면 들어와요. 로그인이 필요해요",
    "🔒 환전한 골드는 영구 강화·캐릭터 해금처럼 <b>네온 호드 안에서만</b> 쓸 수 있어요. 되돌리기·주문서 같은 아이템은 환전 골드로 살 수 없어요",
    "🪙 <b>오늘의 상점 가격이 8배로 올랐어요!</b> 💎 차원 조각 10,000개 80,000골드 · 🛡️ 되돌리기 1개 40,000 · 🍀 강화 주문서 ×1.5 40,000 / ×2 80,000 / ×2.5 160,000 · ⚔️ 검 배틀 1회 4,000골드 (하루 구매 횟수는 그대로). 캐릭터 해금과 외형 가격도 5배가 됐어요",
    "🔓 <b>해금 조건이 훨씬 어려워졌어요.</b> 이미 해금한 캐릭터와 무기는 그대로 쓸 수 있고, 새로 해금하는 것부터 새 조건이 적용돼요",
    "🛠️ <b>버그 수정:</b> 결과 화면 글씨가 화면을 넘어가던 문제, 정예 적·보스 탄막에 체력이 가득한데도 한 번에 쓰러지던 문제, 지뢰 무기가 진화하지 않던 문제를 고쳤어요"
  ] };
  function addNotice() {
    try {
      if (typeof patchNotes === "undefined" || !Array.isArray(patchNotes)) return;
      for (var i = 0; i < patchNotes.length; i++) if (patchNotes[i] && patchNotes[i].version === NOTICE_VERSION) return;
      patchNotes.unshift(NOTICE);
      if (typeof updateNoticeBadge === "function") updateNoticeBadge();
    } catch (e) {}
  }

  function inject() {
    try {
      var anchor = $("noticeBtn");
      if (!anchor || $("nhxMenuBtn")) return;
      var b = document.createElement("button");
      b.className = "close-btn more-menu-item";
      b.id = "nhxMenuBtn";
      b.style.textAlign = "left";
      b.textContent = "💱 네온 호드 환전";
      b.onclick = open;
      anchor.parentNode.insertBefore(b, anchor.nextSibling);
    } catch (e) {}
  }
  function boot() { inject(); addNotice(); }
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", boot);
  else boot();
})();
