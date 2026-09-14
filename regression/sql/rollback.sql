CREATE EXTENSION pg_stat_monitor;

CREATE USER u WITH SUPERUSER;
SET ROLE u;
CREATE TABLE t (a int PRIMARY KEY);

SELECT pg_stat_monitor_reset();

BEGIN;
INSERT INTO t VALUES (1);
COMMIT;

SELECT query, username, datname FROM pg_stat_monitor ORDER BY query COLLATE "C";
SELECT pg_stat_monitor_reset();

-- During manual rollback we will be able to get username of the query that was rolled back.
BEGIN;
INSERT INTO t VALUES (2);
ROLLBACK;

SELECT query, username, datname FROM pg_stat_monitor ORDER BY query COLLATE "C";
SELECT pg_stat_monitor_reset();

-- If transaction is rolled back due an error, we won't be able to get username of the query that was rolled back.
BEGIN;
INSERT INTO t VALUES (1);
ROLLBACK;

SELECT query, username, datname FROM pg_stat_monitor ORDER BY query COLLATE "C";
SELECT pg_stat_monitor_reset();

-- We still able to record ROLLBACK TO SAVEPOINT if subtransaction is aborted due an error.
BEGIN;
SAVEPOINT sp1;
SELECT 1/0;
ROLLBACK TO SAVEPOINT sp1;
INSERT INTO t VALUES (3);
COMMIT;

SELECT query, username, datname FROM pg_stat_monitor ORDER BY query COLLATE "C";
SELECT pg_stat_monitor_reset();

-- We are still able to record PREPARE TRANSACTION issued in an aborted transaction, it rolls it back.
BEGIN;
INSERT INTO t VALUES (1);
PREPARE TRANSACTION 'pgsm_aborted_transaction';

SELECT query, username, datname FROM pg_stat_monitor ORDER BY query COLLATE "C";
SELECT pg_stat_monitor_reset();

DROP TABLE t;
SET ROLE NONE;
DROP USER u;

DROP EXTENSION pg_stat_monitor;
