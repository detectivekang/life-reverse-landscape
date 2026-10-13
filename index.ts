import { createClient } from "npm:@supabase/supabase-js@2";

// 게임(index.html)의 PORTONE_STORE_ID 와 같은 값. 공개돼도 되는 식별자다.
const STORE_ID = "store-ae1726c2-237e-405b-af44-6aef5427446e";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });

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
