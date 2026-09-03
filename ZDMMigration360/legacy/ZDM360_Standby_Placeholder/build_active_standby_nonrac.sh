#!/usr/bin/env bash
set -euo pipefail

: "${SOURCE_ALIAS:?SOURCE_ALIAS required}"
: "${TARGET_ALIAS:?TARGET_ALIAS required}"
: "${TARGET_HOST:?TARGET_HOST required}"
: "${TARGET_ORACLE_HOME:?TARGET_ORACLE_HOME required}"
: "${TARGET_SID:?TARGET_SID required}"
: "${SOURCE_SYS_PASSWORD:?SOURCE_SYS_PASSWORD required}"
: "${TARGET_SYS_PASSWORD:?TARGET_SYS_PASSWORD required}"

TARGET_OS_USER="${TARGET_OS_USER:-oracle}"
RMAN_FILE="${ACTIVE_DUPLICATE_RMAN:-./active_standby_duplicate.rman}"
POST_SQL="${POST_BUILD_SQL:-./standby_post_build_restart.sql}"

[[ "$SOURCE_SYS_PASSWORD" == "$TARGET_SYS_PASSWORD" ]] || {
  echo "ERROR: target SYS password must match source SYS password."
  exit 1
}

[[ -r "$RMAN_FILE" ]] || { echo "Missing $RMAN_FILE"; exit 1; }
[[ -r "$POST_SQL" ]] || { echo "Missing $POST_SQL"; exit 1; }

tmp="$(mktemp /tmp/zdm360_rman.XXXXXX)"
chmod 600 "$tmp"
trap 'rm -f "$tmp"' EXIT

{
  printf 'CONNECT TARGET "sys/%s@%s AS SYSDBA";\n' "$SOURCE_SYS_PASSWORD" "$SOURCE_ALIAS"
  printf 'CONNECT AUXILIARY "sys/%s@%s AS SYSDBA";\n' "$TARGET_SYS_PASSWORD" "$TARGET_ALIAS"
  cat "$RMAN_FILE"
} > "$tmp"

scp -q "$tmp" "$TARGET_OS_USER@$TARGET_HOST:/tmp/zdm360_active_duplicate.rman"
ssh "$TARGET_OS_USER@$TARGET_HOST" "
  set -e
  chmod 600 /tmp/zdm360_active_duplicate.rman
  export ORACLE_HOME='$TARGET_ORACLE_HOME'
  export ORACLE_SID='$TARGET_SID'
  export PATH=\$ORACLE_HOME/bin:\$PATH
  rman cmdfile=/tmp/zdm360_active_duplicate.rman log=/tmp/zdm360_active_duplicate.log
  rm -f /tmp/zdm360_active_duplicate.rman
"

scp -q "$POST_SQL" "$TARGET_OS_USER@$TARGET_HOST:/tmp/zdm360_post_build_restart.sql"
ssh "$TARGET_OS_USER@$TARGET_HOST" "
  set -e
  export ORACLE_HOME='$TARGET_ORACLE_HOME'
  export ORACLE_SID='$TARGET_SID'
  export PATH=\$ORACLE_HOME/bin:\$PATH
  sqlplus -s '/ as sysdba' @/tmp/zdm360_post_build_restart.sql
  rm -f /tmp/zdm360_post_build_restart.sql
"

echo "Active duplicate complete; standby restarted MOUNT and managed recovery started."
