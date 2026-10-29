#!/usr/bin/env bash
# Generate a pgStatsPack2 report between two snapshots.
#
#   bin/pgstatspack2_report.sh -h <writer-endpoint> -U postgres -d appdb            # interactive
#   bin/pgstatspack2_report.sh -d appdb -b 101 -e 125 -f /tmp/report.txt           # non-interactive
#   bin/pgstatspack2_report.sh -d appdb --last 4                                    # last 4 snapshots

source "$(dirname "$0")/_common.sh"

usage() {
    cat <<EOF
Usage: $0 [connection options] [-b BEGIN -e END | --last N] [-f FILE] [-t TOP] [-q QLEN]

  -b ID       begin snapshot id
  -e ID       end snapshot id
  --last N    use the latest snapshot as end and the one N snapshots earlier as begin
  -f FILE     output file (default: ./pgstatreport_<db>_<begin>_<end>.txt)
  -t N        rows per "top" section (default 20)
  -q N        characters of SQL text to show (default 120)

EOF
    psp2_usage_conn
}

psp2_parse_args "$@"
BEGIN_SNAP=""; END_SNAP=""; LAST=""; FILE=""; TOP=20; QLEN=120
set -- "${PSP2_EXTRA[@]}"
while [ $# -gt 0 ]; do
    case "$1" in
        -b) BEGIN_SNAP="$2"; shift 2 ;;
        -e) END_SNAP="$2"; shift 2 ;;
        --last) LAST="$2"; shift 2 ;;
        -f) FILE="$2"; shift 2 ;;
        -t) TOP="$2"; shift 2 ;;
        -q) QLEN="$2"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
    esac
done

is_int() { [[ "$1" =~ ^[0-9]+$ ]]; }

# Pick the database (first -d, or interactive choice)
if [ ${#DBS[@]} -eq 0 ]; then
    psp2_target_dbs
    if [ ${#DBS[@]} -gt 1 ]; then
        echo "Databases:"
        for i in "${!DBS[@]}"; do printf "  %d. %s\n" $((i + 1)) "${DBS[$i]}"; done
        read -r -p "Select [1-${#DBS[@]}]: " sel
        is_int "$sel" && [ "$sel" -ge 1 ] && [ "$sel" -le ${#DBS[@]} ] || { echo "Invalid selection"; exit 1; }
        DBS=("${DBS[$((sel - 1))]}")
    fi
fi
DB="${DBS[0]}"

state="$(psp2_state "$DB")"
case "$state" in
    none|legacy|incomplete|"")
        echo "pgStatsPack2 is not (correctly) installed in ${DB} (${state:-cannot connect}). Run install_pgStatsPack2.sh -d ${DB}"
        exit 1 ;;
esac

if [ -n "$LAST" ]; then
    is_int "$LAST" || { echo "--last needs a number"; exit 1; }
    read -r BEGIN_SNAP END_SNAP < <("${PSQL[@]}" -tA -F ' ' -d "$DB" -c "
        SELECT (SELECT snapid FROM pgstatspack2.pgstatspack2_snap ORDER BY snapid DESC OFFSET ${LAST} LIMIT 1),
               (SELECT max(snapid) FROM pgstatspack2.pgstatspack2_snap);")
fi

if [ -z "$BEGIN_SNAP" ] || [ -z "$END_SNAP" ]; then
    "${PSQL[@]}" -d "$DB" -c "SELECT * FROM pgstatspack2.pgstatspack2_list_snaps(40);"
    [ -z "$BEGIN_SNAP" ] && read -r -p "Enter begin snapshot id: " BEGIN_SNAP
    [ -z "$END_SNAP" ]   && read -r -p "Enter end snapshot id  : " END_SNAP
fi

for v in "$BEGIN_SNAP" "$END_SNAP" "$TOP" "$QLEN"; do
    is_int "$v" || { echo "Snapshot ids, -t and -q must be integers (got '$v')"; exit 1; }
done

[ -z "$FILE" ] && FILE="./pgstatreport_${DB}_${BEGIN_SNAP}_${END_SNAP}.txt"

"${PSQL[@]}" -d "$DB" -v begin_snap="$BEGIN_SNAP" -v end_snap="$END_SNAP" \
    -v top="$TOP" -v qlen="$QLEN" -P pager=off \
    -f "${PSP2_SQL}/pgstatspack2_report.sql" 2>&1 | tee "$FILE"
rc=${PIPESTATUS[0]}
echo
echo "Report saved to ${FILE}"
exit $rc
