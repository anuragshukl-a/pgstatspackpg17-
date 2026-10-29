-- Removes pgStatsPack2 (any version, including the legacy 0.1.x schema) and ALL its data
-- from the current database. Remove pg_cron jobs separately (bin/schedule_pg_cron.sh --remove).
\set ON_ERROR_STOP on
DROP SCHEMA IF EXISTS pgstatspack2 CASCADE;
