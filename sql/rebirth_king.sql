-- 환생왕 랭킹 (이번 시즌에 "직접 환생한 횟수" 순위)
-- 적용: Supabase 대시보드 > SQL Editor 에 통째로 붙여 넣고 Run. 여러 번 실행해도 안전하다.
-- 전제: saves 테이블, bignum() 함수가 있어야 한다 (supabase-migration-life-reverse.sql 적용 완료 상태).
--
-- 동작
--  * saves 가 저장될 때마다(트리거) 이번 시즌 환생 횟수를 rebirth_scores 에 기록한다. 시즌(월)이 지나도 기록이 남아서
--    지난 시즌 순위로 보상을 줄 수 있다.
--  * 횟수는 클라이언트가 보낸 값(data.missionRebirths, 월 키 data.missionMonth)을 쓰되, 서버가 검증한 시즌 누적 수입
--    (data.totalEarned)으로 상한을 건다: N회 환생하려면 허들이 1경,2경,...,N경 이라서 누적 수입이 N(N+1)/2 경 이상이어야 한다.
--    (누적 수입은 기존 saves_validate_growth 트리거가 증가 속도를 제한하므로, 횟수를 부풀릴 수 없다)
--  * 동점이면 시즌 누적 수입이 높은 쪽 → 먼저 그 횟수에 도달한 쪽이 앞선다.
--  * 트리거 안의 오류는 전부 삼켜서, 이 기능 때문에 게임 저장이 실패하는 일은 없다.

create table if not exists public.rebirth_scores (
  season       text not null,                 -- 'YYYY-MM' (한국시간 월)
  user_id      uuid not null references auth.users(id) on delete cascade,
  name         text,
  cnt          int  not null default 0,       -- 이번 시즌 환생 횟수(검증된 값)
  season_total numeric not null default 0,    -- 이번 시즌 누적 수입
  updated_at   timestamptz not null default now(),  -- 마지막으로 횟수가 늘어난 시각(동점 처리용)
  primary key (season, user_id)
);
create index if not exists rebirth_scores_rank_idx on public.rebirth_scores (season, cnt desc, season_total desc, updated_at asc);
alter table public.rebirth_scores enable row level security;
revoke all on public.rebirth_scores from anon, authenticated;

create or replace function public.rebirth_scores_sync()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  sk text := to_char(now() at time zone 'Asia/Seoul', 'YYYY-MM');
  claimed numeric; tot numeric; bound numeric; c int; nm text; banned boolean := false;
begin
  begin
    -- 월이 안 맞으면(지난달 데이터를 새 달에 저장 등) 건너뛴다
    if (NEW.data->>'missionMonth') is distinct from sk then return NEW; end if;
    claimed := case when (NEW.data->>'missionRebirths') ~ '^[0-9]{1,4}$' then (NEW.data->>'missionRebirths')::numeric else 0 end;
    if claimed <= 0 then return NEW; end if;

    tot := public.bignum(NEW.data->>'totalEarned');
    bound := floor((sqrt(1 + 8 * (tot / 1e16)) - 1) / 2);
    c := least(claimed, bound, 1000)::int;
    if c <= 0 then return NEW; end if;

    if to_regclass('public.banned_users') is not null then
      execute 'select exists(select 1 from public.banned_users where user_id = $1)' into banned using NEW.user_id::text;
      if coalesce(banned, false) then return NEW; end if;
    end if;

    select e.name into nm from public.leaderboard_entries e
     where e.user_id = NEW.user_id and e.name is not null
     order by e.updated_at desc nulls last limit 1;

    insert into public.rebirth_scores (season, user_id, name, cnt, season_total, updated_at)
    values (sk, NEW.user_id, coalesce(nm, 'Player'), c, tot, now())
    on conflict (season, user_id) do update set
      name         = coalesce(excluded.name, rebirth_scores.name),
      updated_at   = case when excluded.cnt > rebirth_scores.cnt then now() else rebirth_scores.updated_at end,
      cnt          = greatest(rebirth_scores.cnt, excluded.cnt),
      season_total = greatest(rebirth_scores.season_total, excluded.season_total);
  exception when others then
    null; -- 랭킹 기록 실패가 저장을 막으면 안 된다
  end;
  return NEW;
end $$;

drop trigger if exists rebirth_scores_sync_trg on public.saves;
create trigger rebirth_scores_sync_trg after insert or update on public.saves
  for each row execute function public.rebirth_scores_sync();

-- 랭킹 조회 (nh_ranking 과 같은 모양: ok / season / total / list / me)
create or replace function public.rebirth_ranking(p_season text default null, p_limit int default 50)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  sk text := coalesce(nullif(p_season, ''), to_char(now() at time zone 'Asia/Seoul', 'YYYY-MM'));
  n int := least(greatest(coalesce(p_limit, 50), 1), 100);
  lst jsonb; tot int; me jsonb;
begin
  if uid is null then return jsonb_build_object('ok', false); end if;
  select count(*) into tot from public.rebirth_scores where season = sk and cnt > 0;
  select coalesce(jsonb_agg(jsonb_build_object('rank', x.rk, 'uid', x.user_id, 'name', x.name,
                                               'score', x.cnt, 'total', x.season_total) order by x.rk), '[]'::jsonb)
    into lst
    from (select row_number() over (order by s.cnt desc, s.season_total desc, s.updated_at asc) as rk, s.*
            from public.rebirth_scores s where s.season = sk and s.cnt > 0
           order by s.cnt desc, s.season_total desc, s.updated_at asc limit n) x;
  select jsonb_build_object('rank', (select count(*) + 1 from public.rebirth_scores o
                                      where o.season = sk and o.cnt > 0
                                        and (o.cnt > m.cnt
                                             or (o.cnt = m.cnt and o.season_total > m.season_total)
                                             or (o.cnt = m.cnt and o.season_total = m.season_total and o.updated_at < m.updated_at))),
                            'score', m.cnt, 'total', m.season_total)
    into me from public.rebirth_scores m where m.season = sk and m.user_id = uid and m.cnt > 0;
  return jsonb_build_object('ok', true, 'season', sk, 'total', tot, 'list', lst, 'me', me);
end $$;
revoke all on function public.rebirth_ranking(text, int) from public, anon;
grant execute on function public.rebirth_ranking(text, int) to authenticated;
