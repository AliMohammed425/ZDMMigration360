#!/usr/bin/env bash
set -euo pipefail

MODE="${MODE:-interactive}"
EXECUTE="${EXECUTE:-false}"
CONFIG_FILE="${CONFIG_FILE:-./standby_placeholder.env}"

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
die() { log "ERROR: $*"; exit 1; }

prompt() {
  local var="$1" text="$2" default="${3:-}"
  local cur="${!var:-}"
  [[ -n "$cur" ]] && return
  if [[ "$MODE" != "interactive" ]]; then
    [[ -n "$default" ]] && printf -v "$var" '%s' "$default"
    return
  fi
  local ans=""
  if [[ -n "$default" ]]; then
    read -r -p "$text [$default]: " ans
    printf -v "$var" '%s' "${ans:-$default}"
  else
    read -r -p "$text: " ans
    printf -v "$var" '%s' "$ans"
  fi
}


secret_prompt() {
  local var="$1" text="$2"
  [[ -n "${!var:-}" ]] && return
  if [[ "$MODE" != "interactive" ]]; then
    return
  fi
  local ans=""
  read -r -s -p "$text: " ans
  echo
  printf -v "$var" '%s' "$ans"
}

run() {
  if [[ "$EXECUTE" == "true" ]]; then
    log "EXEC: $*"
    eval "$@"
  else
    log "DRY-RUN: $*"
  fi
}

echo "================================================================================"
echo " ZDMMigration360 - Create Placeholder Oracle Database / Build OCI Standby"
echo "================================================================================"
echo "Collect source/target identity, create TNS aliases, copy the password file,"
echo "then test connectivity before standby build."
echo

prompt SOURCE_DB_NAME        "Source database DB_NAME"
prompt SOURCE_DB_UNIQUE_NAME "Source database DB_UNIQUE_NAME"
prompt SOURCE_SID            "Source Oracle SID" "${SOURCE_DB_NAME:-}"
prompt SOURCE_HOST           "Source hostname / SCAN / IP"
prompt SOURCE_PORT           "Source listener port" "1521"
prompt SOURCE_SERVICE        "Source service name"
prompt SOURCE_OS_USER        "Source OS user" "oracle"
prompt SOURCE_ORACLE_HOME    "Source ORACLE_HOME"
secret_prompt SOURCE_SYS_PASSWORD "Source SYS password (hidden input)"
secret_prompt SOURCE_TDE_PASSWORD "Source TDE wallet/keystore password (hidden input)"

prompt TARGET_DB_NAME        "Target database DB_NAME" "${SOURCE_DB_NAME:-}"
prompt TARGET_DB_UNIQUE_NAME "Target database DB_UNIQUE_NAME (must differ from source)"
prompt TARGET_SID            "Target Oracle SID" "${TARGET_DB_NAME:-}"
prompt TARGET_HOST           "Target OCI hostname / SCAN / IP"
prompt TARGET_PORT           "Target listener port" "1521"
prompt TARGET_SERVICE        "Target service name"
prompt TARGET_OS_USER        "Target OS user" "oracle"
prompt TARGET_ORACLE_HOME    "Target ORACLE_HOME"
secret_prompt TARGET_SYS_PASSWORD "Target SYS password (hidden input; should match source)"
secret_prompt TARGET_TDE_PASSWORD "Target TDE wallet/keystore password (hidden input; should match source)"

prompt TARGET_DB_CREATE_FILE_DEST "Target DB_CREATE_FILE_DEST for non-RAC standby (blank = keep RMAN/SPFILE value)"
prompt TARGET_DB_RECOVERY_FILE_DEST "Target DB_RECOVERY_FILE_DEST/FRA (blank = keep RMAN/SPFILE value)"
prompt RMAN_PRIMARY_CHANNELS "RMAN primary channels" "2"
prompt RMAN_AUX_CHANNELS "RMAN auxiliary channels" "2"

prompt TARGET_RAC_ENABLED "Run target standby as RAC after restore? [YES|NO]" "YES"
TARGET_RAC_ENABLED="$(printf '%s' "$TARGET_RAC_ENABLED" | tr '[:lower:]' '[:upper:]')"
case "$TARGET_RAC_ENABLED" in
  YES|NO) ;;
  *) die "TARGET_RAC_ENABLED must be YES or NO." ;;
esac

if [[ "$TARGET_RAC_ENABLED" == "YES" ]]; then
  prompt TARGET_RAC_INSTANCES "Target RAC instance count" "2"
  prompt TARGET_GRID_HOME "Target GRID_HOME"
  prompt TARGET_UNDO_PREFIX "RAC undo tablespace prefix" "UNDOTBS"
  prompt TARGET_REDO_SIZE_MB "Redo size MB (0 = use largest restored online redo size)" "0"
fi

prompt DG_POSTBUILD_VALIDATE "Run Data Guard health and synchronization validation after build? [YES|NO]" "YES"
DG_POSTBUILD_VALIDATE="$(printf '%s' "$DG_POSTBUILD_VALIDATE" | tr '[:lower:]' '[:upper:]')"
case "$DG_POSTBUILD_VALIDATE" in
  YES|NO) ;;
  *) die "DG_POSTBUILD_VALIDATE must be YES or NO." ;;
esac

prompt STANDBY_BUILD_METHOD "Standby build method [ACTIVE_DUPLICATE|OFFLINE_BACKUP]" "ACTIVE_DUPLICATE"
STANDBY_BUILD_METHOD="$(printf '%s' "$STANDBY_BUILD_METHOD" | tr '[:lower:]' '[:upper:]')"
case "$STANDBY_BUILD_METHOD" in
  ACTIVE_DUPLICATE|OFFLINE_BACKUP) ;;
  *) die "STANDBY_BUILD_METHOD must be ACTIVE_DUPLICATE or OFFLINE_BACKUP." ;;
esac

if [[ "$STANDBY_BUILD_METHOD" == "OFFLINE_BACKUP" ]]; then
  prompt SOURCE_BACKUP_STAGE "Source RMAN backup stage directory"
  prompt TARGET_BACKUP_STAGE "Target RMAN backup stage directory" "$SOURCE_BACKUP_STAGE"
  prompt BACKUP_COPY_METHOD "Backup staging method [SCP|RSYNC|NFS]" "SCP"
  BACKUP_COPY_METHOD="$(printf '%s' "$BACKUP_COPY_METHOD" | tr '[:lower:]' '[:upper:]')"
  case "$BACKUP_COPY_METHOD" in
    SCP|RSYNC|NFS) ;;
    *) die "BACKUP_COPY_METHOD must be SCP, RSYNC, or NFS." ;;
  esac
fi

for v in SOURCE_DB_NAME SOURCE_DB_UNIQUE_NAME SOURCE_HOST SOURCE_SERVICE SOURCE_ORACLE_HOME \
         TARGET_DB_NAME TARGET_DB_UNIQUE_NAME TARGET_HOST TARGET_SERVICE TARGET_ORACLE_HOME; do
  [[ -n "${!v:-}" ]] || die "$v is required"
done

[[ "$SOURCE_DB_UNIQUE_NAME" != "$TARGET_DB_UNIQUE_NAME" ]] || \
  die "Target DB_UNIQUE_NAME must be different from source DB_UNIQUE_NAME"

if [[ "$SOURCE_DB_NAME" != "$TARGET_DB_NAME" ]]; then
  log "WARN: Source DB_NAME ($SOURCE_DB_NAME) differs from target DB_NAME ($TARGET_DB_NAME)."
  log "      For a standard physical standby, DB_NAME is normally the same."
fi

SOURCE_TNS_ADMIN="${SOURCE_TNS_ADMIN:-$SOURCE_ORACLE_HOME/network/admin}"
TARGET_TNS_ADMIN="${TARGET_TNS_ADMIN:-$TARGET_ORACLE_HOME/network/admin}"

SOURCE_PWFILE="${SOURCE_PWFILE:-$SOURCE_ORACLE_HOME/dbs/orapw$SOURCE_SID}"
TARGET_PWFILE="${TARGET_PWFILE:-$TARGET_ORACLE_HOME/dbs/orapw$TARGET_SID}"

SOURCE_ALIAS="${SOURCE_ALIAS:-${SOURCE_DB_UNIQUE_NAME}_SRC}"
TARGET_ALIAS="${TARGET_ALIAS:-${TARGET_DB_UNIQUE_NAME}_TGT}"

cat > "$CONFIG_FILE" <<EOF
SOURCE_DB_NAME="$SOURCE_DB_NAME"
SOURCE_DB_UNIQUE_NAME="$SOURCE_DB_UNIQUE_NAME"
SOURCE_SID="$SOURCE_SID"
SOURCE_HOST="$SOURCE_HOST"
SOURCE_PORT="$SOURCE_PORT"
SOURCE_SERVICE="$SOURCE_SERVICE"
SOURCE_OS_USER="$SOURCE_OS_USER"
SOURCE_ORACLE_HOME="$SOURCE_ORACLE_HOME"
SOURCE_TNS_ADMIN="$SOURCE_TNS_ADMIN"
SOURCE_PWFILE="$SOURCE_PWFILE"
SOURCE_ALIAS="$SOURCE_ALIAS"

TARGET_DB_NAME="$TARGET_DB_NAME"
TARGET_DB_UNIQUE_NAME="$TARGET_DB_UNIQUE_NAME"
TARGET_SID="$TARGET_SID"
TARGET_HOST="$TARGET_HOST"
TARGET_PORT="$TARGET_PORT"
TARGET_SERVICE="$TARGET_SERVICE"
TARGET_OS_USER="$TARGET_OS_USER"
TARGET_ORACLE_HOME="$TARGET_ORACLE_HOME"
TARGET_TNS_ADMIN="$TARGET_TNS_ADMIN"
TARGET_PWFILE="$TARGET_PWFILE"
TARGET_ALIAS="$TARGET_ALIAS"
EOF
chmod 600 "$CONFIG_FILE"

# SYS/TDE passwords are intentionally NOT written to the configuration file.
# They exist only in this process environment/memory for the current run.
export SOURCE_SYS_PASSWORD="${SOURCE_SYS_PASSWORD:-}"
export SOURCE_TDE_PASSWORD="${SOURCE_TDE_PASSWORD:-}"
export TARGET_SYS_PASSWORD="${TARGET_SYS_PASSWORD:-}"
export TARGET_TDE_PASSWORD="${TARGET_TDE_PASSWORD:-}"

# Standby credential consistency checks.
if [[ -n "${SOURCE_SYS_PASSWORD:-}" && -n "${TARGET_SYS_PASSWORD:-}" ]]; then
  [[ "$SOURCE_SYS_PASSWORD" == "$TARGET_SYS_PASSWORD" ]] || \
    die "Target SYS password must match source SYS password for this standby build."
fi

if [[ -n "${SOURCE_TDE_PASSWORD:-}" && -n "${TARGET_TDE_PASSWORD:-}" ]]; then
  [[ "$SOURCE_TDE_PASSWORD" == "$TARGET_TDE_PASSWORD" ]] || \
    die "Target TDE wallet/keystore password must match source TDE password for this standby build."
fi

TMPDIR="${TMPDIR:-/tmp}"
TNS_FILE="$TMPDIR/zdm360_tnsnames_$$.ora"

cat > "$TNS_FILE" <<EOF
$SOURCE_ALIAS =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = $SOURCE_HOST)(PORT = $SOURCE_PORT))
    (CONNECT_DATA =
      (SERVER = DEDICATED)
      (SERVICE_NAME = $SOURCE_SERVICE)
    )
  )

$TARGET_ALIAS =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = $TARGET_HOST)(PORT = $TARGET_PORT))
    (CONNECT_DATA =
      (SERVER = DEDICATED)
      (SERVICE_NAME = $TARGET_SERVICE)
    )
  )
EOF

echo
echo "TNS aliases:"
echo "  $SOURCE_ALIAS -> $SOURCE_HOST:$SOURCE_PORT/$SOURCE_SERVICE"
echo "  $TARGET_ALIAS -> $TARGET_HOST:$TARGET_PORT/$TARGET_SERVICE"
echo

echo "STEP 1 - Validate passwordless SSH key prerequisite"
echo "This is a blocking prerequisite for the standby build."
echo

validate_local_ssh() {
  local label="$1" user="$2" host="$3"
  log "Checking toolkit host -> $label ($user@$host)"
  if [[ "$EXECUTE" == "true" ]]; then
    ssh -o BatchMode=yes -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no \
        -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
        "$user@$host" 'echo SSH_KEY_OK; hostname; id -un' >/tmp/zdm360_ssh_check_$$ 2>&1 \
      || { cat /tmp/zdm360_ssh_check_$$; rm -f /tmp/zdm360_ssh_check_$$; die "Passwordless SSH key validation failed to $label ($user@$host)"; }
    cat /tmp/zdm360_ssh_check_$$
    rm -f /tmp/zdm360_ssh_check_$$
  else
    log "DRY-RUN: ssh -o BatchMode=yes -o PasswordAuthentication=no $user@$host"
  fi
}

validate_remote_to_remote_ssh() {
  local from_label="$1" from_user="$2" from_host="$3"
  local to_label="$4" to_user="$5" to_host="$6"

  log "Checking $from_label -> $to_label using SSH keys"
  if [[ "$EXECUTE" == "true" ]]; then
    ssh -o BatchMode=yes -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no \
        -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
        "$from_user@$from_host" \
        "ssh -o BatchMode=yes -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no \
             -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
             '$to_user@$to_host' 'echo BIDIRECTIONAL_SSH_KEY_OK; hostname; id -un'" \
      >/tmp/zdm360_ssh_check_$$ 2>&1 \
      || { cat /tmp/zdm360_ssh_check_$$; rm -f /tmp/zdm360_ssh_check_$$; die "SSH key prerequisite failed: $from_label -> $to_label"; }
    cat /tmp/zdm360_ssh_check_$$
    rm -f /tmp/zdm360_ssh_check_$$
  else
    log "DRY-RUN: $from_label -> $to_label passwordless SSH-key validation"
  fi
}

# Toolkit/control host must first be able to reach both servers.
validate_local_ssh "SOURCE" "$SOURCE_OS_USER" "$SOURCE_HOST"
validate_local_ssh "TARGET" "$TARGET_OS_USER" "$TARGET_HOST"

# Validate server-to-server key trust in both directions.
validate_remote_to_remote_ssh \
  "SOURCE" "$SOURCE_OS_USER" "$SOURCE_HOST" \
  "TARGET" "$TARGET_OS_USER" "$TARGET_HOST"

validate_remote_to_remote_ssh \
  "TARGET" "$TARGET_OS_USER" "$TARGET_HOST" \
  "SOURCE" "$SOURCE_OS_USER" "$SOURCE_HOST"

echo
echo "SSH prerequisite PASSED:"
echo "  Toolkit host -> Source"
echo "  Toolkit host -> Target"
echo "  Source -> Target"
echo "  Target -> Source"
echo
echo "Password authentication is explicitly disabled during these checks."
echo "If any check fails, the standby build stops before TNS/password-file operations."

echo
echo "STEP 2 - Install tnsnames.ora on source and target"
run "scp '$TNS_FILE' '$SOURCE_OS_USER@$SOURCE_HOST:/tmp/zdm360_tnsnames.ora'"
run "ssh '$SOURCE_OS_USER@$SOURCE_HOST' \"mkdir -p '$SOURCE_TNS_ADMIN'; cp '/tmp/zdm360_tnsnames.ora' '$SOURCE_TNS_ADMIN/tnsnames.ora'\""
run "scp '$TNS_FILE' '$TARGET_OS_USER@$TARGET_HOST:/tmp/zdm360_tnsnames.ora'"
run "ssh '$TARGET_OS_USER@$TARGET_HOST' \"mkdir -p '$TARGET_TNS_ADMIN'; cp '/tmp/zdm360_tnsnames.ora' '$TARGET_TNS_ADMIN/tnsnames.ora'\""

echo
echo "STEP 3 - Copy Oracle password file from source to target BEFORE DB connectivity test"
echo "  Source: $SOURCE_PWFILE"
echo "  Target: $TARGET_PWFILE"

run "ssh '$SOURCE_OS_USER@$SOURCE_HOST' \"test -r '$SOURCE_PWFILE'\""
run "ssh '$TARGET_OS_USER@$TARGET_HOST' \"mkdir -p '$TARGET_ORACLE_HOME/dbs'\""

LOCAL_PW_TMP="$TMPDIR/orapw_${SOURCE_SID}_$$"
run "scp '$SOURCE_OS_USER@$SOURCE_HOST:$SOURCE_PWFILE' '$LOCAL_PW_TMP'"
run "scp '$LOCAL_PW_TMP' '$TARGET_OS_USER@$TARGET_HOST:$TARGET_PWFILE'"
run "ssh '$TARGET_OS_USER@$TARGET_HOST' \"chmod 600 '$TARGET_PWFILE'; ls -l '$TARGET_PWFILE'\""
run "rm -f '$LOCAL_PW_TMP'"

echo
echo "STEP 4 - Validate tnsnames.ora on BOTH source and target"

validate_tns_file() {
  local label="$1" user="$2" host="$3" oracle_home="$4" tns_admin="$5"
  local source_alias="$6" target_alias="$7"

  log "Validating $label tnsnames.ora: $tns_admin/tnsnames.ora"

  if [[ "$EXECUTE" == "true" ]]; then
    ssh "$user@$host" "
      set -e
      test -r '$tns_admin/tnsnames.ora'
      echo '--- $label tnsnames.ora ---'
      grep -n -E '^($source_alias|$target_alias)[[:space:]]*=' '$tns_admin/tnsnames.ora'
      grep -q -E '^$source_alias[[:space:]]*=' '$tns_admin/tnsnames.ora'
      grep -q -E '^$target_alias[[:space:]]*=' '$tns_admin/tnsnames.ora'
      export ORACLE_HOME='$oracle_home'
      export TNS_ADMIN='$tns_admin'
      export PATH=\$ORACLE_HOME/bin:\$PATH
      command -v tnsping >/dev/null
      echo 'TNS_FILE_VALIDATION_OK'
    " || die "$label tnsnames.ora validation failed"
  else
    log "DRY-RUN: validate $tns_admin/tnsnames.ora contains $source_alias and $target_alias"
  fi
}

validate_tns_file "SOURCE" "$SOURCE_OS_USER" "$SOURCE_HOST" \
  "$SOURCE_ORACLE_HOME" "$SOURCE_TNS_ADMIN" "$SOURCE_ALIAS" "$TARGET_ALIAS"

validate_tns_file "TARGET" "$TARGET_OS_USER" "$TARGET_HOST" \
  "$TARGET_ORACLE_HOME" "$TARGET_TNS_ADMIN" "$SOURCE_ALIAS" "$TARGET_ALIAS"

echo
echo "STEP 5 - TNSPING all required aliases from BOTH servers"

# Source must resolve/reach itself and target.
run "ssh '$SOURCE_OS_USER@$SOURCE_HOST' \"export ORACLE_HOME='$SOURCE_ORACLE_HOME'; export TNS_ADMIN='$SOURCE_TNS_ADMIN'; export PATH=\\\$ORACLE_HOME/bin:\\\$PATH; tnsping '$SOURCE_ALIAS'; tnsping '$TARGET_ALIAS'\""

# Target must resolve/reach source and itself.
run "ssh '$TARGET_OS_USER@$TARGET_HOST' \"export ORACLE_HOME='$TARGET_ORACLE_HOME'; export TNS_ADMIN='$TARGET_TNS_ADMIN'; export PATH=\\\$ORACLE_HOME/bin:\\\$PATH; tnsping '$SOURCE_ALIAS'; tnsping '$TARGET_ALIAS'\""

echo
echo "Required TNS validation matrix:"
echo "  Source server -> Source alias : $SOURCE_ALIAS"
echo "  Source server -> Target alias : $TARGET_ALIAS"
echo "  Target server -> Source alias : $SOURCE_ALIAS"
echo "  Target server -> Target alias : $TARGET_ALIAS"

echo
echo "Optional secure SQL*Plus tests after tnsping:"
echo "  Source -> Target: sqlplus 'sys@${TARGET_ALIAS} as sysdba'"
echo "  Target -> Source: sqlplus 'sys@${SOURCE_ALIAS} as sysdba'"
echo "Let SQL*Plus prompt for the password. Do not put SYS passwords on the command line."

echo
echo "STEP 6 - Discover existing source Data Guard / standby configuration"

DG_REPORT_LOCAL="${DG_REPORT_LOCAL:-./source_dataguard_inventory.txt}"
DG_SQL_LOCAL="/tmp/zdm360_dg_inventory_$$.sql"

cat > "$DG_SQL_LOCAL" <<'SQL'
set pages 500 lines 240 trimspool on feedback off verify off echo off
column name format a15
column db_unique_name format a30
column database_role format a22
column open_mode format a22
column log_mode format a14
column force_logging format a14
column destination format a45
column target format a12
column status format a12
column error format a55
column dest_name format a24
column valid_now format a12
column db_unique_name2 format a30
column value format a110
column group# format 999999
column thread# format 999
column sequence# format 999999999
column bytes_mb format 999999
column member format a90

prompt ============================================================
prompt SOURCE DATABASE IDENTITY / ROLE
prompt ============================================================
select name,
       db_unique_name,
       database_role,
       open_mode,
       log_mode,
       force_logging
from v$database;

prompt
prompt ============================================================
prompt ARCHIVE LOG / LOG_ARCHIVE_DEST CONFIGURATION
prompt ============================================================
select dest_id,
       dest_name,
       status,
       target,
       db_unique_name as db_unique_name2,
       valid_now,
       destination,
       error
from v$archive_dest
where dest_id <= 31
  and (status <> 'INACTIVE' or destination is not null)
order by dest_id;

prompt
prompt ============================================================
prompt DATA GUARD RELATED INITIALIZATION PARAMETERS
prompt ============================================================
select name, value
from v$parameter
where name in (
  'log_archive_config',
  'log_archive_dest_1',
  'log_archive_dest_2',
  'log_archive_dest_3',
  'log_archive_dest_4',
  'log_archive_dest_state_1',
  'log_archive_dest_state_2',
  'log_archive_dest_state_3',
  'log_archive_dest_state_4',
  'fal_server',
  'fal_client',
  'standby_file_management',
  'db_file_name_convert',
  'log_file_name_convert',
  'remote_login_passwordfile'
)
order by name;

prompt
prompt ============================================================
prompt DATA GUARD CONFIGURATION MEMBERS
prompt ============================================================
select db_unique_name,
       parent_dbun,
       dest_role
from v$dataguard_config
order by db_unique_name;

prompt
prompt ============================================================
prompt STANDBY REDO LOG SUMMARY
prompt ============================================================
select thread#,
       count(*) srl_groups,
       round(sum(bytes)/1024/1024) total_mb,
       round(min(bytes)/1024/1024) min_group_mb,
       round(max(bytes)/1024/1024) max_group_mb
from v$standby_log
group by thread#
order by thread#;

prompt
prompt ============================================================
prompt STANDBY REDO LOG DETAIL
prompt ============================================================
select group#,
       thread#,
       sequence#,
       round(bytes/1024/1024) bytes_mb,
       status,
       archived
from v$standby_log
order by thread#, group#;

prompt
prompt ============================================================
prompt ONLINE REDO LOG SUMMARY FOR SRL COMPARISON
prompt ============================================================
select thread#,
       count(*) online_groups,
       round(min(bytes)/1024/1024) min_group_mb,
       round(max(bytes)/1024/1024) max_group_mb
from v$log
group by thread#
order by thread#;

prompt
prompt ============================================================
prompt EXISTING REMOTE ARCHIVE DESTINATIONS
prompt ============================================================
select dest_id,
       dest_name,
       target,
       status,
       db_unique_name,
       destination,
       error
from v$archive_dest
where target = 'STANDBY'
   or db_unique_name is not null
order by dest_id;

exit
SQL

SOURCE_HAS_EXISTING_STANDBY="UNKNOWN"

if [[ "$EXECUTE" == "true" ]]; then
  log "Collecting existing Data Guard configuration from source database"

  scp -q "$DG_SQL_LOCAL" "$SOURCE_OS_USER@$SOURCE_HOST:/tmp/zdm360_dg_inventory.sql" \
    || die "Unable to copy Data Guard inventory SQL to source"

  if ssh "$SOURCE_OS_USER@$SOURCE_HOST" "
       export ORACLE_HOME='$SOURCE_ORACLE_HOME'
       export ORACLE_SID='$SOURCE_SID'
       export PATH=\$ORACLE_HOME/bin:\$PATH
       sqlplus -s '/ as sysdba' @/tmp/zdm360_dg_inventory.sql
       rc=\$?
       rm -f /tmp/zdm360_dg_inventory.sql
       exit \$rc
     " > "$DG_REPORT_LOCAL" 2>&1; then
    echo "  Data Guard inventory saved: $DG_REPORT_LOCAL"
  else
    cat "$DG_REPORT_LOCAL"
    rm -f "$DG_SQL_LOCAL"
    die "Unable to collect source Data Guard inventory"
  fi
  rm -f "$DG_SQL_LOCAL"

  # Determine whether source already has a configured standby/archive destination.
  EXISTING_COUNT="$(
    ssh "$SOURCE_OS_USER@$SOURCE_HOST" "
      export ORACLE_HOME='$SOURCE_ORACLE_HOME'
      export ORACLE_SID='$SOURCE_SID'
      export PATH=\$ORACLE_HOME/bin:\$PATH
      sqlplus -s '/ as sysdba' <<'SQL'
set pages 0 feedback off heading off verify off echo off
select count(*)
from v\$archive_dest
where status <> 'INACTIVE'
  and (
       target = 'STANDBY'
       or db_unique_name is not null
       or upper(destination) like '%SERVICE=%'
      );
exit
SQL
    " | tr -d '\r' | awk 'NF{print $1}' | tail -1
  )" || EXISTING_COUNT="UNKNOWN"

  if [[ "$EXISTING_COUNT" =~ ^[0-9]+$ ]] && (( EXISTING_COUNT > 0 )); then
    SOURCE_HAS_EXISTING_STANDBY="YES"
    echo
    echo "  Existing standby/Data Guard configuration: DETECTED"
    echo "  Existing remote/archive destinations found: $EXISTING_COUNT"
    echo "  Review these items before adding another standby:"
    echo "    1. Archive log destinations and LOG_ARCHIVE_DEST_n"
    echo "    2. LOG_ARCHIVE_CONFIG / Data Guard DB_UNIQUE_NAME members"
    echo "    3. Existing standby destinations and transport status/errors"
    echo "    4. Standby redo log groups, threads, size, and status"
    echo "    5. Online redo log count/size versus SRL count/size"
    echo
    echo "  The workflow will CONTINUE, but the existing configuration is preserved"
    echo "  for compatibility review before new Data Guard parameters are changed."
  elif [[ "$EXISTING_COUNT" =~ ^[0-9]+$ ]]; then
    SOURCE_HAS_EXISTING_STANDBY="NO"
    echo "  Existing standby/Data Guard configuration: NOT DETECTED"
    echo "  No active remote standby/archive destination was found."
    echo "  Workflow will continue."
  else
    SOURCE_HAS_EXISTING_STANDBY="UNKNOWN"
    echo "  WARNING: Could not determine whether an existing standby is configured."
    echo "  Review $DG_REPORT_LOCAL before making Data Guard changes."
  fi
else
  echo "  DRY-RUN: inventory source Data Guard configuration using local '/ as sysdba'"
  echo "  Report will include:"
  echo "    - Archive log mode / FORCE LOGGING"
  echo "    - V\$ARCHIVE_DEST configuration and errors"
  echo "    - LOG_ARCHIVE_CONFIG / LOG_ARCHIVE_DEST_n parameters"
  echo "    - V\$DATAGUARD_CONFIG members"
  echo "    - Existing standby redo logs"
  echo "    - Online redo logs for SRL sizing comparison"
fi

echo
echo "STEP 7 - Plan safe new Data Guard archive destination and standby redo logs"

NEW_DG_DEST_NUM=""
NEW_DG_DEST_PARAM=""
NEW_DG_STATE_PARAM=""
DG_APPEND_SQL="${DG_APPEND_SQL:-./new_standby_dataguard_append.sql}"
SRL_CREATE_SQL="${SRL_CREATE_SQL:-./new_standby_srl_create.sql}"

if [[ "$EXECUTE" == "true" ]]; then
  log "Finding first unused LOG_ARCHIVE_DEST_n starting at LOG_ARCHIVE_DEST_10"

  USED_DESTS="$(
    ssh "$SOURCE_OS_USER@$SOURCE_HOST" "
      export ORACLE_HOME='$SOURCE_ORACLE_HOME'
      export ORACLE_SID='$SOURCE_SID'
      export PATH=\$ORACLE_HOME/bin:\$PATH
      sqlplus -s '/ as sysdba' <<'SQL'
set pages 0 feedback off heading off verify off echo off
select regexp_substr(name,'[0-9]+$')
from v\$parameter
where regexp_like(name,'^log_archive_dest_[0-9]+$')
  and value is not null
  and trim(value) is not null
order by to_number(regexp_substr(name,'[0-9]+$'));
exit
SQL
    " | tr -d '\r' | awk 'NF{print $1}'
  )"

  for n in $(seq 10 31); do
    if ! printf '%s\n' "$USED_DESTS" | grep -qx "$n"; then
      NEW_DG_DEST_NUM="$n"
      break
    fi
  done

  [[ -n "$NEW_DG_DEST_NUM" ]] || die "No unused LOG_ARCHIVE_DEST_n found from 10 through 31."

  NEW_DG_DEST_PARAM="LOG_ARCHIVE_DEST_${NEW_DG_DEST_NUM}"
  NEW_DG_STATE_PARAM="LOG_ARCHIVE_DEST_STATE_${NEW_DG_DEST_NUM}"

  echo "  Selected unused destination : $NEW_DG_DEST_PARAM"
  echo "  Matching state parameter    : $NEW_DG_STATE_PARAM"

  # Read existing DG_CONFIG so the new DB_UNIQUE_NAME can be appended safely.
  EXISTING_DG_CONFIG="$(
    ssh "$SOURCE_OS_USER@$SOURCE_HOST" "
      export ORACLE_HOME='$SOURCE_ORACLE_HOME'
      export ORACLE_SID='$SOURCE_SID'
      export PATH=\$ORACLE_HOME/bin:\$PATH
      sqlplus -s '/ as sysdba' <<'SQL'
set pages 0 feedback off heading off verify off echo off
select value from v\$parameter where name='log_archive_config';
exit
SQL
    " | tr -d '\r' | sed '/^[[:space:]]*$/d' | tail -1
  )"

  # Determine whether LOG_ARCHIVE_CONFIG/DG_CONFIG is already configured.
  DG_CONFIG_EXISTS="NO"
  DG_MEMBERS=""

  if [[ "$EXISTING_DG_CONFIG" =~ DG_CONFIG=\((.*)\) ]]; then
    DG_CONFIG_EXISTS="YES"
    DG_MEMBERS="${BASH_REMATCH[1]}"
    echo "  Existing LOG_ARCHIVE_CONFIG : $EXISTING_DG_CONFIG"
    echo "  DG_CONFIG status            : EXISTS - preserve existing members"
  else
    DG_CONFIG_EXISTS="NO"
    DG_MEMBERS="$SOURCE_DB_UNIQUE_NAME"
    echo "  Existing LOG_ARCHIVE_CONFIG : NOT CONFIGURED"
    echo "  DG_CONFIG status            : WILL BE CREATED"
  fi

  # Always ensure the primary/source DB_UNIQUE_NAME is included.
  if ! printf ',%s,' "$DG_MEMBERS" | tr -d ' ' | grep -qi ",${SOURCE_DB_UNIQUE_NAME},"; then
    DG_MEMBERS="${DG_MEMBERS:+${DG_MEMBERS},}${SOURCE_DB_UNIQUE_NAME}"
  fi

  # Add the new standby DB_UNIQUE_NAME only if it is not already a member.
  if ! printf ',%s,' "$DG_MEMBERS" | tr -d ' ' | grep -qi ",${TARGET_DB_UNIQUE_NAME},"; then
    DG_MEMBERS="${DG_MEMBERS:+${DG_MEMBERS},}${TARGET_DB_UNIQUE_NAME}"
  fi

  # Normalize accidental duplicate commas/spaces in generated member list.
  DG_MEMBERS="$(printf '%s' "$DG_MEMBERS" | sed 's/[[:space:]]//g; s/,,*/,/g; s/^,//; s/,$//')"

  echo "  Planned DG_CONFIG members   : $DG_MEMBERS"

  # Generate append-only Data Guard configuration SQL.
  cat > "$DG_APPEND_SQL" <<SQL
-- Generated by ZDM360 OCI Standby Placeholder Wizard.
-- Existing LOG_ARCHIVE_DEST_n values are preserved.
-- New destination chosen by scanning from 10 upward for the first unused slot.
--
-- SAFETY DEFAULT:
-- The new remote destination is initially DEFERRED.
-- Review connectivity and the standby build before enabling transport.

-- LOG_ARCHIVE_CONFIG is created if absent, otherwise its existing members are preserved
-- and the new standby DB_UNIQUE_NAME is appended.
ALTER SYSTEM SET LOG_ARCHIVE_CONFIG='DG_CONFIG=(${DG_MEMBERS})' SCOPE=BOTH;

ALTER SYSTEM SET ${NEW_DG_DEST_PARAM}=
'SERVICE=${TARGET_ALIAS} ASYNC NOAFFIRM VALID_FOR=(ONLINE_LOGFILES,PRIMARY_ROLE) DB_UNIQUE_NAME=${TARGET_DB_UNIQUE_NAME}'
SCOPE=BOTH;

ALTER SYSTEM SET ${NEW_DG_STATE_PARAM}='DEFER' SCOPE=BOTH;

-- Common Data Guard role-management prerequisite:
ALTER SYSTEM SET STANDBY_FILE_MANAGEMENT='AUTO' SCOPE=BOTH;

-- Enable only after the target standby is ready and validation passes:
-- ALTER SYSTEM SET ${NEW_DG_STATE_PARAM}='ENABLE' SCOPE=BOTH;

-- On the target standby, LOG_ARCHIVE_CONFIG must contain the same DG_CONFIG list.
-- Run after the standby SPFILE/database exists:
-- ALTER SYSTEM SET LOG_ARCHIVE_CONFIG='DG_CONFIG=(${DG_MEMBERS})' SCOPE=BOTH;
-- ALTER SYSTEM SET STANDBY_FILE_MANAGEMENT='AUTO' SCOPE=BOTH;
SQL

  chmod 600 "$DG_APPEND_SQL"
  echo "  New Data Guard append SQL   : $DG_APPEND_SQL"
  echo "  Destination starts DEFERRED for safety."

  log "Inspecting online redo and existing standby redo logs"

  REDO_PLAN="$(
    ssh "$SOURCE_OS_USER@$SOURCE_HOST" "
      export ORACLE_HOME='$SOURCE_ORACLE_HOME'
      export ORACLE_SID='$SOURCE_SID'
      export PATH=\$ORACLE_HOME/bin:\$PATH
      sqlplus -s '/ as sysdba' <<'SQL'
set pages 0 feedback off heading off verify off echo off
select thread#||'|'||
       count(*)||'|'||
       max(bytes)||'|'||
       (select count(*) from v\$standby_log s where s.thread#=l.thread#)
from v\$log l
group by thread#
order by thread#;
exit
SQL
    " | tr -d '\r' | awk -F'|' 'NF>=4{
        gsub(/[[:space:]]/,"",$1);
        gsub(/[[:space:]]/,"",$2);
        gsub(/[[:space:]]/,"",$3);
        gsub(/[[:space:]]/,"",$4);
        print $1"|"$2"|"$3"|"$4
      }'
  )"

  MAX_GROUP="$(
    ssh "$SOURCE_OS_USER@$SOURCE_HOST" "
      export ORACLE_HOME='$SOURCE_ORACLE_HOME'
      export ORACLE_SID='$SOURCE_SID'
      export PATH=\$ORACLE_HOME/bin:\$PATH
      sqlplus -s '/ as sysdba' <<'SQL'
set pages 0 feedback off heading off verify off echo off
select greatest(
  nvl((select max(group#) from v\$log),0),
  nvl((select max(group#) from v\$standby_log),0)
) from dual;
exit
SQL
    " | tr -d '\r' | awk 'NF{gsub(/[[:space:]]/,"",$1); print $1}' | tail -1
  )"

  [[ "$MAX_GROUP" =~ ^[0-9]+$ ]] || die "Unable to determine maximum redo log group number."
  NEXT_GROUP=$((MAX_GROUP + 1))

  {
    echo "-- Generated standby redo log plan for SOURCE database."
    echo "-- Oracle Data Guard sizing rule used by this toolkit:"
    echo "--   required SRLs per redo thread = online redo groups + 1"
    echo "--   SRL size = largest online redo log size for that thread"
    echo "-- Existing SRLs are preserved; only missing groups are added."
    echo
  } > "$SRL_CREATE_SQL"

  NEED_SRL_CREATE="NO"

  while IFS='|' read -r THREAD_NO ONLINE_COUNT MAX_BYTES SRL_COUNT; do
    [[ -n "$THREAD_NO" ]] || continue
    REQUIRED=$((ONLINE_COUNT + 1))
    MISSING=$((REQUIRED - SRL_COUNT))
    (( MISSING < 0 )) && MISSING=0

    echo "  Thread $THREAD_NO: online=$ONLINE_COUNT existing_SRL=$SRL_COUNT required=$REQUIRED missing=$MISSING size_bytes=$MAX_BYTES"

    if (( MISSING > 0 )); then
      NEED_SRL_CREATE="YES"
      for ((i=1; i<=MISSING; i++)); do
        echo "ALTER DATABASE ADD STANDBY LOGFILE THREAD ${THREAD_NO} GROUP ${NEXT_GROUP} SIZE ${MAX_BYTES};" >> "$SRL_CREATE_SQL"
        NEXT_GROUP=$((NEXT_GROUP + 1))
      done
    fi
  done <<< "$REDO_PLAN"

  if [[ "$NEED_SRL_CREATE" == "YES" ]]; then
    echo
    echo "  Standby redo logs are missing."
    echo "  Creation SQL generated      : $SRL_CREATE_SQL"
    echo "  Group numbering begins at   : $((MAX_GROUP + 1))"
    echo "  Existing groups are never reused or overwritten."
  else
    echo
    echo "  Standby redo log requirement already satisfied."
    echo "  No SRL creation is required."
    echo "-- No standby redo log creation required." >> "$SRL_CREATE_SQL"
  fi
  chmod 600 "$SRL_CREATE_SQL"

else
  echo "  DRY-RUN safety plan:"
  echo "    1. Inspect LOG_ARCHIVE_DEST_10."
  echo "    2. If occupied, check 11, 12, ... up to 31."
  echo "    3. Select the first unused destination."
  echo "    4. Check LOG_ARCHIVE_CONFIG/DG_CONFIG; if absent, create DG_CONFIG=(source,target).
       If present, preserve all existing members and append the new target DB_UNIQUE_NAME."
  echo "    5. Create new remote destination with the target TNS alias and DB_UNIQUE_NAME."
  echo "    6. Keep the new destination DEFERRED until standby validation completes."
  echo "    7. For every redo thread, compare online redo groups to standby redo groups."
  echo "    8. If SRLs are missing, create enough to reach online-groups + 1 per thread."
  echo "    9. New SRL group numbers start at MAX(V\$LOG.GROUP#, V\$STANDBY_LOG.GROUP#) + 1."
  echo "   10. New SRLs use the largest online redo size for that thread."
fi

echo
echo "STEP 8 - Detect source TDE status"

SOURCE_TDE_ENABLED="UNKNOWN"

if [[ "$EXECUTE" == "true" ]]; then
  log "Checking source database for TDE wallet/keystore and encrypted tablespaces"

  TDE_CHECK_SQL="/tmp/zdm360_tde_check_$$.sql"
  cat > "$TDE_CHECK_SQL" <<'SQL'
set pages 0 feedback off heading off verify off echo off
select case
         when exists (select 1 from v$encrypted_tablespaces)
           then 'TDE_ENABLED'
         else 'TDE_NOT_ENABLED'
       end
from dual;
exit
SQL

  # Use local OS authentication on the source host; no SYS password is exposed.
  TDE_RESULT="$(
    scp -q "$TDE_CHECK_SQL" "$SOURCE_OS_USER@$SOURCE_HOST:/tmp/zdm360_tde_check.sql" &&
    ssh "$SOURCE_OS_USER@$SOURCE_HOST" "
      export ORACLE_HOME='$SOURCE_ORACLE_HOME'
      export ORACLE_SID='$SOURCE_SID'
      export PATH=\$ORACLE_HOME/bin:\$PATH
      sqlplus -s '/ as sysdba' @/tmp/zdm360_tde_check.sql
      rm -f /tmp/zdm360_tde_check.sql
    " | tr -d '\r' | awk 'NF{print $1}' | tail -1
  )" || TDE_RESULT="TDE_CHECK_FAILED"
  rm -f "$TDE_CHECK_SQL"

  case "$TDE_RESULT" in
    TDE_ENABLED)
      SOURCE_TDE_ENABLED="YES"
      echo "  Source TDE status : ENABLED"
      echo "  TDE wallet/keystore validation and standby wallet handling are required."
      ;;
    TDE_NOT_ENABLED)
      SOURCE_TDE_ENABLED="NO"
      echo "  Source TDE status : NOT ENABLED"
      echo "  No encrypted tablespaces were detected."
      echo "  TDE-specific password/wallet steps will be skipped; standby workflow will CONTINUE."
      SOURCE_TDE_PASSWORD=""
      TARGET_TDE_PASSWORD=""
      ;;
    *)
      SOURCE_TDE_ENABLED="UNKNOWN"
      echo "  WARNING: Unable to determine source TDE status automatically."
      echo "  Review source database/TDE status before production standby build."
      ;;
  esac
else
  echo "  DRY-RUN: query V\$ENCRYPTED_TABLESPACES on source using local '/ as sysdba'"
  echo "  If no encrypted tablespaces exist: report 'TDE NOT ENABLED' and continue."
fi

echo
echo "STEP 9 - Source / Target SYS and TDE credential readiness"
if [[ -n "${SOURCE_SYS_PASSWORD:-}" ]]; then
  echo "  Source SYS password: supplied securely (not displayed or saved)"
else
  echo "  Source SYS password: not supplied; SQL*Plus will need to prompt when required"
fi
if [[ "${SOURCE_TDE_ENABLED:-UNKNOWN}" == "NO" ]]; then
  echo "  Source TDE password: NOT REQUIRED - TDE is not enabled"
  echo "  Target TDE password: NOT REQUIRED - TDE-specific standby steps skipped"
elif [[ -n "${SOURCE_TDE_PASSWORD:-}" ]]; then
  echo "  Source TDE password: supplied securely (not displayed or saved)"
else
  echo "  Source TDE password: not supplied; required when a password-protected TDE keystore is used"
fi

if [[ -n "${TARGET_SYS_PASSWORD:-}" ]]; then
  echo "  Target SYS password: supplied securely and checked against source when both are provided"
else
  echo "  Target SYS password: not supplied; target must use the same SYS password/password file as source"
fi

if [[ "${SOURCE_TDE_ENABLED:-UNKNOWN}" != "NO" ]]; then
  if [[ -n "${TARGET_TDE_PASSWORD:-}" ]]; then
    echo "  Target TDE password: supplied securely and checked against source when both are provided"
  else
    echo "  Target TDE password: not supplied; target keystore password should match source when TDE is enabled"
  fi
fi

echo
echo "Recommended source database checks:"
echo "  SELECT name, db_unique_name, open_mode, database_role FROM v\\$database;"
echo "  SELECT status, wallet_type, keystore_mode FROM v\\$encryption_wallet;"
echo
echo "Security: SYS/TDE passwords are never written to standby_placeholder.env,"
echo "never printed, and should not be supplied as command-line arguments."


echo
echo "STEP 9B - Standby build method and offline RMAN backup validation"

OFFLINE_BACKUP_REPORT="${OFFLINE_BACKUP_REPORT:-./offline_backup_validation_report.txt}"
OFFLINE_BACKUP_RMAN="${OFFLINE_BACKUP_RMAN:-./offline_standby_duplicate.rman}"
OFFLINE_BACKUP_CREATE_RMAN="${OFFLINE_BACKUP_CREATE_RMAN:-./create_offline_source_backup.rman}"
BACKUP_STAGE_SCRIPT="${BACKUP_STAGE_SCRIPT:-./stage_offline_backup.sh}"

if [[ "$STANDBY_BUILD_METHOD" == "OFFLINE_BACKUP" ]]; then
  {
    echo "ZDMMigration360 Offline RMAN Backup Validation"
    echo "================================================"
    echo "Source host          : $SOURCE_HOST"
    echo "Source SID           : $SOURCE_SID"
    echo "Source backup stage  : $SOURCE_BACKUP_STAGE"
    echo "Target host          : $TARGET_HOST"
    echo "Target SID           : $TARGET_SID"
    echo "Target backup stage  : $TARGET_BACKUP_STAGE"
    echo "Copy/stage method    : $BACKUP_COPY_METHOD"
    echo
  } > "$OFFLINE_BACKUP_REPORT"

  if [[ "$EXECUTE" == "true" ]]; then
    SOURCE_BACKUP_COUNT="$(
      ssh "$SOURCE_OS_USER@$SOURCE_HOST" "
        if [ -d '$SOURCE_BACKUP_STAGE' ]; then
          find '$SOURCE_BACKUP_STAGE' -maxdepth 1 -type f \( -name '*.bkp' -o -name '*.bak' -o -name '*.rman' -o -name '*.ctl' -o -name '*.spfile' -o -name '*.arc' -o -name 'c-*' -o -name 'o1_mf_*' \) -print 2>/dev/null | wc -l
        else
          echo 0
        fi
      " | tr -d '\r' | awk 'NF{print $1}' | tail -1
    )"
    SOURCE_BACKUP_COUNT="${SOURCE_BACKUP_COUNT:-0}"

    echo "Source staged backup files: $SOURCE_BACKUP_COUNT" | tee -a "$OFFLINE_BACKUP_REPORT"

    if [[ "$SOURCE_BACKUP_COUNT" -eq 0 ]]; then
      echo "STATUS: BACKUP NOT FOUND" | tee -a "$OFFLINE_BACKUP_REPORT"
      echo "ACTION: create a new consistent offline RMAN backup or choose ACTIVE_DUPLICATE." | tee -a "$OFFLINE_BACKUP_REPORT"
      BACKUP_EXISTS="NO"
    else
      BACKUP_EXISTS="YES"
      echo "STATUS: BACKUP FILES FOUND" | tee -a "$OFFLINE_BACKUP_REPORT"

      ssh "$SOURCE_OS_USER@$SOURCE_HOST" "
        export ORACLE_HOME='$SOURCE_ORACLE_HOME'
        export ORACLE_SID='$SOURCE_SID'
        export PATH=\$ORACLE_HOME/bin:\$PATH
        rman target / <<RMAN
set echo on;
list backup summary;
crosscheck backup;
exit
RMAN
      " >> "$OFFLINE_BACKUP_REPORT" 2>&1 || {
        echo "WARNING: RMAN inventory validation returned an error; review report." | tee -a "$OFFLINE_BACKUP_REPORT"
      }
    fi
  else
    BACKUP_EXISTS="UNKNOWN"
    echo "DRY-RUN: source backup stage and RMAN inventory will be validated during --execute." | tee -a "$OFFLINE_BACKUP_REPORT"
  fi

  cat > "$OFFLINE_BACKUP_CREATE_RMAN" <<RMAN
# Consistent offline backup template for source database.
# Run only during an approved outage.
SHUTDOWN IMMEDIATE;
STARTUP MOUNT;
RUN {
  ALLOCATE CHANNEL c1 TYPE DISK;
  ALLOCATE CHANNEL c2 TYPE DISK;
  BACKUP AS COMPRESSED BACKUPSET DATABASE
    FORMAT '${SOURCE_BACKUP_STAGE}/db_%d_%T_%U.bkp';
  BACKUP CURRENT CONTROLFILE FOR STANDBY
    FORMAT '${SOURCE_BACKUP_STAGE}/standby_ctl_%d_%T_%U.bkp';
  BACKUP SPFILE
    FORMAT '${SOURCE_BACKUP_STAGE}/spfile_%d_%T_%U.bkp';
}
ALTER DATABASE OPEN;
RMAN
  chmod 600 "$OFFLINE_BACKUP_CREATE_RMAN"

  cat > "$BACKUP_STAGE_SCRIPT" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
: "${SOURCE_HOST:?}"
: "${SOURCE_OS_USER:=oracle}"
: "${SOURCE_BACKUP_STAGE:?}"
: "${TARGET_HOST:?}"
: "${TARGET_OS_USER:=oracle}"
: "${TARGET_BACKUP_STAGE:?}"
: "${BACKUP_COPY_METHOD:=SCP}"

case "${BACKUP_COPY_METHOD^^}" in
  NFS)
    ssh "$TARGET_OS_USER@$TARGET_HOST" "test -d '$TARGET_BACKUP_STAGE' && test -r '$TARGET_BACKUP_STAGE'" \
      || { echo "ERROR: target NFS/shared backup stage is not readable."; exit 1; }
    echo "NFS/shared staging validated. No file copy performed."
    ;;
  RSYNC)
    ssh "$TARGET_OS_USER@$TARGET_HOST" "mkdir -p '$TARGET_BACKUP_STAGE'"
    rsync -a --info=progress2 -e ssh \
      "$SOURCE_OS_USER@$SOURCE_HOST:$SOURCE_BACKUP_STAGE/" \
      "$TARGET_OS_USER@$TARGET_HOST:$TARGET_BACKUP_STAGE/"
    ;;
  SCP)
    tmp="$(mktemp -d /tmp/zdm360_backupstage.XXXXXX)"
    trap 'rm -rf "$tmp"' EXIT
    scp -q -r "$SOURCE_OS_USER@$SOURCE_HOST:$SOURCE_BACKUP_STAGE/." "$tmp/"
    ssh "$TARGET_OS_USER@$TARGET_HOST" "mkdir -p '$TARGET_BACKUP_STAGE'"
    scp -q -r "$tmp/." "$TARGET_OS_USER@$TARGET_HOST:$TARGET_BACKUP_STAGE/"
    ;;
  *)
    echo "ERROR: BACKUP_COPY_METHOD must be SCP, RSYNC, or NFS."
    exit 1
    ;;
esac

src_count="$(ssh "$SOURCE_OS_USER@$SOURCE_HOST" "find '$SOURCE_BACKUP_STAGE' -maxdepth 1 -type f | wc -l" | awk 'NF{print $1}' | tail -1)"
tgt_count="$(ssh "$TARGET_OS_USER@$TARGET_HOST" "find '$TARGET_BACKUP_STAGE' -maxdepth 1 -type f | wc -l" | awk 'NF{print $1}' | tail -1)"
echo "Source staged files: $src_count"
echo "Target staged files: $tgt_count"
[[ "$src_count" -gt 0 && "$tgt_count" -ge "$src_count" ]] || {
  echo "ERROR: staged backup file-count validation failed."
  exit 1
}
echo "Backup staging validation PASSED."
SH
  chmod 700 "$BACKUP_STAGE_SCRIPT"

  cat > "$OFFLINE_BACKUP_RMAN" <<RMAN
# Backup-based physical standby duplicate.
# Run on target after backup pieces are staged and auxiliary is STARTUP NOMOUNT.
# Passwords are NOT stored here.
DUPLICATE DATABASE FOR STANDBY
  BACKUP LOCATION '${TARGET_BACKUP_STAGE}'
  DORECOVER
  SPFILE
    SET DB_UNIQUE_NAME='${TARGET_DB_UNIQUE_NAME}'
    SET CLUSTER_DATABASE='FALSE'
    SET STANDBY_FILE_MANAGEMENT='AUTO'
  NOFILENAMECHECK;
RMAN
  chmod 600 "$OFFLINE_BACKUP_RMAN"

  echo "  Validation report            : $OFFLINE_BACKUP_REPORT"
  echo "  Create-offline-backup RMAN   : $OFFLINE_BACKUP_CREATE_RMAN"
  echo "  Backup stage/copy helper     : $BACKUP_STAGE_SCRIPT"
  echo "  Offline duplicate RMAN       : $OFFLINE_BACKUP_RMAN"

  if [[ "$EXECUTE" == "true" && "${BACKUP_EXISTS:-NO}" == "NO" ]]; then
    echo
    echo "  OFFLINE_BACKUP selected but no existing backup was found."
    echo "  The wizard will NOT continue to duplicate."
    echo "  Use $OFFLINE_BACKUP_CREATE_RMAN during an approved source outage,"
    echo "  stage/validate the backup, or rerun with STANDBY_BUILD_METHOD=ACTIVE_DUPLICATE."
  fi
else
  echo "  Selected build method         : ACTIVE_DUPLICATE"
  echo "  Offline backup validation/staging is not required."
fi

echo
echo "STEP 10 - Non-RAC target validation and RMAN active standby duplicate plan"

ACTIVE_DUPLICATE_RMAN="${ACTIVE_DUPLICATE_RMAN:-./active_standby_duplicate.rman}"
POST_BUILD_SQL="${POST_BUILD_SQL:-./standby_post_build_restart.sql}"

# Non-RAC target safety check: if a target database/placeholder instance is already running,
# CLUSTER_DATABASE must not be TRUE.
if [[ "$EXECUTE" == "true" ]]; then
  TARGET_CLUSTER_DATABASE="$(
    ssh "$TARGET_OS_USER@$TARGET_HOST" "
      export ORACLE_HOME='$TARGET_ORACLE_HOME'
      export ORACLE_SID='$TARGET_SID'
      export PATH=\$ORACLE_HOME/bin:\$PATH
      sqlplus -s '/ as sysdba' <<'SQL'
set pages 0 feedback off heading off verify off echo off
select value from v\$parameter where name='cluster_database';
exit
SQL
    " 2>/dev/null | tr -d '\r' | awk 'NF{gsub(/[[:space:]]/,"",$1); print toupper($1)}' | tail -1
  )" || TARGET_CLUSTER_DATABASE="UNKNOWN"

  case "$TARGET_CLUSTER_DATABASE" in
    TRUE)
      die "Target CLUSTER_DATABASE=TRUE. This workflow is for a non-RAC/single-instance target only."
      ;;
    FALSE)
      echo "  Target topology             : NON-RAC / CLUSTER_DATABASE=FALSE"
      ;;
    *)
      echo "  Target topology             : placeholder not running or CLUSTER_DATABASE unavailable"
      echo "  The generated duplicate SPFILE will force CLUSTER_DATABASE=FALSE."
      ;;
  esac
else
  echo "  DRY-RUN: validate target CLUSTER_DATABASE is FALSE (non-RAC target)."
fi

# Generate an RMAN template without storing SYS passwords.
{
  echo "# RMAN active physical standby duplicate"
  echo "# Passwords are NOT embedded in this file."
  echo "# Connect to RMAN interactively or use the secure runtime wrapper."
  echo "RUN {"
  for ((i=1; i<=RMAN_PRIMARY_CHANNELS; i++)); do
    echo "  ALLOCATE CHANNEL prim${i} TYPE DISK;"
  done
  for ((i=1; i<=RMAN_AUX_CHANNELS; i++)); do
    echo "  ALLOCATE AUXILIARY CHANNEL aux${i} TYPE DISK;"
  done
  echo "  DUPLICATE TARGET DATABASE FOR STANDBY FROM ACTIVE DATABASE"
  echo "    DORECOVER"
  echo "    SPFILE"
  echo "    SET DB_UNIQUE_NAME='${TARGET_DB_UNIQUE_NAME}'"
  echo "    SET CLUSTER_DATABASE='FALSE'"
  echo "    SET STANDBY_FILE_MANAGEMENT='AUTO'"
  [[ -n "${TARGET_DB_CREATE_FILE_DEST:-}" ]] && \
    echo "    SET DB_CREATE_FILE_DEST='${TARGET_DB_CREATE_FILE_DEST}'"
  [[ -n "${TARGET_DB_RECOVERY_FILE_DEST:-}" ]] && \
    echo "    SET DB_RECOVERY_FILE_DEST='${TARGET_DB_RECOVERY_FILE_DEST}'"
  echo "    NOFILENAMECHECK;"
  echo "}"
} > "$ACTIVE_DUPLICATE_RMAN"
chmod 600 "$ACTIVE_DUPLICATE_RMAN"

cat > "$POST_BUILD_SQL" <<'SQL'
whenever sqlerror exit failure
prompt === Verify standby role after RMAN duplicate ===
select name, db_unique_name, database_role, open_mode from v$database;

prompt === Stop standby cleanly ===
shutdown immediate;

prompt === Restart standby in MOUNT mode ===
startup mount;

prompt === Verify role/mode after restart ===
select name, db_unique_name, database_role, open_mode from v$database;

prompt === Start managed redo apply ===
alter database recover managed standby database disconnect from session;

prompt === Data Guard process verification ===
select role, thread#, sequence#, action
from v$dataguard_process
order by role, thread#;

exit
SQL
chmod 600 "$POST_BUILD_SQL"

echo "  RMAN duplicate template      : $ACTIVE_DUPLICATE_RMAN"
echo "  Post-build restart SQL       : $POST_BUILD_SQL"
echo
echo "  Build sequence:"
echo "    1. Target placeholder instance STARTUP NOMOUNT."
echo "    2. RMAN TARGET connects to source; AUXILIARY connects to target."
echo "    3. DUPLICATE TARGET DATABASE FOR STANDBY FROM ACTIVE DATABASE DORECOVER."
echo "    4. Verify target DATABASE_ROLE=PHYSICAL STANDBY."
echo "    5. SHUTDOWN IMMEDIATE target."
echo "    6. STARTUP MOUNT target."
echo "    7. Start managed standby recovery."
echo "    8. Validate V\$DATAGUARD_PROCESS / redo transport."

if [[ "$EXECUTE" == "true" && "$STANDBY_BUILD_METHOD" == "ACTIVE_DUPLICATE" ]]; then
  [[ -n "${SOURCE_SYS_PASSWORD:-}" ]] || die "SOURCE_SYS_PASSWORD is required for live active duplicate."
  [[ -n "${TARGET_SYS_PASSWORD:-}" ]] || die "TARGET_SYS_PASSWORD is required for live active duplicate."
  [[ "$SOURCE_SYS_PASSWORD" == "$TARGET_SYS_PASSWORD" ]] || die "Source and target SYS passwords must match."

  echo
  echo "  Live active duplicate requested."
  echo "  SYS passwords will be supplied through a temporary mode-600 RMAN command file and deleted immediately."

  SECURE_RMAN="/tmp/zdm360_active_duplicate_$$.rman"
  {
    printf 'CONNECT TARGET "sys/%s@%s AS SYSDBA";\n' "$SOURCE_SYS_PASSWORD" "$SOURCE_ALIAS"
    printf 'CONNECT AUXILIARY "sys/%s@%s AS SYSDBA";\n' "$TARGET_SYS_PASSWORD" "$TARGET_ALIAS"
    cat "$ACTIVE_DUPLICATE_RMAN"
  } > "$SECURE_RMAN"
  chmod 600 "$SECURE_RMAN"

  # Ensure secure command file cleanup even if RMAN fails.
  cleanup_secure_rman() { rm -f "$SECURE_RMAN"; }
  trap cleanup_secure_rman EXIT

  run "scp -q '$SECURE_RMAN' '$TARGET_OS_USER@$TARGET_HOST:/tmp/zdm360_active_duplicate.rman'"
  run "ssh '$TARGET_OS_USER@$TARGET_HOST' \"chmod 600 /tmp/zdm360_active_duplicate.rman; export ORACLE_HOME='$TARGET_ORACLE_HOME'; export ORACLE_SID='$TARGET_SID'; export PATH=\\\$ORACLE_HOME/bin:\\\$PATH; rman cmdfile=/tmp/zdm360_active_duplicate.rman log=/tmp/zdm360_active_duplicate.log; rc=\\\$?; rm -f /tmp/zdm360_active_duplicate.rman; exit \\\$rc\""

  cleanup_secure_rman
  trap - EXIT

  run "scp -q '$POST_BUILD_SQL' '$TARGET_OS_USER@$TARGET_HOST:/tmp/zdm360_post_build_restart.sql'"
  run "ssh '$TARGET_OS_USER@$TARGET_HOST' \"export ORACLE_HOME='$TARGET_ORACLE_HOME'; export ORACLE_SID='$TARGET_SID'; export PATH=\\\$ORACLE_HOME/bin:\\\$PATH; sqlplus -s '/ as sysdba' @/tmp/zdm360_post_build_restart.sql; rc=\\\$?; rm -f /tmp/zdm360_post_build_restart.sql; exit \\\$rc\""

  echo
  echo "  Non-RAC active standby duplicate and post-build restart sequence completed."
elif [[ "$EXECUTE" == "true" && "$STANDBY_BUILD_METHOD" == "OFFLINE_BACKUP" ]]; then
  [[ "${BACKUP_EXISTS:-NO}" == "YES" ]] || die "Offline RMAN backup was not found/validated. See $OFFLINE_BACKUP_REPORT."

  echo
  echo "  Staging validated offline backup to target..."
  SOURCE_HOST="$SOURCE_HOST" SOURCE_OS_USER="$SOURCE_OS_USER" \
  SOURCE_BACKUP_STAGE="$SOURCE_BACKUP_STAGE" TARGET_HOST="$TARGET_HOST" \
  TARGET_OS_USER="$TARGET_OS_USER" TARGET_BACKUP_STAGE="$TARGET_BACKUP_STAGE" \
  BACKUP_COPY_METHOD="$BACKUP_COPY_METHOD" "$BACKUP_STAGE_SCRIPT"

  echo "  Validating staged backup pieces on target with RMAN CATALOG/LIST..."
  run "ssh '$TARGET_OS_USER@$TARGET_HOST' \"export ORACLE_HOME='$TARGET_ORACLE_HOME'; export ORACLE_SID='$TARGET_SID'; export PATH=\\\$ORACLE_HOME/bin:\\\$PATH; rman auxiliary / <<RMAN
CATALOG START WITH '$TARGET_BACKUP_STAGE/' NOPROMPT;
LIST BACKUP SUMMARY;
exit
RMAN\""

  [[ -n "${TARGET_SYS_PASSWORD:-}" ]] || die "TARGET_SYS_PASSWORD is required for live backup-based duplicate."

  SECURE_RMAN="/tmp/zdm360_offline_duplicate_$$.rman"
  {
    printf 'CONNECT AUXILIARY "sys/%s@%s AS SYSDBA";\n' "$TARGET_SYS_PASSWORD" "$TARGET_ALIAS"
    cat "$OFFLINE_BACKUP_RMAN"
  } > "$SECURE_RMAN"
  chmod 600 "$SECURE_RMAN"
  trap 'rm -f "$SECURE_RMAN"' EXIT

  run "scp -q '$SECURE_RMAN' '$TARGET_OS_USER@$TARGET_HOST:/tmp/zdm360_offline_duplicate.rman'"
  run "ssh '$TARGET_OS_USER@$TARGET_HOST' \"chmod 600 /tmp/zdm360_offline_duplicate.rman; export ORACLE_HOME='$TARGET_ORACLE_HOME'; export ORACLE_SID='$TARGET_SID'; export PATH=\\\$ORACLE_HOME/bin:\\\$PATH; rman cmdfile=/tmp/zdm360_offline_duplicate.rman log=/tmp/zdm360_offline_duplicate.log; rc=\\\$?; rm -f /tmp/zdm360_offline_duplicate.rman; exit \\\$rc\""
  rm -f "$SECURE_RMAN"
  trap - EXIT

  run "scp -q '$POST_BUILD_SQL' '$TARGET_OS_USER@$TARGET_HOST:/tmp/zdm360_post_build_restart.sql'"
  run "ssh '$TARGET_OS_USER@$TARGET_HOST' \"export ORACLE_HOME='$TARGET_ORACLE_HOME'; export ORACLE_SID='$TARGET_SID'; export PATH=\\\$ORACLE_HOME/bin:\\\$PATH; sqlplus -s '/ as sysdba' @/tmp/zdm360_post_build_restart.sql; rc=\\\$?; rm -f /tmp/zdm360_post_build_restart.sql; exit \\\$rc\""

  echo
  echo "  Offline backup-based standby duplicate and post-build restart sequence completed."
else
  echo
  echo "  DRY-RUN only: selected standby build method was not executed."
fi

echo
echo "================================================================================"
echo " Standby Placeholder Summary"
echo "================================================================================"
printf "%-30s : %s\n" "Source DB_NAME" "$SOURCE_DB_NAME"
printf "%-30s : %s\n" "Source DB_UNIQUE_NAME" "$SOURCE_DB_UNIQUE_NAME"
printf "%-30s : %s\n" "Source Host" "$SOURCE_HOST"
printf "%-30s : %s\n" "Source Service" "$SOURCE_SERVICE"
printf "%-30s : %s\n" "Target DB_NAME" "$TARGET_DB_NAME"
printf "%-30s : %s\n" "Target DB_UNIQUE_NAME" "$TARGET_DB_UNIQUE_NAME"
printf "%-30s : %s\n" "Target Host" "$TARGET_HOST"
printf "%-30s : %s\n" "Target Service" "$TARGET_SERVICE"
printf "%-30s : %s\n" "Password File Target" "$TARGET_PWFILE"

echo
echo "Next: validate ARCHIVELOG, FORCE LOGGING, standby redo logs, TDE/wallet,"
echo "Data Guard parameters, and the selected RMAN/ZDM standby-build method."
echo
echo "RAC/ASM note: this placeholder assumes filesystem password files under ORACLE_HOME/dbs."
echo "For RAC/ASM-managed password files, replace the copy step with your approved srvctl/asmcmd process."


echo
echo "STEP 11 - Post-restore RAC standby validation / repair"
if [[ "$TARGET_RAC_ENABLED" == "YES" ]]; then
  if [[ "$EXECUTE" == "true" ]]; then
    TARGET_HOST="$TARGET_HOST" TARGET_OS_USER="$TARGET_OS_USER" \
    TARGET_ORACLE_HOME="$TARGET_ORACLE_HOME" TARGET_SID="$TARGET_SID" \
    TARGET_DB_UNIQUE_NAME="$TARGET_DB_UNIQUE_NAME" \
    TARGET_GRID_HOME="$TARGET_GRID_HOME" TARGET_RAC_INSTANCES="$TARGET_RAC_INSTANCES" \
    TARGET_UNDO_PREFIX="$TARGET_UNDO_PREFIX" TARGET_REDO_SIZE_MB="$TARGET_REDO_SIZE_MB" \
    EXECUTE=true "$ROOT/post_restore_rac_validate_fix.sh"
  else
    echo "  DRY-RUN: post_restore_rac_validate_fix.sh will validate/fix RAC requirements after restore."
  fi
else
  echo "  RAC target not requested."
fi

echo
echo "STEP 12 - Data Guard post-build validation / synchronization"
if [[ "$DG_POSTBUILD_VALIDATE" == "YES" ]]; then
  if [[ "$EXECUTE" == "true" ]]; then
    SOURCE_HOST="$SOURCE_HOST" SOURCE_OS_USER="$SOURCE_OS_USER" SOURCE_ORACLE_HOME="$SOURCE_ORACLE_HOME" \
    SOURCE_SID="$SOURCE_SID" SOURCE_DB_UNIQUE_NAME="$SOURCE_DB_UNIQUE_NAME" \
    TARGET_HOST="$TARGET_HOST" TARGET_OS_USER="$TARGET_OS_USER" TARGET_ORACLE_HOME="$TARGET_ORACLE_HOME" \
    TARGET_SID="$TARGET_SID" TARGET_DB_UNIQUE_NAME="$TARGET_DB_UNIQUE_NAME" \
    "$ROOT/dg_postbuild_validate.sh"

    SOURCE_HOST="$SOURCE_HOST" SOURCE_OS_USER="$SOURCE_OS_USER" SOURCE_ORACLE_HOME="$SOURCE_ORACLE_HOME" \
    SOURCE_SID="$SOURCE_SID" TARGET_HOST="$TARGET_HOST" TARGET_OS_USER="$TARGET_OS_USER" \
    TARGET_ORACLE_HOME="$TARGET_ORACLE_HOME" TARGET_SID="$TARGET_SID" \
    "$ROOT/dg_sync_database.sh"
  else
    echo "  DRY-RUN: Data Guard health and sync checks are available after the build."
  fi
fi

echo
echo "Post-build operational helpers:"
echo "  $ROOT/dg_postbuild_validate.sh"
echo "  $ROOT/dg_sync_database.sh"
echo "  $ROOT/dg_snapshot_standby.sh"
echo "  $ROOT/dg_switchover.sh"
echo "  $ROOT/dg_failover.sh"
