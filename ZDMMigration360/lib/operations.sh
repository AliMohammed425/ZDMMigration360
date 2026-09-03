#!/usr/bin/env bash
set -euo pipefail

broker_state(){
  local raw
  raw="$(
    remote_sql "$SOURCE_HOST" "$SOURCE_OS_USER" "$SOURCE_ORACLE_HOME" "$SOURCE_SID" <<'SQL'
set pages 0 feedback off heading off verify off echo off
select value from v$parameter where name='dg_broker_start';
exit
SQL
  )"
  printf '%s\n' "$raw" | tr -d '\r' | awk 'NF{print toupper($1)}' | tail -1
}

snapshot_status(){
  remote_sql "$TARGET_HOST" "$TARGET_OS_USER" "$TARGET_ORACLE_HOME" "$TARGET_SID" <<'SQL'
set pages 100 lines 220
select name,db_unique_name,database_role,open_mode,flashback_on,switchover_status from v$database;
exit
SQL
}

switchover_precheck(){
  local broker
  broker="$(broker_state)"

  if [[ "$broker" == "TRUE" ]]; then
    ssh "$SOURCE_OS_USER@$SOURCE_HOST" "
      export ORACLE_HOME='$SOURCE_ORACLE_HOME'
      export PATH=\$ORACLE_HOME/bin:\$PATH
      dgmgrl / <<DGMGRL
show configuration verbose;
validate database verbose '$TARGET_DB_UNIQUE_NAME';
validate network configuration for all;
exit
DGMGRL
    "
  else
    echo "Data Guard Broker is not enabled; switchover readiness checked through database status only."
    remote_sql "$SOURCE_HOST" "$SOURCE_OS_USER" "$SOURCE_ORACLE_HOME" "$SOURCE_SID" <<'SQL'
set pages 100 lines 220
select name,db_unique_name,database_role,open_mode,switchover_status from v$database;
exit
SQL
    remote_sql "$TARGET_HOST" "$TARGET_OS_USER" "$TARGET_ORACLE_HOME" "$TARGET_SID" <<'SQL'
set pages 100 lines 220
select name,db_unique_name,database_role,open_mode,switchover_status from v$database;
select * from v$archive_gap;
exit
SQL
  fi
}

failover_precheck(){
  local broker
  broker="$(broker_state)"

  if [[ "$broker" == "TRUE" ]]; then
    ssh "$SOURCE_OS_USER@$SOURCE_HOST" "
      export ORACLE_HOME='$SOURCE_ORACLE_HOME'
      export PATH=\$ORACLE_HOME/bin:\$PATH
      dgmgrl / <<DGMGRL
validate database verbose '$TARGET_DB_UNIQUE_NAME' strict all;
exit
DGMGRL
    "
  else
    echo "Data Guard Broker is not enabled; failover readiness validation is limited."
    remote_sql "$TARGET_HOST" "$TARGET_OS_USER" "$TARGET_ORACLE_HOME" "$TARGET_SID" <<'SQL'
set pages 100 lines 220
select name,db_unique_name,database_role,open_mode,switchover_status from v$database;
select name,value,time_computed,datum_time from v$dataguard_stats order by name;
select * from v$archive_gap;
exit
SQL
  fi
}
