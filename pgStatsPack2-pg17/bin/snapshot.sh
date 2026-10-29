#!/usr/bin/env bash
# Take a pgStatsPack2 snapshot in every target database that has it installed.
# Suitable for cron on an EC2 / bastion host, e.g.:
#   */15 * * * * PGHOST=writer-endpoint PGUSER=pgsp2 /opt/pgStatsPack2/bin/snapshot.sh >> /var/log/pgsp2.log 2>&1
# (inside RDS/Aurora, prefer bin/schedule_pg_cron.sh instead)

source "$(dirname "$0")/_common.sh"

usage() {
    echo "Usage: $0 [connection options] [-c 'description']"
    echo
    psp2_usage_conn
}

psp2_parse_args "$@"
DESC="scheduled snapshot"
set -- "${PSP2_EXTRA[@]}"
while [ $# -gt 0 ]; do
    case "$1" in
        -c) DESC="$2"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
    esac
done

psp2_target_dbs
rc=0
for db in "${DBS[@]}"; do
    state="$(psp2_state "$db")"
    case "$state" in
        none|legacy|incomplete|"") echo "$(date '+%F %T') ${db}: pgStatsPack2 not installed (${state:-no connection}), skipped"; continue ;;
    esac
    # (psql only interpolates :'var' in scripts read from stdin/-f, not in -c)
    if id=$(echo "SELECT pgstatspack2.pgstatspack2_snap(:'d');" \
            | "${PSQL[@]}" -tA -d "$db" -v d="$DESC" 2>&1); then
        echo "$(date '+%F %T') ${db}: snapshot ${id}"
    else
        echo "$(date '+%F %T') ${db}: FAILED: ${id}"; rc=1
    fi
done
exit $rc
