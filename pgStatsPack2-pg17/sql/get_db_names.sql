-- Databases pgStatsPack2 is installed into / snapshotted by the shell scripts.
-- Skips templates, databases that refuse connections, and the RDS/Aurora
-- internal 'rdsadmin' database. 'postgres' is skipped as in the original tool;
-- pass -d postgres to the scripts if you want it.
SET client_min_messages TO error;
SELECT datname
FROM pg_database
WHERE datallowconn
  AND NOT datistemplate
  AND datname NOT IN ('rdsadmin', 'postgres')
ORDER BY datname;
