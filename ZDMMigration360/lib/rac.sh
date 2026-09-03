#!/usr/bin/env bash
set -euo pipefail

rac_validate(){
  remote_sql "$TARGET_HOST" "$TARGET_OS_USER" "$TARGET_ORACLE_HOME" "$TARGET_SID" <<'SQL'
set pages 200 lines 250
select name,db_unique_name,database_role,open_mode from v$database;
show parameter cluster_database
select thread#,status,enabled,instance from v$thread order by thread#;
select thread#,group#,bytes/1024/1024 mb,status from v$log order by thread#,group#;
select thread#,group#,bytes/1024/1024 mb,status from v$standby_log order by thread#,group#;
select tablespace_name,status from dba_tablespaces where contents='UNDO' order by 1;
exit
SQL
}

rac_enable(){
  [[ "${TARGET_RAC_ENABLED:-NO}" == YES ]] || return 0
  require_var TARGET_GRID_HOME; require_var TARGET_DB_UNIQUE_NAME

  # If already registered/configured as RAC, validate and use the existing
  # Clusterware topology. This is the production-safe path.
  if ssh "$TARGET_OS_USER@$TARGET_HOST" "'$TARGET_GRID_HOME/bin/srvctl' config database -db '$TARGET_DB_UNIQUE_NAME' >/dev/null 2>&1"; then
    ssh "$TARGET_OS_USER@$TARGET_HOST" "'$TARGET_GRID_HOME/bin/srvctl' start database -db '$TARGET_DB_UNIQUE_NAME' -startoption MOUNT || true; '$TARGET_GRID_HOME/bin/srvctl' status database -db '$TARGET_DB_UNIQUE_NAME'"
    rac_validate
    return 0
  fi

  # Cross-environment automatic RAC registration/conversion requires exact GI
  # topology and per-instance settings. Do not invent those values in production.
  if [[ "${RAC_CONVERSION_MODE:-VALIDATE_ONLY}" != LEGACY_AUTOFIX ]]; then
    die "RAC requested but database is not registered with Clusterware. Production-safe automation will not guess instance names, thread/undo mappings, SCAN/listener ownership, or ASM password-file placement. Register/configure the RAC database first, or explicitly set RAC_CONVERSION_MODE=LEGACY_AUTOFIX after site review."
  fi

  local helper="$ZDM360_ROOT/legacy/ZDM360_Standby_Placeholder/post_restore_rac_validate_fix.sh"
  [[ -x "$helper" ]] || die "Legacy RAC conversion helper not found."
  TARGET_HOST="$TARGET_HOST" TARGET_OS_USER="$TARGET_OS_USER" TARGET_ORACLE_HOME="$TARGET_ORACLE_HOME" TARGET_SID="$TARGET_SID" TARGET_DB_UNIQUE_NAME="$TARGET_DB_UNIQUE_NAME" TARGET_GRID_HOME="$TARGET_GRID_HOME" TARGET_RAC_INSTANCES="${TARGET_RAC_INSTANCES:-2}" TARGET_UNDO_PREFIX="${TARGET_UNDO_PREFIX:-UNDOTBS}" TARGET_REDO_SIZE_MB="${TARGET_REDO_SIZE_MB:-0}" EXECUTE=true "$helper"
}
