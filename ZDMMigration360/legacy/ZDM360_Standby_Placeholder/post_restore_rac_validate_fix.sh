#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
source "$ROOT/dg_ops_lib.sh"

for n in TARGET_HOST TARGET_OS_USER TARGET_ORACLE_HOME TARGET_SID TARGET_DB_UNIQUE_NAME TARGET_RAC_INSTANCES; do
  require_var "$n"
done

TARGET_GRID_HOME="${TARGET_GRID_HOME:-}"
TARGET_UNDO_PREFIX="${TARGET_UNDO_PREFIX:-UNDOTBS}"
TARGET_REDO_SIZE_MB="${TARGET_REDO_SIZE_MB:-0}"
EXECUTE="${EXECUTE:-false}"
REPORT="${RAC_REPORT:-./post_restore_rac_validation_report.txt}"
SQLFILE="${RAC_FIX_SQL:-./post_restore_rac_fix_generated.sql}"

: > "$REPORT"
echo "Post-Restore RAC Standby Validation" | tee -a "$REPORT"
echo "===================================" | tee -a "$REPORT"

STATE="$(
remote_sql "$TARGET_HOST" "$TARGET_OS_USER" "$TARGET_ORACLE_HOME" "$TARGET_SID" <<'SQL'
set pages 0 feedback off heading off lines 300
select 'ROLE='||database_role from v$database;
select 'OPEN='||open_mode from v$database;
select 'CLUSTER='||value from v$parameter where name='cluster_database';
select 'OMF='||nvl(value,'') from v$parameter where name='db_create_file_dest';
select 'REDOMB='||ceil(max(bytes)/1024/1024) from v$log;
select 'MAXGROUP='||greatest(nvl((select max(group#) from v$log),0),nvl((select max(group#) from v$standby_log),0)) from dual;
exit
SQL
)"
echo "$STATE" >> "$REPORT"

ROLE="$(printf '%s\n' "$STATE" | awk -F= '/^ROLE=/{print $2}' | tail -1)"
OMF="$(printf '%s\n' "$STATE" | awk -F= '/^OMF=/{sub(/^OMF=/,"");print}' | tail -1)"
REDOMB="$(printf '%s\n' "$STATE" | awk -F= '/^REDOMB=/{print $2}' | tail -1)"
MAXGROUP="$(printf '%s\n' "$STATE" | awk -F= '/^MAXGROUP=/{print $2}' | tail -1)"
[[ "$ROLE" == "PHYSICAL STANDBY" ]] || die "Target is not PHYSICAL STANDBY (role=$ROLE)."
[[ -n "$OMF" ]] || die "DB_CREATE_FILE_DEST is empty. Auto-fix refuses to guess RAC undo/redo file placement."
[[ "$TARGET_REDO_SIZE_MB" != "0" ]] && REDOMB="$TARGET_REDO_SIZE_MB"
REDOMB="${REDOMB:-1024}"
MAXGROUP="${MAXGROUP:-0}"

cat > "$SQLFILE" <<SQL
whenever sqlerror exit failure
set echo on serveroutput on
alter database recover managed standby database cancel;
alter system set standby_file_management='MANUAL' scope=both;
SQL

for ((thr=1; thr<=TARGET_RAC_INSTANCES; thr++)); do
  undo="${TARGET_UNDO_PREFIX}${thr}"
  undo_count="$(
    remote_sql "$TARGET_HOST" "$TARGET_OS_USER" "$TARGET_ORACLE_HOME" "$TARGET_SID" <<SQL | awk 'NF{print $1}' | tail -1
set pages 0 feedback off heading off
select count(*) from dba_tablespaces where contents='UNDO' and upper(tablespace_name)=upper('$undo');
exit
SQL
  )"
  if [[ "${undo_count:-0}" -eq 0 ]]; then
    echo "CREATE UNDO TABLESPACE $undo DATAFILE SIZE 2G AUTOEXTEND ON NEXT 512M MAXSIZE UNLIMITED;" >> "$SQLFILE"
    echo "MISSING UNDO: $undo -> CREATE planned" | tee -a "$REPORT"
  else
    echo "UNDO OK: $undo" | tee -a "$REPORT"
  fi

  online="$(
    remote_sql "$TARGET_HOST" "$TARGET_OS_USER" "$TARGET_ORACLE_HOME" "$TARGET_SID" <<SQL | awk 'NF{print $1}' | tail -1
set pages 0 feedback off heading off
select count(*) from v\$log where thread#=$thr;
exit
SQL
  )"
  online="${online:-0}"
  if (( online < 2 )); then
    need=$((2-online))
    for ((x=1;x<=need;x++)); do
      MAXGROUP=$((MAXGROUP+1))
      echo "ALTER DATABASE ADD LOGFILE THREAD $thr GROUP $MAXGROUP SIZE ${REDOMB}M;" >> "$SQLFILE"
    done
    echo "THREAD $thr: online redo groups=$online; add $need group(s)" | tee -a "$REPORT"
  else
    echo "THREAD $thr: online redo groups=$online" | tee -a "$REPORT"
  fi

  thread_enabled="$(
    remote_sql "$TARGET_HOST" "$TARGET_OS_USER" "$TARGET_ORACLE_HOME" "$TARGET_SID" <<SQL | awk 'NF{print toupper($1)}' | tail -1
set pages 0 feedback off heading off
select nvl(max(enabled),'NO') from v\$thread where thread#=$thr;
exit
SQL
  )"
  if [[ "$thread_enabled" != "PUBLIC" && "$thread_enabled" != "PRIVATE" ]]; then
    echo "ALTER DATABASE ENABLE THREAD $thr;" >> "$SQLFILE"
    echo "THREAD $thr: enable planned" | tee -a "$REPORT"
  fi

  # Need one more SRL group than online redo groups for each thread.
  # Use planned online count at least 2.
  planned_online=$online
  (( planned_online < 2 )) && planned_online=2
  srl="$(
    remote_sql "$TARGET_HOST" "$TARGET_OS_USER" "$TARGET_ORACLE_HOME" "$TARGET_SID" <<SQL | awk 'NF{print $1}' | tail -1
set pages 0 feedback off heading off
select count(*) from v\$standby_log where thread#=$thr;
exit
SQL
  )"
  srl="${srl:-0}"
  need_srl=$((planned_online+1-srl))
  if (( need_srl > 0 )); then
    for ((x=1;x<=need_srl;x++)); do
      MAXGROUP=$((MAXGROUP+1))
      echo "ALTER DATABASE ADD STANDBY LOGFILE THREAD $thr GROUP $MAXGROUP SIZE ${REDOMB}M;" >> "$SQLFILE"
    done
    echo "THREAD $thr: SRLs=$srl; add $need_srl group(s)" | tee -a "$REPORT"
  else
    echo "THREAD $thr: SRLs=$srl OK" | tee -a "$REPORT"
  fi
done

cat >> "$SQLFILE" <<SQL
alter system set standby_file_management='AUTO' scope=both;
alter system set cluster_database=true scope=spfile;
shutdown immediate;
exit
SQL
chmod 600 "$SQLFILE"
echo "Generated fix SQL: $SQLFILE" | tee -a "$REPORT"

if [[ "$EXECUTE" == "true" ]]; then
  scp -q "$SQLFILE" "$TARGET_OS_USER@$TARGET_HOST:/tmp/zdm360_rac_fix.sql"
  ssh "$TARGET_OS_USER@$TARGET_HOST" "
    export ORACLE_HOME='$TARGET_ORACLE_HOME'
    export ORACLE_SID='$TARGET_SID'
    export PATH=\$ORACLE_HOME/bin:\$PATH
    sqlplus -s '/ as sysdba' @/tmp/zdm360_rac_fix.sql
    rc=\$?
    rm -f /tmp/zdm360_rac_fix.sql
    exit \$rc
  "

  [[ -n "$TARGET_GRID_HOME" ]] || die "GRID_HOME is required to start the RAC standby with srvctl."
  ssh "$TARGET_OS_USER@$TARGET_HOST" "
    export PATH='$TARGET_GRID_HOME/bin':\$PATH
    srvctl config database -db '$TARGET_DB_UNIQUE_NAME' >/dev/null 2>&1 ||
      { echo 'ERROR: database is not registered with Clusterware; register DB/instances before RAC start.'; exit 4; }
    srvctl start database -db '$TARGET_DB_UNIQUE_NAME' -startoption MOUNT
  "

  remote_sql "$TARGET_HOST" "$TARGET_OS_USER" "$TARGET_ORACLE_HOME" "$TARGET_SID" <<'SQL' >> "$REPORT"
set pages 200 lines 250
select inst_id,instance_name,status,thread# from gv$instance order by inst_id;
select thread#,status,enabled,instance from v$thread order by thread#;
select tablespace_name,status from dba_tablespaces where contents='UNDO' order by 1;
select thread#,count(*) online_groups,max(bytes)/1024/1024 max_mb from v$log group by thread# order by 1;
select thread#,count(*) srl_groups,max(bytes)/1024/1024 max_mb from v$standby_log group by thread# order by 1;
alter database recover managed standby database disconnect from session;
select role,thread#,sequence#,action from v$dataguard_process order by role,thread#;
exit
SQL
  echo "RAC standby validation/fix completed. Review $REPORT"
else
  echo "DRY-RUN: no RAC changes applied. Review $REPORT and $SQLFILE"
fi
