-- =====================================================================
-- 공격(툴/봇) 여부 점검용 조회 모음 — 전부 "읽기만" 하고 아무것도 바꾸지 않는다.
-- Supabase SQL Editor에서 한 블록씩 실행해 보고 결과를 알려주세요.
-- =====================================================================

-- [A] 용량이 비정상적으로 큰 테이블 (스팸 insert가 쌓였는지)
select relname as table_name,
       pg_size_pretty(pg_total_relation_size(relid)) as total_size,
       n_live_tup as approx_rows
  from pg_stat_user_tables
 order by pg_total_relation_size(relid) desc
 limit 10;

-- [B] 최근 24시간 로그인/토큰 관련 이벤트를 IP·종류별로 집계 (같은 IP가 비정상적으로 많이 두드리는지)
select ip_address, payload->>'action' as action, count(*) as n,
       min(created_at) as first_at, max(created_at) as last_at
  from auth.audit_log_entries
 where created_at > now() - interval '24 hours'
 group by 1, 2
 order by n desc
 limit 30;

-- [C] 시간대별 신규 가입자 수 (계정을 대량으로 만들고 있는지)
select date_trunc('hour', created_at) as hour, count(*) as new_users
  from auth.users
 where created_at > now() - interval '3 days'
 group by 1
 order by 1 desc;

-- [D] 로그인 안 한 사람(anon)에게 열려 있는 것 — 여기가 공격 표면이다
--  D-1) 테이블 정책: roles 에 anon 또는 public 이 있으면 로그인 없이도 접근 가능
select tablename, policyname, cmd, roles, qual as using_expr, with_check
  from pg_policies
 where schemaname = 'public'
 order by tablename, cmd;
--  D-2) anon이 실행할 수 있는 함수(RPC)
select routine_name, privilege_type
  from information_schema.routine_privileges
 where grantee in ('anon', 'PUBLIC') and routine_schema = 'public'
 order by routine_name;

-- =====================================================================
-- [E] Supabase 대시보드 → Logs → API Edge Logs (Logs Explorer)에서 실행하는 검색 (SQL Editor 아님)
--     어떤 IP / 어떤 프로그램(User-Agent)이 어디를 두드리는지 본다.
--     사람 브라우저는 user_agent 가 Chrome/Safari/Mobile 로 보이고,
--     툴은 python-requests, curl, node, axios, okhttp, k6 같은 이름이 보인다.
--
-- select h.cf_connecting_ip as ip, h.user_agent as ua, r.method as method, r.path as path, count(*) as n
--   from edge_logs as t
--   cross join unnest(t.metadata) as m
--   cross join unnest(m.request) as r
--   cross join unnest(r.headers) as h
--  group by ip, ua, method, path
--  order by n desc
--  limit 30
-- (컬럼 이름이 다르다는 오류가 나면 그 메시지를 알려주세요)
-- =====================================================================
