-- Pure-SQL alternative to bin/schedule_pg_cron.sh.
-- Run in the pg_cron database (cron.database_name, 'postgres' by default on RDS/Aurora)
-- as the user the jobs should run as. Replace appdb with your database; repeat per database.

SELECT cron.schedule_in_database('pgstatspack2_snap_appdb',  '*/15 * * * *',
       $$SELECT pgstatspack2.pgstatspack2_snap('pg_cron')$$, 'appdb');

SELECT cron.schedule_in_database('pgstatspack2_purge_appdb', '30 3 * * *',
       $$SELECT pgstatspack2.pgstatspack2_delete_snap()$$, 'appdb');

-- Keep pg_cron's own history small
SELECT cron.schedule('pgstatspack2_cron_history', '0 4 * * *',
       $$DELETE FROM cron.job_run_details WHERE end_time < now() - interval '7 days'$$);

-- Check
SELECT jobid, jobname, database, schedule, active FROM cron.job WHERE jobname LIKE 'pgstatspack2%';
SELECT jobid, status, start_time, return_message FROM cron.job_run_details ORDER BY start_time DESC LIMIT 10;

-- Remove
-- SELECT cron.unschedule('pgstatspack2_snap_appdb');
-- SELECT cron.unschedule('pgstatspack2_purge_appdb');
