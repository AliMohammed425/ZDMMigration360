#!/usr/bin/env bash
set -euo pipefail

validate_network_values(){
  [[ "${SOURCE_HOST:-}" =~ ^[A-Za-z0-9._:-]+$ ]] || die "Invalid SOURCE_HOST"
  [[ "${TARGET_HOST:-}" =~ ^[A-Za-z0-9._:-]+$ ]] || die "Invalid TARGET_HOST"
  [[ "${SOURCE_TNS_ALIAS:-}" =~ ^[A-Za-z0-9_.-]+$ ]] || die "Invalid SOURCE_TNS_ALIAS"
  [[ "${TARGET_TNS_ALIAS:-}" =~ ^[A-Za-z0-9_.-]+$ ]] || die "Invalid TARGET_TNS_ALIAS"
  [[ "${SOURCE_SERVICE:-}" =~ ^[A-Za-z0-9_.-]+$ ]] || die "Invalid SOURCE_SERVICE"
  [[ "${TARGET_SERVICE:-}" =~ ^[A-Za-z0-9_.-]+$ ]] || die "Invalid TARGET_SERVICE"
  [[ "${TARGET_SID:-}" =~ ^[A-Za-z0-9_]+$ ]] || die "Invalid TARGET_SID"
}

configure_tns_on_host(){
  local user="$1" host="$2" oh="$3"
  local admin="${oh}/network/admin" file="${admin}/tnsnames.ora"
  local src_port="${SOURCE_LISTENER_PORT:-1521}"
  local tgt_port="${TARGET_AUX_PORT:-1529}"
  ssh "$user@$host" "mkdir -p '$admin'; touch '$file'; cp -p '$file' '$file.zdm360.bak' 2>/dev/null || true; awk '/# ZDM360 BEGIN/{skip=1} /# ZDM360 END/{skip=0;next} !skip{print}' '$file' > '$file.zdm360'; cat >> '$file.zdm360' <<'TNS'
# ZDM360 BEGIN
${SOURCE_TNS_ALIAS} =
  (DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=${SOURCE_HOST})(PORT=${src_port}))
   (CONNECT_DATA=(SERVER=DEDICATED)(SERVICE_NAME=${SOURCE_SERVICE})))
${TARGET_TNS_ALIAS} =
  (DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=${TARGET_HOST})(PORT=${tgt_port}))
   (CONNECT_DATA=(SERVER=DEDICATED)(SERVICE_NAME=${TARGET_SERVICE})))
# ZDM360 END
TNS
mv '$file.zdm360' '$file'; chmod 600 '$file'"
}

tns_configure(){
  validate_network_values
  configure_tns_on_host "$SOURCE_OS_USER" "$SOURCE_HOST" "$SOURCE_ORACLE_HOME"
  configure_tns_on_host "$TARGET_OS_USER" "$TARGET_HOST" "$TARGET_ORACLE_HOME"
}

aux_listener_configure(){
  validate_network_values
  local port="${TARGET_AUX_PORT:-1529}"
  local lname="${TARGET_AUX_LISTENER_NAME:-LISTENER_ZDM360}"
  local admin="${TARGET_ORACLE_HOME}/network/admin"
  local file="${admin}/listener.ora"
  ssh "$TARGET_OS_USER@$TARGET_HOST" "mkdir -p '$admin'; touch '$file'; cp -p '$file' '$file.zdm360.bak' 2>/dev/null || true; awk '/# ZDM360 AUX BEGIN/{skip=1} /# ZDM360 AUX END/{skip=0;next} !skip{print}' '$file' > '$file.zdm360'; cat >> '$file.zdm360' <<'LST'
# ZDM360 AUX BEGIN
${lname} =
  (DESCRIPTION_LIST=(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=0.0.0.0)(PORT=${port}))))
SID_LIST_${lname} =
  (SID_LIST=(SID_DESC=(GLOBAL_DBNAME=${TARGET_SERVICE})(ORACLE_HOME=${TARGET_ORACLE_HOME})(SID_NAME=${TARGET_SID})))
# ZDM360 AUX END
LST
mv '$file.zdm360' '$file'; chmod 600 '$file'; export ORACLE_HOME='$TARGET_ORACLE_HOME'; export PATH=\$ORACLE_HOME/bin:\$PATH; lsnrctl stop '$lname' >/dev/null 2>&1 || true; lsnrctl start '$lname'; lsnrctl status '$lname'"
}

tns_validate_matrix(){
  for spec in \
    "$SOURCE_OS_USER|$SOURCE_HOST|$SOURCE_ORACLE_HOME|$SOURCE_TNS_ALIAS" \
    "$SOURCE_OS_USER|$SOURCE_HOST|$SOURCE_ORACLE_HOME|$TARGET_TNS_ALIAS" \
    "$TARGET_OS_USER|$TARGET_HOST|$TARGET_ORACLE_HOME|$SOURCE_TNS_ALIAS" \
    "$TARGET_OS_USER|$TARGET_HOST|$TARGET_ORACLE_HOME|$TARGET_TNS_ALIAS"; do
    IFS='|' read -r u h oh a <<<"$spec"
    tnsping_remote "$u" "$h" "$oh" "$a"
  done
}

sysdba_connectivity_validate(){
  require_var SOURCE_SYS_PASSWORD
  require_var TARGET_SYS_PASSWORD
  local test_script
  test_script="set pages 0 feedback off heading off\nconnect sys/\"${SOURCE_SYS_PASSWORD}\"@${SOURCE_TNS_ALIAS} as sysdba\nselect 'SOURCE_SYSDBA_OK' from dual;\nconnect sys/\"${TARGET_SYS_PASSWORD}\"@${TARGET_TNS_ALIAS} as sysdba\nselect 'TARGET_SYSDBA_OK' from dual;\nexit\n"
  printf '%b' "$test_script" | ssh "$TARGET_OS_USER@$TARGET_HOST" "export ORACLE_HOME='$TARGET_ORACLE_HOME'; export PATH=\$ORACLE_HOME/bin:\$PATH; sqlplus -L -s /nolog"
}
