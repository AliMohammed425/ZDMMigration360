#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
source "$ROOT/dg_ops_lib.sh"
for n in TARGET_HOST TARGET_OS_USER TARGET_ORACLE_HOME TARGET_SID; do require_var "$n"; done
ACTION="${1:-status}"
case "$ACTION" in
 status)
  remote_sql "$TARGET_HOST" "$TARGET_OS_USER" "$TARGET_ORACLE_HOME" "$TARGET_SID" <<'SQL'
set pages 100 lines 220
select name,db_unique_name,database_role,open_mode,flashback_on,switchover_status from v$database;
select name,value,time_computed,datum_time from v$dataguard_stats order by name;
exit
SQL
  ;;
 to-snapshot)
  confirm_live "CONVERT SNAPSHOT" || exit 0
  remote_sql "$TARGET_HOST" "$TARGET_OS_USER" "$TARGET_ORACLE_HOME" "$TARGET_SID" <<'SQL'
whenever sqlerror exit failure
alter database recover managed standby database cancel;
shutdown immediate;
startup mount;
alter database convert to snapshot standby;
alter database open read write;
select name,db_unique_name,database_role,open_mode from v$database;
exit
SQL
  ;;
 to-physical)
  confirm_live "CONVERT PHYSICAL" || exit 0
  remote_sql "$TARGET_HOST" "$TARGET_OS_USER" "$TARGET_ORACLE_HOME" "$TARGET_SID" <<'SQL'
whenever sqlerror exit failure
shutdown immediate;
startup mount;
alter database convert to physical standby;
shutdown immediate;
startup mount;
alter database recover managed standby database disconnect from session;
select name,db_unique_name,database_role,open_mode from v$database;
exit
SQL
  ;;
 *) echo "Usage: $0 {status|to-snapshot|to-physical}"; exit 2;;
esac
