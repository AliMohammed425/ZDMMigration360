#!/usr/bin/env bash
set -euo pipefail

passwordfile_prepare(){
  require_var SOURCE_SYS_PASSWORD
  require_var TARGET_SYS_PASSWORD
  [[ "$SOURCE_SYS_PASSWORD" == "$TARGET_SYS_PASSWORD" ]] || die "SYS password must match for primary/auxiliary connectivity."

  local platform="${RESOLVED_OCI_PLATFORM:-${OCI_TARGET_PLATFORM:-AUTO}}"
  if [[ "$platform" == "BASE_DB_SERVICE_DBCLI" ]]; then
    require_var TARGET_ADMIN_PASSWORD
    [[ "$TARGET_ADMIN_PASSWORD" == "$SOURCE_SYS_PASSWORD" ]] || die "For OCI Base DB Service instance-only creation, TARGET_ADMIN_PASSWORD must match the primary admin/SYS password for this workflow."
    echo "Base DB Service placeholder owns password-file creation; matching credential validated."
    return 0
  fi

  ssh "$TARGET_OS_USER@$TARGET_HOST" "command -v expect >/dev/null 2>&1" || die "expect is required on generic target for unattended ORAPWD prompting."
  local td; td="$(mktemp -d /tmp/zdm360_orapwd.XXXXXX)"; trap 'rm -rf "$td"' RETURN
  printf '%s' "$TARGET_SYS_PASSWORD" > "$td/secret"; chmod 600 "$td/secret"
  cat > "$td/run.expect" <<'EXP'
set timeout 120
set fh [open "/tmp/zdm360_orapwd.secret" r]
set pw [string trimright [read $fh] "\r\n"]
close $fh
set cmd $env(ZDM360_ORAPWD_CMD)
eval spawn $cmd
expect {
  -re {(?i)password.*:} { send -- "$pw\r"; exp_continue }
  eof
}
catch wait result
exit [lindex $result 3]
EXP
  chmod 600 "$td/run.expect"
  scp -q "$td/secret" "$TARGET_OS_USER@$TARGET_HOST:/tmp/zdm360_orapwd.secret"
  scp -q "$td/run.expect" "$TARGET_OS_USER@$TARGET_HOST:/tmp/zdm360_orapwd.expect"
  ssh "$TARGET_OS_USER@$TARGET_HOST" "set -e; export ORACLE_HOME='$TARGET_ORACLE_HOME'; export ORACLE_SID='$TARGET_SID'; export PATH=\$ORACLE_HOME/bin:\$PATH; umask 077; export ZDM360_ORAPWD_CMD=\"\$ORACLE_HOME/bin/orapwd FILE=\$ORACLE_HOME/dbs/orapw$TARGET_SID FORCE=Y FORMAT=12.2 SYS=Y\"; expect /tmp/zdm360_orapwd.expect; rc=\$?; rm -f /tmp/zdm360_orapwd.secret /tmp/zdm360_orapwd.expect; test -s \$ORACLE_HOME/dbs/orapw'$TARGET_SID'; exit \$rc"
}

tde_detect(){
  local out
  out="$(remote_sql "$SOURCE_HOST" "$SOURCE_OS_USER" "$SOURCE_ORACLE_HOME" "$SOURCE_SID" <<'SQL'
set pages 0 feedback off heading off verify off echo off
select case when exists (select 1 from v$encrypted_tablespaces) then 'TDE_ENABLED' else 'TDE_NOT_ENABLED' end from dual;
exit
SQL
)"
  TDE_STATUS="$(printf '%s\n' "$out" | tr -d '\r ' | grep -E 'TDE_(ENABLED|NOT_ENABLED)' | tail -1)"
  export TDE_STATUS
  echo "$TDE_STATUS"
}

tde_prepare(){
  tde_detect
  if [[ "$TDE_STATUS" == "TDE_NOT_ENABLED" ]]; then
    echo "TDE is not enabled; keystore staging is not required."
    return 0
  fi
  require_var SOURCE_TDE_WALLET_PATH
  require_var TARGET_TDE_WALLET_PATH
  [[ "$SOURCE_TDE_WALLET_PATH" == "$TARGET_TDE_WALLET_PATH" ]] || die "Automatic TDE handling requires the same absolute keystore path on source and target so inherited wallet configuration remains valid."
  ssh "$SOURCE_OS_USER@$SOURCE_HOST" "test -d '$SOURCE_TDE_WALLET_PATH'; test -s '$SOURCE_TDE_WALLET_PATH/ewallet.p12' -o -s '$SOURCE_TDE_WALLET_PATH/cwallet.sso'"
  ssh "$TARGET_OS_USER@$TARGET_HOST" "mkdir -p '$TARGET_TDE_WALLET_PATH'; chmod 700 '$TARGET_TDE_WALLET_PATH'"
  local td; td="$(mktemp -d /tmp/zdm360_wallet.XXXXXX)"; trap 'rm -rf "$td"' RETURN
  scp -q "$SOURCE_OS_USER@$SOURCE_HOST:$SOURCE_TDE_WALLET_PATH/ewallet.p12" "$td/" 2>/dev/null || true
  scp -q "$SOURCE_OS_USER@$SOURCE_HOST:$SOURCE_TDE_WALLET_PATH/cwallet.sso" "$td/" 2>/dev/null || true
  compgen -G "$td/*" >/dev/null || die "No TDE keystore files could be staged."
  scp -q "$td"/* "$TARGET_OS_USER@$TARGET_HOST:$TARGET_TDE_WALLET_PATH/"
  ssh "$TARGET_OS_USER@$TARGET_HOST" "chmod 600 '$TARGET_TDE_WALLET_PATH'/*; ls -l '$TARGET_TDE_WALLET_PATH'"
}
