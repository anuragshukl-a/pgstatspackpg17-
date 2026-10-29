#!/usr/bin/env bash
# Purge old pgStatsPack2 snapshots in every target database.
# Default retention comes from pgstatspack2.pgstatspack2_config ('retention', 30 days).

source "$(dirname "$0")/_common.sh"

usage() {
    echo "Usage: $0 [connection options] [-k '14 days']"
    echo
    echo "  -k INTERVAL   keep snapshots newer than this (overrides the configured retention)"
    echo
    psp2_usage_conn
}

psp2_parse_args "$@"
KEEP=""
set -- "${PSP2_EXTRA[@]}"
while [ $# -gt 0 ]; do
    case "$1" in
        -k) KEEP="$2"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
    esac
done

psp2_target_dbs
rc=0
for db in "${DBS[@]}"; do
    state="$(psp2_state "$db")"
    case "$state" in
        none|legacy|incomplete|"") continue ;;
    esac
    if [ -n "$KEEP" ]; then
        out=$(echo "SELECT pgstatspack2.pgstatspack2_delete_snap(:'k'::interval);" \
              | "${PSQL[@]}" -tA -d "$db" -v k="$KEEP" 2>&1)
    else
        out=$("${PSQL[@]}" -tA -d "$db" -c "SELECT pgstatspack2.pgstatspack2_delete_snap();" 2>&1)
    fi
    [ $? -eq 0 ] || rc=1
    echo "$(date '+%F %T') ${db}: ${out}"
done
exit $rc
