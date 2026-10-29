#!/usr/bin/env bash
# Install / upgrade pgStatsPack2 (PostgreSQL 17/18 edition) into one or more databases.
#
#   ./install_pgStatsPack2.sh -h mycluster.cluster-xxxx.ap-south-1.rds.amazonaws.com \
#        -U postgres -d appdb --with-pgss --grant monitoring_role
#
# Re-running is safe: tables are kept, functions and views are replaced.

source "$(dirname "$0")/bin/_common.sh"

usage() {
    cat <<EOF
Usage: $0 [connection options] [--with-pgss] [--grant ROLE] [--drop-old]

Installs schema "pgstatspack2" (tables, views, functions) into each target database.

  --with-pgss    also run CREATE EXTENSION IF NOT EXISTS pg_stat_statements
                 (needs rds_superuser on RDS/Aurora; the library must be in
                 shared_preload_libraries of the DB parameter group)
  --grant ROLE   let ROLE take snapshots and read the data (also grants pg_monitor)
  --drop-old     drop an existing legacy (0.1.x) pgstatspack2 schema and ITS DATA first

EOF
    psp2_usage_conn
}

psp2_parse_args "$@"
WITH_PGSS=0; GRANT_ROLE=""; DROP_OLD=0
set -- "${PSP2_EXTRA[@]}"
while [ $# -gt 0 ]; do
    case "$1" in
        --with-pgss) WITH_PGSS=1; shift ;;
        --grant)     GRANT_ROLE="$2"; shift 2 ;;
        --drop-old)  DROP_OLD=1; shift ;;
        *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
    esac
done

psp2_target_dbs
rc=0

for db in "${DBS[@]}"; do
    echo "=== ${db}"
    state="$(psp2_state "$db")"
    if [ -z "$state" ]; then
        echo "  cannot connect to ${db}, skipping"; rc=1; continue
    fi

    if [ "$state" = "legacy" ]; then
        if [ "$DROP_OLD" -eq 1 ]; then
            echo "  dropping legacy pgstatspack2 schema"
            "${PSQL[@]}" -d "$db" -f "${PSP2_SQL}/pgstatspack2_uninstall.sql" || { rc=1; continue; }
        else
            echo "  legacy (0.1.x) schema found - rerun with --drop-old to replace it (its data is lost)"
            rc=1; continue
        fi
    fi

    if [ "$WITH_PGSS" -eq 1 ]; then
        "${PSQL[@]}" -d "$db" -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements;" \
            || echo "  WARNING: could not create pg_stat_statements (continuing without it)"
    fi

    if "${PSQL[@]}" -d "$db" \
            -f "${PSP2_SQL}/pgstatspack2_create_schema.sql" \
            -f "${PSP2_SQL}/pgstatspack2_snap.sql" \
            -f "${PSP2_SQL}/pgstatspack2_maintenance.sql"; then
        echo "  installed ($(psp2_state "$db"))"
    else
        echo "  FAILED"; rc=1; continue
    fi

    if [ -n "$GRANT_ROLE" ]; then
        "${PSQL[@]}" -d "$db" -v role="$GRANT_ROLE" <<'SQL' && echo "  granted to ${GRANT_ROLE}" || rc=1
GRANT pg_monitor TO :"role";
GRANT USAGE ON SCHEMA pgstatspack2 TO :"role";
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA pgstatspack2 TO :"role";
GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA pgstatspack2 TO :"role";
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA pgstatspack2 TO :"role";
SQL
    fi
done

if [ $rc -eq 0 ]; then
    cat <<EOF

Done. Next steps:
  * take snapshots:   bin/snapshot.sh   (cron on a host)  or  bin/schedule_pg_cron.sh  (inside RDS/Aurora)
  * report:           bin/pgstatspack2_report.sh -d <db>
EOF
fi
exit $rc
