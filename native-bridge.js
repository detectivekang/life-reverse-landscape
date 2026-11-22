/* 안드로이드 앱(Capacitor) 전용 다리.
   웹 브라우저에서는 아무것도 하지 않는다 (Capacitor 가 없으면 바로 종료).
   앱에서는 두 가지를 게임 코드에 열어 준다:
     window.LR_NativeGoogleIdToken()  → Promise<string>  앱용 구글 로그인으로 받은 ID 토큰
     window.LR_NativeRewardedAd()     → Promise<boolean> AdMob 보상형 광고를 끝까지 봤으면 true */
(function () {
  var C = window.Capacitor;
  if (!C || typeof C.isNativePlatform !== "function" || !C.isNativePlatform())
    return;
  var P = C.Plugins || {};

  // ===== 출시 전에 본인 값으로 교체하는 곳 =====
  var CFG = {
    // Google Cloud 콘솔 > 사용자 인증 정보 > "웹 애플리케이션" 클라이언트 ID (Supabase 구글 로그인에 넣은 것과 같은 값)
    GOOGLE_WEB_CLIENT_ID:
      "570917473549-hk0one4un4b7o9i2gl1p8e1np23b50vd.apps.googleusercontent.com",
    // AdMob > 앱 > 광고 단위 > 보상형 광고 단위 ID
    ADMOB_REWARDED_ID: "ca-app-pub-0000000000000000/0000000000",
    // true 면 구글 공식 테스트 광고만 나온다. 출시 빌드 전에 반드시 false 로.
    // AdMob > 광고 단위 > 전면 광고 단위 ID (네온 호드 죽었을 때 나오는 광고)
    ADMOB_INTERSTITIAL_ID: "ca-app-pub-0000000000000000/0000000000",
    USE_TEST_ADS: true,
    // 전면 광고 사이 최소 간격(밀리초). 너무 자주 나오면 이탈이 늘고 정책상도 좋지 않아서 간격을 둔다.
    INTERSTITIAL_MIN_GAP_MS: 90000,
  };
  var TEST_REWARDED_ID = "ca-app-pub-3940256099942544/5224354917"; // 구글 공식 테스트 보상형 광고 단위
  var TEST_INTERSTITIAL_ID = "ca-app-pub-3940256099942544/1033173712"; // 구글 공식 테스트 전면 광고 단위

  // ---------- 구글 로그인 ----------
  var socialReady = null;
  function initSocial() {
    if (socialReady) return socialReady;
    if (!P.SocialLogin)
      return Promise.reject(new Error("SocialLogin 플러그인 없음"));
    socialReady = P.SocialLogin.initialize({
      google: { webClientId: CFG.GOOGLE_WEB_CLIENT_ID },
    }).catch(function (e) {
      socialReady = null;
      throw e;
    });
    return socialReady;
  }
  window.LR_NativeGoogleIdToken = function () {
    return initSocial()
      .then(function () {
        return P.SocialLogin.login({ provider: "google", options: {} });
      })
      .then(function (res) {
        var r = res && res.result;
        var token = r && r.idToken;
        if (!token) throw new Error("ID 토큰을 받지 못했어요");
        return token;
      });
  };

  // ---------- 보상형 광고 (AdMob) ----------
  var adInit = null;
  var adBusy = false;
  function initAds() {
    if (adInit) return adInit;
    if (!P.AdMob) return Promise.reject(new Error("AdMob 플러그인 없음"));
    var A = P.AdMob;
    // 유럽(EEA)·영국 사용자에게는 광고 동의 창(UMP)이 필요하다. AdMob 콘솔에 동의 메시지를 만들어 두면 자동으로 뜬다.
    var consent = A.requestConsentInfo
      ? A.requestConsentInfo()
          .then(function (info) {
            if (
              info &&
              info.isConsentFormAvailable &&
              info.status === "REQUIRED"
            )
              return A.showConsentForm();
          })
          .catch(function () {})
      : Promise.resolve();
    adInit = consent
      .then(function () {
        return A.initialize({ initializeForTesting: CFG.USE_TEST_ADS });
      })
      .catch(function (e) {
        adInit = null;
        throw e;
      });
    return adInit;
  }
  window.LR_NativeRewardedAd = function () {
    if (adBusy) return Promise.resolve(false);
    adBusy = true;
    var A = P.AdMob;
    return initAds()
      .then(function () {
        return A.prepareRewardVideoAd({
          adId: CFG.USE_TEST_ADS ? TEST_REWARDED_ID : CFG.ADMOB_REWARDED_ID,
          isTesting: CFG.USE_TEST_ADS,
        });
      })
      .then(function () {
        return A.showRewardVideoAd(); // 보상을 받으면 resolve, 보상 전에 닫으면 REWARDED_AD_CANCELLED 로 reject
      })
      .then(
        function () {
          adBusy = false;
          return true;
        },
        function (e) {
          adBusy = false;
          if (
            e &&
            (e.code === "REWARDED_AD_CANCELLED" ||
              /dismissed before/i.test(e.message || ""))
          )
            return false;
          throw e;
        },
      );
  };

  // ---------- 전면 광고 (AdMob) ----------
  // 광고가 닫히면 true, 안 나왔으면(간격 제한·불러오기 실패·시간 초과) false 로 끝난다.
  var lastInterstitial = 0;
  window.LR_NativeInterstitialAd = function () {
    if (adBusy || Date.now() - lastInterstitial < CFG.INTERSTITIAL_MIN_GAP_MS)
      return Promise.resolve(false);
    adBusy = true;
    var A = P.AdMob;
    return new Promise(function (resolve) {
      var handles = [],
        done = false;
      function finish(shown) {
        if (done) return;
        done = true;
        adBusy = false;
        if (shown) lastInterstitial = Date.now();
        handles.forEach(function (h) {
          try {
            h.remove();
          } catch (e) {}
        });
        resolve(shown);
      }
      initAds()
        .then(function () {
          return Promise.all([
            A.addListener("interstitialAdDismissed", function () {
              finish(true);
            }),
            A.addListener("interstitialAdFailedToShow", function () {
              finish(false);
            }),
          ]);
        })
        .then(function (hs) {
          handles = hs;
          var timeout = new Promise(function (_, rej) {
            setTimeout(function () {
              rej(new Error("load timeout"));
            }, 7000);
          });
          return Promise.race([
            A.prepareInterstitial({
              adId: CFG.USE_TEST_ADS
                ? TEST_INTERSTITIAL_ID
                : CFG.ADMOB_INTERSTITIAL_ID,
              isTesting: CFG.USE_TEST_ADS,
            }),
            timeout,
          ]);
        })
        .then(function () {
          return A.showInterstitial();
        })
        .then(function () {
          setTimeout(function () {
            finish(true);
          }, 120000);
        }) // 닫힘 알림을 못 받아도 멈추지 않게 하는 안전장치
        .catch(function () {
          finish(false);
        });
    });
  };

  // ---------- 뒤로가기 버튼 ----------
  // 게임 화면이 'lr-back' 이벤트를 받아서(preventDefault) 직접 처리하면 앱이 꺼지지 않는다.
  // 아무도 처리하지 않으면 기본 동작: 이전 화면이 있으면 뒤로, 없으면 앱 종료.
  if (P.App && P.App.addListener) {
    P.App.addListener("backButton", function (ev) {
      var e = new CustomEvent("lr-back", { cancelable: true });
      window.dispatchEvent(e);
      if (e.defaultPrevented) return;
      if (ev && ev.canGoBack) window.history.back();
      else P.App.exitApp();
    });
  }
})();
