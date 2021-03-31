CREATE EXTENSION pg_stat_monitor;
SET pg_stat_monitor.pgsm_normalized_query TO off;

CREATE TABLE tb1(id int, name text);
INSERT INTO tb1 VALUES (1,'foo'),(2,'bar'),(3,'baz');

CREATE OR REPLACE FUNCTION dup(int) RETURNS TABLE(f1 int, f2 text)
AS $$ SELECT $1, CAST($1 AS text) || ' is text' $$
LANGUAGE SQL;

PREPARE gettb1 AS SELECT name,'test placeholder in string: $1' AS test_string FROM tb1 WHERE id = $1;
SELECT pg_stat_monitor_reset();

SELECT dup(22);
EXECUTE gettb1(2);

SELECT query, calls FROM pg_stat_monitor ORDER BY query COLLATE "C";
DROP TABLE tb1;
DROP FUNCTION dup;
DEALLOCATE gettb1;
SELECT pg_stat_monitor_reset();
DROP EXTENSION pg_stat_monitor;