-- pgStatsPack2 report for PostgreSQL 17 / 18 (Amazon RDS and Aurora PostgreSQL compatible)
--
-- Usage (any psql 12+ client, e.g. from an EC2 bastion / CloudShell):
--   psql "host=... dbname=appdb user=... sslmode=require" \
--        -v begin_snap=101 -v end_snap=125 -f sql/pgstatspack2_report.sql -o report.txt
--
-- Optional: -v top=20   (rows per "top N" section, default 20)
--           -v qlen=120 (characters of query text shown, default 120)

\set ON_ERROR_STOP on
\set QUIET on
\pset footer off
\pset null ''
SET client_min_messages TO warning;
SET search_path TO pgstatspack2, pg_catalog;

\if :{?top}
\else
\set top 20
\endif
\if :{?qlen}
\else
\set qlen 120
\endif
\if :{?begin_snap}
\else
\echo 'ERROR: pass -v begin_snap=<id> -v end_snap=<id>  (see: SELECT * FROM pgstatspack2.pgstatspack2_list_snaps();)'
\quit
\endif

-- Validate and normalise the snapshot range ---------------------------------------------
SELECT b.snapid AS rpt_b, e.snapid AS rpt_e,
       greatest(extract(epoch FROM e.ts - b.ts), 1)::numeric AS rpt_secs,
       (b.postmaster_start IS DISTINCT FROM e.postmaster_start) AS rpt_restart,
       coalesce(b.pgss_found AND e.pgss_found, false) AS rpt_pgss,
       (e.snapid > b.snapid) AS rpt_order_ok
FROM pgstatspack2_snap b, pgstatspack2_snap e
WHERE b.snapid = :'begin_snap'::bigint AND e.snapid = :'end_snap'::bigint \gset

\if :{?rpt_b}
\else
\echo 'ERROR: snapshot' :begin_snap 'or' :end_snap 'not found in this database.'
\quit
\endif
\if :rpt_order_ok
\else
\echo 'ERROR: end_snap must be greater than begin_snap.'
\quit
\endif

\echo '#####################################################################################'
\echo '  pgStatsPack2 report  (PostgreSQL 17/18 edition 2.0.0)'
\echo '#####################################################################################'
\echo

\echo '== Snapshots =========================================================================='
SELECT s.snapid, s.ts, s.description, pg_size_pretty(s.db_size) AS db_size,
       s.server_version, CASE WHEN s.is_aurora THEN 'Aurora' ELSE 'RDS/PostgreSQL' END AS engine,
       s.postmaster_start
FROM pgstatspack2_snap s
WHERE s.snapid IN (:rpt_b, :rpt_e)
ORDER BY s.snapid;

SELECT current_database() AS database,
       to_char(:rpt_secs, 'FM999G999G990') AS seconds_in_range,
       justify_interval(make_interval(secs => :rpt_secs)) AS duration,
       pg_size_pretty(e.db_size - b.db_size) AS db_growth
FROM pgstatspack2_snap b, pgstatspack2_snap e
WHERE b.snapid = :rpt_b AND e.snapid = :rpt_e;

\if :rpt_restart
\echo
\echo '!!! WARNING: the server restarted (or failed over) between these snapshots.'
\echo '!!! Cumulative counters were reset; deltas below may be negative or meaningless.'
\endif

-- =======================================================================================
\echo
\echo '== Database load (all databases in the cluster) ======================================='
SELECT a.datname AS database,
       round((b.xact_commit - a.xact_commit) / :rpt_secs, 2)                       AS commits_ps,
       round((b.xact_rollback - a.xact_rollback) / :rpt_secs, 2)                   AS rollbacks_ps,
       round(100.0 * (b.blks_hit - a.blks_hit)
             / nullif((b.blks_hit - a.blks_hit) + (b.blks_read - a.blks_read), 0), 2) AS hit_pct,
       round(((b.blks_hit - a.blks_hit) + (b.blks_read - a.blks_read)) / :rpt_secs, 1) AS lio_ps,
       round((b.blks_read - a.blks_read) / :rpt_secs, 1)                           AS pio_ps,
       round((b.tup_inserted - a.tup_inserted) / :rpt_secs, 1)                     AS ins_ps,
       round((b.tup_updated - a.tup_updated) / :rpt_secs, 1)                       AS upd_ps,
       round((b.tup_deleted - a.tup_deleted) / :rpt_secs, 1)                       AS del_ps,
       b.temp_files - a.temp_files                                                 AS temp_files,
       pg_size_pretty((b.temp_bytes - a.temp_bytes)::bigint)                       AS temp_written,
       b.deadlocks - a.deadlocks                                                   AS deadlocks,
       b.sessions - a.sessions                                                     AS new_sessions,
       b.numbackends                                                               AS backends_now
FROM pgstatspack2_database_v a
JOIN pgstatspack2_database_v b ON b.datid = a.datid
WHERE a.snapid = :rpt_b AND b.snapid = :rpt_e
  AND (b.xact_commit - a.xact_commit) + (b.xact_rollback - a.xact_rollback) + b.numbackends > 0
ORDER BY commits_ps DESC NULLS LAST;

\echo
\echo '-- Session / I/O time (ms, needs track_io_timing=on for read/write time)'
SELECT a.datname AS database,
       round((b.blk_read_time - a.blk_read_time)::numeric, 1)   AS blk_read_ms,
       round((b.blk_write_time - a.blk_write_time)::numeric, 1) AS blk_write_ms,
       round((b.active_time - a.active_time)::numeric, 1)       AS active_ms,
       round((b.idle_in_transaction_time - a.idle_in_transaction_time)::numeric, 1) AS idle_in_xact_ms,
       round(((b.active_time - a.active_time) / 1000)::numeric / :rpt_secs, 2) AS avg_active_sessions,
       b.sessions_abandoned - a.sessions_abandoned AS abandoned,
       b.sessions_fatal - a.sessions_fatal         AS fatal,
       b.sessions_killed - a.sessions_killed       AS killed,
       b.conflicts - a.conflicts                   AS conflicts
FROM pgstatspack2_database_v a
JOIN pgstatspack2_database_v b ON b.datid = a.datid
WHERE a.snapid = :rpt_b AND b.snapid = :rpt_e
  AND (b.xact_commit - a.xact_commit) > 0
ORDER BY active_ms DESC NULLS LAST;

-- =======================================================================================
\echo
\echo '== WAL (pg_stat_wal) ================================================================='
\echo '   On Aurora, storage-level replication replaces most classic WAL behaviour; treat as indicative.'
SELECT pg_size_pretty(b.wal_bytes - a.wal_bytes)                            AS wal_generated,
       pg_size_pretty(((b.wal_bytes - a.wal_bytes) / :rpt_secs)::bigint) || '/s' AS wal_rate,
       b.wal_records - a.wal_records                                         AS wal_records,
       b.wal_fpi - a.wal_fpi                                                 AS full_page_images,
       round(100.0 * (b.wal_fpi - a.wal_fpi) / nullif(b.wal_records - a.wal_records, 0), 2) AS fpi_pct,
       b.wal_buffers_full - a.wal_buffers_full                               AS wal_buffers_full
FROM pgstatspack2_wal a, pgstatspack2_wal b
WHERE a.snapid = :rpt_b AND b.snapid = :rpt_e;

-- =======================================================================================
\echo
\echo '== Checkpointer / background writer =================================================='
SELECT b.checkpoints_timed - a.checkpoints_timed                     AS ckpt_timed,
       b.checkpoints_req - a.checkpoints_req                         AS ckpt_requested,
       b.checkpoints_done - a.checkpoints_done                       AS ckpt_done,
       round(:rpt_secs / 60.0 / nullif((b.checkpoints_timed - a.checkpoints_timed)
                                     + (b.checkpoints_req - a.checkpoints_req), 0), 1) AS minutes_between_ckpt,
       round((b.checkpoint_write_time - a.checkpoint_write_time)::numeric / 1000, 1) AS ckpt_write_s,
       round((b.checkpoint_sync_time - a.checkpoint_sync_time)::numeric / 1000, 1)   AS ckpt_sync_s,
       b.buffers_checkpoint - a.buffers_checkpoint                   AS buf_checkpoint,
       b.buffers_clean - a.buffers_clean                             AS buf_bgwriter,
       b.buffers_backend - a.buffers_backend                         AS buf_backend,
       b.maxwritten_clean - a.maxwritten_clean                       AS maxwritten_clean,
       b.buffers_alloc - a.buffers_alloc                             AS buf_alloc
FROM pgstatspack2_bgwriter a, pgstatspack2_bgwriter b
WHERE a.snapid = :rpt_b AND b.snapid = :rpt_e;

\echo
\echo '-- Who writes dirty buffers (ideal: mostly checkpoint + bgwriter, little backend)'
WITH d AS (
    SELECT (b.buffers_checkpoint - a.buffers_checkpoint)::numeric AS ck,
           (b.buffers_clean - a.buffers_clean)::numeric           AS bg,
           (b.buffers_backend - a.buffers_backend)::numeric       AS be,
           ((b.buffers_checkpoint - a.buffers_checkpoint)::numeric
             / nullif((b.checkpoints_timed - a.checkpoints_timed) + (b.checkpoints_req - a.checkpoints_req), 0)) AS per_ckpt
    FROM pgstatspack2_bgwriter a, pgstatspack2_bgwriter b
    WHERE a.snapid = :rpt_b AND b.snapid = :rpt_e
)
SELECT round(100 * ck / nullif(ck + bg + be, 0), 1) || '%' AS by_checkpoint,
       round(100 * bg / nullif(ck + bg + be, 0), 1) || '%' AS by_bgwriter,
       round(100 * be / nullif(ck + bg + be, 0), 1) || '%' AS by_backends,
       round((ck + bg + be) * current_setting('block_size')::int / 1048576 / :rpt_secs, 3) || ' MB/s' AS total_write_rate,
       round(per_ckpt * current_setting('block_size')::int / 1048576, 1) || ' MB' AS avg_ckpt_write
FROM d;

-- =======================================================================================
\echo
\echo '== I/O by backend type (pg_stat_io) ================================================='
SELECT b.backend_type, b.object, b.context,
       b.reads - coalesce(a.reads, 0)                                   AS reads,
       pg_size_pretty((b.read_bytes - coalesce(a.read_bytes, 0))::bigint) AS read_size,
       round((b.read_time - coalesce(a.read_time, 0))::numeric, 1)      AS read_ms,
       b.writes - coalesce(a.writes, 0)                                 AS writes,
       pg_size_pretty((b.write_bytes - coalesce(a.write_bytes, 0))::bigint) AS write_size,
       b.extends - coalesce(a.extends, 0)                               AS extends,
       b.hits - coalesce(a.hits, 0)                                     AS hits,
       b.evictions - coalesce(a.evictions, 0)                           AS evictions,
       b.fsyncs - coalesce(a.fsyncs, 0)                                 AS fsyncs
FROM pgstatspack2_io b
LEFT JOIN pgstatspack2_io a
       ON a.snapid = :rpt_b AND a.backend_type = b.backend_type
      AND a.object = b.object AND a.context = b.context
WHERE b.snapid = :rpt_e
  AND (b.reads - coalesce(a.reads, 0)) + (b.writes - coalesce(a.writes, 0))
    + (b.extends - coalesce(a.extends, 0)) + coalesce(b.fsyncs - coalesce(a.fsyncs, 0), 0) > 0
ORDER BY (b.reads - coalesce(a.reads, 0)) + (b.writes - coalesce(a.writes, 0))
       + (b.extends - coalesce(a.extends, 0)) DESC
LIMIT :top;

-- =======================================================================================
\if :rpt_pgss
\echo
\echo '== SQL statements (pg_stat_statements, this database) ================================'
\echo '   Full text: SELECT query FROM pgstatspack2.pgstatspack2_query_text WHERE queryid = <queryid>;'

DROP TABLE IF EXISTS pg_temp.pgsp2_rpt_stmt;

-- Deltas. A statement missing from the begin snapshot (new, or below the top-N cut, or
-- evicted and re-added) is counted from zero only if its stats_since (PG17+) is inside
-- the range, or stats_since is unknown; otherwise it is skipped as unreliable.
CREATE TEMP TABLE pgsp2_rpt_stmt AS
SELECT e.userid, e.user_name_id, e.queryid, e.toplevel,
       e.plans - coalesce(b.plans, 0)                             AS plans,
       e.total_plan_time - coalesce(b.total_plan_time, 0)         AS total_plan_time,
       e.calls - coalesce(b.calls, 0)                             AS calls,
       e.total_exec_time - coalesce(b.total_exec_time, 0)         AS total_exec_time,
       e.rows - coalesce(b.rows, 0)                               AS rows,
       e.shared_blks_hit - coalesce(b.shared_blks_hit, 0)         AS shared_blks_hit,
       e.shared_blks_read - coalesce(b.shared_blks_read, 0)       AS shared_blks_read,
       e.shared_blks_dirtied - coalesce(b.shared_blks_dirtied, 0) AS shared_blks_dirtied,
       e.temp_blks_read - coalesce(b.temp_blks_read, 0)           AS temp_blks_read,
       e.temp_blks_written - coalesce(b.temp_blks_written, 0)     AS temp_blks_written,
       e.blk_read_time - coalesce(b.blk_read_time, 0)             AS blk_read_time,
       e.wal_fpi - coalesce(b.wal_fpi, 0)                         AS wal_fpi,
       e.wal_bytes - coalesce(b.wal_bytes, 0)                     AS wal_bytes,
       b.snapid IS NULL                                           AS is_new
FROM pgstatspack2_statements e
LEFT JOIN pgstatspack2_statements b
       ON b.snapid = :rpt_b AND b.userid = e.userid AND b.queryid = e.queryid AND b.toplevel = e.toplevel
WHERE e.snapid = :rpt_e
  AND (b.snapid IS NOT NULL
       OR e.stats_since IS NULL
       OR e.stats_since >= (SELECT ts FROM pgstatspack2_snap WHERE snapid = :rpt_b))
  AND (b.snapid IS NULL OR e.calls >= b.calls);   -- skip entries reset in between

DELETE FROM pgsp2_rpt_stmt WHERE calls <= 0 AND plans <= 0;

SELECT count(*) AS statements, sum(calls) AS calls,
       round(sum(total_exec_time)::numeric / 1000, 1) AS exec_seconds,
       round(sum(total_plan_time)::numeric / 1000, 1) AS plan_seconds,
       round(sum(calls) / :rpt_secs, 1) AS calls_ps,
       count(*) FILTER (WHERE is_new) AS new_in_range
FROM pgsp2_rpt_stmt;

\echo
\echo '-- Top statements by total execution time'
SELECT s.queryid, n.name AS user,
       s.calls,
       round(s.total_exec_time::numeric, 1)                                        AS exec_ms,
       round(100 * s.total_exec_time::numeric / nullif(sum(s.total_exec_time) OVER (), 0)::numeric, 1) AS pct,
       round((s.total_exec_time / nullif(s.calls, 0))::numeric, 3)                AS mean_ms,
       round(s.total_plan_time::numeric, 1)                                        AS plan_ms,
       s.rows,
       round(100.0 * s.shared_blks_hit / nullif(s.shared_blks_hit + s.shared_blks_read, 0), 1) AS hit_pct,
       left(regexp_replace(q.query, '\s+', ' ', 'g'), :qlen)                      AS query
FROM pgsp2_rpt_stmt s
JOIN pgstatspack2_names n ON n.nameid = s.user_name_id
LEFT JOIN pgstatspack2_query_text q ON q.queryid = s.queryid
ORDER BY s.total_exec_time DESC
LIMIT :top;

\echo
\echo '-- Top statements by calls'
SELECT s.queryid, n.name AS user, s.calls,
       round(s.calls / :rpt_secs, 2)                               AS calls_ps,
       round((s.total_exec_time / nullif(s.calls, 0))::numeric, 3) AS mean_ms,
       round(s.rows::numeric / nullif(s.calls, 0), 1)              AS rows_per_call,
       left(regexp_replace(q.query, '\s+', ' ', 'g'), :qlen)      AS query
FROM pgsp2_rpt_stmt s
JOIN pgstatspack2_names n ON n.nameid = s.user_name_id
LEFT JOIN pgstatspack2_query_text q ON q.queryid = s.queryid
ORDER BY s.calls DESC
LIMIT :top;

\echo
\echo '-- Top statements by physical reads (shared_blks_read)'
SELECT s.queryid, n.name AS user, s.calls,
       s.shared_blks_read                                           AS blks_read,
       pg_size_pretty(s.shared_blks_read * current_setting('block_size')::bigint) AS read_size,
       round(s.blk_read_time::numeric, 1)                           AS read_ms,
       round(100.0 * s.shared_blks_hit / nullif(s.shared_blks_hit + s.shared_blks_read, 0), 1) AS hit_pct,
       left(regexp_replace(q.query, '\s+', ' ', 'g'), :qlen)       AS query
FROM pgsp2_rpt_stmt s
JOIN pgstatspack2_names n ON n.nameid = s.user_name_id
LEFT JOIN pgstatspack2_query_text q ON q.queryid = s.queryid
WHERE s.shared_blks_read > 0
ORDER BY s.shared_blks_read DESC
LIMIT :top;

\echo
\echo '-- Top statements by temp usage (spills to disk: consider work_mem / query rewrite)'
SELECT s.queryid, n.name AS user, s.calls,
       pg_size_pretty(s.temp_blks_written * current_setting('block_size')::bigint) AS temp_written,
       pg_size_pretty(s.temp_blks_read * current_setting('block_size')::bigint)    AS temp_read,
       round((s.total_exec_time / nullif(s.calls, 0))::numeric, 3)  AS mean_ms,
       left(regexp_replace(q.query, '\s+', ' ', 'g'), :qlen)       AS query
FROM pgsp2_rpt_stmt s
JOIN pgstatspack2_names n ON n.nameid = s.user_name_id
LEFT JOIN pgstatspack2_query_text q ON q.queryid = s.queryid
WHERE s.temp_blks_written > 0
ORDER BY s.temp_blks_written DESC
LIMIT :top;

\echo
\echo '-- Top statements by WAL generated'
SELECT s.queryid, n.name AS user, s.calls,
       pg_size_pretty(s.wal_bytes::bigint)                          AS wal,
       s.wal_fpi                                                    AS fpi,
       s.shared_blks_dirtied                                        AS blks_dirtied,
       left(regexp_replace(q.query, '\s+', ' ', 'g'), :qlen)       AS query
FROM pgsp2_rpt_stmt s
JOIN pgstatspack2_names n ON n.nameid = s.user_name_id
LEFT JOIN pgstatspack2_query_text q ON q.queryid = s.queryid
WHERE s.wal_bytes > 0
ORDER BY s.wal_bytes DESC
LIMIT :top;

DROP TABLE pgsp2_rpt_stmt;
\else
\echo
\echo '== SQL statements: pg_stat_statements was not available in one or both snapshots.'
\echo '   On RDS/Aurora: add pg_stat_statements to shared_preload_libraries in the DB parameter'
\echo '   group (it is there by default on recent versions) and run CREATE EXTENSION pg_stat_statements;'
\echo '   in this database.'
\endif

-- =======================================================================================
\echo
\echo '== Tables: most rows read (seq + index) ==============================================='
WITH d AS (
    SELECT b.table_name,
           b.seq_scan - a.seq_scan             AS seq_scans,
           b.seq_tup_read - a.seq_tup_read     AS seq_rows,
           coalesce(b.idx_scan - a.idx_scan, 0)           AS idx_scans,
           coalesce(b.idx_tup_fetch - a.idx_tup_fetch, 0) AS idx_rows,
           b.heap_blks_read - a.heap_blks_read AS heap_read,
           b.heap_blks_hit - a.heap_blks_hit   AS heap_hit
    FROM pgstatspack2_tables_v a
    JOIN pgstatspack2_tables_v b ON b.table_name_id = a.table_name_id AND b.relid = a.relid
    WHERE a.snapid = :rpt_b AND b.snapid = :rpt_e
      AND b.seq_tup_read >= a.seq_tup_read
)
SELECT table_name AS table, seq_scans, seq_rows, idx_scans, idx_rows,
       round(100.0 * (seq_rows + idx_rows) / nullif(sum(seq_rows + idx_rows) OVER (), 0), 1) AS pct_of_rows_read,
       round(100.0 * seq_rows / nullif(seq_rows + idx_rows, 0), 1)                         AS seq_pct,
       round(100.0 * heap_hit / nullif(heap_hit + heap_read, 0), 1)                        AS heap_hit_pct
FROM d
WHERE seq_rows + idx_rows > 0
ORDER BY seq_rows + idx_rows DESC
LIMIT :top;

\echo
\echo '-- Large sequential scans (candidates for missing indexes)'
SELECT b.table_name AS table,
       b.seq_scan - a.seq_scan                                   AS seq_scans,
       b.seq_tup_read - a.seq_tup_read                           AS seq_rows,
       round((b.seq_tup_read - a.seq_tup_read)::numeric / nullif(b.seq_scan - a.seq_scan, 0)) AS rows_per_scan,
       b.n_live_tup                                              AS live_rows,
       pg_size_pretty(b.tbl_size)                                AS table_size
FROM pgstatspack2_tables_v a
JOIN pgstatspack2_tables_v b ON b.table_name_id = a.table_name_id AND b.relid = a.relid
WHERE a.snapid = :rpt_b AND b.snapid = :rpt_e
  AND b.seq_scan > a.seq_scan
  AND b.table_name NOT LIKE 'pg\_catalog.%' AND b.table_name NOT LIKE 'pgstatspack2.%'
ORDER BY b.seq_tup_read - a.seq_tup_read DESC
LIMIT :top;

\echo
\echo '-- DML activity'
SELECT b.table_name AS table,
       b.n_tup_ins - a.n_tup_ins                                 AS inserts,
       b.n_tup_upd - a.n_tup_upd                                 AS updates,
       round(100.0 * (b.n_tup_hot_upd - a.n_tup_hot_upd) / nullif(b.n_tup_upd - a.n_tup_upd, 0), 1) AS hot_upd_pct,
       b.n_tup_del - a.n_tup_del                                 AS deletes,
       round(((b.n_tup_ins - a.n_tup_ins) + (b.n_tup_upd - a.n_tup_upd) + (b.n_tup_del - a.n_tup_del)) / :rpt_secs, 2) AS dml_ps
FROM pgstatspack2_tables_v a
JOIN pgstatspack2_tables_v b ON b.table_name_id = a.table_name_id AND b.relid = a.relid
WHERE a.snapid = :rpt_b AND b.snapid = :rpt_e
  AND (b.n_tup_ins - a.n_tup_ins) + (b.n_tup_upd - a.n_tup_upd) + (b.n_tup_del - a.n_tup_del) > 0
ORDER BY (b.n_tup_ins - a.n_tup_ins) + (b.n_tup_upd - a.n_tup_upd) + (b.n_tup_del - a.n_tup_del) DESC
LIMIT :top;

\echo
\echo '-- Size growth (table incl. TOAST, and its indexes)'
SELECT b.table_name AS table,
       pg_size_pretty(b.tbl_size)                AS table_size,
       pg_size_pretty(b.tbl_size - a.tbl_size)   AS table_growth,
       pg_size_pretty(b.idx_size)                AS index_size,
       pg_size_pretty(b.idx_size - a.idx_size)   AS index_growth
FROM pgstatspack2_tables_v a
JOIN pgstatspack2_tables_v b ON b.table_name_id = a.table_name_id AND b.relid = a.relid
WHERE a.snapid = :rpt_b AND b.snapid = :rpt_e
  AND (b.tbl_size <> a.tbl_size OR b.idx_size <> a.idx_size)
ORDER BY abs(b.tbl_size - a.tbl_size) + abs(b.idx_size - a.idx_size) DESC
LIMIT :top;

\echo
\echo '-- Vacuum health (dead tuples at end snapshot, autovacuum activity in range)'
SELECT b.table_name AS table,
       b.n_live_tup                                          AS live_rows,
       b.n_dead_tup                                          AS dead_rows,
       round(100.0 * b.n_dead_tup / nullif(b.n_live_tup + b.n_dead_tup, 0), 1) AS dead_pct,
       b.autovacuum_count - a.autovacuum_count               AS autovacuums,
       b.autoanalyze_count - a.autoanalyze_count             AS autoanalyzes,
       b.vacuum_count - a.vacuum_count                       AS manual_vacuums,
       greatest(b.last_autovacuum, b.last_vacuum)            AS last_vacuum,
       greatest(b.last_autoanalyze, b.last_analyze)          AS last_analyze
FROM pgstatspack2_tables_v a
JOIN pgstatspack2_tables_v b ON b.table_name_id = a.table_name_id AND b.relid = a.relid
WHERE a.snapid = :rpt_b AND b.snapid = :rpt_e
  AND (b.n_dead_tup > 0 OR b.autovacuum_count > a.autovacuum_count)
ORDER BY b.n_dead_tup DESC
LIMIT :top;

-- =======================================================================================
\echo
\echo '== Indexes: most scanned ============================================================='
SELECT b.index_name AS index, b.table_name AS table,
       b.idx_scan - a.idx_scan                       AS scans,
       b.idx_tup_read - a.idx_tup_read               AS tup_read,
       b.idx_tup_fetch - a.idx_tup_fetch             AS tup_fetch,
       b.idx_blks_read - a.idx_blks_read             AS blks_read,
       round(100.0 * (b.idx_blks_hit - a.idx_blks_hit)
             / nullif((b.idx_blks_hit - a.idx_blks_hit) + (b.idx_blks_read - a.idx_blks_read), 0), 1) AS hit_pct,
       pg_size_pretty(b.idx_size)                    AS size
FROM pgstatspack2_indexes_v a
JOIN pgstatspack2_indexes_v b ON b.index_name_id = a.index_name_id AND b.indexrelid = a.indexrelid
WHERE a.snapid = :rpt_b AND b.snapid = :rpt_e
  AND b.idx_scan > a.idx_scan
ORDER BY b.idx_scan - a.idx_scan DESC
LIMIT :top;

\echo
\echo '-- Indexes not scanned in this range (non-unique, largest first; check replicas before dropping)'
SELECT b.index_name AS index, b.table_name AS table,
       pg_size_pretty(b.idx_size) AS size, b.last_idx_scan
FROM pgstatspack2_indexes_v a
JOIN pgstatspack2_indexes_v b ON b.index_name_id = a.index_name_id AND b.indexrelid = a.indexrelid
JOIN pg_index i ON i.indexrelid = b.indexrelid
WHERE a.snapid = :rpt_b AND b.snapid = :rpt_e
  AND b.idx_scan = a.idx_scan
  AND NOT i.indisunique AND NOT i.indisprimary
  AND b.index_name NOT LIKE 'pg\_catalog.%'
ORDER BY b.idx_size DESC NULLS LAST
LIMIT :top;

-- =======================================================================================
\echo
\echo '== Sequences ========================================================================='
SELECT b.sequence_name AS sequence,
       b.seq_blks_read - a.seq_blks_read AS blks_read,
       b.seq_blks_hit - a.seq_blks_hit   AS blks_hit
FROM pgstatspack2_sequences_v a
JOIN pgstatspack2_sequences_v b ON b.sequence_name = a.sequence_name
WHERE a.snapid = :rpt_b AND b.snapid = :rpt_e
  AND (b.seq_blks_read - a.seq_blks_read) + (b.seq_blks_hit - a.seq_blks_hit) > 0
ORDER BY (b.seq_blks_read - a.seq_blks_read) + (b.seq_blks_hit - a.seq_blks_hit) DESC
LIMIT :top;

-- =======================================================================================
\echo
\echo '== User functions (needs track_functions = pl or all) ================================'
SELECT b.function_name AS function,
       b.calls - coalesce(a.calls, 0)                                       AS calls,
       round((b.total_time - coalesce(a.total_time, 0))::numeric, 1)        AS total_ms,
       round((b.self_time - coalesce(a.self_time, 0))::numeric, 1)          AS self_ms,
       round(((b.total_time - coalesce(a.total_time, 0))
              / nullif(b.calls - coalesce(a.calls, 0), 0))::numeric, 3)     AS mean_ms
FROM pgstatspack2_functions_v b
LEFT JOIN pgstatspack2_functions_v a ON a.snapid = :rpt_b AND a.funcid = b.funcid
WHERE b.snapid = :rpt_e
  AND b.calls > coalesce(a.calls, 0)
ORDER BY b.self_time - coalesce(a.self_time, 0) DESC
LIMIT :top;

-- =======================================================================================
\echo
\echo '== Parameters changed between the snapshots ========================================='
SELECT coalesce(e.name, b.name) AS name,
       b.setting AS begin_setting, e.setting AS end_setting,
       coalesce(e.unit, b.unit) AS unit,
       coalesce(e.source, b.source) AS source
FROM (SELECT * FROM pgstatspack2_settings_v WHERE snapid = :rpt_b) b
FULL JOIN (SELECT * FROM pgstatspack2_settings_v WHERE snapid = :rpt_e) e ON e.name = b.name
WHERE b.setting IS DISTINCT FROM e.setting
ORDER BY 1;

\echo
\echo '== Non-default parameters at end snapshot ==========================================='
SELECT s.name, s.setting, s.unit, s.source
FROM pgstatspack2_settings_v s
WHERE s.snapid = :rpt_e
ORDER BY s.name;

\echo
\echo '== End of report ===================================================================='
