-- pgStatsPack2 for PostgreSQL 17 / 18 (Amazon RDS and Aurora PostgreSQL compatible)
-- Retention, unused-index finder and snapshot listing helpers.

\set ON_ERROR_STOP on
SET client_min_messages TO warning;

-- ---------------------------------------------------------------------------
-- pgstatspack2_delete_snap([older_than]): purge old snapshots.
-- Default retention comes from pgstatspack2_config('retention'), shipped as 30 days.
-- Child rows go via ON DELETE CASCADE; orphaned query texts are removed too.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS pgstatspack2.pgstatspack2_delete_snap();

CREATE OR REPLACE FUNCTION pgstatspack2.pgstatspack2_delete_snap(p_older_than interval DEFAULT NULL)
RETURNS text
LANGUAGE plpgsql
SET search_path = pg_catalog, pgstatspack2, pg_temp
AS $fn$
DECLARE
    v_keep    interval;
    v_cutoff  timestamptz;
    v_snaps   bigint;
    v_texts   bigint;
BEGIN
    v_keep := coalesce(p_older_than,
                       (SELECT value FROM pgstatspack2_config WHERE name = 'retention')::interval,
                       interval '30 days');
    v_cutoff := now() - v_keep;

    DELETE FROM pgstatspack2_snap WHERE ts < v_cutoff;
    GET DIAGNOSTICS v_snaps = ROW_COUNT;

    DELETE FROM pgstatspack2_query_text q
     WHERE NOT EXISTS (SELECT 1 FROM pgstatspack2_statements s WHERE s.queryid = q.queryid);
    GET DIAGNOSTICS v_texts = ROW_COUNT;

    RETURN format('Deleted %s snapshots older than %s (%s orphaned query texts)',
                  v_snaps, v_cutoff::text, v_texts);
END
$fn$;

-- ---------------------------------------------------------------------------
-- pgstatspack2_get_unused_indexes([timespan]): indexes with zero scans between the
-- first snapshot inside the timespan and the latest snapshot.
-- Primary keys, unique indexes and indexes backing constraints (exclusion etc.) are
-- skipped. Indexes on foreign-key columns are reported but flagged, because they
-- often matter for DELETE/UPDATE on the parent table even when never "scanned".
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS pgstatspack2.pgstatspack2_get_unused_indexes(interval);

CREATE OR REPLACE FUNCTION pgstatspack2.pgstatspack2_get_unused_indexes(p_timespan interval DEFAULT '7 days')
RETURNS TABLE (table_name text, index_name text, index_size text, size_bytes bigint,
               fk_supporting boolean, observed_since timestamptz, indexdef text)
LANGUAGE plpgsql
SET search_path = pg_catalog, pgstatspack2, pg_temp
AS $fn$
DECLARE
    v_max_ts  timestamptz;
    v_stop    bigint;
BEGIN
    SELECT s.snapid, s.ts INTO v_stop, v_max_ts FROM pgstatspack2_snap s ORDER BY s.snapid DESC LIMIT 1;
    IF v_stop IS NULL THEN
        RAISE INFO 'pgstatspack2: no snapshots found';
        RETURN;
    END IF;
    IF v_max_ts < now() - interval '1 day' THEN
        RAISE INFO 'pgstatspack2: latest snapshot is older than 1 day (%). Is the scheduler running?', v_max_ts;
    END IF;

    RETURN QUERY
    WITH win AS (
        SELECT s.snapid, s.ts FROM pgstatspack2_snap s
        WHERE s.ts >= v_max_ts - coalesce(p_timespan, interval '7 days') AND s.snapid < v_stop
    ),
    first_seen AS (           -- earliest snapshot in the window that has the index
        SELECT DISTINCT ON (i.indexrelid) i.indexrelid, i.idx_scan, w.ts
        FROM pgstatspack2_indexes i JOIN win w ON w.snapid = i.snapid
        ORDER BY i.indexrelid, i.snapid
    )
    SELECT tn.name, xn.name,
           pg_size_pretty(pg_relation_size(c.oid)),
           pg_relation_size(c.oid),
           EXISTS (SELECT 1 FROM pg_constraint fk
                   WHERE fk.contype = 'f' AND fk.conrelid = ix.indrelid
                     AND (ix.indkey::int2[])[0:cardinality(fk.conkey) - 1] @> fk.conkey
                     AND (ix.indkey::int2[])[0:cardinality(fk.conkey) - 1] <@ fk.conkey),
           f.ts,
           pg_get_indexdef(c.oid)
    FROM pgstatspack2_indexes b
    JOIN first_seen f            ON f.indexrelid = b.indexrelid
    JOIN pgstatspack2_names xn   ON xn.nameid = b.index_name_id
    JOIN pgstatspack2_names tn   ON tn.nameid = b.table_name_id
    JOIN pg_class c              ON c.oid = b.indexrelid
    JOIN pg_index ix             ON ix.indexrelid = c.oid
    JOIN pg_namespace ns         ON ns.oid = c.relnamespace
    WHERE b.snapid = v_stop
      AND b.idx_scan = f.idx_scan              -- no scans since first seen (and no reset)
      AND NOT ix.indisprimary
      AND NOT ix.indisunique
      AND ix.indisvalid
      AND ns.nspname NOT IN ('pg_catalog', 'information_schema', 'pgstatspack2')
      AND NOT EXISTS (SELECT 1 FROM pg_constraint con WHERE con.conindid = c.oid)
    ORDER BY pg_relation_size(c.oid) DESC;
END
$fn$;

-- ---------------------------------------------------------------------------
-- pgstatspack2_list_snaps([limit]): quick listing for picking report ranges.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pgstatspack2.pgstatspack2_list_snaps(p_limit integer DEFAULT 50)
RETURNS TABLE (snapid bigint, ts timestamptz, description text, pgss boolean,
               db_size text, elapsed_ms numeric, restart_since_prev boolean)
LANGUAGE sql STABLE
SET search_path = pg_catalog, pgstatspack2, pg_temp
AS $fn$
    SELECT s.snapid, s.ts, s.description, s.pgss_found, pg_size_pretty(s.db_size), s.elapsed_ms,
           s.postmaster_start IS DISTINCT FROM lag(s.postmaster_start) OVER (ORDER BY s.snapid)
             AND lag(s.snapid) OVER (ORDER BY s.snapid) IS NOT NULL
    FROM pgstatspack2_snap s
    ORDER BY s.snapid DESC
    LIMIT p_limit;
$fn$;
