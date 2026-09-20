-- =====================================================================
-- 인생 로또 (매일 밤 8시 이월형 추첨) — 서버 쪽 SQL
--
-- 사용법: Supabase 대시보드 > SQL Editor 에 이 파일 전체를 붙여넣고 Run 한 번.
--   * 여러 번 실행해도 안전합니다 (기존 데이터는 지우지 않아요).
--   * 기존 테이블(saves, leaderboard_entries 등)은 건드리지 않습니다.
--
-- 동작 방식
--   * 회차 = "다음 추첨일". 밤 8시(한국시간) 전에 사면 오늘 회차, 8시 이후에 사면 내일 회차예요.
--   * 크론이 필요 없어요. 8시가 지난 뒤 누구든 접속해서 lotto_settle()을 부르면
--     밀린 회차를 전부(하루씩 순서대로) 추첨해요. 이미 추첨된 회차는 다시 안 해요.
--   * 당첨번호는 서버에서만 뽑습니다 (gen_random_uuid 기반 CSPRNG 셔플).
--   * 게임의 돈은 클라이언트가 들고 있어서, 서버는 "티켓·추첨·당첨금 계산·중복 수령 방지"만 맡아요.
--
-- 금액을 바꾸려면 lotto_draw() 맨 위의 c_price / c_base / c_p2 / c_p3 / c_p4 와
-- lotto_get_state() 의 'cfg' 두 곳만 고치면 됩니다 (클라이언트는 cfg를 서버에서 받아 써요).
-- =====================================================================

-- ---------- 테이블 ----------
create table if not exists public.lotto_state (
  id          int primary key default 1 check (id = 1),   -- 한 줄짜리 테이블
  next_round  date not null,                               -- 다음에 추첨할 회차(추첨일, KST)
  carry       numeric(40,0) not null default 0,            -- 이월금
  carry_days  int not null default 0                       -- 1등이 안 나와서 이월된 연속 일수
);

create table if not exists public.lotto_tickets (
  id          bigserial primary key,
  round_date  date not null,
  user_id     uuid not null,
  name        text not null,
  nums        int[] not null,
  kind        text not null default '자동',
  created_at  timestamptz not null default now(),
  matches     smallint,                                    -- 추첨 후 채워짐
  rank        smallint,                                    -- 0=꽝, 1~4=등수
  prize       numeric(40,0) not null default 0,
  claimed     boolean not null default false
);
create index if not exists lotto_tickets_round_user on public.lotto_tickets (round_date, user_id);
create index if not exists lotto_tickets_user_unclaimed on public.lotto_tickets (user_id) where rank > 0 and not claimed;

create table if not exists public.lotto_rounds (
  round_date  date primary key,
  win         int[] not null,                              -- 공이 나온 "순서" 그대로
  sold        int not null,
  pot         numeric(40,0) not null,                      -- 1등 상금 총액(기본금+판매금+이월금)
  intake      numeric(40,0) not null,                      -- 티켓 판매 총액(회수)
  payout      numeric(40,0) not null,                      -- 당첨금 지급 총액
  first_share numeric(40,0) not null,                      -- 1등 1장당 상금
  counts      jsonb not null,                              -- {"1":n,"2":n,"3":n,"4":n}
  carry_out   numeric(40,0) not null,
  carry_days  int not null,
  season_end  boolean not null default false,              -- 그 달 마지막 회차 (이월금 소멸)
  top         jsonb not null,                              -- 1·2등 당첨자 목록
  all_nums    jsonb not null,                              -- 그 회차 전체 티켓 번호 (연출용 후보 계산)
  drawn_at    timestamptz not null default now()
);

create table if not exists public.lotto_claps (
  round_date  date not null,
  user_id     uuid not null,
  cnt         int not null default 0,
  primary key (round_date, user_id)
);

-- 테이블은 RPC 함수로만 접근: RLS를 켜고 정책을 하나도 안 만들면 클라이언트가 직접 못 읽고 못 써요.
alter table public.lotto_state   enable row level security;
alter table public.lotto_tickets enable row level security;
alter table public.lotto_rounds  enable row level security;
alter table public.lotto_claps   enable row level security;
revoke all on public.lotto_state, public.lotto_tickets, public.lotto_rounds, public.lotto_claps from anon, authenticated;

-- ---------- 시간 ----------
-- 시간 함수를 한 곳에 모아둔 것 (테스트할 때 이 함수만 바꿔 끼우면 시간을 조작할 수 있어요)
create or replace function public.lotto_now() returns timestamptz
language sql stable as $$ select now() $$;

-- 지금 사면 참가하는 회차 = 다음 추첨일 (한국시간 밤 8시 기준)
create or replace function public.lotto_cur_round() returns date
language sql stable set search_path = public as $$
  select case when (lotto_now() at time zone 'Asia/Seoul')::time >= time '20:00'
              then (lotto_now() at time zone 'Asia/Seoul')::date + 1
              else (lotto_now() at time zone 'Asia/Seoul')::date end
$$;

-- 회차의 추첨 시각(에포크 ms)
create or replace function public.lotto_draw_ms(p_round date) returns bigint
language sql stable as $$
  select (extract(epoch from ((p_round + time '20:00') at time zone 'Asia/Seoul')) * 1000)::bigint
$$;

-- ---------- 추첨 (내부용: 클라이언트에 권한 안 줌) ----------
-- p_win 은 테스트용(당첨번호 고정). 평소엔 null → 서버가 무작위로 뽑음.
create or replace function public.lotto_draw(p_round date, p_win int[] default null) returns void
language plpgsql security definer set search_path = public as $$
declare
  c_price constant numeric := 1000000000000;        -- 1장 가격 1조
  c_base  constant numeric := 500000000000000000;   -- 1등 기본 보장금 50경
  c_p2    constant numeric := 50000000000000000;    -- 2등 5경
  c_p3    constant numeric := 1000000000000000;     -- 3등 1,000조
  c_p4    constant numeric := 100000000000000;      -- 4등 100조
  v_win int[]; v_carry numeric; v_days int;
  v_sold int; v_intake numeric; v_pot numeric; v_first int; v_share numeric; v_payout numeric;
  v_carry_out numeric; v_days_out int; v_season_end boolean;
  v_counts jsonb; v_top jsonb; v_all jsonb;
begin
  -- 추첨하는 동안 티켓 추가/변경을 잠깐 막는다 (몇십 ms)
  lock table public.lotto_tickets in share row exclusive mode;

  select carry, carry_days into v_carry, v_days from public.lotto_state where id = 1;

  if p_win is not null then
    v_win := p_win;
  else
    select array_agg(n order by rn) into v_win
    from (select n, row_number() over (order by gen_random_uuid()) as rn from generate_series(1, 20) n) s
    where rn <= 6;
  end if;

  update public.lotto_tickets t
     set matches = (select count(*) from unnest(t.nums) x where x = any (v_win))
   where t.round_date = p_round;
  update public.lotto_tickets
     set rank = case matches when 6 then 1 when 5 then 2 when 4 then 3 when 3 then 4 else 0 end
   where round_date = p_round;

  select count(*) into v_sold  from public.lotto_tickets where round_date = p_round;
  select count(*) into v_first from public.lotto_tickets where round_date = p_round and rank = 1;
  v_intake := v_sold * c_price;
  v_pot    := c_base + v_intake + v_carry;                       -- 1등 상금 = 기본 보장금 + 오늘 판매금 + 누적 이월금
  v_share  := case when v_first > 0 then floor(v_pot / v_first) else 0 end;   -- 1등이 여러 장이면 균등 분배

  update public.lotto_tickets
     set prize = case rank when 1 then v_share when 2 then c_p2 when 3 then c_p3 when 4 then c_p4 else 0 end
   where round_date = p_round;
  select coalesce(sum(prize), 0) into v_payout from public.lotto_tickets where round_date = p_round;

  -- 1등이 없으면 상금 전부(기본금 포함)를 100% 이월. 나눗셈 자투리도 이월.
  v_carry_out := case when v_first > 0 then v_pot - v_share * v_first else v_pot end;
  v_days_out  := case when v_first > 0 then 0 else v_days + 1 end;
  -- 그 달 마지막 회차면 시즌이 끝나므로 이월금 소멸 (게임의 월간 초기화와 맞춤)
  v_season_end := extract(day from (p_round + 1)) = 1;
  if v_season_end then v_carry_out := 0; v_days_out := 0; end if;

  select jsonb_build_object(
           '1', count(*) filter (where rank = 1), '2', count(*) filter (where rank = 2),
           '3', count(*) filter (where rank = 3), '4', count(*) filter (where rank = 4))
    into v_counts from public.lotto_tickets where round_date = p_round;

  select coalesce(jsonb_agg(jsonb_build_object('uid', user_id, 'name', name, 'rank', rank, 'prize', prize::text)
                            order by rank, prize desc, id), '[]'::jsonb)
    into v_top
    from (select * from public.lotto_tickets where round_date = p_round and rank in (1, 2)
           order by rank, prize desc, id limit 12) w;

  select coalesce(jsonb_agg(to_jsonb(nums) order by id), '[]'::jsonb) into v_all
    from public.lotto_tickets where round_date = p_round;

  insert into public.lotto_rounds (round_date, win, sold, pot, intake, payout, first_share, counts, carry_out, carry_days, season_end, top, all_nums)
  values (p_round, v_win, v_sold, v_pot, v_intake, v_payout, v_share, v_counts, v_carry_out, v_days_out, v_season_end, v_top, v_all);

  update public.lotto_state set next_round = p_round + 1, carry = v_carry_out, carry_days = v_days_out where id = 1;
end $$;
revoke all on function public.lotto_draw(date, int[]) from public, anon, authenticated;

-- ---------- 8시가 지난 회차를 전부 추첨 (누가 불러도 안전: 한 번에 하나만 실행, 이미 한 회차는 건너뜀) ----------
create or replace function public.lotto_settle() returns int
language plpgsql security definer set search_path = public as $$
declare v_cur date := lotto_cur_round(); v_next date; n int := 0;
begin
  perform 1 from public.lotto_state where id = 1 for update;    -- 동시에 여러 명이 불러도 줄 세운다
  loop
    select next_round into v_next from public.lotto_state where id = 1;
    exit when v_next >= v_cur or n >= 40;
    perform public.lotto_draw(v_next);
    n := n + 1;
  end loop;
  return n;
end $$;

-- ---------- 현재 상태 (전광판 + 내 티켓 + 최근 추첨 기록) ----------
create or replace function public.lotto_get_state(p_history int default 10) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid(); v_cur date := lotto_cur_round(); v_st public.lotto_state%rowtype;
  v_sold int; v_mine jsonb; v_rounds jsonb; v_last date;
begin
  select * into v_st from public.lotto_state where id = 1;
  select count(*) into v_sold from public.lotto_tickets where round_date = v_cur;
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'nums', to_jsonb(nums), 'kind', kind) order by id), '[]'::jsonb)
    into v_mine from public.lotto_tickets where round_date = v_cur and user_id = v_uid;
  select max(round_date) into v_last from public.lotto_rounds;

  select coalesce(jsonb_agg(x.r order by x.d desc), '[]'::jsonb) into v_rounds from (
    select lr.round_date as d, jsonb_build_object(
      'round', lr.round_date, 'win', to_jsonb(lr.win), 'sold', lr.sold,
      'pot', lr.pot::text, 'intake', lr.intake::text, 'payout', lr.payout::text, 'first', lr.first_share::text,
      'counts', lr.counts, 'carry_out', lr.carry_out::text, 'carry_days', lr.carry_days, 'season_end', lr.season_end,
      'top', lr.top,
      'all_nums', case when lr.round_date = v_last then lr.all_nums else null end,
      'mine', (select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'nums', to_jsonb(t.nums), 'kind', t.kind,
                        'm', t.matches, 'rank', t.rank, 'prize', t.prize::text, 'claimed', t.claimed) order by t.id), '[]'::jsonb)
                 from public.lotto_tickets t where t.round_date = lr.round_date and t.user_id = v_uid)
    ) as r
    from public.lotto_rounds lr order by lr.round_date desc limit greatest(1, least(coalesce(p_history, 10), 30))
  ) x;

  return jsonb_build_object(
    'server_now', (extract(epoch from lotto_now()) * 1000)::bigint,
    'round', v_cur, 'draw_at', lotto_draw_ms(v_cur),
    'sold', v_sold, 'carry', v_st.carry::text, 'carry_days', v_st.carry_days,
    'last_drawn', v_last, 'mine', v_mine, 'rounds', v_rounds, 'uid', v_uid,
    'cfg', jsonb_build_object('price', '1000000000000', 'base1', '500000000000000000',
                              'p2', '50000000000000000', 'p3', '1000000000000000', 'p4', '100000000000000',
                              'max', 10)
  );
end $$;

-- ---------- 구매 (회차당 1인 10장 한도를 서버에서 강제) ----------
-- p_tickets: [{"nums":[1,2,3,4,5,6],"kind":"수동"|"자동"|"반자동"}, ...]
create or replace function public.lotto_buy(p_tickets jsonb, p_name text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  c_max constant int := 10;
  v_uid uuid := auth.uid(); v_round date := lotto_cur_round();
  v_have int; v_n int; t jsonb; v_nums int[]; v_kind text; v_name text; v_id bigint; v_new jsonb := '[]'::jsonb;
begin
  if v_uid is null then return jsonb_build_object('ok', false, 'err', 'auth'); end if;
  if p_tickets is null or jsonb_typeof(p_tickets) <> 'array' then return jsonb_build_object('ok', false, 'err', 'bad'); end if;
  v_n := jsonb_array_length(p_tickets);
  if v_n < 1 or v_n > c_max then return jsonb_build_object('ok', false, 'err', 'bad'); end if;

  perform pg_advisory_xact_lock(hashtextextended(v_uid::text || v_round::text, 0));   -- 같은 사람의 동시 구매를 줄 세운다
  select count(*) into v_have from public.lotto_tickets where round_date = v_round and user_id = v_uid;
  if v_have + v_n > c_max then
    return jsonb_build_object('ok', false, 'err', 'limit', 'left', c_max - v_have);
  end if;

  v_name := left(btrim(regexp_replace(coalesce(p_name, ''), '[[:cntrl:]]', ' ', 'g')), 12);
  if v_name = '' then v_name := '익명'; end if;

  for t in select * from jsonb_array_elements(p_tickets) loop
    select array_agg(x::int order by x::int) into v_nums from jsonb_array_elements_text(t -> 'nums') x;
    if v_nums is null or cardinality(v_nums) <> 6
       or (select count(distinct n) from unnest(v_nums) n) <> 6
       or exists (select 1 from unnest(v_nums) n where n < 1 or n > 20) then
      raise exception 'lotto_bad_ticket';            -- 예외로 던져서 앞에서 넣은 티켓도 함께 취소
    end if;
    v_kind := coalesce(t ->> 'kind', '자동');
    if v_kind not in ('수동', '자동', '반자동') then v_kind := '자동'; end if;
    insert into public.lotto_tickets (round_date, user_id, name, nums, kind)
    values (v_round, v_uid, v_name, v_nums, v_kind) returning id into v_id;
    v_new := v_new || jsonb_build_object('id', v_id, 'nums', to_jsonb(v_nums), 'kind', v_kind);
  end loop;

  return jsonb_build_object('ok', true, 'round', v_round, 'tickets', v_new, 'price', '1000000000000');
end $$;

-- ---------- 당첨금 수령 (한 번만: 받은 티켓은 claimed 처리) ----------
-- p_upto 회차까지의 미수령 당첨금을 합쳐서 돌려준다. 지난달 회차의 미수령분은 시즌 초기화와 함께 소멸.
create or replace function public.lotto_claim(p_upto date) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid(); v_total numeric; v_cnt int;
  v_month_start date := date_trunc('month', lotto_now() at time zone 'Asia/Seoul')::date;
begin
  if v_uid is null then return jsonb_build_object('ok', false, 'err', 'auth'); end if;
  update public.lotto_tickets set claimed = true
   where user_id = v_uid and not claimed and rank > 0 and round_date < v_month_start;
  with c as (
    update public.lotto_tickets set claimed = true
     where user_id = v_uid and not claimed and rank > 0
       and round_date <= coalesce(p_upto, '9999-12-31'::date) and round_date >= v_month_start
    returning prize)
  select coalesce(sum(prize), 0), count(*) into v_total, v_cnt from c;
  return jsonb_build_object('ok', true, 'total', v_total::text, 'count', v_cnt);
end $$;

-- ---------- 축하하기 (사람당 회차별 최대 50번) ----------
create or replace function public.lotto_congrats(p_round date, p_add int default 0) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_total bigint;
begin
  if v_uid is not null and coalesce(p_add, 0) > 0 then
    insert into public.lotto_claps (round_date, user_id, cnt) values (p_round, v_uid, least(p_add, 50))
    on conflict (round_date, user_id) do update set cnt = least(50, public.lotto_claps.cnt + least(p_add, 50));
  end if;
  select coalesce(sum(cnt), 0) into v_total from public.lotto_claps where round_date = p_round;
  return jsonb_build_object('total', v_total);
end $$;

-- ---------- 권한: 필요한 함수만 열어준다 ----------
revoke all on function public.lotto_settle()                      from public;
revoke all on function public.lotto_get_state(int)                from public;
revoke all on function public.lotto_buy(jsonb, text)              from public;
revoke all on function public.lotto_claim(date)                   from public;
revoke all on function public.lotto_congrats(date, int)           from public;
grant execute on function public.lotto_settle()                   to anon, authenticated;   -- 비로그인도 추첨 트리거 가능(멱등)
grant execute on function public.lotto_get_state(int)             to anon, authenticated;
grant execute on function public.lotto_congrats(date, int)        to anon, authenticated;
grant execute on function public.lotto_buy(jsonb, text)           to authenticated;
grant execute on function public.lotto_claim(date)                to authenticated;

-- ---------- 첫 회차 시작 (이미 있으면 그대로 둠) ----------
insert into public.lotto_state (id, next_round) values (1, public.lotto_cur_round()) on conflict (id) do nothing;
