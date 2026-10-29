-- pgStatsPack2 for PostgreSQL 17 / 18 (Amazon RDS and Aurora PostgreSQL compatible)
-- pgstatspack2_snap(description): take one statistics snapshot of the current database.
--
-- Version differences handled at run time (no reinstall needed after a major upgrade):
--   * PG17+: checkpoint counters read from pg_stat_checkpointer; backend writes/fsyncs
--            (old buffers_backend / buffers_backend_fsync) derived from pg_stat_io.
--   * PG18+: pg_stat_checkpointer.num_done / slru_written; pg_stat_io *_bytes columns.
--   * pg_stat_statements 1.11+ (PG17): shared_blk_read_time / shared_blk_write_time / stats_since.
--   * pg_stat_statements is optional; it is found in whatever schema the extension lives in.

\set ON_ERROR_STOP on
SET client_min_messages TO warning;

CREATE OR REPLACE FUNCTION pgstatspack2.pgstatspack2_snap(p_description text DEFAULT 'manual snapshot')
RETURNS bigint
LANGUAGE plpgsql
SET search_path = pg_catalog, pgstatspack2, pg_temp
SET lock_timeout = '3s'
AS $fn$
DECLARE
    v_snapid        bigint;
    v_start         timestamptz := clock_timestamp();
    v_dboid         oid;
    v_locked        oid[];
    v_sizes         boolean;
    v_limit         integer;
    v_pss           regclass;
    v_pss_override  text;
    v_rt_col        text;
    v_wt_col        text;
    v_since_col     text;
    v_rb            text;
    v_wb            text;
    v_eb            text;
    v_rel           regclass;
    v_aurora        boolean := to_regproc('aurora_version') IS NOT NULL;
BEGIN
    SELECT oid INTO v_dboid FROM pg_database WHERE datname = current_database();

    v_sizes := coalesce((SELECT value FROM pgstatspack2_config WHERE name = 'collect_sizes'), 'on')
               IN ('on', 'true', '1', 'yes');
    v_limit := coalesce(nullif((SELECT value FROM pgstatspack2_config WHERE name = 'statements_limit'), '')::int, 1000);

    INSERT INTO pgstatspack2_snap (description, server_version_num, server_version, is_aurora,
                                   postmaster_start, db_size)
    VALUES (p_description,
            current_setting('server_version_num')::int,
            current_setting('server_version'),
            v_aurora,
            pg_postmaster_start_time(),
            pg_database_size(v_dboid))
    RETURNING snapid INTO v_snapid;

    -- Relations currently held/requested in ACCESS EXCLUSIVE mode: skip their size
    -- so the snapshot never queues behind DDL (and DDL never queues behind us).
    v_locked := ARRAY(SELECT relation FROM pg_locks
                      WHERE locktype = 'relation' AND mode = 'AccessExclusiveLock'
                        AND database = v_dboid AND relation IS NOT NULL);

    ---------------------------------------------------------------------------
    -- Databases
    ---------------------------------------------------------------------------
    INSERT INTO pgstatspack2_names (name)
    SELECT DISTINCT d.datname FROM pg_stat_database d
    WHERE d.datname IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM pgstatspack2_names n WHERE n.name = d.datname)
    ON CONFLICT (name) DO NOTHING;

    INSERT INTO pgstatspack2_database
        (snapid, datid, dbnameid, numbackends, xact_commit, xact_rollback, blks_read, blks_hit,
         tup_returned, tup_fetched, tup_inserted, tup_updated, tup_deleted, conflicts, temp_files,
         temp_bytes, deadlocks, checksum_failures, blk_read_time, blk_write_time, session_time,
         active_time, idle_in_transaction_time, sessions, sessions_abandoned, sessions_fatal,
         sessions_killed, stats_reset)
    SELECT v_snapid, d.datid, n.nameid, d.numbackends, d.xact_commit, d.xact_rollback, d.blks_read,
           d.blks_hit, d.tup_returned, d.tup_fetched, d.tup_inserted, d.tup_updated, d.tup_deleted,
           d.conflicts, d.temp_files, d.temp_bytes, d.deadlocks, d.checksum_failures,
           d.blk_read_time, d.blk_write_time, d.session_time, d.active_time,
           d.idle_in_transaction_time, d.sessions, d.sessions_abandoned, d.sessions_fatal,
           d.sessions_killed, d.stats_reset
    FROM pg_stat_database d
    JOIN pgstatspack2_names n ON n.name = d.datname;

    ---------------------------------------------------------------------------
    -- Tables (temp and toast schemas skipped; toast I/O is rolled into its parent)
    ---------------------------------------------------------------------------
    INSERT INTO pgstatspack2_names (name)
    SELECT DISTINCT quote_ident(t.schemaname) || '.' || quote_ident(t.relname)
    FROM pg_stat_all_tables t
    WHERE t.schemaname NOT LIKE 'pg\_toast%' AND t.schemaname NOT LIKE 'pg\_temp\_%'
      AND NOT EXISTS (SELECT 1 FROM pgstatspack2_names n
                      WHERE n.name = quote_ident(t.schemaname) || '.' || quote_ident(t.relname))
    ON CONFLICT (name) DO NOTHING;

    INSERT INTO pgstatspack2_tables
        (snapid, table_name_id, relid, seq_scan, seq_tup_read, idx_scan, idx_tup_fetch,
         n_tup_ins, n_tup_upd, n_tup_del, n_tup_hot_upd, n_tup_newpage_upd, n_live_tup, n_dead_tup,
         n_mod_since_analyze, n_ins_since_vacuum, last_seq_scan, last_idx_scan, last_vacuum,
         last_autovacuum, last_analyze, last_autoanalyze, vacuum_count, autovacuum_count,
         analyze_count, autoanalyze_count, heap_blks_read, heap_blks_hit, idx_blks_read,
         idx_blks_hit, toast_blks_read, toast_blks_hit, tidx_blks_read, tidx_blks_hit)
    SELECT v_snapid, n.nameid, t.relid, t.seq_scan, t.seq_tup_read, t.idx_scan, t.idx_tup_fetch,
           t.n_tup_ins, t.n_tup_upd, t.n_tup_del, t.n_tup_hot_upd, t.n_tup_newpage_upd,
           t.n_live_tup, t.n_dead_tup, t.n_mod_since_analyze, t.n_ins_since_vacuum,
           t.last_seq_scan, t.last_idx_scan, t.last_vacuum, t.last_autovacuum, t.last_analyze,
           t.last_autoanalyze, t.vacuum_count, t.autovacuum_count, t.analyze_count,
           t.autoanalyze_count, io.heap_blks_read, io.heap_blks_hit, io.idx_blks_read,
           io.idx_blks_hit, io.toast_blks_read, io.toast_blks_hit, io.tidx_blks_read,
           io.tidx_blks_hit
    FROM pg_stat_all_tables t
    JOIN pg_statio_all_tables io ON io.relid = t.relid
    JOIN pgstatspack2_names n ON n.name = quote_ident(t.schemaname) || '.' || quote_ident(t.relname)
    WHERE t.schemaname NOT LIKE 'pg\_toast%' AND t.schemaname NOT LIKE 'pg\_temp\_%';

    ---------------------------------------------------------------------------
    -- Indexes
    ---------------------------------------------------------------------------
    INSERT INTO pgstatspack2_names (name)
    SELECT DISTINCT x.name
    FROM pg_stat_all_indexes i
    CROSS JOIN LATERAL (VALUES (quote_ident(i.schemaname) || '.' || quote_ident(i.indexrelname)),
                               (quote_ident(i.schemaname) || '.' || quote_ident(i.relname))) AS x(name)
    WHERE i.schemaname NOT LIKE 'pg\_toast%' AND i.schemaname NOT LIKE 'pg\_temp\_%'
      AND NOT EXISTS (SELECT 1 FROM pgstatspack2_names n WHERE n.name = x.name)
    ON CONFLICT (name) DO NOTHING;

    INSERT INTO pgstatspack2_indexes
        (snapid, index_name_id, table_name_id, indexrelid, relid, idx_scan, idx_tup_read,
         idx_tup_fetch, last_idx_scan, idx_blks_read, idx_blks_hit)
    SELECT v_snapid, n1.nameid, n2.nameid, i.indexrelid, i.relid, i.idx_scan, i.idx_tup_read,
           i.idx_tup_fetch, i.last_idx_scan, ii.idx_blks_read, ii.idx_blks_hit
    FROM pg_stat_all_indexes i
    JOIN pg_statio_all_indexes ii ON ii.indexrelid = i.indexrelid
    JOIN pgstatspack2_names n1 ON n1.name = quote_ident(i.schemaname) || '.' || quote_ident(i.indexrelname)
    JOIN pgstatspack2_names n2 ON n2.name = quote_ident(i.schemaname) || '.' || quote_ident(i.relname)
    WHERE i.schemaname NOT LIKE 'pg\_toast%' AND i.schemaname NOT LIKE 'pg\_temp\_%';

    ---------------------------------------------------------------------------
    -- Sizes (guarded: never wait on locks, never fail the whole snapshot)
    ---------------------------------------------------------------------------
    IF v_sizes THEN
        BEGIN
            UPDATE pgstatspack2_tables s
               SET tbl_size = pg_table_size(s.relid),
                   idx_size = pg_indexes_size(s.relid)
             WHERE s.snapid = v_snapid
               AND s.relid <> ALL (v_locked);

            UPDATE pgstatspack2_indexes s
               SET idx_size = pg_relation_size(s.indexrelid)
             WHERE s.snapid = v_snapid
               AND s.indexrelid <> ALL (v_locked)
               AND s.relid <> ALL (v_locked);
        EXCEPTION
            WHEN lock_not_available OR query_canceled OR undefined_table THEN
                RAISE WARNING 'pgstatspack2: relation sizes skipped for snapshot %: %', v_snapid, SQLERRM;
        END;
    END IF;

    ---------------------------------------------------------------------------
    -- Sequences
    ---------------------------------------------------------------------------
    INSERT INTO pgstatspack2_names (name)
    SELECT DISTINCT quote_ident(s.schemaname) || '.' || quote_ident(s.relname)
    FROM pg_statio_all_sequences s
    WHERE s.schemaname NOT LIKE 'pg\_temp\_%'
      AND NOT EXISTS (SELECT 1 FROM pgstatspack2_names n
                      WHERE n.name = quote_ident(s.schemaname) || '.' || quote_ident(s.relname))
    ON CONFLICT (name) DO NOTHING;

    INSERT INTO pgstatspack2_sequences (snapid, sequence_name_id, seq_blks_read, seq_blks_hit)
    SELECT v_snapid, n.nameid, s.blks_read, s.blks_hit
    FROM pg_statio_all_sequences s
    JOIN pgstatspack2_names n ON n.name = quote_ident(s.schemaname) || '.' || quote_ident(s.relname)
    WHERE s.schemaname NOT LIKE 'pg\_temp\_%';

    ---------------------------------------------------------------------------
    -- Non-default server settings (session/client-level values of the snapshot
    -- session itself are ignored)
    ---------------------------------------------------------------------------
    INSERT INTO pgstatspack2_names (name)
    SELECT DISTINCT x.name
    FROM pg_settings s
    CROSS JOIN LATERAL (VALUES (s.name), (coalesce(s.setting, '')), (s.source)) AS x(name)
    WHERE s.source NOT IN ('default', 'session', 'client', 'interactive')
      AND NOT EXISTS (SELECT 1 FROM pgstatspack2_names n WHERE n.name = x.name)
    ON CONFLICT (name) DO NOTHING;

    INSERT INTO pgstatspack2_settings (snapid, name_id, setting_id, source_id, unit)
    SELECT v_snapid, n1.nameid, n2.nameid, n3.nameid, s.unit
    FROM pg_settings s
    JOIN pgstatspack2_names n1 ON n1.name = s.name
    JOIN pgstatspack2_names n2 ON n2.name = coalesce(s.setting, '')
    JOIN pgstatspack2_names n3 ON n3.name = s.source
    WHERE s.source NOT IN ('default', 'session', 'client', 'interactive');

    ---------------------------------------------------------------------------
    -- User functions
    ---------------------------------------------------------------------------
    INSERT INTO pgstatspack2_names (name)
    SELECT DISTINCT format('%I.%I(%s)', f.schemaname, f.funcname, oidvectortypes(p.proargtypes))
    FROM pg_stat_user_functions f
    JOIN pg_proc p ON p.oid = f.funcid
    WHERE NOT EXISTS (SELECT 1 FROM pgstatspack2_names n
                      WHERE n.name = format('%I.%I(%s)', f.schemaname, f.funcname, oidvectortypes(p.proargtypes)))
    ON CONFLICT (name) DO NOTHING;

    INSERT INTO pgstatspack2_functions (snapid, funcid, function_name_id, calls, total_time, self_time)
    SELECT v_snapid, f.funcid, n.nameid, f.calls, f.total_time, f.self_time
    FROM pg_stat_user_functions f
    JOIN pg_proc p ON p.oid = f.funcid
    JOIN pgstatspack2_names n
      ON n.name = format('%I.%I(%s)', f.schemaname, f.funcname, oidvectortypes(p.proargtypes));

    ---------------------------------------------------------------------------
    -- Background writer / checkpointer
    ---------------------------------------------------------------------------
    BEGIN
        IF to_regclass('pg_stat_checkpointer') IS NULL THEN
            -- PostgreSQL 16: everything is still in pg_stat_bgwriter
            INSERT INTO pgstatspack2_bgwriter
                (snapid, checkpoints_timed, checkpoints_req, checkpoint_write_time, checkpoint_sync_time,
                 buffers_checkpoint, buffers_clean, maxwritten_clean, buffers_backend,
                 buffers_backend_fsync, buffers_alloc)
            SELECT v_snapid, b.checkpoints_timed, b.checkpoints_req, b.checkpoint_write_time,
                   b.checkpoint_sync_time, b.buffers_checkpoint, b.buffers_clean, b.maxwritten_clean,
                   b.buffers_backend, b.buffers_backend_fsync, b.buffers_alloc
            FROM pg_stat_bgwriter b;
        ELSE
            -- PostgreSQL 17+: checkpointer has its own view; backend writes come from pg_stat_io
            INSERT INTO pgstatspack2_bgwriter
                (snapid, checkpoints_timed, checkpoints_req, restartpoints_timed, restartpoints_req,
                 restartpoints_done, checkpoint_write_time, checkpoint_sync_time, buffers_checkpoint,
                 buffers_clean, maxwritten_clean, buffers_alloc)
            SELECT v_snapid, c.num_timed, c.num_requested, c.restartpoints_timed, c.restartpoints_req,
                   c.restartpoints_done, c.write_time, c.sync_time, c.buffers_written,
                   b.buffers_clean, b.maxwritten_clean, b.buffers_alloc
            FROM pg_stat_checkpointer c
            CROSS JOIN pg_stat_bgwriter b;

            -- Backend writes/fsyncs (old buffers_backend*) now come from pg_stat_io
            BEGIN
                UPDATE pgstatspack2_bgwriter t
                   SET buffers_backend = io.writes, buffers_backend_fsync = io.fsyncs
                  FROM (SELECT sum(writes)::bigint AS writes, sum(fsyncs)::bigint AS fsyncs
                        FROM pg_stat_io
                        WHERE object = 'relation'
                          AND backend_type NOT IN ('background writer', 'checkpointer')) io
                 WHERE t.snapid = v_snapid;
            EXCEPTION WHEN OTHERS THEN
                NULL;   -- pg_stat_io unavailable (reported once in the pg_stat_io section)
            END;

            -- PostgreSQL 18+: extra checkpointer counters
            v_rel := to_regclass('pg_stat_checkpointer');
            IF EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = v_rel AND attname = 'num_done' AND NOT attisdropped) THEN
                EXECUTE format('UPDATE pgstatspack2.pgstatspack2_bgwriter b
                                   SET checkpoints_done = c.num_done, slru_written = c.slru_written
                                  FROM %s c WHERE b.snapid = $1', v_rel)
                USING v_snapid;
            END IF;
        END IF;
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'pgstatspack2: bgwriter/checkpointer stats skipped: %', SQLERRM;
    END;

    ---------------------------------------------------------------------------
    -- WAL
    ---------------------------------------------------------------------------
    IF NOT v_aurora THEN   -- Aurora does not implement pg_stat_get_wal()
        BEGIN
            INSERT INTO pgstatspack2_wal (snapid, wal_records, wal_fpi, wal_bytes, wal_buffers_full, stats_reset)
            SELECT v_snapid, w.wal_records, w.wal_fpi, w.wal_bytes, w.wal_buffers_full, w.stats_reset
            FROM pg_stat_wal w;
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING 'pgstatspack2: pg_stat_wal skipped: %', SQLERRM;
        END;
    END IF;

    ---------------------------------------------------------------------------
    -- pg_stat_io (PG16+). PG18 replaced op_bytes with read/write/extend_bytes.
    ---------------------------------------------------------------------------
    BEGIN
        v_rel := to_regclass('pg_stat_io');
        IF v_rel IS NOT NULL THEN
            IF EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = v_rel AND attname = 'read_bytes' AND NOT attisdropped) THEN
                v_rb := 'io.read_bytes';  v_wb := 'io.write_bytes';  v_eb := 'io.extend_bytes';           -- PG18+
            ELSE
                v_rb := 'io.reads * io.op_bytes';  v_wb := 'io.writes * io.op_bytes';  v_eb := 'io.extends * io.op_bytes';
            END IF;

            EXECUTE format($q$
                INSERT INTO pgstatspack2.pgstatspack2_io
                    (snapid, backend_type, object, context, reads, read_bytes, read_time, writes,
                     write_bytes, write_time, writebacks, writeback_time, extends, extend_bytes,
                     extend_time, hits, evictions, reuses, fsyncs, fsync_time)
                SELECT $1, io.backend_type, io.object, io.context, io.reads, %2$s,
                       io.read_time, io.writes, %3$s, io.write_time, io.writebacks, io.writeback_time,
                       io.extends, %4$s, io.extend_time, io.hits, io.evictions, io.reuses,
                       io.fsyncs, io.fsync_time
                FROM %1$s io
                WHERE coalesce(io.reads, 0) + coalesce(io.writes, 0) + coalesce(io.extends, 0)
                    + coalesce(io.hits, 0) + coalesce(io.fsyncs, 0) + coalesce(io.writebacks, 0) > 0
                $q$, v_rel, v_rb, v_wb, v_eb)
            USING v_snapid;
        END IF;
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'pgstatspack2: pg_stat_io skipped: %', SQLERRM;
    END;

    ---------------------------------------------------------------------------
    -- pg_stat_statements (optional)
    ---------------------------------------------------------------------------
    v_pss_override := nullif((SELECT value FROM pgstatspack2_config WHERE name = 'statements_view'), '');
    IF v_pss_override IS NOT NULL THEN
        v_pss := to_regclass(v_pss_override);
    ELSE
        SELECT to_regclass(format('%I.pg_stat_statements', n.nspname))
          INTO v_pss
          FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace
         WHERE e.extname = 'pg_stat_statements';
    END IF;

    IF v_pss IS NOT NULL THEN
        IF EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = v_pss AND attname = 'shared_blk_read_time' AND NOT attisdropped) THEN
            v_rt_col := 'shared_blk_read_time';
            v_wt_col := 'shared_blk_write_time';
        ELSE
            v_rt_col := 'blk_read_time';
            v_wt_col := 'blk_write_time';
        END IF;
        v_since_col := CASE WHEN EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = v_pss AND attname = 'stats_since' AND NOT attisdropped)
                            THEN 's.stats_since' ELSE 'NULL::timestamptz' END;

        BEGIN
            -- Top N entries of this database by cumulative (exec + plan) time
            EXECUTE format($q$
                CREATE TEMP TABLE pgstatspack2_pss_tmp ON COMMIT DROP AS
                SELECT s.userid, pg_get_userbyid(s.userid)::text AS user_name, s.queryid, s.toplevel,
                       s.query, s.plans, s.total_plan_time, s.calls, s.total_exec_time, s.rows,
                       s.shared_blks_hit, s.shared_blks_read, s.shared_blks_dirtied,
                       s.shared_blks_written, s.local_blks_hit, s.local_blks_read,
                       s.temp_blks_read, s.temp_blks_written,
                       s.%2$I AS blk_read_time, s.%3$I AS blk_write_time,
                       s.wal_records, s.wal_fpi, s.wal_bytes, %4$s AS stats_since
                FROM %1$s s
                WHERE s.dbid = $1 AND s.queryid IS NOT NULL
                ORDER BY s.total_exec_time + s.total_plan_time DESC
                LIMIT %5$s
                $q$, v_pss, v_rt_col, v_wt_col, v_since_col, v_limit)
            USING v_dboid;

            INSERT INTO pgstatspack2_names (name)
            SELECT DISTINCT t.user_name FROM pg_temp.pgstatspack2_pss_tmp t
            WHERE NOT EXISTS (SELECT 1 FROM pgstatspack2_names n WHERE n.name = t.user_name)
            ON CONFLICT (name) DO NOTHING;

            INSERT INTO pgstatspack2_query_text (queryid, query)
            SELECT DISTINCT ON (t.queryid) t.queryid, t.query
            FROM pg_temp.pgstatspack2_pss_tmp t
            WHERE NOT EXISTS (SELECT 1 FROM pgstatspack2_query_text q WHERE q.queryid = t.queryid)
            ORDER BY t.queryid
            ON CONFLICT (queryid) DO NOTHING;

            INSERT INTO pgstatspack2_statements
                (snapid, userid, user_name_id, queryid, toplevel, plans, total_plan_time, calls,
                 total_exec_time, "rows", shared_blks_hit, shared_blks_read, shared_blks_dirtied,
                 shared_blks_written, local_blks_hit, local_blks_read, temp_blks_read,
                 temp_blks_written, blk_read_time, blk_write_time, wal_records, wal_fpi, wal_bytes,
                 stats_since)
            SELECT v_snapid, t.userid, n.nameid, t.queryid, t.toplevel, t.plans, t.total_plan_time,
                   t.calls, t.total_exec_time, t.rows, t.shared_blks_hit, t.shared_blks_read,
                   t.shared_blks_dirtied, t.shared_blks_written, t.local_blks_hit, t.local_blks_read,
                   t.temp_blks_read, t.temp_blks_written, t.blk_read_time, t.blk_write_time,
                   t.wal_records, t.wal_fpi, t.wal_bytes, t.stats_since
            FROM pg_temp.pgstatspack2_pss_tmp t
            JOIN pgstatspack2_names n ON n.name = t.user_name;

            DROP TABLE pg_temp.pgstatspack2_pss_tmp;
            UPDATE pgstatspack2_snap SET pgss_found = true WHERE snapid = v_snapid;
        EXCEPTION
            WHEN OTHERS THEN
                -- e.g. extension created but not in shared_preload_libraries
                RAISE WARNING 'pgstatspack2: pg_stat_statements skipped: %', SQLERRM;
                UPDATE pgstatspack2_snap SET pgss_found = false WHERE snapid = v_snapid;
        END;
    ELSE
        UPDATE pgstatspack2_snap SET pgss_found = false WHERE snapid = v_snapid;
    END IF;

    UPDATE pgstatspack2_snap
       SET elapsed_ms = round((extract(epoch FROM clock_timestamp() - v_start) * 1000)::numeric, 1)
     WHERE snapid = v_snapid;

    RETURN v_snapid;
END
$fn$;

COMMENT ON FUNCTION pgstatspack2.pgstatspack2_snap(text) IS
    'Take a pgStatsPack2 statistics snapshot of the current database. Returns the snapshot id.';
