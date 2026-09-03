#!/usr/bin/env bash
set -euo pipefail

dg_health(){
  local report="${DG_HEALTH_REPORT:-$REPORT_ROOT/dg_postbuild_health_report.txt}"
  : > "$report"

  {
    echo "=== PRIMARY ==="
    remote_sql "$SOURCE_HOST" "$SOURCE_OS_USER" "$SOURCE_ORACLE_HOME" "$SOURCE_SID" <<'SQL'
set pages 200 lines 250
select name,db_unique_name,database_role,open_mode,switchover_status,protection_mode,protection_level from v$database;
select dest_id,status,target,db_unique_name,synchronization_status,error
from v$archive_dest_status where status <> 'INACTIVE' order by dest_id;
select severity,error_code,message,timestamp
from v$dataguard_status
where severity in ('Error','Fatal') and timestamp > sysdate-1 order by timestamp;
exit
SQL
    echo "=== STANDBY ==="
    remote_sql "$TARGET_HOST" "$TARGET_OS_USER" "$TARGET_ORACLE_HOME" "$TARGET_SID" <<'SQL'
set pages 200 lines 250
select name,db_unique_name,database_role,open_mode,switchover_status,protection_mode,protection_level from v$database;
select name,value,unit,time_computed,datum_time from v$dataguard_stats
where name in ('transport lag','apply lag','apply finish time') order by name;
select role,thread#,sequence#,action from v$dataguard_process order by role,thread#;
select * from v$archive_gap;
exit
SQL
  } | tee -a "$report"

  echo "Report: $report"
}

dg_sync(){
  local wait="${SYNC_WAIT_SECONDS:-900}"
  local poll="${SYNC_POLL_SECONDS:-15}"

  remote_sql "$SOURCE_HOST" "$SOURCE_OS_USER" "$SOURCE_ORACLE_HOME" "$SOURCE_SID" <<'SQL'
whenever sqlerror exit failure
alter system archive log current;
exit
SQL

  local deadline=$(( $(date +%s)+wait ))
  while :; do
    local out gaps transport apply
    out="$(
      remote_sql "$TARGET_HOST" "$TARGET_OS_USER" "$TARGET_ORACLE_HOME" "$TARGET_SID" <<'SQL'
set pages 0 feedback off heading off verify off echo off
select 'GAPS='||count(*) from v$archive_gap;
select 'TRANSPORT='||value from v$dataguard_stats where name='transport lag';
select 'APPLY='||value from v$dataguard_stats where name='apply lag';
exit
SQL
    )"
    echo "$out"
    gaps="$(printf '%s\n' "$out" | awk -F= '/^GAPS=/{print $2}' | tail -1)"
    transport="$(printf '%s\n' "$out" | sed -n 's/^TRANSPORT=//p' | tail -1)"
    apply="$(printf '%s\n' "$out" | sed -n 's/^APPLY=//p' | tail -1)"

    if [[ "${gaps:-1}" == "0" && "$transport" == "+00 00:00:"* && "$apply" == "+00 00:00:"* ]]; then
      echo "SYNC PASSED"
      return 0
    fi

    (( $(date +%s) < deadline )) || {
      echo "SYNC TIMED OUT after ${wait}s"
      return 2
    }
    sleep "$poll"
  done
}
