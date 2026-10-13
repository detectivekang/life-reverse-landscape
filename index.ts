import { createClient } from "npm:@supabase/supabase-js@2";

// 게임(index.html)의 PORTONE_STORE_ID 와 같은 값. 공개돼도 되는 식별자다.
const STORE_ID = "store-ae1726c2-237e-405b-af44-6aef5427446e";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
// 응답에 항상 v 가 들어간다. 게임 콘솔의 "[충전] portone-verify 응답"에 v 가 보이면 이 버전이 배포된 것.
const VERSION = "2026-10-13-d-diag";
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify({ v: VERSION, ...(body as Record<string, unknown>) }), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });

// 404 원인 진단용: 이 시크릿으로 실제로 보이는 최근 결제 5건을 서버 로그에만 남긴다(응답에는 넣지 않음).
async function diagRecentPayments(secret: string) {
  try {
    const body = { page: { number: 0, size: 5 }, filter: { storeId: STORE_ID } };
    const r = await fetch(
      `https://api.portone.io/payments?requestBody=${encodeURIComponent(JSON.stringify(body))}`,
      { headers: { Authorization: `PortOne ${secret}` } },
    );
    const text = await r.text();
    if (!r.ok) {
      console.error("diag list http", r.status, text.slice(0, 300));
      return;
    }
    const j = JSON.parse(text);
    const items = (j.items ?? []).map((p: any) => ({
      id: p.id,
      status: p.status,
      store: p.storeId,
      channel: p.channel?.type,
    }));
    console.error("diag recent payments", JSON.stringify(items), "total", j.page?.totalCount);
  } catch (e) {
    console.error("diag failed", String(e));
  }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  try {
    const { paymentId } = await req.json();
    // charge_prepare 가 만드는 형식(lr- + 32자리 hex)만 받는다
    if (typeof paymentId !== "string" || !/^lr-[0-9a-f]{32}$/.test(paymentId)) {
      return json({ ok: false, reason: "bad_payment_id" });
    }

    const secret = Deno.env.get("PORTONE_API_SECRET")?.trim();
    if (!secret) {
      console.error("PORTONE_API_SECRET 시크릿이 없습니다");
      return json({ ok: false, reason: "server_misconfigured" });
    }

    // 1) 포트원에서 실제 결제 상태·금액 확인 (브라우저가 하는 말은 믿지 않는다)
    const r = await fetch(
      `https://api.portone.io/payments/${encodeURIComponent(paymentId)}?storeId=${STORE_ID}`,
      { headers: { Authorization: `PortOne ${secret}` } },
    );
    if (r.status === 404) {
      // 결제창만 열고 끝내지 않았거나, 시크릿이 다른 상점 것인 경우
      console.error("portone 404", paymentId, await r.text());
      await diagRecentPayments(secret);
      return json({ ok: false, reason: "not_paid", portone: 404 });
    }
    if (!r.ok) {
      console.error("portone api", r.status, await r.text());
      return json({ ok: false, reason: "portone_http_" + r.status });
    }
    const payment = await r.json();
    if (payment.status !== "PAID") {
      return json({ ok: false, reason: "not_paid", status: payment.status });
    }
    const paid = Number(payment.amount?.total);
    if (!Number.isInteger(paid)) return json({ ok: false, reason: "bad_amount" });

    // 2) 서버 DB 의 주문과 대조 + 루비 지급 (중복 지급 방지는 charge_complete 안에서 처리됨)
    const sb = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );
    const { data, error } = await sb.rpc("charge_complete", {
      p_payment_id: paymentId,
      p_paid_amount: paid,
    });
    if (error) {
      console.error("charge_complete", error);
      return json({ ok: false, reason: "db_error" });
    }
    return json(data);
  } catch (e) {
    console.error(e);
    return json({ ok: false, reason: "exception" });
  }
});
