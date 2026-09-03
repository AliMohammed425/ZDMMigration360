#!/usr/bin/env bash
set -euo pipefail

# Supported zdm360PH.drv keys.  Keep this list explicit so the driver file
# cannot execute arbitrary shell code.
ZDM360_DRV_ALLOWED_KEYS="
SOURCE_DB_NAME
SOURCE_DB_UNIQUE_NAME
SOURCE_SID
SOURCE_HOST
SOURCE_OS_USER
SOURCE_ORACLE_HOME
SOURCE_LISTENER_PORT
SOURCE_SERVICE
SOURCE_IS_CDB
SOURCE_TNS_ALIAS
SOURCE_SYS_PASSWORD

TARGET_DB_NAME
TARGET_DB_UNIQUE_NAME
TARGET_SID
TARGET_HOST
TARGET_OS_USER
TARGET_PROVISION_OS_USER
TARGET_ORACLE_HOME
TARGET_LISTENER_PORT
TARGET_AUX_PORT
TARGET_AUX_LISTENER_NAME
TARGET_SERVICE
TARGET_TNS_ALIAS
TARGET_ADMIN_PASSWORD
TARGET_SYS_PASSWORD

OCI_TARGET_PLATFORM
TARGET_DB_CREATE_FILE_DEST
TARGET_DB_RECOVERY_FILE_DEST
TARGET_DB_RECOVERY_FILE_DEST_SIZE

STANDBY_BUILD_METHOD
SOURCE_BACKUP_STAGE
TARGET_BACKUP_STAGE
BACKUP_COPY_METHOD

TARGET_RAC_ENABLED
TARGET_RAC_INSTANCES
TARGET_GRID_HOME
TARGET_UNDO_PREFIX
TARGET_REDO_SIZE_MB
RAC_CONVERSION_MODE

SYNC_WAIT_SECONDS
SYNC_POLL_SECONDS
SOURCE_TDE_WALLET_PATH
TARGET_TDE_WALLET_PATH
DG_ARCHIVE_DEST_ID
FULL_BUILD_BACKGROUND
"

drv_key_allowed(){
  local key="$1"
  grep -qx "$key" <<<"$ZDM360_DRV_ALLOWED_KEYS"
}

drv_trim(){
  local v="$1"
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  printf '%s' "$v"
}

drv_unquote(){
  local v="$1"
  if [[ ${#v} -ge 2 ]]; then
    if [[ "${v:0:1}" == '"' && "${v: -1}" == '"' ]]; then
      v="${v:1:${#v}-2}"
    elif [[ "${v:0:1}" == "'" && "${v: -1}" == "'" ]]; then
      v="${v:1:${#v}-2}"
    fi
  fi
  printf '%s' "$v"
}

load_driver_file(){
  local file="$1"
  [[ -f "$file" ]] || die "Driver file not found: $file"
  [[ -r "$file" ]] || die "Driver file is not readable: $file"

  local line key value lineno=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno+1))
    line="${line%$'\r'}"
    line="$(drv_trim "$line")"

    [[ -z "$line" ]] && continue
    [[ "$line" == \#* ]] && continue
    [[ "$line" == \;* ]] && continue

    [[ "$line" == *=* ]] ||
      die "Invalid driver-file line $lineno: expected KEY=VALUE"

    key="$(drv_trim "${line%%=*}")"
    value="$(drv_trim "${line#*=}")"

    [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] ||
      die "Invalid driver-file key '$key' at line $lineno"

    drv_key_allowed "$key" ||
      die "Unsupported driver-file key '$key' at line $lineno"

    value="$(drv_unquote "$value")"

    # A blank secret in the driver must not erase a protected credential that
    # was injected through the environment for background/non-interactive use.
    if [[ "$key" == *_PASSWORD && -z "$value" && -n "${!key:-}" ]]; then
      continue
    fi
    printf -v "$key" '%s' "$value"
    export "$key"
  done < "$file"

  export ZDM360_DRIVER_FILE="$file"
}

driver_has_required_inputs(){
  local vars=(SOURCE_DB_NAME SOURCE_DB_UNIQUE_NAME SOURCE_SID SOURCE_HOST SOURCE_OS_USER SOURCE_ORACLE_HOME SOURCE_SERVICE SOURCE_TNS_ALIAS TARGET_DB_NAME TARGET_DB_UNIQUE_NAME TARGET_SID TARGET_HOST TARGET_OS_USER TARGET_ORACLE_HOME TARGET_SERVICE TARGET_TNS_ALIAS STANDBY_BUILD_METHOD)
  local v
  for v in "${vars[@]}"; do [[ -n "${!v:-}" ]] || return 1; done
  [[ "$SOURCE_DB_NAME" == "$TARGET_DB_NAME" ]] || return 1
  [[ "$SOURCE_DB_UNIQUE_NAME" != "$TARGET_DB_UNIQUE_NAME" ]] || return 1
  return 0
}

validate_driver_file(){
  local file="$1"
  local tmp_out
  (
    set -euo pipefail
    load_driver_file "$file"
    validate_full_build_inputs
  )
}

print_driver_file_summary(){
  local file="${ZDM360_DRIVER_FILE:-}"
  [[ -n "$file" ]] || return 0
  echo "Driver file     : $file"
  echo "Source database : ${SOURCE_DB_NAME:-}"
  echo "Source unique   : ${SOURCE_DB_UNIQUE_NAME:-}"
  echo "Source host     : ${SOURCE_HOST:-}"
  echo "Target database : ${TARGET_DB_NAME:-}"
  echo "Target unique   : ${TARGET_DB_UNIQUE_NAME:-}"
  echo "Target host     : ${TARGET_HOST:-}"
  echo "Build method    : ${STANDBY_BUILD_METHOD:-}"
  echo "RAC target      : ${TARGET_RAC_ENABLED:-NO}"
}

create_driver_template(){
  local out="${1:-$ZDM360_ROOT/conf/zdm360PH.drv}"
  umask 077
  cat > "$out" <<'EOF'
# ==============================================================================
# ZDMMigration360 Physical Standby Driver File
# File name: zdm360PH.drv
#
# Format: KEY=VALUE
# Blank lines and lines beginning with # or ; are ignored.
# This file is parsed as DATA, not sourced as shell code.
#
# Protect this file with chmod 600 if it contains passwords.
# Prefer a secret manager/environment for production credentials.
# ==============================================================================

# SOURCE DATABASE
SOURCE_DB_NAME=ORCL
SOURCE_DB_UNIQUE_NAME=ORCLPRD
SOURCE_SID=ORCL1
SOURCE_HOST=primary01
SOURCE_OS_USER=oracle
SOURCE_ORACLE_HOME=/u01/app/oracle/product/19.0.0/dbhome_1
SOURCE_LISTENER_PORT=1521
SOURCE_SERVICE=ORCLPRD
SOURCE_IS_CDB=YES
SOURCE_TNS_ALIAS=ORCLPRD_SRC

# Optional runtime secret. Environment/secret manager is preferred.
SOURCE_SYS_PASSWORD=

# TARGET OCI DATABASE / PLACEHOLDER
TARGET_DB_NAME=ORCL
TARGET_DB_UNIQUE_NAME=ORCLSTBY
TARGET_SID=ORCL1
TARGET_HOST=standby01
TARGET_OS_USER=oracle
TARGET_PROVISION_OS_USER=opc
TARGET_ORACLE_HOME=/u01/app/oracle/product/19.0.0/dbhome_1
TARGET_LISTENER_PORT=1521
TARGET_AUX_PORT=1529
TARGET_AUX_LISTENER_NAME=LISTENER_ZDM360
TARGET_SERVICE=ORCLSTBY
TARGET_TNS_ALIAS=ORCLSTBY_TGT

# Optional runtime secrets.
TARGET_SYS_PASSWORD=
TARGET_ADMIN_PASSWORD=

# OCI PLATFORM
# AUTO | BASE_DB_SERVICE_DBCLI | GENERIC_OCI_OR_SELF_MANAGED
OCI_TARGET_PLATFORM=AUTO

# STORAGE
TARGET_DB_CREATE_FILE_DEST=+DATA
TARGET_DB_RECOVERY_FILE_DEST=+RECO
TARGET_DB_RECOVERY_FILE_DEST_SIZE=500G

# STANDBY BUILD
# ACTIVE_DUPLICATE | OFFLINE_BACKUP
STANDBY_BUILD_METHOD=ACTIVE_DUPLICATE

# OFFLINE BACKUP SETTINGS
SOURCE_BACKUP_STAGE=
TARGET_BACKUP_STAGE=
# SCP | RSYNC | NFS
BACKUP_COPY_METHOD=SCP

# TARGET RAC
TARGET_RAC_ENABLED=NO
TARGET_RAC_INSTANCES=2
TARGET_GRID_HOME=
TARGET_UNDO_PREFIX=UNDOTBS
TARGET_REDO_SIZE_MB=0
# VALIDATE_ONLY is production-safe. LEGACY_AUTOFIX requires site approval.
RAC_CONVERSION_MODE=VALIDATE_ONLY

# DATA GUARD SYNCHRONIZATION
SYNC_WAIT_SECONDS=1800
SYNC_POLL_SECONDS=15

# TDE (required only when encrypted tablespaces are detected)
SOURCE_TDE_WALLET_PATH=
TARGET_TDE_WALLET_PATH=

# Optional fixed source LOG_ARCHIVE_DEST_n. Blank = auto-select unused 2..31.
DG_ARCHIVE_DEST_ID=

# YES = background when complete-build uses the driver file.
FULL_BUILD_BACKGROUND=YES
EOF
  chmod 600 "$out"
  echo "Created driver template: $out"
}

write_driver_file(){
  local out="${1:-$ZDM360_ROOT/conf/zdm360PH.drv}"
  umask 077
  cat > "$out" <<EOF2
# Generated by ZDMMigration360. Secrets intentionally omitted.
SOURCE_DB_NAME=${SOURCE_DB_NAME:-}
SOURCE_DB_UNIQUE_NAME=${SOURCE_DB_UNIQUE_NAME:-}
SOURCE_SID=${SOURCE_SID:-}
SOURCE_HOST=${SOURCE_HOST:-}
SOURCE_OS_USER=${SOURCE_OS_USER:-oracle}
SOURCE_ORACLE_HOME=${SOURCE_ORACLE_HOME:-}
SOURCE_LISTENER_PORT=${SOURCE_LISTENER_PORT:-1521}
SOURCE_SERVICE=${SOURCE_SERVICE:-}
SOURCE_IS_CDB=${SOURCE_IS_CDB:-YES}
SOURCE_TNS_ALIAS=${SOURCE_TNS_ALIAS:-}
SOURCE_SYS_PASSWORD=
TARGET_DB_NAME=${TARGET_DB_NAME:-}
TARGET_DB_UNIQUE_NAME=${TARGET_DB_UNIQUE_NAME:-}
TARGET_SID=${TARGET_SID:-}
TARGET_HOST=${TARGET_HOST:-}
TARGET_OS_USER=${TARGET_OS_USER:-oracle}
TARGET_PROVISION_OS_USER=${TARGET_PROVISION_OS_USER:-opc}
TARGET_ORACLE_HOME=${TARGET_ORACLE_HOME:-}
TARGET_LISTENER_PORT=${TARGET_LISTENER_PORT:-1521}
TARGET_AUX_PORT=${TARGET_AUX_PORT:-1529}
TARGET_AUX_LISTENER_NAME=${TARGET_AUX_LISTENER_NAME:-LISTENER_ZDM360}
TARGET_SERVICE=${TARGET_SERVICE:-}
TARGET_TNS_ALIAS=${TARGET_TNS_ALIAS:-}
TARGET_SYS_PASSWORD=
TARGET_ADMIN_PASSWORD=
OCI_TARGET_PLATFORM=${OCI_TARGET_PLATFORM:-AUTO}
TARGET_DB_CREATE_FILE_DEST=${TARGET_DB_CREATE_FILE_DEST:-}
TARGET_DB_RECOVERY_FILE_DEST=${TARGET_DB_RECOVERY_FILE_DEST:-}
TARGET_DB_RECOVERY_FILE_DEST_SIZE=${TARGET_DB_RECOVERY_FILE_DEST_SIZE:-}
STANDBY_BUILD_METHOD=${STANDBY_BUILD_METHOD:-ACTIVE_DUPLICATE}
SOURCE_BACKUP_STAGE=${SOURCE_BACKUP_STAGE:-}
TARGET_BACKUP_STAGE=${TARGET_BACKUP_STAGE:-}
BACKUP_COPY_METHOD=${BACKUP_COPY_METHOD:-SCP}
TARGET_RAC_ENABLED=${TARGET_RAC_ENABLED:-NO}
TARGET_RAC_INSTANCES=${TARGET_RAC_INSTANCES:-2}
TARGET_GRID_HOME=${TARGET_GRID_HOME:-}
TARGET_UNDO_PREFIX=${TARGET_UNDO_PREFIX:-UNDOTBS}
TARGET_REDO_SIZE_MB=${TARGET_REDO_SIZE_MB:-0}
RAC_CONVERSION_MODE=${RAC_CONVERSION_MODE:-VALIDATE_ONLY}
SYNC_WAIT_SECONDS=${SYNC_WAIT_SECONDS:-1800}
SYNC_POLL_SECONDS=${SYNC_POLL_SECONDS:-15}
SOURCE_TDE_WALLET_PATH=${SOURCE_TDE_WALLET_PATH:-}
TARGET_TDE_WALLET_PATH=${TARGET_TDE_WALLET_PATH:-}
DG_ARCHIVE_DEST_ID=${DG_ARCHIVE_DEST_ID:-}
FULL_BUILD_BACKGROUND=${FULL_BUILD_BACKGROUND:-YES}
EOF2
  chmod 600 "$out"
  echo "Driver saved: $out (secrets omitted)"
}
