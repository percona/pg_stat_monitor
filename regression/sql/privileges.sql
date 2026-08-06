--
-- Only superusers and roles with privileges of the pg_read_all_stats role
-- are allowed to see the SQL text of queries executed by other users. Other
-- users can see the statistics.
--

CREATE EXTENSION pg_stat_monitor;
SET pg_stat_monitor.pgsm_track_utility = off;
SET pg_stat_monitor.pgsm_normalized_query = on;

CREATE ROLE regress_stats_superuser SUPERUSER;
CREATE ROLE regress_stats_user1;
CREATE ROLE regress_stats_user2;
GRANT pg_read_all_stats TO regress_stats_user2;

SET ROLE regress_stats_superuser;
SELECT pg_stat_monitor_reset() IS NOT NULL AS t;
SELECT 1 AS "ONE";

SET ROLE regress_stats_user1;
SELECT 1+1 AS "TWO";

--
-- A superuser can read all columns of queries executed by others,
-- including query text.
--

SET ROLE regress_stats_superuser;
SELECT r.rolname, ss.queryid <> 0 AS queryid_bool, ss.query, ss.calls, ss.rows
    FROM pg_stat_monitor ss JOIN pg_roles r ON ss.userid = r.oid
    ORDER BY r.rolname, ss.query COLLATE "C", ss.calls, ss.rows;

--
-- regress_stats_user1 has no privileges to read the query text of queries
-- executed by others but can see statistics like calls and rows.
--

SET ROLE regress_stats_user1;
SELECT r.rolname, ss.queryid <> 0 AS queryid_bool, ss.query, ss.calls, ss.rows
    FROM pg_stat_monitor ss JOIN pg_roles r ON ss.userid = r.oid
    ORDER BY r.rolname, ss.query COLLATE "C", ss.calls, ss.rows;

--
-- regress_stats_user2, with pg_read_all_stats role privileges, can
-- read all columns, including query text, of queries executed by others.
--

SET ROLE regress_stats_user2;
SELECT r.rolname, ss.queryid <> 0 AS queryid_bool, ss.query, ss.calls, ss.rows
    FROM pg_stat_monitor ss JOIN pg_roles r ON ss.userid = r.oid
    ORDER BY r.rolname, ss.query COLLATE "C", ss.calls, ss.rows;

--
-- cleanup
--

RESET ROLE;
DROP ROLE regress_stats_superuser;
DROP ROLE regress_stats_user1;
REVOKE pg_read_all_stats FROM regress_stats_user2;
DROP ROLE regress_stats_user2;
SELECT pg_stat_monitor_reset() IS NOT NULL AS t;
DROP EXTENSION pg_stat_monitor;
