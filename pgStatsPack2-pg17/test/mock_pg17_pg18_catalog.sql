-- Test harness: shadow catalog views with the exact PG17 / PG18 column layouts so the
-- version-specific branches of pgstatspack2_snap() can be exercised on an older server.
-- Used only by test/run_tests.sh; never install this in a real database.

-- ---------- PostgreSQL 17 shapes ----------
CREATE SCHEMA mock17;
CREATE VIEW mock17.pg_stat_checkpointer AS
SELECT checkpoints_timed AS num_timed, checkpoints_req AS num_requested,
       0::bigint AS restartpoints_timed, 0::bigint AS restartpoints_req, 0::bigint AS restartpoints_done,
       checkpoint_write_time AS write_time, checkpoint_sync_time AS sync_time,
       buffers_checkpoint AS buffers_written, stats_reset
FROM pg_catalog.pg_stat_bgwriter;
CREATE VIEW mock17.pg_stat_bgwriter AS                -- checkpoint + backend columns removed in 17
SELECT buffers_clean, maxwritten_clean, buffers_alloc, stats_reset FROM pg_catalog.pg_stat_bgwriter;
CREATE VIEW mock17.pg_stat_statements AS              -- pg_stat_statements 1.11 renames + stats_since
SELECT userid, dbid, toplevel, queryid, query, plans, total_plan_time, calls, total_exec_time, rows,
       shared_blks_hit, shared_blks_read, shared_blks_dirtied, shared_blks_written,
       local_blks_hit, local_blks_read, local_blks_dirtied, local_blks_written,
       temp_blks_read, temp_blks_written,
       blk_read_time AS shared_blk_read_time, blk_write_time AS shared_blk_write_time,
       0::float8 AS local_blk_read_time, 0::float8 AS local_blk_write_time,
       wal_records, wal_fpi, wal_bytes, pg_postmaster_start_time() AS stats_since,
       pg_postmaster_start_time() AS minmax_stats_since
FROM public.pg_stat_statements;

-- ---------- PostgreSQL 18 shapes ----------
CREATE SCHEMA mock18;
CREATE VIEW mock18.pg_stat_checkpointer AS
SELECT c.num_timed, c.num_requested, (c.num_timed + c.num_requested) AS num_done,
       c.restartpoints_timed, c.restartpoints_req, c.restartpoints_done,
       c.write_time, c.sync_time, c.buffers_written, 7::bigint AS slru_written, c.stats_reset
FROM mock17.pg_stat_checkpointer c;
CREATE VIEW mock18.pg_stat_bgwriter AS SELECT * FROM mock17.pg_stat_bgwriter;
CREATE VIEW mock18.pg_stat_io AS                      -- op_bytes removed, *_bytes added in 18
SELECT backend_type, object, context, reads, reads * op_bytes AS read_bytes, read_time,
       writes, writes * op_bytes AS write_bytes, write_time, writebacks, writeback_time,
       extends, extends * op_bytes AS extend_bytes, extend_time, hits, evictions, reuses,
       fsyncs, fsync_time, stats_reset
FROM pg_catalog.pg_stat_io;
CREATE VIEW mock18.pg_stat_statements AS
SELECT s.*, 0::bigint AS parallel_workers_to_launch, 0::bigint AS parallel_workers_launched,
       0::bigint AS wal_buffers_full, 0::bigint AS generic_plan_calls, 0::bigint AS custom_plan_calls
FROM mock17.pg_stat_statements s;

-- ---------- Aurora-like: unsupported stats functions raise errors ----------
CREATE SCHEMA mockaurora;
CREATE FUNCTION mockaurora.aurora_version() RETURNS text LANGUAGE sql AS $$ SELECT '17.mock' $$;
CREATE FUNCTION mockaurora.not_supported(f text) RETURNS bigint LANGUAGE plpgsql AS
$$ BEGIN RAISE EXCEPTION 'Function %() is currently not supported for Aurora', f
         USING ERRCODE = 'feature_not_supported'; END $$;
CREATE VIEW mockaurora.pg_stat_wal AS
SELECT mockaurora.not_supported('pg_stat_get_wal') AS wal_records, 0::bigint AS wal_fpi,
       0::numeric AS wal_bytes, 0::bigint AS wal_buffers_full, now() AS stats_reset;
CREATE VIEW mockaurora.pg_stat_checkpointer AS SELECT * FROM mock17.pg_stat_checkpointer;
CREATE VIEW mockaurora.pg_stat_bgwriter AS SELECT * FROM mock17.pg_stat_bgwriter;
CREATE VIEW mockaurora.pg_stat_io AS
SELECT io.*, mockaurora.not_supported('pg_stat_get_io') AS boom FROM pg_catalog.pg_stat_io io;
CREATE VIEW mockaurora.pg_stat_statements AS SELECT * FROM mock17.pg_stat_statements;
