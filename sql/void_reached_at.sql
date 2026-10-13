-- 공허 랭킹 동점 처리: "같은 웨이브면 먼저 도달한 사람이 위"
-- Supabase SQL Editor에서 한 번 실행하세요. (여러 번 실행해도 안전)
-- 클라이언트는 이 값을 보내지 않고, 서버가 직접 기록합니다 (위조 방지).

alter table public.leaderboard_entries
  add column if not exists reached_at bigint;   -- 현재 amount에 처음 도달한 시각(ms)

create or replace function public.set_void_reached_at()
returns trigger
language plpgsql
as $$
begin
  -- 공허 월별 보드에만 적용
  if new.board_key is null or new.board_key not like 'leaderboard\_void\_monthly\_%' then
    return new;
  end if;

  if tg_op = 'INSERT' then
    new.reached_at := (extract(epoch from clock_timestamp()) * 1000)::bigint;
  elsif (new.amount)::text::numeric > (old.amount)::text::numeric then
    -- 웨이브가 올랐을 때만 시각 갱신
    new.reached_at := (extract(epoch from clock_timestamp()) * 1000)::bigint;
  else
    -- 같은 웨이브로 다시 저장될 때는 기존 시각 유지 (클라이언트가 보낸 값은 무시)
    new.reached_at := old.reached_at;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_set_void_reached_at on public.leaderboard_entries;
create trigger trg_set_void_reached_at
  before insert or update on public.leaderboard_entries
  for each row execute function public.set_void_reached_at();

-- 이미 쌓인 기록은 도달 시각을 알 수 없어서, 마지막 저장 시각(updated_at)으로 임시 채웁니다.
do $$
declare t text;
begin
  select data_type into t from information_schema.columns
   where table_schema = 'public' and table_name = 'leaderboard_entries' and column_name = 'updated_at';
  if t = 'bigint' or t = 'numeric' or t = 'double precision' or t = 'integer' then
    execute $q$update public.leaderboard_entries
                  set reached_at = updated_at::bigint
                where board_key like 'leaderboard\_void\_monthly\_%' and reached_at is null$q$;
  else  -- timestamp / timestamptz
    execute $q$update public.leaderboard_entries
                  set reached_at = (extract(epoch from updated_at) * 1000)::bigint
                where board_key like 'leaderboard\_void\_monthly\_%' and reached_at is null$q$;
  end if;
end $$;

-- ⚠️ 아직 남은 작업: leaderboard_view() 함수의 정렬/순위 계산을
--    amount desc, reached_at asc nulls last 로 바꿔야 "내 순위"와 시즌 정산 순위에도 반영됩니다.
--    (현재 함수 SQL을 보여주시면 그 부분까지 맞춰서 드릴게요.)
