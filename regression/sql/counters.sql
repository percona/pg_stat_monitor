CREATE EXTENSION pg_stat_monitor;
Set pg_stat_monitor.pgsm_track = 'all';
SELECT pg_stat_monitor_reset();

CREATE TABLE t1 (a int);
CREATE TABLE t2 (b int);
CREATE TABLE t3 (c int);
CREATE TABLE t4 (d int);

SELECT pg_stat_monitor_reset();
SELECT a, b, c, d FROM t1, t2, t3, t4 WHERE t1.a = t2.b AND t3.c = t4.d ORDER BY a;
SELECT a, b, c, d FROM t1, t2, t3, t4 WHERE t1.a = t2.b AND t3.c = t4.d ORDER BY a;
SELECT a, b, c, d FROM t1, t2, t3, t4 WHERE t1.a = t2.b AND t3.c = t4.d ORDER BY a;
SELECT a, b, c, d FROM t1, t2, t3, t4 WHERE t1.a = t2.b AND t3.c = t4.d ORDER BY a;
SELECT query, sum(calls) as calls FROM pg_stat_monitor GROUP BY query ORDER BY query COLLATE "C";

SELECT pg_stat_monitor_reset();

DO $$
DECLARE
    n int := 1;
BEGIN
    LOOP
        PERFORM a, b, c, d FROM t1, t2, t3, t4 WHERE t1.a = t2.b AND t3.c = t4.d ORDER BY a;
        EXIT WHEN n = 1000;
        n := n + 1;
    END LOOP;
END
$$;
SELECT query, sum(calls) as calls FROM pg_stat_monitor GROUP BY query ORDER BY query COLLATE "C";

DROP TABLE t1;
DROP TABLE t2;
DROP TABLE t3;
DROP TABLE t4;

DROP EXTENSION pg_stat_monitor;
