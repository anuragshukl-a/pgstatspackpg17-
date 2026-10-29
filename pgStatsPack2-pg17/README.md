# pgStatsPack2 — PostgreSQL 17 / 18 edition (Amazon RDS & Aurora ready)

Statspack-style snapshot and comparison tool for PostgreSQL: take periodic snapshots of the
cumulative statistics views, then report what happened **between any two snapshots**
(top SQL, table/index activity, I/O, WAL, checkpoints, vacuum, parameter changes).

This is a rewrite of [dtseiler/pgStatsPack2](https://github.com/dtseiler/pgStatsPack2)
(itself derived from the original *pgstatspack* by Frits Hoogland, Uwe Bartels et al.)
for PostgreSQL 17 and 18, running on Amazon RDS for PostgreSQL and Aurora PostgreSQL
without superuser or OS access.

## What changed from the original

| Area | Original (pre-PG12) | This edition |
|---|---|---|
| `pg_stat_statements` | `total_time` (removed in PG13); broken join (`n.name`, `s.pg_get_userbyid`) | `total_exec_time` + `total_plan_time`, keyed by `queryid`/`userid`/`toplevel`; PG17 `shared_blk_read_time`, `stats_since`; query text de-duplicated; extension found in any schema |
| Checkpoints | `pg_stat_bgwriter.checkpoints_*`, `buffers_checkpoint`, `buffers_backend` (moved/removed in PG17) | `pg_stat_checkpointer` on PG17+ (plus `num_done`, `slru_written` on PG18); backend writes derived from `pg_stat_io` |
| New views | — | `pg_stat_io` (handles PG18's `read_bytes`/`write_bytes`/`extend_bytes` replacing `op_bytes`), `pg_stat_wal` |
| Database stats | 5 counters | + tuples, temp files/bytes, deadlocks, I/O time, session/active/idle-in-xact time (PG14+) |
| Table stats | basic counters | + HOT/new-page updates, live/dead tuples, vacuum/analyze counts and timestamps, `last_seq_scan`/`last_idx_scan` |
| Functions | `total_time` stored as `bigint` (truncated); ordered ascending | `double precision`; overloads distinguished by signature |
| Unused indexes | referenced columns that don't exist | rewritten; skips PK/unique/constraint indexes, flags FK-supporting ones |
| Locking | could queue behind DDL when sizing relations | relations under ACCESS EXCLUSIVE are skipped, `lock_timeout = 3s`, sizes never fail the snapshot |
| Retention | delete by hand in 8 tables | `ON DELETE CASCADE`, configurable retention |
| Install | `CREATE LANGUAGE plpgsql`, required superuser | runs as RDS master user or any role with `pg_monitor`; skips `rdsadmin` |
| Scheduling | OS cron only | `pg_cron` inside RDS/Aurora (`schedule_pg_cron.sh`) or OS cron on a host |
| Report | interactive bash with SQL inlined, values interpolated into SQL | `sql/pgstatspack2_report.sql` runs from plain `psql` with variables; bash wrapper is optional |

The snapshot function detects the server's catalog layout at run time, so an in-place
major-version upgrade (17 → 18) needs no reinstall. PostgreSQL 16 also works.

## Requirements

* PostgreSQL 16, 17 or 18 (RDS for PostgreSQL, Aurora PostgreSQL, or self-managed)
* `psql` client (12+) and `bash` on the machine you install from (EC2 bastion, CloudShell, laptop)
* Recommended: `pg_stat_statements` (top-SQL sections), `track_io_timing = on`
* Optional: `pg_cron` (to schedule snapshots inside RDS/Aurora), `track_functions = pl`

## Setup on Amazon RDS / Aurora PostgreSQL

### 1. Parameter group

In the DB parameter group (RDS) or **DB cluster parameter group** (Aurora):

| Parameter | Value | Why |
|---|---|---|
| `shared_preload_libraries` | include `pg_stat_statements` (and `pg_cron` if scheduling inside the DB) | top SQL; scheduling |
| `track_io_timing` | `1` | I/O time columns |
| `pg_stat_statements.track` | `top` (default) or `all` | |
| `track_functions` | `pl` | optional, function section |
| `cron.database_name` | `postgres` (default) | where pg_cron lives |

`shared_preload_libraries` is static: reboot the instance / writer after changing it.

### 2. Install

Connect to the **writer** endpoint (snapshots insert rows, so they cannot run on a reader).

```bash
export PGHOST=mycluster.cluster-xxxxxxxx.ap-south-1.rds.amazonaws.com
export PGUSER=postgres            # master user (rds_superuser)
export PGSSLMODE=require          # or verify-full + PGSSLROOTCERT=global-bundle.pem
# password via ~/.pgpass, PGPASSWORD, or an IAM auth token in PGPASSWORD

./install_pgStatsPack2.sh -d appdb --with-pgss
#   no -d  → every connectable database except templates, postgres, rdsadmin
#   --grant pgsp2_role → let a non-master role (gets pg_monitor) run snapshots/reports
#   --drop-old → replace a legacy 0.1.x pgstatspack2 schema (e.g. after in-place upgrade)
```

Installing is idempotent; re-run it after pulling a newer version.

### 3. Schedule snapshots

**Inside the database with pg_cron (no extra server needed):**

```bash
psql -d postgres -c "CREATE EXTENSION IF NOT EXISTS pg_cron;"
bin/schedule_pg_cron.sh -d appdb                       # every 15 min + daily purge
bin/schedule_pg_cron.sh -d appdb -s '*/5 * * * *'      # custom interval
bin/schedule_pg_cron.sh --list                         # jobs and last run status
bin/schedule_pg_cron.sh -d appdb --remove
```

(`sql/pg_cron_example.sql` has the same as plain SQL.) pg_cron times are UTC.

**Or OS cron on an EC2/bastion host:**

```cron
*/15 * * * * PGHOST=... PGUSER=pgsp2 /opt/pgStatsPack2/bin/snapshot.sh -d appdb >> /var/log/pgsp2.log 2>&1
30 3 * * *   PGHOST=... PGUSER=pgsp2 /opt/pgStatsPack2/bin/delete_snapshot.sh -d appdb >> /var/log/pgsp2.log 2>&1
```

Manual snapshot from any client: `SELECT pgstatspack2.pgstatspack2_snap('before deploy');`

### 4. Report

```bash
bin/pgstatspack2_report.sh -d appdb                    # lists snapshots, asks for ids
bin/pgstatspack2_report.sh -d appdb -b 120 -e 168      # explicit range
bin/pgstatspack2_report.sh -d appdb --last 4           # last hour at 15-min snapshots
```

Or with psql only:

```bash
psql -d appdb -c "SELECT * FROM pgstatspack2.pgstatspack2_list_snaps();"
psql -d appdb -v begin_snap=120 -v end_snap=168 -f sql/pgstatspack2_report.sql -o report.txt
```

Report sections: snapshot info and restart/failover warning · database load (TPS, hit %,
temp, deadlocks, sessions, active time) · WAL · checkpointer/bgwriter and who writes
buffers · `pg_stat_io` by backend type · top SQL by time, calls, physical reads, temp
spill and WAL · tables by rows read, large sequential scans, DML, size growth, vacuum
health · most-used and unused indexes · sequences · functions · parameters changed
between the snapshots and all non-default parameters.

Full SQL text for a `queryid` shown in the report:
`SELECT query FROM pgstatspack2.pgstatspack2_query_text WHERE queryid = ...;`

Unused indexes over a longer window:
`SELECT * FROM pgstatspack2.pgstatspack2_get_unused_indexes('14 days');`

## Configuration

```sql
SELECT * FROM pgstatspack2.pgstatspack2_config;
UPDATE pgstatspack2.pgstatspack2_config SET value = '14 days' WHERE name = 'retention';
```

| name | default | meaning |
|---|---|---|
| `retention` | `30 days` | age at which `pgstatspack2_delete_snap()` removes snapshots |
| `statements_limit` | `1000` | top-N `pg_stat_statements` entries (by exec+plan time) stored per snapshot |
| `collect_sizes` | `on` | table/index sizes; turn `off` for databases with tens of thousands of relations |
| `statements_view` | empty | override location of `pg_stat_statements` (normally auto-detected) |

Storage rough guide: one snapshot ≈ (tables + indexes) rows + up to `statements_limit`
rows. 2,000 relations at 15-minute snapshots for 30 days ≈ 6 M small rows.

## Notes for Aurora / RDS

* **Run snapshots on the writer.** Statistics on Aurora readers are per-instance and the
  readers are read-only; this tool profiles the writer's workload.
* **Failover / reboot:** cumulative statistics survive a clean shutdown but are reset on
  crash recovery and Aurora failover. The report warns when the server restarted between
  the two snapshots; pick a range that does not span the event.
* **Aurora storage:** Aurora does not use classic checkpoints or local WAL files, so the
  checkpointer, bgwriter and WAL sections are indicative only there. Database, table,
  index, SQL and `pg_stat_io` sections are fully meaningful.
* `pg_stat_reset()` / `pg_stat_statements_reset()` between snapshots invalidate that range.
* Complements, rather than replaces, Performance Insights / CloudWatch Database Insights
  (wait-event sampling); pgStatsPack2 adds exact counters, history you own, and
  object-level detail.

## Files

```
install_pgStatsPack2.sh             install / upgrade into one or more databases
bin/snapshot.sh                     take a snapshot in each installed database (OS cron)
bin/delete_snapshot.sh              purge snapshots older than the retention
bin/pgstatspack2_report.sh          report wrapper (interactive or flags)
bin/schedule_pg_cron.sh             create/list/remove pg_cron jobs in RDS/Aurora
bin/_common.sh                      shared connection handling
sql/pgstatspack2_create_schema.sql  schema, tables, views, config
sql/pgstatspack2_snap.sql           pgstatspack2_snap()
sql/pgstatspack2_maintenance.sql    delete_snap(), get_unused_indexes(), list_snaps()
sql/pgstatspack2_report.sql         the report (plain psql)
sql/pg_cron_example.sql             pg_cron scheduling as plain SQL
sql/pgstatspack2_uninstall.sql      DROP SCHEMA pgstatspack2 CASCADE
sql/get_db_names.sql, sql/pgstatspack2_exists.sql   helpers used by the scripts
test/run_tests.sh                   regression test (native + PG17 + PG18 catalog shapes)
```

## Uninstall

```bash
bin/schedule_pg_cron.sh -d appdb --remove     # if scheduled with pg_cron
psql -d appdb -f sql/pgstatspack2_uninstall.sql
```

## Testing

`PGHOST=... PGUSER=<superuser> test/run_tests.sh` installs into a scratch database, runs a
small workload, snapshots and reports, then repeats with the PG17 and PG18 layouts of
`pg_stat_checkpointer`, `pg_stat_bgwriter`, `pg_stat_io` and `pg_stat_statements` mocked
in, and finally checks purge and the unused-index function. Run it against a non-production
instance of your target version before rolling out.

## License

MIT, as the original project. Original authors: Don Seiler, Frits Hoogland, Keith Pierno,
Uwe Bartels, Glenn Fawcett.
