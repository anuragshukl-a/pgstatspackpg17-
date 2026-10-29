#!/usr/bin/env bash
# Schedule pgStatsPack2 snapshots and purges INSIDE RDS / Aurora PostgreSQL with pg_cron,
# so no external host or OS cron is needed.
#
# One-time prerequisites (RDS/Aurora):
#   1. DB parameter group (cluster parameter group for Aurora):
#        shared_preload_libraries  must include  pg_cron   (keep pg_stat_statements too)
#        cron.database_name        = postgres   (default; the DB where pg_cron lives)
#      then reboot the instance / writer.
#   2. As the master user, in that database:  CREATE EXTENSION pg_cron;
#
# Jobs are created with cron.schedule_in_database(), so one pg_cron install drives
# every target database. Jobs run as the user who runs this script.
# pg_cron schedules are in UTC (cron.timezone).

source "$(dirname "$0")/_common.sh"

usage() {
    cat <<EOF
Usage: $0 [connection options] [-s 'CRON'] [-r 'CRON'] [--remove]

  -s CRON     snapshot schedule        (default: '*/15 * * * *'  = every 15 minutes)
  -r CRON     retention purge schedule (default: '30 3 * * *'    = daily 03:30 UTC)
  --remove    unschedule the pgStatsPack2 jobs for the target databases
  --list      show the pgStatsPack2 jobs and their last runs

The pg_cron database is taken from -m (default: postgres).
EOF
    echo
    psp2_usage_conn
}

psp2_parse_args "$@"
SNAP_CRON='*/15 * * * *'; PURGE_CRON='30 3 * * *'; REMOVE=0; LIST=0
set -- "${PSP2_EXTRA[@]}"
while [ $# -gt 0 ]; do
    case "$1" in
        -s) SNAP_CRON="$2"; shift 2 ;;
        -r) PURGE_CRON="$2"; shift 2 ;;
        --remove) REMOVE=1; shift ;;
        --list) LIST=1; shift ;;
        *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
    esac
done

CRON_DB="$MAINT_DB"
has_cron=$("${PSQL[@]}" -tA -d "$CRON_DB" -c "SELECT count(*) FROM pg_extension WHERE extname = 'pg_cron';" 2>/dev/null)
if [ "$has_cron" != "1" ]; then
    echo "pg_cron is not installed in database '${CRON_DB}'."
    echo "Add pg_cron to shared_preload_libraries in the parameter group, reboot, then run"
    echo "  CREATE EXTENSION pg_cron;   in '${CRON_DB}' (or pass -m <cron.database_name>)."
    exit 1
fi

if [ "$LIST" -eq 1 ]; then
    "${PSQL[@]}" -d "$CRON_DB" -c "
        SELECT j.jobid, j.jobname, j.database, j.schedule, j.active,
               r.status AS last_status, r.start_time AS last_start, left(r.return_message, 60) AS last_message
        FROM cron.job j
        LEFT JOIN LATERAL (SELECT * FROM cron.job_run_details d WHERE d.jobid = j.jobid
                           ORDER BY d.start_time DESC LIMIT 1) r ON true
        WHERE j.jobname LIKE 'pgstatspack2%'
        ORDER BY j.jobname;"
    exit $?
fi

psp2_target_dbs
rc=0
for db in "${DBS[@]}"; do
    if [ "$REMOVE" -eq 1 ]; then
        "${PSQL[@]}" -tA -d "$CRON_DB" -v snap="pgstatspack2_snap_${db}" -v purge="pgstatspack2_purge_${db}" <<'SQL' >/dev/null \
            && echo "${db}: jobs removed" || rc=1
SELECT cron.unschedule(jobname) FROM cron.job WHERE jobname IN (:'snap', :'purge');
SQL
        continue
    fi

    state="$(psp2_state "$db")"
    case "$state" in
        none|legacy|incomplete|"") echo "${db}: pgStatsPack2 not installed (${state:-no connection}), skipped"; rc=1; continue ;;
    esac

    "${PSQL[@]}" -tA -d "$CRON_DB" \
        -v db="$db" -v snap="pgstatspack2_snap_${db}" -v purge="pgstatspack2_purge_${db}" \
        -v snap_cron="$SNAP_CRON" -v purge_cron="$PURGE_CRON" <<'SQL' >/dev/null \
        && echo "${db}: snapshot '${SNAP_CRON}', purge '${PURGE_CRON}' scheduled" || rc=1
SELECT cron.schedule_in_database(:'snap',  :'snap_cron',
                                 $$SELECT pgstatspack2.pgstatspack2_snap('pg_cron')$$, :'db');
SELECT cron.schedule_in_database(:'purge', :'purge_cron',
                                 $$SELECT pgstatspack2.pgstatspack2_delete_snap()$$, :'db');
SQL
done

if [ "$REMOVE" -eq 0 ] && [ $rc -eq 0 ]; then
    echo
    echo "Tip: cron.job_run_details grows forever; purge it periodically, e.g. in '${CRON_DB}':"
    echo "  SELECT cron.schedule('pgstatspack2_cron_history', '0 4 * * *',"
    echo "    \$\$DELETE FROM cron.job_run_details WHERE end_time < now() - interval '7 days'\$\$);"
fi
exit $rc
