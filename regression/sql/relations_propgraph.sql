--
-- Property graph relations (PostgreSQL 19+)
--
SELECT setting::int < 190000 AS skip_test FROM pg_settings where name = 'server_version_num' \gset
\if :skip_test
\quit
\endif

CREATE EXTENSION pg_stat_monitor;

CREATE TABLE people (id int PRIMARY KEY, name text);
CREATE TABLE knows (a int REFERENCES people (id), b int REFERENCES people (id));

CREATE PROPERTY GRAPH social
  VERTEX TABLES ( people KEY (id) )
  EDGE TABLES ( knows KEY (a, b)
                SOURCE KEY (a) REFERENCES people (id)
                DESTINATION KEY (b) REFERENCES people (id) );

-- A property graph must be marked with a trailing '*' in the relations column,
-- and its underlying element tables must be listed alongside it.
SELECT pg_stat_monitor_reset();
SELECT * FROM GRAPH_TABLE (social MATCH (p IS people) COLUMNS (p.name)) AS g;
SELECT query, relations FROM pg_stat_monitor ORDER BY query COLLATE "C";
SELECT pg_stat_monitor_reset();

DROP PROPERTY GRAPH social;
DROP TABLE knows;
DROP TABLE people;

DROP EXTENSION pg_stat_monitor;
