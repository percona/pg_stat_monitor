--
-- Only superusers and roles with privileges of the pg_read_all_stats role
-- are allowed to see the SQL text of queries executed by other users. Other
-- users can see the statistics.
--

CREATE EXTENSION pg_stat_monitor;
SET pg_stat_monitor.pgsm_track_utility = off;
SET pg_stat_monitor.pgsm_normalized_query = on;
SET pg_stat_monitor.pgsm_track = 'all';
SET pg_stat_monitor.pgsm_extract_comments = on;
SET pg_stat_monitor.pgsm_enable_query_plan = on;

CREATE FUNCTION regress_stats_nested(int) RETURNS int AS
$$
BEGIN
    RETURN (SELECT $1 + 1);
END
$$ LANGUAGE plpgsql;

CREATE ROLE regress_stats_superuser SUPERUSER;
CREATE ROLE regress_stats_user1;
CREATE ROLE regress_stats_user2;
CREATE ROLE regress_stats_user3 NOINHERIT;
GRANT pg_read_all_stats TO regress_stats_user2;
GRANT pg_read_all_stats TO regress_stats_user3;

SET ROLE regress_stats_superuser;
SELECT pg_stat_monitor_reset() IS NOT NULL AS t;
SELECT 1 AS "ONE";
SELECT regress_stats_nested(1);

SET ROLE regress_stats_user1;
SELECT 1+1 AS "TWO";
SELECT regress_stats_nested(2) /* comment */;
SELECT 1 / 0;

--
-- regress_stats_user1 has no privileges to read the query text of queries
-- executed by others but can see statistics like calls and rows.
--

SELECT r.rolname, ss.queryid <> 0 AS queryid_bool, ss.query, ss.top_query,
       ss.message, ss.comments, ss.pgsm_query_id <> 0 AS pgsm_query_id_bool,
       ss.planid <> 0 AS planid_bool,
       ss.top_queryid <> 0 AS top_queryid_bool,
       ss.client_ip IS NOT NULL AS client_ip_bool, ss.calls, ss.rows
    FROM pg_stat_monitor ss JOIN pg_roles r ON ss.userid = r.oid
    ORDER BY r.rolname, ss.query COLLATE "C", ss.calls, ss.rows;

--
-- A superuser can read all columns of queries executed by others,
-- including query text.
--

SET ROLE regress_stats_superuser;
SELECT r.rolname, ss.queryid <> 0 AS queryid_bool, ss.query, ss.top_query,
       ss.message, ss.comments, ss.pgsm_query_id <> 0 AS pgsm_query_id_bool,
       ss.planid <> 0 AS planid_bool,
       ss.top_queryid <> 0 AS top_queryid_bool,
       ss.client_ip IS NOT NULL AS client_ip_bool, ss.calls, ss.rows
    FROM pg_stat_monitor ss JOIN pg_roles r ON ss.userid = r.oid
    ORDER BY r.rolname, ss.query COLLATE "C", ss.calls, ss.rows;

--
-- regress_stats_user2, with pg_read_all_stats role privileges, can
-- read all columns, including query text, of queries executed by others.
--

SET ROLE regress_stats_user2;
SELECT r.rolname, ss.queryid <> 0 AS queryid_bool, ss.query, ss.top_query,
       ss.message, ss.comments, ss.pgsm_query_id <> 0 AS pgsm_query_id_bool,
       ss.planid <> 0 AS planid_bool,
       ss.top_queryid <> 0 AS top_queryid_bool,
       ss.client_ip IS NOT NULL AS client_ip_bool, ss.calls, ss.rows
    FROM pg_stat_monitor ss JOIN pg_roles r ON ss.userid = r.oid
    ORDER BY r.rolname, ss.query COLLATE "C", ss.calls, ss.rows;

--
-- regress_stats_user3 is a member of pg_read_all_stats, but it is a NOINHERIT
-- role, so the privilege does not apply until it does SET ROLE.
--

SET ROLE regress_stats_user3;
SELECT r.rolname, ss.queryid <> 0 AS queryid_bool, ss.query, ss.top_query,
       ss.message, ss.comments, ss.pgsm_query_id <> 0 AS pgsm_query_id_bool,
       ss.planid <> 0 AS planid_bool,
       ss.top_queryid <> 0 AS top_queryid_bool,
       ss.client_ip IS NOT NULL AS client_ip_bool, ss.calls, ss.rows
    FROM pg_stat_monitor ss JOIN pg_roles r ON ss.userid = r.oid
    ORDER BY r.rolname, ss.query COLLATE "C", ss.calls, ss.rows;

SET ROLE pg_read_all_stats;
SELECT r.rolname, ss.queryid <> 0 AS queryid_bool, ss.query, ss.top_query,
       ss.message, ss.comments, ss.pgsm_query_id <> 0 AS pgsm_query_id_bool,
       ss.planid <> 0 AS planid_bool,
       ss.top_queryid <> 0 AS top_queryid_bool,
       ss.client_ip IS NOT NULL AS client_ip_bool, ss.calls, ss.rows
    FROM pg_stat_monitor ss JOIN pg_roles r ON ss.userid = r.oid
    ORDER BY r.rolname, ss.query COLLATE "C", ss.calls, ss.rows;

--
-- cleanup
--

RESET ROLE;
DROP FUNCTION regress_stats_nested(int);
DROP ROLE regress_stats_superuser;
DROP ROLE regress_stats_user1;
REVOKE pg_read_all_stats FROM regress_stats_user2;
DROP ROLE regress_stats_user2;
REVOKE pg_read_all_stats FROM regress_stats_user3;
DROP ROLE regress_stats_user3;
SELECT pg_stat_monitor_reset() IS NOT NULL AS t;
DROP EXTENSION pg_stat_monitor;
