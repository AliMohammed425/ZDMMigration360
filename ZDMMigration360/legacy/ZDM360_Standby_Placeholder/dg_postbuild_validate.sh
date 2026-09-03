#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
source "$ROOT/dg_ops_lib.sh"
for n in SOURCE_HOST SOURCE_OS_USER SOURCE_ORACLE_HOME SOURCE_SID TARGET_HOST TARGET_OS_USER TARGET_ORACLE_HOME TARGET_SID TARGET_DB_UNIQUE_NAME; do require_var "$n"; done
REPORT="${DG_HEALTH_REPORT:-./dg_postbuild_health_report.txt}"
: > "$REPORT"

echo "=== PRIMARY ===" >> "$REPORT"
remote_sql "$SOURCE_HOST" "$SOURCE_OS_USER" "$SOURCE_ORACLE_HOME" "$SOURCE_SID" <<'SQL' >> "$REPORT"
set pages 200 lines 250
select name,db_unique_name,database_role,open_mode,switchover_status,protection_mode,protection_level from v$database;
select dest_id,status,target,db_unique_name,synchronization_status,error from v$archive_dest_status where status <> 'INACTIVE' order by dest_id;
select severity,error_code,message,timestamp from v$dataguard_status
 where severity in ('Error','Fatal') and timestamp > sysdate-1 order by timestamp;
exit
SQL

echo "=== STANDBY ===" >> "$REPORT"
remote_sql "$TARGET_HOST" "$TARGET_OS_USER" "$TARGET_ORACLE_HOME" "$TARGET_SID" <<'SQL' >> "$REPORT"
set pages 200 lines 250
select name,db_unique_name,database_role,open_mode,switchover_status,protection_mode,protection_level from v$database;
select name,value,unit,time_computed,datum_time from v$dataguard_stats
 where name in ('transport lag','apply lag','apply finish time') order by name;
select role,thread#,sequence#,action from v$dataguard_process order by role,thread#;
select * from v$archive_gap;
select file#,status,error from v$datafile_header where status='OFFLINE' or error is not null;
select severity,error_code,message,timestamp from v$dataguard_status
 where severity in ('Error','Fatal') and timestamp > sysdate-1 order by timestamp;
exit
SQL

BROKER="$(broker_enabled "$SOURCE_HOST" "$SOURCE_OS_USER" "$SOURCE_ORACLE_HOME" "$SOURCE_SID" || true)"
echo "DG_BROKER_START=$BROKER" >> "$REPORT"
if [[ "$BROKER" == "TRUE" ]]; then
  ssh "$SOURCE_OS_USER@$SOURCE_HOST" "
    export ORACLE_HOME='$SOURCE_ORACLE_HOME'; export PATH=\$ORACLE_HOME/bin:\$PATH
    dgmgrl / <<DGMGRL
show configuration verbose;
show database verbose '$TARGET_DB_UNIQUE_NAME';
validate database verbose '$TARGET_DB_UNIQUE_NAME';
validate network configuration for all;
exit
DGMGRL
  " >> "$REPORT" 2>&1 || true
fi
echo "Data Guard health report: $REPORT"
