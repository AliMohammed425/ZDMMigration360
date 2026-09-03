#!/usr/bin/env bash
set -euo pipefail

oci_placeholder_detect_platform(){
  local user="${TARGET_PROVISION_OS_USER:-opc}"
  ssh "$user@$TARGET_HOST" "if [ -x /opt/oracle/dcs/bin/dbcli ]; then echo BASE_DB_SERVICE_DBCLI; elif command -v dbaascli >/dev/null 2>&1 || [ -x /var/opt/oracle/dbaascli/dbaascli ]; then echo DBAASCLI_PLATFORM; else echo GENERIC_OCI_OR_SELF_MANAGED; fi"
}

oci_placeholder_validate_inputs(){
  require_var SOURCE_DB_NAME; require_var SOURCE_DB_UNIQUE_NAME; require_var TARGET_DB_UNIQUE_NAME; require_var TARGET_HOST
  [[ "$SOURCE_DB_UNIQUE_NAME" != "$TARGET_DB_UNIQUE_NAME" ]] || die "Target DB_UNIQUE_NAME must differ from source."
  [[ -z "${TARGET_DB_NAME:-}" || "$TARGET_DB_NAME" == "$SOURCE_DB_NAME" ]] || die "Physical standby DB_NAME must match source."
}

oci_placeholder_existing_ok(){
  local out rc=0
  out="$(remote_sql "$TARGET_HOST" "$TARGET_OS_USER" "$TARGET_ORACLE_HOME" "$TARGET_SID" <<'SQL' 2>/dev/null || true
set pages 0 feedback off heading off verify off echo off
select 'INSTANCE='||status from v$instance;
select 'DBNAME='||value from v$parameter where name='db_name';
select 'DBUNQ='||value from v$parameter where name='db_unique_name';
exit
SQL
)"
  grep -q 'INSTANCE=STARTED' <<<"$out" || rc=1
  grep -qi "DBNAME=${SOURCE_DB_NAME}" <<<"$out" || rc=1
  grep -qi "DBUNQ=${TARGET_DB_UNIQUE_NAME}" <<<"$out" || rc=1
  [[ $rc -eq 0 ]] && { echo "Existing NOMOUNT placeholder matches requested DB_NAME/DB_UNIQUE_NAME; reusing it."; return 0; }
  return 1
}

oci_placeholder_base_dbservice(){
  local ssh_user="${TARGET_PROVISION_OS_USER:-opc}" dbcli="/opt/oracle/dcs/bin/dbcli"
  require_var TARGET_ADMIN_PASSWORD
  local cdb_opt=""; [[ "${SOURCE_IS_CDB:-YES}" == "YES" ]] && cdb_opt="--cdb"
  log "Creating OCI Base Database Service instance-only placeholder."
  ssh "$ssh_user@$TARGET_HOST" "command -v expect >/dev/null 2>&1" || die "expect is required on Base DB Service target for unattended dbcli password prompting."
  local td; td="$(mktemp -d /tmp/zdm360_dbcli.XXXXXX)"; trap 'rm -rf "$td"' RETURN
  printf '%s' "$TARGET_ADMIN_PASSWORD" > "$td/secret"; chmod 600 "$td/secret"
  cat > "$td/run.expect" <<'EXP'
set timeout 1800
set fh [open "/tmp/zdm360_dbcli.secret" r]
set pw [string trimright [read $fh] "\r\n"]
close $fh
set cmd $env(ZDM360_DBCLI_CMD)
eval spawn $cmd
expect {
  -re {(?i)password.*:} { send -- "$pw\r"; exp_continue }
  eof
}
catch wait result
exit [lindex $result 3]
EXP
  chmod 600 "$td/run.expect"
  scp -q "$td/secret" "$ssh_user@$TARGET_HOST:/tmp/zdm360_dbcli.secret"
  scp -q "$td/run.expect" "$ssh_user@$TARGET_HOST:/tmp/zdm360_dbcli.expect"
  local remote_cmd="sudo -n $dbcli create-database --dbname $SOURCE_DB_NAME --databaseUniqueName $TARGET_DB_UNIQUE_NAME --instanceonly $cdb_opt --adminpassword"
  ssh "$ssh_user@$TARGET_HOST" "chmod 600 /tmp/zdm360_dbcli.secret /tmp/zdm360_dbcli.expect; export ZDM360_DBCLI_CMD=\"$remote_cmd\"; expect /tmp/zdm360_dbcli.expect; rc=\$?; rm -f /tmp/zdm360_dbcli.secret /tmp/zdm360_dbcli.expect; exit \$rc"
}

oci_placeholder_base_dbservice_wait(){
  local ssh_user="${TARGET_PROVISION_OS_USER:-opc}" wait="${OCI_PLACEHOLDER_WAIT_SECONDS:-1800}" poll="${OCI_PLACEHOLDER_POLL_SECONDS:-20}" deadline=$(( $(date +%s)+wait ))
  while :; do
    ssh "$ssh_user@$TARGET_HOST" "sudo -n /opt/oracle/dcs/bin/dbcli list-jobs" || true
    if ssh "$ssh_user@$TARGET_HOST" "sudo -n /opt/oracle/dcs/bin/dbcli list-databases | grep -i -q '$TARGET_DB_UNIQUE_NAME'"; then break; fi
    (( $(date +%s) < deadline )) || return 2
    sleep "$poll"
  done
}

oci_placeholder_generic(){
  local pfile="/tmp/init${TARGET_SID}.ora"
  ssh "$TARGET_OS_USER@$TARGET_HOST" "cat > '$pfile' <<EOF2
db_name='${SOURCE_DB_NAME}'
db_unique_name='${TARGET_DB_UNIQUE_NAME}'
cluster_database=false
remote_login_passwordfile='EXCLUSIVE'
standby_file_management='AUTO'
${TARGET_DB_CREATE_FILE_DEST:+db_create_file_dest='${TARGET_DB_CREATE_FILE_DEST}'}
${TARGET_DB_RECOVERY_FILE_DEST:+db_recovery_file_dest='${TARGET_DB_RECOVERY_FILE_DEST}'}
${TARGET_DB_RECOVERY_FILE_DEST_SIZE:+db_recovery_file_dest_size='${TARGET_DB_RECOVERY_FILE_DEST_SIZE}'}
EOF2
chmod 600 '$pfile'; export ORACLE_HOME='$TARGET_ORACLE_HOME'; export ORACLE_SID='$TARGET_SID'; export PATH=\$ORACLE_HOME/bin:\$PATH; sqlplus -s '/ as sysdba' <<SQL
whenever sqlerror exit failure
startup nomount pfile='$pfile';
create spfile from pfile='$pfile';
shutdown immediate;
startup nomount;
exit
SQL"
}

oci_placeholder_verify(){
  remote_sql "$TARGET_HOST" "$TARGET_OS_USER" "$TARGET_ORACLE_HOME" "$TARGET_SID" <<SQL
whenever sqlerror exit failure
set pages 0 feedback off heading off
select case when status='STARTED' then 'NOMOUNT_OK' else 'BAD_'||status end from v\$instance;
select value from v\$parameter where name='db_name';
select value from v\$parameter where name='db_unique_name';
exit
SQL
}

oci_placeholder_create(){
  oci_placeholder_validate_inputs
  if oci_placeholder_existing_ok; then return 0; fi
  local platform="${OCI_TARGET_PLATFORM:-AUTO}"
  [[ "$platform" != "AUTO" ]] || platform="$(oci_placeholder_detect_platform)"
  RESOLVED_OCI_PLATFORM="$platform"; export RESOLVED_OCI_PLATFORM
  echo "OCI target platform: $platform"
  case "$platform" in
    BASE_DB_SERVICE_DBCLI) oci_placeholder_base_dbservice; oci_placeholder_base_dbservice_wait ;;
    GENERIC_OCI_OR_SELF_MANAGED) oci_placeholder_generic ;;
    DBAASCLI_PLATFORM) die "dbaascli-managed target detected; automatic placeholder creation is intentionally blocked until a platform-approved dbaascli lifecycle is configured." ;;
    *) die "Unsupported OCI_TARGET_PLATFORM=$platform" ;;
  esac
  oci_placeholder_verify
}
