#!/usr/bin/env bash
set -euo pipefail
: "${SOURCE_HOST:?SOURCE_HOST required}"
: "${TARGET_HOST:?TARGET_HOST required}"
: "${SOURCE_ORACLE_HOME:?SOURCE_ORACLE_HOME required}"
: "${TARGET_ORACLE_HOME:?TARGET_ORACLE_HOME required}"
: "${SOURCE_ALIAS:?SOURCE_ALIAS required}"
: "${TARGET_ALIAS:?TARGET_ALIAS required}"

SOURCE_OS_USER="${SOURCE_OS_USER:-oracle}"
TARGET_OS_USER="${TARGET_OS_USER:-oracle}"
SOURCE_TNS_ADMIN="${SOURCE_TNS_ADMIN:-$SOURCE_ORACLE_HOME/network/admin}"
TARGET_TNS_ADMIN="${TARGET_TNS_ADMIN:-$TARGET_ORACLE_HOME/network/admin}"

check_host() {
  local label="$1" user="$2" host="$3" home="$4" admin="$5"
  echo "=== $label: $user@$host ==="
  ssh "$user@$host" "
    set -e
    test -r '$admin/tnsnames.ora'
    grep -q -E '^$SOURCE_ALIAS[[:space:]]*=' '$admin/tnsnames.ora'
    grep -q -E '^$TARGET_ALIAS[[:space:]]*=' '$admin/tnsnames.ora'
    export ORACLE_HOME='$home'
    export TNS_ADMIN='$admin'
    export PATH=\$ORACLE_HOME/bin:\$PATH
    echo 'Testing $SOURCE_ALIAS'
    tnsping '$SOURCE_ALIAS'
    echo 'Testing $TARGET_ALIAS'
    tnsping '$TARGET_ALIAS'
  "
  echo "$label TNS validation PASSED"
}

check_host SOURCE "$SOURCE_OS_USER" "$SOURCE_HOST" "$SOURCE_ORACLE_HOME" "$SOURCE_TNS_ADMIN"
check_host TARGET "$TARGET_OS_USER" "$TARGET_HOST" "$TARGET_ORACLE_HOME" "$TARGET_TNS_ADMIN"

echo "All four TNS resolution/connectivity checks PASSED."
