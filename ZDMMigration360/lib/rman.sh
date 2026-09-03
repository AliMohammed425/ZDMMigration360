#!/usr/bin/env bash
set -euo pipefail


rman_duplicate_method_validate(){
  local method="${STANDBY_BUILD_METHOD:-ACTIVE_DUPLICATE}"
  method="${method^^}"
  case "$method" in
    ACTIVE_DUPLICATE)
      require_var SOURCE_SYS_PASSWORD
      require_var TARGET_SYS_PASSWORD
      [[ "$SOURCE_SYS_PASSWORD" == "$TARGET_SYS_PASSWORD" ]] || die "ACTIVE_DUPLICATE requires matching SYS password-file credentials."
      # Confirm source is suitable and auxiliary is reachable/NOMOUNT before the long RMAN operation.
      remote_sql "$SOURCE_HOST" "$SOURCE_OS_USER" "$SOURCE_ORACLE_HOME" "$SOURCE_SID" <<'SQL'
whenever sqlerror exit failure
set pages 100 lines 220
select name,db_unique_name,database_role,log_mode,force_logging,open_mode from v$database;
select name,value from v$parameter where name in ('remote_login_passwordfile','db_unique_name');
exit
SQL
      remote_sql "$TARGET_HOST" "$TARGET_OS_USER" "$TARGET_ORACLE_HOME" "$TARGET_SID" <<'SQL'
whenever sqlerror exit failure
set pages 100 lines 220
select instance_name,status from v$instance;
select name,value from v$parameter where name in ('db_name','db_unique_name','remote_login_passwordfile');
exit
SQL
      ssh "$TARGET_OS_USER@$TARGET_HOST" "export ORACLE_HOME='$TARGET_ORACLE_HOME'; export PATH=\$ORACLE_HOME/bin:\$PATH; tnsping '$SOURCE_TNS_ALIAS' >/dev/null"
      ssh "$SOURCE_OS_USER@$SOURCE_HOST" "export ORACLE_HOME='$SOURCE_ORACLE_HOME'; export PATH=\$ORACLE_HOME/bin:\$PATH; tnsping '$TARGET_TNS_ALIAS' >/dev/null"
      echo "RMAN method gate: ACTIVE_DUPLICATE prerequisites passed."
      ;;
    OFFLINE_BACKUP)
      require_var TARGET_SYS_PASSWORD
      require_var SOURCE_BACKUP_STAGE
      require_var TARGET_BACKUP_STAGE
      [[ -f "${CURRENT_JOB_DIR:-$REPORT_ROOT}/backup.sha256" ]] || die "Source backup SHA-256 manifest is missing."
      [[ -f "${CURRENT_JOB_DIR:-$REPORT_ROOT}/backup.target.sha256" ]] || die "Target backup SHA-256 manifest is missing."
      diff -u "${CURRENT_JOB_DIR:-$REPORT_ROOT}/backup.sha256" "${CURRENT_JOB_DIR:-$REPORT_ROOT}/backup.target.sha256" >/dev/null ||
        die "Backup source/target SHA-256 manifests do not match."

      # Ask RMAN on the auxiliary host to parse/catalog the staged backup set before DUPLICATE.
      # This catches unreadable/foreign/incomplete staging earlier than the duplicate itself.
      ssh "$TARGET_OS_USER@$TARGET_HOST" "export ORACLE_HOME='$TARGET_ORACLE_HOME'; export ORACLE_SID='$TARGET_SID'; export PATH=\$ORACLE_HOME/bin:\$PATH; rman auxiliary / <<RMAN
CATALOG START WITH '${TARGET_BACKUP_STAGE}/' NOPROMPT;
LIST BACKUP SUMMARY;
exit
RMAN"
      echo "RMAN method gate: OFFLINE_BACKUP staging/catalog validation passed."
      ;;
    *)
      die "Unsupported STANDBY_BUILD_METHOD=$method. Use ACTIVE_DUPLICATE or OFFLINE_BACKUP."
      ;;
  esac
}

rman_active_duplicate(){
  require_var SOURCE_SYS_PASSWORD; require_var TARGET_SYS_PASSWORD
  [[ "$SOURCE_SYS_PASSWORD" == "$TARGET_SYS_PASSWORD" ]] || die "SYS credentials must match."
  local tmp; tmp="$(mktemp /tmp/zdm360_active_dup.XXXXXX)"; chmod 600 "$tmp"; trap 'rm -f "$tmp"' RETURN
  local cfg
  cfg="$(remote_sql "$SOURCE_HOST" "$SOURCE_OS_USER" "$SOURCE_ORACLE_HOME" "$SOURCE_SID" <<'SQL' | tr -d '
' | sed '/^[[:space:]]*$/d' | tail -1
set pages 0 feedback off heading off verify off echo off
select value from v$parameter where name='log_archive_config';
exit
SQL
)"
  [[ "$cfg" == DG_CONFIG=* ]] || cfg="DG_CONFIG=(${SOURCE_DB_UNIQUE_NAME},${TARGET_DB_UNIQUE_NAME})"
  cat > "$tmp" <<RMAN
CONNECT TARGET "sys/${SOURCE_SYS_PASSWORD}@${SOURCE_TNS_ALIAS} AS SYSDBA";
CONNECT AUXILIARY "sys/${TARGET_SYS_PASSWORD}@${TARGET_TNS_ALIAS} AS SYSDBA";
RUN {
  DUPLICATE TARGET DATABASE FOR STANDBY
    FROM ACTIVE DATABASE
    DORECOVER
    SPFILE
      SET DB_UNIQUE_NAME='${TARGET_DB_UNIQUE_NAME}'
      SET CLUSTER_DATABASE='FALSE'
      SET STANDBY_FILE_MANAGEMENT='AUTO'
      SET LOG_ARCHIVE_CONFIG='${cfg}'
      SET FAL_SERVER='${SOURCE_TNS_ALIAS}'
    NOFILENAMECHECK;
}
RMAN
  scp -q "$tmp" "$TARGET_OS_USER@$TARGET_HOST:/tmp/zdm360_active_duplicate.rman"
  ssh "$TARGET_OS_USER@$TARGET_HOST" "set -e; chmod 600 /tmp/zdm360_active_duplicate.rman; export ORACLE_HOME='$TARGET_ORACLE_HOME'; export ORACLE_SID='$TARGET_SID'; export PATH=\$ORACLE_HOME/bin:\$PATH; rman cmdfile=/tmp/zdm360_active_duplicate.rman log=/tmp/zdm360_active_duplicate.log; rc=\$?; rm -f /tmp/zdm360_active_duplicate.rman; exit \$rc"
}

rman_validate_backup(){
  require_var SOURCE_BACKUP_STAGE
  ssh "$SOURCE_OS_USER@$SOURCE_HOST" "test -d '$SOURCE_BACKUP_STAGE'; find '$SOURCE_BACKUP_STAGE' -maxdepth 1 -type f -print -quit | grep -q ."
  ssh "$SOURCE_OS_USER@$SOURCE_HOST" "export ORACLE_HOME='$SOURCE_ORACLE_HOME'; export ORACLE_SID='$SOURCE_SID'; export PATH=\$ORACLE_HOME/bin:\$PATH; rman target / <<RMAN
LIST BACKUP SUMMARY;
CROSSCHECK BACKUP;
exit
RMAN"
  ssh "$SOURCE_OS_USER@$SOURCE_HOST" "cd '$SOURCE_BACKUP_STAGE'; find . -maxdepth 1 -type f -print0 | sort -z | xargs -0 sha256sum" > "${CURRENT_JOB_DIR:-$REPORT_ROOT}/backup.sha256"
}

rman_stage_backup(){
  require_var SOURCE_BACKUP_STAGE; require_var TARGET_BACKUP_STAGE
  local method="${BACKUP_COPY_METHOD:-SCP}"
  case "${method^^}" in
    NFS) ssh "$TARGET_OS_USER@$TARGET_HOST" "test -d '$TARGET_BACKUP_STAGE'" ;;
    RSYNC)
      # Standard rsync cannot have two remote endpoints. Run the transfer on the target and pull from source.
      ssh "$TARGET_OS_USER@$TARGET_HOST" "command -v rsync >/dev/null; mkdir -p '$TARGET_BACKUP_STAGE'; rsync -a -e ssh '$SOURCE_OS_USER@$SOURCE_HOST:$SOURCE_BACKUP_STAGE/' '$TARGET_BACKUP_STAGE/'"
      ;;
    SCP)
      local td; td="$(mktemp -d /tmp/zdm360_backup.XXXXXX)"; trap 'rm -rf "$td"' RETURN
      scp -q -r "$SOURCE_OS_USER@$SOURCE_HOST:$SOURCE_BACKUP_STAGE/." "$td/"
      ssh "$TARGET_OS_USER@$TARGET_HOST" "mkdir -p '$TARGET_BACKUP_STAGE'"
      scp -q -r "$td/." "$TARGET_OS_USER@$TARGET_HOST:$TARGET_BACKUP_STAGE/"
      ;;
    *) die "BACKUP_COPY_METHOD must be SCP, RSYNC, or NFS." ;;
  esac
  local target_manifest="${CURRENT_JOB_DIR:-$REPORT_ROOT}/backup.target.sha256"
  ssh "$TARGET_OS_USER@$TARGET_HOST" "cd '$TARGET_BACKUP_STAGE'; find . -maxdepth 1 -type f -print0 | sort -z | xargs -0 sha256sum" > "$target_manifest"
  diff -u "${CURRENT_JOB_DIR:-$REPORT_ROOT}/backup.sha256" "$target_manifest" || die "Backup SHA-256 manifest mismatch after staging."
}

rman_offline_duplicate(){
  require_var TARGET_SYS_PASSWORD; require_var TARGET_BACKUP_STAGE
  local cfg
  cfg="$(remote_sql "$SOURCE_HOST" "$SOURCE_OS_USER" "$SOURCE_ORACLE_HOME" "$SOURCE_SID" <<'SQL' | tr -d '
' | sed '/^[[:space:]]*$/d' | tail -1
set pages 0 feedback off heading off verify off echo off
select value from v$parameter where name='log_archive_config';
exit
SQL
)"
  [[ "$cfg" == DG_CONFIG=* ]] || cfg="DG_CONFIG=(${SOURCE_DB_UNIQUE_NAME},${TARGET_DB_UNIQUE_NAME})"
  local tmp; tmp="$(mktemp /tmp/zdm360_offline_dup.XXXXXX)"; chmod 600 "$tmp"; trap 'rm -f "$tmp"' RETURN
  cat > "$tmp" <<RMAN
CONNECT AUXILIARY "sys/${TARGET_SYS_PASSWORD}@${TARGET_TNS_ALIAS} AS SYSDBA";
DUPLICATE DATABASE FOR STANDBY
  BACKUP LOCATION '${TARGET_BACKUP_STAGE}'
  DORECOVER
  SPFILE
    SET DB_UNIQUE_NAME='${TARGET_DB_UNIQUE_NAME}'
    SET CLUSTER_DATABASE='FALSE'
    SET STANDBY_FILE_MANAGEMENT='AUTO'
    SET LOG_ARCHIVE_CONFIG='${cfg}'
    SET FAL_SERVER='${SOURCE_TNS_ALIAS}'
  NOFILENAMECHECK;
RMAN
  scp -q "$tmp" "$TARGET_OS_USER@$TARGET_HOST:/tmp/zdm360_offline_duplicate.rman"
  ssh "$TARGET_OS_USER@$TARGET_HOST" "set -e; chmod 600 /tmp/zdm360_offline_duplicate.rman; export ORACLE_HOME='$TARGET_ORACLE_HOME'; export ORACLE_SID='$TARGET_SID'; export PATH=\$ORACLE_HOME/bin:\$PATH; rman cmdfile=/tmp/zdm360_offline_duplicate.rman log=/tmp/zdm360_offline_duplicate.log; rc=\$?; rm -f /tmp/zdm360_offline_duplicate.rman; exit \$rc"
}

postbuild_restart_mount(){
  remote_sql "$TARGET_HOST" "$TARGET_OS_USER" "$TARGET_ORACLE_HOME" "$TARGET_SID" <<'SQL'
whenever sqlerror exit failure
select name,db_unique_name,database_role,open_mode from v$database;
alter database recover managed standby database cancel;
shutdown immediate;
startup mount;
alter database recover managed standby database disconnect from session;
select name,db_unique_name,database_role,open_mode from v$database;
exit
SQL
}
