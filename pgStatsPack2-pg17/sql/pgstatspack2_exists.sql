-- Prints: 'none' (not installed), 'legacy' (old 0.1.x schema), 'incomplete',
-- or the installed version (e.g. 2.0.0). Run with: psql -qtAX -f pgstatspack2_exists.sql
SET client_min_messages TO error;
SELECT to_regclass('pgstatspack2.pgstatspack2_version') IS NOT NULL AS pgsp2_has_version \gset
\if :pgsp2_has_version
SELECT CASE
         WHEN NOT EXISTS (SELECT 1 FROM pg_attribute
                          WHERE attrelid = to_regclass('pgstatspack2.pgstatspack2_version')
                            AND attname = 'edition') THEN 'legacy'
         WHEN to_regprocedure('pgstatspack2.pgstatspack2_snap(text)') IS NULL THEN 'incomplete'
         ELSE coalesce((SELECT schema_version FROM pgstatspack2.pgstatspack2_version LIMIT 1), 'incomplete')
       END;
\else
SELECT 'none';
\endif
