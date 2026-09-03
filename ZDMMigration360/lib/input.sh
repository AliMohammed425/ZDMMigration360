#!/usr/bin/env bash
set -euo pipefail

prompt_value(){
  local var="$1" label="$2" default="${3:-}"
  local cur="${!var:-}"
  [[ -n "$cur" ]] && return 0
  local suffix=""
  [[ -n "$default" ]] && suffix=" [$default]"
  read -r -p "$label$suffix: " val
  val="${val:-$default}"
  printf -v "$var" '%s' "$val"
  export "$var"
}

prompt_secret(){
  local var="$1" label="$2"
  [[ -n "${!var:-}" ]] && return 0
  local val
  read -r -s -p "$label: " val
  echo
  printf -v "$var" '%s' "$val"
  export "$var"
}

prompt_yesno(){
  local var="$1" label="$2" default="${3:-YES}"
  prompt_value "$var" "$label [YES|NO]" "$default"
  local val="${!var}"
  val="${val^^}"
  [[ "$val" == "YES" || "$val" == "NO" ]] || die "$var must be YES or NO."
  printf -v "$var" '%s' "$val"
  export "$var"
}

prompt_choice(){
  local var="$1" label="$2" allowed="$3" default="$4"
  prompt_value "$var" "$label [$allowed]" "$default"
  local val="${!var}"
  val="${val^^}"
  case "|$allowed|" in
    *"|$val|"*) ;;
    *) die "$var must be one of: ${allowed//|/, }" ;;
  esac
  printf -v "$var" '%s' "$val"
  export "$var"
}

collect_full_build_inputs(){
  echo
  echo "======================================================================"
  echo " ZDMMigration360 - OCI Standby Complete Build Wizard"
  echo "======================================================================"
  echo "This wizard collects inputs, creates the OCI placeholder, performs the"
  echo "RMAN standby build, optionally enables RAC, validates Data Guard, and"
  echo "waits for redo synchronization."
  echo

  echo "SOURCE DATABASE"
  echo "---------------"
  prompt_value SOURCE_DB_NAME "Source DB_NAME"
  prompt_value SOURCE_DB_UNIQUE_NAME "Source DB_UNIQUE_NAME"
  prompt_value SOURCE_SID "Source ORACLE_SID" "$SOURCE_DB_NAME"
  prompt_value SOURCE_HOST "Source hostname / SCAN / IP"
  prompt_value SOURCE_OS_USER "Source OS user" "oracle"
  prompt_value SOURCE_ORACLE_HOME "Source ORACLE_HOME"
  prompt_value SOURCE_LISTENER_PORT "Source listener port" "1521"
  prompt_value SOURCE_SERVICE "Source service name"
  prompt_yesno SOURCE_IS_CDB "Is source a CDB?" "YES"
  prompt_value SOURCE_TNS_ALIAS "Source TNS alias" "${SOURCE_DB_UNIQUE_NAME}_SRC"

  echo
  echo "TARGET OCI PLACEHOLDER"
  echo "----------------------"
  prompt_value TARGET_DB_NAME "Target DB_NAME" "$SOURCE_DB_NAME"
  [[ "$TARGET_DB_NAME" == "$SOURCE_DB_NAME" ]] ||
    die "Physical standby target DB_NAME must match source DB_NAME."
  prompt_value TARGET_DB_UNIQUE_NAME "Target DB_UNIQUE_NAME"
  [[ "$TARGET_DB_UNIQUE_NAME" != "$SOURCE_DB_UNIQUE_NAME" ]] ||
    die "Target DB_UNIQUE_NAME must differ from source DB_UNIQUE_NAME."
  prompt_value TARGET_SID "Target initial ORACLE_SID" "$TARGET_DB_NAME"
  prompt_value TARGET_HOST "Target OCI hostname / SCAN / IP"
  prompt_value TARGET_OS_USER "Target Oracle OS user" "oracle"
  prompt_value TARGET_PROVISION_OS_USER "OCI provisioning OS user" "opc"
  prompt_value TARGET_ORACLE_HOME "Target ORACLE_HOME"
  prompt_value TARGET_LISTENER_PORT "Target listener port" "1521"
  prompt_value TARGET_AUX_PORT "Dedicated RMAN auxiliary listener port" "1529"
  prompt_value TARGET_AUX_LISTENER_NAME "Dedicated RMAN auxiliary listener name" "LISTENER_ZDM360"
  prompt_value TARGET_SERVICE "Target service name"
  prompt_value TARGET_TNS_ALIAS "Target TNS alias" "${TARGET_DB_UNIQUE_NAME}_TGT"

  echo
  echo "OCI PLATFORM"
  echo "------------"
  echo "AUTO detects OCI Base Database Service dbcli when available."
  prompt_choice OCI_TARGET_PLATFORM "OCI target platform" \
    "AUTO|BASE_DB_SERVICE_DBCLI|GENERIC_OCI_OR_SELF_MANAGED" "AUTO"

  if [[ "$OCI_TARGET_PLATFORM" == "BASE_DB_SERVICE_DBCLI" || "$OCI_TARGET_PLATFORM" == "AUTO" ]]; then
    echo
    echo "OCI Base Database Service placeholder creation may require an admin"
    echo "password. The password is kept only in this process environment and"
    echo "is not written to the generated configuration file."
    prompt_secret TARGET_ADMIN_PASSWORD "Target placeholder admin password"
  fi

  echo
  echo "STORAGE"
  echo "-------"
  prompt_value TARGET_DB_CREATE_FILE_DEST "Target DB_CREATE_FILE_DEST / ASM disk group (optional)"
  prompt_value TARGET_DB_RECOVERY_FILE_DEST "Target DB_RECOVERY_FILE_DEST / FRA (optional)"
  prompt_value TARGET_DB_RECOVERY_FILE_DEST_SIZE "Target FRA size, e.g. 500G (optional)"

  echo
  echo "STANDBY BUILD METHOD"
  echo "--------------------"
  prompt_choice STANDBY_BUILD_METHOD "Build method" "ACTIVE_DUPLICATE|OFFLINE_BACKUP" "ACTIVE_DUPLICATE"

  echo
  echo "SYS PASSWORD"
  echo "------------"
  echo "The standby password file credential must match the primary."
  prompt_secret SOURCE_SYS_PASSWORD "Source SYS password"
  prompt_secret TARGET_SYS_PASSWORD "Target SYS password"
  [[ "$SOURCE_SYS_PASSWORD" == "$TARGET_SYS_PASSWORD" ]] ||
    die "Source and target SYS passwords must match for this standby workflow."

  if [[ "$STANDBY_BUILD_METHOD" == "OFFLINE_BACKUP" ]]; then
    echo
    echo "OFFLINE RMAN BACKUP"
    echo "-------------------"
    prompt_value SOURCE_BACKUP_STAGE "Source backup stage directory"
    prompt_value TARGET_BACKUP_STAGE "Target backup stage directory"
    prompt_choice BACKUP_COPY_METHOD "Backup staging method" "SCP|RSYNC|NFS" "SCP"
  fi

  echo
  echo "TARGET RAC STANDBY"
  echo "------------------"
  prompt_yesno TARGET_RAC_ENABLED "Run target standby as RAC after restore?" "NO"
  if [[ "$TARGET_RAC_ENABLED" == "YES" ]]; then
    prompt_value TARGET_RAC_INSTANCES "Target RAC instance count" "2"
    prompt_value TARGET_GRID_HOME "Target GRID_HOME"
    prompt_value TARGET_UNDO_PREFIX "Undo tablespace prefix" "UNDOTBS"
    prompt_value TARGET_REDO_SIZE_MB "Redo size MB (0 = derive)" "0"
  fi

  echo
  echo "TDE / KEYSTORE (optional unless source uses encrypted tablespaces)"
  echo "--------------------------------------------------------------"
  prompt_value SOURCE_TDE_WALLET_PATH "Source TDE wallet/keystore path (blank if none)"
  prompt_value TARGET_TDE_WALLET_PATH "Target TDE wallet/keystore path (normally same absolute path)"

  echo
  echo "DATA GUARD SYNCHRONIZATION"
  echo "--------------------------"
  prompt_value SYNC_WAIT_SECONDS "Maximum synchronization wait seconds" "1800"
  prompt_value SYNC_POLL_SECONDS "Synchronization poll seconds" "15"

  echo
  echo "EXECUTION"
  echo "---------"
  prompt_yesno FULL_BUILD_BACKGROUND "Submit RMAN/full build as background job?" "YES"

  validate_full_build_inputs
}

validate_full_build_inputs(){
  local required=(
    SOURCE_DB_NAME SOURCE_DB_UNIQUE_NAME SOURCE_SID SOURCE_HOST SOURCE_OS_USER SOURCE_ORACLE_HOME
    SOURCE_SERVICE TARGET_DB_NAME TARGET_DB_UNIQUE_NAME TARGET_SID TARGET_HOST TARGET_OS_USER
    TARGET_ORACLE_HOME TARGET_SERVICE STANDBY_BUILD_METHOD
  )
  local v
  for v in "${required[@]}"; do
    [[ -n "${!v:-}" ]] || die "$v is required."
  done

  [[ "$SOURCE_DB_NAME" == "$TARGET_DB_NAME" ]] ||
    die "SOURCE_DB_NAME and TARGET_DB_NAME must match for a physical standby."
  [[ "$SOURCE_DB_UNIQUE_NAME" != "$TARGET_DB_UNIQUE_NAME" ]] ||
    die "Source and target DB_UNIQUE_NAME must differ."
}

write_runtime_config(){
  local out="${1:-$ZDM360_ROOT/conf/standby.env}"
  umask 077
  mkdir -p "$(dirname "$out")"
  cat > "$out" <<EOF
# Generated by ZDMMigration360 Complete Build Wizard
# Secrets are intentionally NOT stored in this file.

SOURCE_DB_NAME='$SOURCE_DB_NAME'
SOURCE_DB_UNIQUE_NAME='$SOURCE_DB_UNIQUE_NAME'
SOURCE_SID='$SOURCE_SID'
SOURCE_HOST='$SOURCE_HOST'
SOURCE_OS_USER='$SOURCE_OS_USER'
SOURCE_ORACLE_HOME='$SOURCE_ORACLE_HOME'
SOURCE_LISTENER_PORT='${SOURCE_LISTENER_PORT:-1521}'
SOURCE_SERVICE='$SOURCE_SERVICE'
SOURCE_IS_CDB='${SOURCE_IS_CDB:-YES}'
SOURCE_TNS_ALIAS='${SOURCE_TNS_ALIAS:-${SOURCE_DB_UNIQUE_NAME}_SRC}'

TARGET_DB_NAME='$TARGET_DB_NAME'
TARGET_DB_UNIQUE_NAME='$TARGET_DB_UNIQUE_NAME'
TARGET_SID='$TARGET_SID'
TARGET_HOST='$TARGET_HOST'
TARGET_OS_USER='$TARGET_OS_USER'
TARGET_PROVISION_OS_USER='${TARGET_PROVISION_OS_USER:-opc}'
TARGET_ORACLE_HOME='$TARGET_ORACLE_HOME'
TARGET_LISTENER_PORT='${TARGET_LISTENER_PORT:-1521}'
TARGET_AUX_PORT='${TARGET_AUX_PORT:-1529}'
TARGET_AUX_LISTENER_NAME='${TARGET_AUX_LISTENER_NAME:-LISTENER_ZDM360}'
TARGET_SERVICE='$TARGET_SERVICE'
TARGET_TNS_ALIAS='${TARGET_TNS_ALIAS:-${TARGET_DB_UNIQUE_NAME}_TGT}'

OCI_TARGET_PLATFORM='${OCI_TARGET_PLATFORM:-AUTO}'
TARGET_DB_CREATE_FILE_DEST='${TARGET_DB_CREATE_FILE_DEST:-}'
TARGET_DB_RECOVERY_FILE_DEST='${TARGET_DB_RECOVERY_FILE_DEST:-}'
TARGET_DB_RECOVERY_FILE_DEST_SIZE='${TARGET_DB_RECOVERY_FILE_DEST_SIZE:-}'

STANDBY_BUILD_METHOD='$STANDBY_BUILD_METHOD'
SOURCE_BACKUP_STAGE='${SOURCE_BACKUP_STAGE:-}'
TARGET_BACKUP_STAGE='${TARGET_BACKUP_STAGE:-}'
BACKUP_COPY_METHOD='${BACKUP_COPY_METHOD:-SCP}'

TARGET_RAC_ENABLED='${TARGET_RAC_ENABLED:-NO}'
TARGET_RAC_INSTANCES='${TARGET_RAC_INSTANCES:-2}'
TARGET_GRID_HOME='${TARGET_GRID_HOME:-}'
TARGET_UNDO_PREFIX='${TARGET_UNDO_PREFIX:-UNDOTBS}'
TARGET_REDO_SIZE_MB='${TARGET_REDO_SIZE_MB:-0}'

SYNC_WAIT_SECONDS='${SYNC_WAIT_SECONDS:-1800}'
SYNC_POLL_SECONDS='${SYNC_POLL_SECONDS:-15}'
SOURCE_TDE_WALLET_PATH='${SOURCE_TDE_WALLET_PATH:-}'
TARGET_TDE_WALLET_PATH='${TARGET_TDE_WALLET_PATH:-}'
DG_ARCHIVE_DEST_ID='${DG_ARCHIVE_DEST_ID:-}'
EOF
  chmod 600 "$out"
  echo "Non-secret configuration saved: $out"
}
