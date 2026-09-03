#!/usr/bin/env bash
set -euo pipefail

: "${SOURCE_HOST:?SOURCE_HOST required}"
: "${SOURCE_ORACLE_HOME:?SOURCE_ORACLE_HOME required}"
: "${SOURCE_SID:?SOURCE_SID required}"
: "${SOURCE_DB_UNIQUE_NAME:?SOURCE_DB_UNIQUE_NAME required}"
: "${TARGET_DB_UNIQUE_NAME:?TARGET_DB_UNIQUE_NAME required}"

SOURCE_OS_USER="${SOURCE_OS_USER:-oracle}"
EXECUTE="${EXECUTE:-false}"

CURRENT="$(
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

if [[ "$CURRENT" =~ DG_CONFIG=\((.*)\) ]]; then
  MEMBERS="${BASH_REMATCH[1]}"
  echo "DG_CONFIG exists: $CURRENT"
  echo "Mode: APPEND ONLY - existing members will not be removed or overwritten"
else
  MEMBERS="$SOURCE_DB_UNIQUE_NAME"
  echo "DG_CONFIG does not exist. It will be initialized."
fi

normalize_members() {
  printf '%s\n' "$1" \
    | tr ',' '\n' \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
    | awk 'NF {
        key=toupper($0)
        if (!seen[key]++) {
          if (out=="") out=$0
          else out=out "," $0
        }
      }
      END { print out }'
}

ORIGINAL_MEMBERS="$MEMBERS"
MEMBERS="$(normalize_members "$MEMBERS")"

if [[ "$(printf '%s' "$ORIGINAL_MEMBERS" | sed 's/[[:space:]]//g')" != "$(printf '%s' "$MEMBERS" | sed 's/[[:space:]]//g')" ]]; then
  echo "Duplicate DG_CONFIG values detected. They will be removed before update."
else
  echo "No duplicate DG_CONFIG values detected."
fi

for db in "$SOURCE_DB_UNIQUE_NAME" "$TARGET_DB_UNIQUE_NAME"; do
  if ! printf ',%s,' "$MEMBERS" | tr -d ' ' | grep -qi ",${db},"; then
    MEMBERS="${MEMBERS:+${MEMBERS},}${db}"
  else
    echo "$db already exists in DG_CONFIG; not adding duplicate."
  fi
done

FINAL="$(normalize_members "$MEMBERS")"
[[ "$(printf '%s' "$FINAL" | tr '[:lower:]' '[:upper:]')" == "$(printf '%s' "$MEMBERS" | tr -d ' ' | tr '[:lower:]' '[:upper:]')" ]] \
  || { echo "Duplicate value remains after validation. Aborting."; exit 1; }
MEMBERS="$FINAL"

echo "Planned value: DG_CONFIG=($MEMBERS)"

if [[ "$EXECUTE" == "true" ]]; then
  ssh "$SOURCE_OS_USER@$SOURCE_HOST" "
    export ORACLE_HOME='$SOURCE_ORACLE_HOME'
    export ORACLE_SID='$SOURCE_SID'
    export PATH=\$ORACLE_HOME/bin:\$PATH
    sqlplus -s '/ as sysdba' <<SQL
whenever sqlerror exit failure
ALTER SYSTEM SET LOG_ARCHIVE_CONFIG='DG_CONFIG=($MEMBERS)' SCOPE=BOTH;
ALTER SYSTEM SET STANDBY_FILE_MANAGEMENT='AUTO' SCOPE=BOTH;
exit
SQL
  "
  echo "DG_CONFIG setup/update completed."
else
  echo "DRY-RUN only. Set EXECUTE=true to apply."
fi
