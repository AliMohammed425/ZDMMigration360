#!/usr/bin/env bash
set -euo pipefail

precheck_validate_config(){
  local vars=(SOURCE_DB_NAME SOURCE_HOST SOURCE_OS_USER SOURCE_ORACLE_HOME SOURCE_SID SOURCE_DB_UNIQUE_NAME SOURCE_SERVICE SOURCE_TNS_ALIAS TARGET_DB_NAME TARGET_HOST TARGET_OS_USER TARGET_ORACLE_HOME TARGET_SID TARGET_DB_UNIQUE_NAME TARGET_SERVICE TARGET_TNS_ALIAS)
  local v; for v in "${vars[@]}"; do require_var "$v"; done
  [[ "$SOURCE_DB_NAME" == "$TARGET_DB_NAME" ]] || die "Physical standby DB_NAME must match source DB_NAME."
  [[ "$SOURCE_DB_UNIQUE_NAME" != "$TARGET_DB_UNIQUE_NAME" ]] || die "SOURCE_DB_UNIQUE_NAME and TARGET_DB_UNIQUE_NAME must differ."
  case "${STANDBY_BUILD_METHOD:-ACTIVE_DUPLICATE}" in ACTIVE_DUPLICATE|OFFLINE_BACKUP) ;; *) die "Invalid STANDBY_BUILD_METHOD";; esac
  case "${TARGET_RAC_ENABLED:-NO}" in YES|NO) ;; *) die "TARGET_RAC_ENABLED must be YES or NO";; esac
  [[ "${TARGET_AUX_PORT:-1529}" =~ ^[0-9]+$ ]] || die "TARGET_AUX_PORT must be numeric"
}

precheck_local_tools(){
  local c; for c in ssh scp awk sed grep sha256sum setsid flock; do command -v "$c" >/dev/null || die "Required local command missing: $c"; done
}

precheck_ssh(){
  ssh_check "$SOURCE_OS_USER" "$SOURCE_HOST"
  ssh_check "$TARGET_OS_USER" "$TARGET_HOST"
  ssh "$SOURCE_OS_USER@$SOURCE_HOST" "ssh -o BatchMode=yes -o PasswordAuthentication=no -o ConnectTimeout=10 '$TARGET_OS_USER@$TARGET_HOST' true"
  ssh "$TARGET_OS_USER@$TARGET_HOST" "ssh -o BatchMode=yes -o PasswordAuthentication=no -o ConnectTimeout=10 '$SOURCE_OS_USER@$SOURCE_HOST' true"
}

precheck_remote_tools(){
  ssh "$SOURCE_OS_USER@$SOURCE_HOST" "test -x '$SOURCE_ORACLE_HOME/bin/sqlplus'; test -x '$SOURCE_ORACLE_HOME/bin/rman'; test -x '$SOURCE_ORACLE_HOME/bin/tnsping'"
  ssh "$TARGET_OS_USER@$TARGET_HOST" "test -x '$TARGET_ORACLE_HOME/bin/sqlplus'; test -x '$TARGET_ORACLE_HOME/bin/rman'; test -x '$TARGET_ORACLE_HOME/bin/tnsping'; test -x '$TARGET_ORACLE_HOME/bin/lsnrctl'"
}

precheck_database_roles(){
  local out
  out="$(remote_sql "$SOURCE_HOST" "$SOURCE_OS_USER" "$SOURCE_ORACLE_HOME" "$SOURCE_SID" <<'SQL'
set pages 0 feedback off heading off verify off echo off
select 'DB='||name||'|'||db_unique_name||'|'||database_role||'|'||open_mode||'|'||log_mode||'|'||force_logging from v$database;
select 'PWF='||value from v$parameter where name='remote_login_passwordfile';
exit
SQL
)"
  echo "$out"
  grep -q '|PRIMARY|' <<<"$out" || die "Source database must be PRIMARY."
  if grep -q '|READ WRITE|NOARCHIVELOG|' <<<"$out"; then die "Open source must be in ARCHIVELOG mode for active duplication."; fi
  grep -q '|ARCHIVELOG|' <<<"$out" || [[ "${STANDBY_BUILD_METHOD:-ACTIVE_DUPLICATE}" == "OFFLINE_BACKUP" ]] || die "Source must be ARCHIVELOG for active duplicate."
  grep -q '|YES$' <<<"$out" || die "FORCE LOGGING is not enabled on source. Enable it before production standby build."
  grep -Eq 'PWF=(EXCLUSIVE|SHARED)' <<<"$out" || die "REMOTE_LOGIN_PASSWORDFILE must be EXCLUSIVE or SHARED."
}

precheck_target_nonrac(){
  ssh "$TARGET_OS_USER@$TARGET_HOST" "test -d '$TARGET_ORACLE_HOME'; test -x '$TARGET_ORACLE_HOME/bin/sqlplus'; test -w '$TARGET_ORACLE_HOME/dbs'"
  remote_sql "$TARGET_HOST" "$TARGET_OS_USER" "$TARGET_ORACLE_HOME" "$TARGET_SID" <<'SQL' || true
set pages 100 lines 220
show parameter cluster_database
select instance_name,status from v$instance;
exit
SQL
}

production_preflight(){
  operator_access_preflight
  precheck_validate_config
  precheck_local_tools
  precheck_ssh
  precheck_remote_tools
  precheck_database_roles
  oci_placeholder_validate_inputs
  echo "PRODUCTION PREFLIGHT PASSED (host/database checks)."
}
