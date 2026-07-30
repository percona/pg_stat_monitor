CREATE EXTENSION pg_stat_monitor;

DO $$
DECLARE
    i int;
BEGIN
    FOR i IN 10..25 LOOP
        RAISE NOTICE 'error_code: %, error_level: %', i, decode_error_level(i);
    END LOOP;
END
$$;

DROP EXTENSION pg_stat_monitor;
