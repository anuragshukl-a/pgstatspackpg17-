#!/usr/bin/env bash
# Regression test: install, snapshot and report on the connected server, then repeat
# with PG17 and PG18 catalog shapes mocked in. Needs a superuser and a scratch database
# name that does not exist (it is dropped and re-created).
#   PGHOST=... PGUSER=postgres test/run_tests.sh [scratch_db]
set -euo pipefail
cd "$(dirname "$0")/.."
DB="${1:-pgsp2_test}"
P=(psql -X -q -v ON_ERROR_STOP=1)
export PGOPTIONS="-c client_min_messages=warning"
fail() { echo "FAIL: $*"; exit 1; }

dropdb --if-exists "$DB"; createdb "$DB"
"${P[@]}" -d "$DB" -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements;"
./install_pgStatsPack2.sh -d "$DB" >/dev/null
"${P[@]}" -d "$DB" -f test/mock_pg17_pg18_catalog.sql

check_snap() {   # $1 = label, $2 = search_path prefix for the snap function ("" = real catalog)
    local label="$1" prefix="$2"
    if [ -n "$prefix" ]; then
        sed "s/SET search_path = pg_catalog, pgstatspack2, pg_temp/SET search_path = ${prefix}, pg_catalog, pgstatspack2, pg_temp/" \
            sql/pgstatspack2_snap.sql | "${P[@]}" -d "$DB"
        "${P[@]}" -d "$DB" -c "UPDATE pgstatspack2.pgstatspack2_config SET value = '${prefix}.pg_stat_statements' WHERE name = 'statements_view';"
    else
        "${P[@]}" -d "$DB" -f sql/pgstatspack2_snap.sql
        "${P[@]}" -d "$DB" -c "UPDATE pgstatspack2.pgstatspack2_config SET value = '' WHERE name = 'statements_view';"
    fi
    "${P[@]}" -d "$DB" -c "CREATE TABLE IF NOT EXISTS t_load(id int, v text); INSERT INTO t_load SELECT g, md5(g::text) FROM generate_series(1,20000) g;"
    b=$("${P[@]}" -tA -d "$DB" -c "SELECT pgstatspack2.pgstatspack2_snap('$label begin')")
    "${P[@]}" -d "$DB" -c "SELECT count(*) FROM t_load WHERE v LIKE 'a%'; UPDATE t_load SET v = v || 'x' WHERE id < 5000; CHECKPOINT;" >/dev/null
    e=$("${P[@]}" -tA -d "$DB" -c "SELECT pgstatspack2.pgstatspack2_snap('$label end')")

    read -r stmts io ckpt done slru be pgss < <("${P[@]}" -tA -F ' ' -d "$DB" -c "
        SELECT (SELECT count(*) FROM pgstatspack2.pgstatspack2_statements WHERE snapid = $e),
               (SELECT count(*) FROM pgstatspack2.pgstatspack2_io WHERE snapid = $e),
               coalesce((SELECT checkpoints_req FROM pgstatspack2.pgstatspack2_bgwriter WHERE snapid = $e), -1),
               coalesce((SELECT checkpoints_done FROM pgstatspack2.pgstatspack2_bgwriter WHERE snapid = $e), -1),
               coalesce((SELECT slru_written FROM pgstatspack2.pgstatspack2_bgwriter WHERE snapid = $e), -1),
               coalesce((SELECT buffers_backend FROM pgstatspack2.pgstatspack2_bgwriter WHERE snapid = $e), -1),
               (SELECT pgss_found FROM pgstatspack2.pgstatspack2_snap WHERE snapid = $e);")
    [ "$pgss" = "t" ]      || fail "$label: pg_stat_statements not captured"
    [ "$stmts" -gt 0 ]     || fail "$label: no statements"
    if [ "$label" != aurora ]; then
        [ "$io" -gt 0 ]    || fail "$label: no pg_stat_io rows"
        [ "$ckpt" -ge 1 ]  || fail "$label: checkpoint counter not captured"
        [ "$be" -ge 0 ]    || fail "$label: buffers_backend not captured"
    fi
    case "$label" in
        aurora)
            [ "$("${P[@]}" -tA -d "$DB" -c "SELECT is_aurora FROM pgstatspack2.pgstatspack2_snap WHERE snapid = $e")" = "t" ] \
                || fail "aurora: not detected"
            [ "$("${P[@]}" -tA -d "$DB" -c "SELECT count(*) FROM pgstatspack2.pgstatspack2_wal WHERE snapid = $e")" = "0" ] \
                || fail "aurora: WAL should be skipped"
            [ "$ckpt" -ge 1 ] || fail "aurora: checkpoint counters should still be captured" ;;
        pg18) [ "$done" -ge 1 ] && [ "$slru" -eq 7 ] || fail "pg18: num_done/slru_written not captured" ;;
        *)    [ "$done" -eq -1 ] || fail "$label: num_done should be empty" ;;
    esac

    out=$("${P[@]}" -d "$DB" -v begin_snap="$b" -v end_snap="$e" -v top=3 -f sql/pgstatspack2_report.sql 2>&1) \
        || { echo "$out" | tail -5; fail "$label: report failed"; }
    echo "$out" | grep -q "End of report" || fail "$label: report incomplete"
    echo "$out" | grep -q "t_load" || fail "$label: report missing table activity"
    echo "ok  $label  (snap $b..$e: statements=$stmts io_rows=$io ckpt_req=$ckpt num_done=$done slru=$slru backend_writes=$be)"
}

check_snap native ""
check_snap pg17 mock17
check_snap pg18 mock18
check_snap aurora mockaurora

# Maintenance functions
"${P[@]}" -d "$DB" -c "SELECT * FROM pgstatspack2.pgstatspack2_get_unused_indexes('1 day');" >/dev/null || fail "unused indexes"
"${P[@]}" -tA -d "$DB" -c "SELECT pgstatspack2.pgstatspack2_delete_snap('0 seconds');" | grep -q "Deleted 8 snapshots" || fail "purge"
[ "$("${P[@]}" -tA -d "$DB" -c "SELECT count(*) FROM pgstatspack2.pgstatspack2_tables")" = "0" ] || fail "cascade delete"
echo "ok  maintenance (unused indexes, purge, cascade)"

dropdb "$DB"
echo "ALL TESTS PASSED"
