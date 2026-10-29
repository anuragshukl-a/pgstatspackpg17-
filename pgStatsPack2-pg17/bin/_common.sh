#!/usr/bin/env bash
# Shared helpers for pgStatsPack2 scripts.
# Connection settings follow normal libpq rules: command-line flags below, or the
# PGHOST / PGPORT / PGUSER / PGPASSWORD / PGSSLMODE / PGSSLROOTCERT environment
# variables, or ~/.pgpass. For RDS/Aurora IAM auth, put a token in PGPASSWORD.

set -o pipefail

PSP2_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PSP2_SQL="${PSP2_HOME}/sql"
PSQL=(psql -X -q -v ON_ERROR_STOP=1)
export PGOPTIONS="${PGOPTIONS:+$PGOPTIONS }-c client_min_messages=warning"
MAINT_DB="${PGSTATSPACK2_MAINT_DB:-postgres}"
DBS=()

psp2_usage_conn() {
    cat <<EOF
Connection options (all optional; libpq environment variables also work):
  -h HOST       server host / RDS or Aurora *writer* endpoint     (PGHOST)
  -p PORT       port                                               (PGPORT)
  -U USER       user (RDS master user or a role with pg_monitor)   (PGUSER)
  -d DBNAME     target database; repeat for several. Default: every connectable
                database except templates, postgres and rdsadmin
  -m DBNAME     maintenance database used to list databases (default: postgres)
  --help        show this help
EOF
}

# Parses the connection options; leaves unknown long options in PSP2_EXTRA.
psp2_parse_args() {
    PSP2_EXTRA=()
    while [ $# -gt 0 ]; do
        case "$1" in
            -h) export PGHOST="$2"; shift 2 ;;
            -p) export PGPORT="$2"; shift 2 ;;
            -U) export PGUSER="$2"; shift 2 ;;
            -d) DBS+=("$2"); shift 2 ;;
            -m) MAINT_DB="$2"; shift 2 ;;
            --help) usage; exit 0 ;;
            *) PSP2_EXTRA+=("$1"); shift ;;
        esac
    done
}

psp2_target_dbs() {
    if [ ${#DBS[@]} -eq 0 ]; then
        mapfile -t DBS < <("${PSQL[@]}" -tA -d "$MAINT_DB" -f "${PSP2_SQL}/get_db_names.sql") || {
            echo "ERROR: could not list databases via '$MAINT_DB' (use -m or -d)" >&2; exit 1; }
    fi
    if [ ${#DBS[@]} -eq 0 ]; then
        echo "No target databases found (use -d DBNAME)." >&2; exit 1
    fi
}

psp2_state() {   # prints none | legacy | incomplete | <version>
    "${PSQL[@]}" -tA -d "$1" -f "${PSP2_SQL}/pgstatspack2_exists.sql" 2>/dev/null | tail -n 1
}
