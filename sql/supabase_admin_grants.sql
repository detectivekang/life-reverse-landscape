-- =====================================================================
-- 운영자 보상 우편함 (되돌리기/강화 아이템 등을 안전하게 지급)
-- 왜 필요한가: saves 테이블의 data를 SQL로 직접 고쳐도, 플레이어의 게임(브라우저/localStorage)이
--   "내 기록이 더 최신"이라고 판단해 서버 값을 무시하고 오히려 자기 값으로 덮어써 버린다.
--   → 지급할 내용을 별도 테이블에 넣어두고, 게임이 로그인할 때 받아가서 자기 세이브에 더하는 방식으로 바꾼다.
--   (같은 지급이 두 번 반영되거나 유실되지 않도록 게임이 받은 id를 세이브에 기록하고, 서버가 확인 처리한다)
-- =====================================================================
create table if not exists public.admin_grants (
  id         uuid primary key default gen_random_uuid(),
  user_id    text not null,
  item       text not null,   -- 아래 check 제약으로 종류를 제한
  amount     int  not null check (amount between 1 and 9999),
  title      text check (char_length(title) <= 40),      -- 우편 제목   예) 추석 기념 선물
  gift_name  text check (char_length(gift_name) <= 40),  -- 선물 이름   예) 한가위 보름달 선물 상자
  message    text check (char_length(message) <= 500),   -- 운영자 메시지(본문)
  note       text,                                       -- 운영자 메모(유저에게 안 보임)
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '30 days'),  -- 이 시각이 지나면 우편함에서 사라진다(기본 30일)
  claimed_at timestamptz
);
-- (이미 이전 버전 테이블을 만들었다면 아래 3줄이 컬럼을 추가해 준다)
alter table public.admin_grants add column if not exists title     text check (char_length(title) <= 40);
alter table public.admin_grants add column if not exists gift_name text check (char_length(gift_name) <= 40);
alter table public.admin_grants add column if not exists message   text check (char_length(message) <= 500);
alter table public.admin_grants add column if not exists expires_at timestamptz not null default (now() + interval '30 days');   -- 이미 있던 우편은 지금부터 30일
-- 지급 종류 제한 ('revive_floor' = "최소 N개가 되게 맞춰주기": 이미 N개 이상이면 아무 일도 안 하고, 모자라면 N개로 채운다)
alter table public.admin_grants drop constraint if exists admin_grants_item_check;
alter table public.admin_grants add constraint admin_grants_item_check
  check (item in ('revive', 'revive_floor', 'boost_x15', 'boost_x20', 'boost_x25', 'void_shards', 'talent_points'));
create index if not exists admin_grants_user_idx on public.admin_grants (user_id) where claimed_at is null;
alter table public.admin_grants enable row level security;          -- 정책 없음: 앱이 직접 읽고 쓸 수 없다
revoke all on public.admin_grants from anon, authenticated;

-- 게임이 호출하는 함수: ① 이미 반영했다고 알려온 id들을 '수령 완료' 처리 ② 아직 반영 안 한 지급 목록을 돌려준다
create or replace function public.admin_grants_sync(p_applied uuid[] default '{}')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare uid text := auth.uid()::text; res jsonb;
begin
  if uid is null then return '[]'::jsonb; end if;
  update public.admin_grants set claimed_at = now()
   where user_id = uid and claimed_at is null and id = any(coalesce(p_applied, '{}'));
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'item', item, 'amount', amount, 'title', title, 'gift_name', gift_name, 'message', message, 'created_at', created_at, 'expires_at', expires_at) order by created_at), '[]'::jsonb)
    into res
    from public.admin_grants
   where user_id = uid and claimed_at is null and expires_at > now() and not (id = any(coalesce(p_applied, '{}')));
  return res;
end $$;
revoke all on function public.admin_grants_sync(uuid[]) from public;
grant execute on function public.admin_grants_sync(uuid[]) to authenticated;

-- =====================================================================
-- 지급하는 방법 (이 줄들만 필요할 때 실행)
--   item: 'revive'(되돌리기) | 'revive_floor'(최소 보장) | 'boost_x15' | 'boost_x20' | 'boost_x25' | 'void_shards'(차원 조각) | 'talent_points'(특성 포인트)
--   받는 기한: 기본 30일 (expires_at). 다르게 하려면 insert 할 때 expires_at 컬럼에 날짜를 직접 넣는다.
--   ※ 이제 유저가 우편함에서 '받기'를 눌러야 지급된다 (자동 지급 아님). 기한이 지나면 사라지고 지급되지 않는다.
--   title/gift_name/message 는 유저 화면에 보이는 글, note 는 운영자 메모
--
-- ① 특정 유저에게
-- insert into public.admin_grants (user_id, item, amount, title, gift_name, message, note) values
--   ('e3131b78-0f23-4764-9d65-7aa7cf2055ad', 'revive', 12,
--    '되돌리기 복구 안내', '되돌리기 12개', '불편을 드려 죄송해요. 사라졌던 되돌리기를 다시 드려요!', '되돌리기 복구');
--
-- ② 전체 유저에게 (예: 추석 선물)
-- insert into public.admin_grants (user_id, item, amount, title, gift_name, message, note)
-- select user_id, 'revive', 3,
--        '🌕 추석 기념 선물', '한가위 보름달 되돌리기 ×3',
--        '풍성한 한가위 보내세요! 늘 함께해 주셔서 감사합니다.', '2026 추석 이벤트'
--   from public.saves
--  where user_id not in (select user_id from public.banned_users);   -- 차단 계정 제외 (banned_users 가 없으면 이 줄 삭제)
--
-- ③ 되돌리기 개수 오류 복구 (전체 유저, 한 번만 실행)
--    각자 DB에 저장된 현재 개수를 '최소 보장'으로 보낸다. 게임이 받으면:
--      · 화면에 0개로 잘못 보이던 사람  → 그 개수로 채워지고 안내 창이 뜬다
--      · 이미 같거나 더 많이 가진 사람 → 아무것도 안 바뀌고 창도 안 뜬다(조용히 처리)
-- insert into public.admin_grants (user_id, item, amount, title, gift_name, message, note)
-- select user_id, 'revive_floor',
--        least(9999, (data->>'swordReviveCharges')::int),
--        '🛡️ 되돌리기 복구', '되돌리기 개수 복구',
--        '일부 계정에서 되돌리기 개수가 0으로 보이던 오류를 바로잡았어요. 불편을 드려 죄송합니다.',
--        '되돌리기 복구 2026-10'
--   from public.saves
--  where (data->>'swordReviveCharges') ~ '^[0-9]+$' and (data->>'swordReviveCharges')::int >= 1;
--
-- 확인:  select user_id, item, amount, title, claimed_at from public.admin_grants order by created_at desc;
--   (claimed_at 이 채워져 있으면 게임이 받아서 저장까지 끝낸 것. 비어 있으면 아직 접속 전)
-- 취소:  delete from public.admin_grants where id = '<id>' and claimed_at is null;
--   이벤트 통째로 취소: delete from public.admin_grants where note = '2026 추석 이벤트' and claimed_at is null;
-- =====================================================================
