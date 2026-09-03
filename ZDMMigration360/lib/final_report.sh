#!/usr/bin/env bash
set -euo pipefail
final_validation_report(){
  local jid="${CURRENT_JOB_ID:-manual}" out="$REPORT_ROOT/standby_final_${jid}.txt"
  {
    echo "ZDMMigration360 Production Validation Report"
    echo "Generated: $(ts)"
    echo "Source: ${SOURCE_DB_UNIQUE_NAME}@${SOURCE_HOST}"
    echo "Standby: ${TARGET_DB_UNIQUE_NAME}@${TARGET_HOST}"
    echo
    echo "=== PRIMARY ==="
    remote_sql "$SOURCE_HOST" "$SOURCE_OS_USER" "$SOURCE_ORACLE_HOME" "$SOURCE_SID" <<'SQL'
set pages 200 lines 260
select name,db_unique_name,database_role,open_mode,log_mode,force_logging,protection_mode,switchover_status from v$database;
select dest_id,status,db_unique_name,synchronization_status,error from v$archive_dest_status where status <> 'INACTIVE' order by dest_id;
select thread#,count(*) online_groups,max(bytes)/1024/1024 max_mb from v$log group by thread# order by 1;
select thread#,count(*) srl_groups,max(bytes)/1024/1024 max_mb from v$standby_log group by thread# order by 1;
exit
SQL
    echo "=== STANDBY ==="
    remote_sql "$TARGET_HOST" "$TARGET_OS_USER" "$TARGET_ORACLE_HOME" "$TARGET_SID" <<'SQL'
set pages 200 lines 260
select name,db_unique_name,database_role,open_mode,switchover_status from v$database;
select name,value,time_computed,datum_time from v$dataguard_stats where name in ('transport lag','apply lag','apply finish time') order by name;
select role,thread#,sequence#,action from v$dataguard_process order by role,thread#;
select * from v$archive_gap;
select thread#,count(*) online_groups,max(bytes)/1024/1024 max_mb from v$log group by thread# order by 1;
select thread#,count(*) srl_groups,max(bytes)/1024/1024 max_mb from v$standby_log group by thread# order by 1;
exit
SQL
  } | tee "$out"
  echo "Final report: $out"
}

final_validation_gate(){
  local out
  out="$(remote_sql "$TARGET_HOST" "$TARGET_OS_USER" "$TARGET_ORACLE_HOME" "$TARGET_SID" <<'SQL'
set pages 0 feedback off heading off verify off echo off
select 'ROLE='||database_role from v$database;
select 'OPEN='||open_mode from v$database;
select 'GAPS='||count(*) from v$archive_gap;
select 'MRP='||count(*) from v$dataguard_process where role like 'managed recovery%';
exit
SQL
)"
  echo "$out"
  grep -q 'ROLE=PHYSICAL STANDBY' <<<"$out" || die "Final gate: target is not PHYSICAL STANDBY."
  grep -q 'GAPS=0' <<<"$out" || die "Final gate: archive gap remains."
  local mrp; mrp="$(sed -n 's/^MRP=//p' <<<"$out" | tr -d ' ' | tail -1)"
  [[ "${mrp:-0}" -gt 0 ]] || die "Final gate: managed recovery process not detected."
  echo "FINAL PRODUCTION VALIDATION GATE PASSED"
}
