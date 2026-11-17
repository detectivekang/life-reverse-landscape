-- 네온 호드 2 · 1단계 서버 패치 (nh_finish_run 만 교체, 여러 번 실행해도 안전)
--   승급 상한 10 → 25 / 변형 규칙 골드 배율 2.5 → 4.5 (변이 18종) / 일일 도전 보너스 여유(relic 1.5 → 2.5) / 한 판 골드 상한 20000 → 60000
--   적용하지 않아도 게임은 동작하지만, 승급 10 초과 판의 서버 인정 골드(환전용)가 승급 10 기준으로 잘린다.

create or replace function public.nh_finish_run(
  p_run uuid, p_time numeric, p_kills int, p_win boolean, p_asc int,
  p_bosskills int, p_coins int, p_gold bigint, p_name text
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  -- ===== 튜닝 상수 =====
  c_max_kps      constant numeric := 12;      -- 초당 최대 처치 수(이 이상은 인정 안 함 · 실제 플레이 데이터를 보고 조정)
  c_kill_base    constant numeric := 100;     -- 기본 여유 처치 수
  c_min_run_sec  constant numeric := 15;      -- 이보다 짧은 판은 점수/골드 없음
  c_gold_run_cap constant bigint  := 60000;   -- 한 판에서 인정하는 최대 골드
  c_mult_greed   constant numeric := 1.5;     -- 탐욕 5단계 최대 배율
  c_mult_relic   constant numeric := 2.5;     -- 탐욕의 주머니 유물
  c_mult_mut     constant numeric := 4.5;     -- 변형 규칙 골드 배율 최대치(보수적으로 넉넉히)
  -- =====================
  uid uuid := auth.uid(); r public.nh_runs%rowtype;
  real_s numeric; t numeric; k int; bk int; coins int; a int; won boolean;
  base numeric; g_max numeric; g_ok bigint; sc bigint; sk text := public.nh_season_key();
  nm text := public.nh_clean_name(p_name); sscore bigint; swallet bigint;
begin
  if uid is null then raise exception 'NH_LOGIN'; end if;
  if public.nh_is_banned(uid::text) then raise exception 'NH_BANNED'; end if;

  select * into r from public.nh_runs where id = p_run and user_id = uid for update;
  if not found or r.finished_at is not null then raise exception 'NH_BAD_RUN'; end if;

  real_s := extract(epoch from (now() - r.started_at));
  -- 게임 시간은 실제 흐른 시간을 넘을 수 없다 (일시정지가 있으면 실제 시간이 더 길다)
  t := least(greatest(coalesce(p_time, 0), 0), real_s + 3);
  if r.stage < 3 then t := least(t, 660); end if;   -- 일반 스테이지는 10분 + 보스전 여유
  k  := least(greatest(coalesce(p_kills, 0), 0), floor(c_kill_base + t * c_max_kps))::int;
  bk := least(greatest(coalesce(p_bosskills, 0), 0), case when r.stage = 3 then 1 + floor(t / 300) else 0 end)::int;
  coins := least(greatest(coalesce(p_coins, 0), 0), floor(60 + t * 3))::int;
  a := least(greatest(coalesce(p_asc, 0), 0), 25);
  -- 일반 스테이지의 승리 = 보스 처치(보스는 약 10분에 등장) → 짧은 판의 승리는 인정하지 않는다
  won := coalesce(p_win, false) and r.stage < 3 and t >= 540;

  if real_s < c_min_run_sec or t < c_min_run_sec then
    update public.nh_runs set finished_at = now(), time_s = t, kills = 0, boss_kills = 0, win = false,
           asc_lv = a, claim_gold = p_gold, credited_gold = 0, score = 0 where id = r.id;
    return jsonb_build_object('ok', true, 'credited_gold', 0, 'score_added', 0, 'season', sk, 'too_short', true);
  end if;

  -- 클라이언트의 골드 공식: (처치*.15 + 시간*.1 + 승리150 + 코인 + 보스*25) × 탐욕 × 유물 × 변형 × 스테이지 × 승급
  base  := k * 0.15 + t * 0.1 + (case when won then 150 else 0 end) + coins + bk * 25;
  g_max := floor(base * c_mult_greed * c_mult_relic * c_mult_mut
                 * (1 + least(r.stage, 2) * 0.5) * (1 + 0.25 * a));
  g_ok  := least(greatest(coalesce(p_gold, 0), 0), g_max::bigint, c_gold_run_cap);

  sc := k + floor(t / 2)::bigint + (case when won then 300 else 0 end) + bk * 100;

  update public.nh_runs set finished_at = now(), time_s = t, kills = k, boss_kills = bk, win = won,
         asc_lv = a, claim_gold = p_gold, credited_gold = g_ok, score = sc where id = r.id;

  insert into public.nh_wallet as w (user_id, earned_gold) values (uid, g_ok)
  on conflict (user_id) do update set earned_gold = w.earned_gold + excluded.earned_gold, updated_at = now()
  returning w.earned_gold - w.exchanged_gold into swallet;

  insert into public.nh_season_scores as s (season, user_id, name, score, runs, best_time)
  values (sk, uid, nm, sc, 1, t::int)
  on conflict (season, user_id) do update
    set score = s.score + excluded.score, runs = s.runs + 1, name = excluded.name,
        best_time = greatest(s.best_time, excluded.best_time), updated_at = now()
  returning s.score into sscore;

  return jsonb_build_object('ok', true, 'credited_gold', g_ok, 'score_added', sc, 'season', sk,
                            'season_score', sscore, 'exchangeable', swallet);
end $$;
revoke all on function public.nh_finish_run(uuid, numeric, int, boolean, int, int, int, bigint, text) from public, anon;
grant execute on function public.nh_finish_run(uuid, numeric, int, boolean, int, int, int, bigint, text) to authenticated;
