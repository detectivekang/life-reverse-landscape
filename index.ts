// 포트원 결제 검증 + 루비 지급 (Supabase Edge Function)
// 호출 경로 2가지: ① 게임(브라우저)이 결제 직후 { paymentId } 전송  ② 포트원 웹훅 (body.data.paymentId)
// 어느 쪽이든 "받은 값을 믿지 않고" 포트원 API 로 결제를 다시 조회해서 확인한다.
//   → 누가 이 주소를 호출하든, 실제로 PAID 이고 금액이 주문과 같을 때만 루비가 들어간다 (중복 호출해도 한 번만).
// 배포: supabase functions deploy portone-verify --no-verify-jwt
// 시크릿: supabase secrets set PORTONE_API_SECRET=... (SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY 는 자동 제공)
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "https://detectivekang.github.io",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, status = 200) =>
  new Response(JSON.stringify(b), { status, headers: { ...cors, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ ok: false, reason: "method" }, 405);

  let body: any = {};
  try { body = await req.json(); } catch (_) { /* 빈 본문 */ }
  const paymentId: string | undefined = body?.paymentId ?? body?.data?.paymentId;
  if (!paymentId || typeof paymentId !== "string" || !paymentId.startsWith("lr-") || paymentId.length > 80) {
    return json({ ok: false, reason: "bad_payment_id" }, 400);
  }

  // 1) 포트원에서 결제 단건 조회
  const secret = Deno.env.get("PORTONE_API_SECRET");
  if (!secret) return json({ ok: false, reason: "server_config" }, 500);
  const pr = await fetch(`https://api.portone.io/payments/${encodeURIComponent(paymentId)}`, {
    headers: { Authorization: `PortOne ${secret}` },
  });
  if (!pr.ok) return json({ ok: false, reason: "portone_lookup_failed", status: pr.status }, 502);
  const pay = await pr.json();

  // 2) 결제 완료 여부
  if (pay.status !== "PAID") return json({ ok: false, reason: "not_paid", status: pay.status });
  if (pay.currency && pay.currency !== "KRW") return json({ ok: false, reason: "bad_currency" });

  // 3) 금액 확인 + 루비 지급은 DB 함수가 한 번에 처리 (주문 금액과 비교, 중복 지급 방지)
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const { data, error } = await sb.rpc("charge_complete", {
    p_payment_id: paymentId,
    p_paid_amount: Number(pay.amount?.total),
  });
  if (error) { console.error("charge_complete", error); return json({ ok: false, reason: "db_error" }, 500); }
  return json(data);
});
