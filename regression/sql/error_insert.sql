CREATE TABLE company (
    id int PRIMARY KEY NOT NULL,
    name text NOT NULL
);

CREATE EXTENSION pg_stat_monitor;
SELECT pg_stat_monitor_reset();
INSERT INTO company (id, name) VALUES (1, 'Percona');
INSERT INTO company (id, name) VALUES (1, 'Percona');

DROP TABLE company;
SELECT query, elevel, sqlcode, message FROM pg_stat_monitor ORDER BY query COLLATE "C", elevel;
SELECT pg_stat_monitor_reset();
DROP EXTENSION pg_stat_monitor;
