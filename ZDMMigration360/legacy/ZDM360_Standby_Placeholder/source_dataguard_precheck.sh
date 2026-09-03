#!/usr/bin/env bash
set -euo pipefail

: "${SOURCE_HOST:?SOURCE_HOST required}"
: "${SOURCE_ORACLE_HOME:?SOURCE_ORACLE_HOME required}"
: "${SOURCE_SID:?SOURCE_SID required}"
SOURCE_OS_USER="${SOURCE_OS_USER:-oracle}"
REPORT="${DG_REPORT_LOCAL:-./source_dataguard_inventory.txt}"

ssh "$SOURCE_OS_USER@$SOURCE_HOST" "
export ORACLE_HOME='$SOURCE_ORACLE_HOME'
export ORACLE_SID='$SOURCE_SID'
export PATH=\$ORACLE_HOME/bin:\$PATH
sqlplus -s '/ as sysdba' <<'SQL'
set pages 500 lines 240 trimspool on feedback off verify off echo off

prompt === DATABASE / ARCHIVE MODE ===
select name, db_unique_name, database_role, open_mode, log_mode, force_logging
from v\$database;

prompt === ARCHIVE DESTINATIONS ===
select dest_id, dest_name, status, target, db_unique_name, destination, error
from v\$archive_dest
where dest_id <= 31
  and (status <> 'INACTIVE' or destination is not null)
order by dest_id;

prompt === DATA GUARD PARAMETERS ===
select name, value
from v\$parameter
where name like 'log_archive_config'
   or name like 'log_archive_dest_%'
   or name in ('fal_server','fal_client','standby_file_management',
               'db_file_name_convert','log_file_name_convert',
               'remote_login_passwordfile')
order by name;

prompt === DATA GUARD CONFIG MEMBERS ===
select db_unique_name, parent_dbun, dest_role
from v\$dataguard_config
order by db_unique_name;

prompt === STANDBY REDO LOGS ===
select group#, thread#, sequence#, round(bytes/1024/1024) mb, status, archived
from v\$standby_log
order by thread#, group#;

prompt === ONLINE REDO LOGS ===
select group#, thread#, round(bytes/1024/1024) mb, status, archived
from v\$log
order by thread#, group#;

exit
SQL
" | tee "$REPORT"

echo
echo "Data Guard inventory saved to: $REPORT"
