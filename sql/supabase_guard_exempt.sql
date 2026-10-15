-- =====================================================================
-- 운영자(본인) 계정은 서버 가드에서 제외 — Supabase SQL Editor에서 [1]→[2]→[3]→[4] 순서로 실행
--
-- 왜 필요한가
--   가드(battle_points_guard / sword_progress_guard / lb_guard / sword_state_enforce 등)는
--   "정상 플레이로 가능한 속도"만 인정해서, 테스트로 값을 올려 둔 계정은 다음 동기화 때마다
--   점수·검 단계가 서버 기록 쪽으로 깎이거나 저장이 거절돼요. (기준선이 옛날 값에 멈춰 있기 때문)
--   → 운영자 계정만 목록에 넣어 두면, 그 계정의 저장은 가드를 통과하고 값이 되돌아가지 않아요.
--   → 다른 유저에 대한 검증은 그대로예요. (밴 차단 trg_block_banned 와 기록용 트리거는 건드리지 않음)
-- 되돌리기: 맨 아래 [되돌리기] 참고
-- =====================================================================

-- [1] 예외 계정 목록 (앱은 읽기/쓰기 불가, SQL Editor 에서만 편집)
create table if not exists public.guard_exempt (
  user_id    text primary key,
  note       text,
  created_at timestamptz not null default now()
);
alter table public.guard_exempt enable row level security;
revoke all on public.guard_exempt from anon, authenticated;

create or replace function public.is_guard_exempt(p_uid text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$ select exists (select 1 from public.guard_exempt where user_id = p_uid) $$;
revoke all on function public.is_guard_exempt(text) from public;
grant execute on function public.is_guard_exempt(text) to anon, authenticated;

-- [2] 검증 트리거에 "예외 계정이면 실행하지 않음" 조건(WHEN)을 붙인다. 함수 코드는 그대로 둔다.
--     (목록에 없는 트리거 이름은 건너뜀. 이미 적용된 트리거도 건너뜀. 몇 번 실행해도 안전)
do $$
declare r record; def text; n int := 0;
begin
  for r in
    select t.tgname, pg_get_triggerdef(t.oid) as d
      from pg_trigger t
     where t.tgrelid = 'public.leaderboard_entries'::regclass
       and not t.tgisinternal
       and t.tgname in ('lb_guard_trg', 'trg_battle_points_guard', 'trg_sword_progress_guard',
                        'zz_sword_progress_guard', 'zz_sword_state_enforce', 'trg_void_progress_guard')
  loop
    continue when r.d like '%is_guard_exempt%' or r.d like '% WHEN %';
    def := replace(r.d, 'FOR EACH ROW', 'FOR EACH ROW WHEN (NOT public.is_guard_exempt((NEW.user_id)::text))');
    execute format('drop trigger %I on public.leaderboard_entries', r.tgname);
    execute def;
    n := n + 1;
  end loop;
  raise notice '예외 조건을 붙인 트리거: %개', n;
end $$;

-- [3] 내 계정 확인 후 등록
--   (가) 먼저 닉네임으로 user_id 를 확인한다 (같은 닉네임을 쓰는 다른 유저가 없는지 보기)
select distinct user_id::text as user_id, name
  from public.leaderboard_entries
 where name in ('미나미');            -- ← 본인 계정 닉네임을 여기에 추가 (예: '미나미', '원이')

--   (나) 맞으면 등록한다 (위 닉네임 목록을 똑같이 맞춰서 실행)
insert into public.guard_exempt (user_id, note)
select distinct user_id::text, '운영자 계정'
  from public.leaderboard_entries
 where name in ('미나미')             -- ← 위와 같은 목록
on conflict do nothing;

-- [4] 확인
select * from public.guard_exempt;
select tgname, tgenabled, pg_get_triggerdef(oid) like '%is_guard_exempt%' as 예외적용
  from pg_trigger
 where tgrelid = 'public.leaderboard_entries'::regclass and not tgisinternal
 order by tgname;
-- 예외적용 = true 가 lb_guard_trg / trg_battle_points_guard / zz_sword_progress_guard / zz_sword_state_enforce 에 떠야 한다.

-- [참고] 가드가 조용히 버린 기록 보기 (lb_guard 는 오류 없이 저장만 건너뛴다)
--   select * from public.lb_rejects order by at desc limit 30;

-- [되돌리기]
--   계정만 빼기:   delete from public.guard_exempt where user_id = '<user_id>';
--   전체 해제:     원래 SQL(supabase_battle_guard.sql / supabase_sword_guard.sql / ranking_guard.sql)의
--                  create trigger 부분을 다시 실행하면 WHEN 조건 없는 원래 트리거로 돌아간다.
