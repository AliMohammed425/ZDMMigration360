#!/usr/bin/env bash
set -euo pipefail

: "${SOURCE_HOST:?SOURCE_HOST required}"
: "${SOURCE_ORACLE_HOME:?SOURCE_ORACLE_HOME required}"
: "${SOURCE_SID:?SOURCE_SID required}"
: "${SOURCE_DB_UNIQUE_NAME:?SOURCE_DB_UNIQUE_NAME required}"
: "${TARGET_DB_UNIQUE_NAME:?TARGET_DB_UNIQUE_NAME required}"
: "${TARGET_ALIAS:?TARGET_ALIAS required}"

SOURCE_OS_USER="${SOURCE_OS_USER:-oracle}"
DG_APPEND_SQL="${DG_APPEND_SQL:-./new_standby_dataguard_append.sql}"
SRL_CREATE_SQL="${SRL_CREATE_SQL:-./new_standby_srl_create.sql}"

sql_source() {
  ssh "$SOURCE_OS_USER@$SOURCE_HOST" "
    export ORACLE_HOME='$SOURCE_ORACLE_HOME'
    export ORACLE_SID='$SOURCE_SID'
    export PATH=\$ORACLE_HOME/bin:\$PATH
    sqlplus -s '/ as sysdba'
  "
}

USED="$(
  sql_source <<'SQL'
set pages 0 feedback off heading off verify off echo off
select regexp_substr(name,'[0-9]+$')
from v$parameter
where regexp_like(name,'^log_archive_dest_[0-9]+$')
  and value is not null and trim(value) is not null;
exit
SQL
)"

DEST=""
for n in $(seq 10 31); do
  if ! printf '%s\n' "$USED" | awk '{$1=$1};1' | grep -qx "$n"; then
    DEST="$n"; break
  fi
done
[[ -n "$DEST" ]] || { echo "No unused LOG_ARCHIVE_DEST_n from 10..31"; exit 1; }

echo "Selected LOG_ARCHIVE_DEST_$DEST"
echo "Use LOG_ARCHIVE_DEST_STATE_$DEST=DEFER until standby is ready."

MAX_GROUP="$(
  sql_source <<'SQL' | awk 'NF{gsub(/[[:space:]]/,"",$1); print $1}' | tail -1
set pages 0 feedback off heading off verify off echo off
select greatest(nvl((select max(group#) from v$log),0),
                nvl((select max(group#) from v$standby_log),0))
from dual;
exit
SQL
)"
NEXT_GROUP=$((MAX_GROUP+1))

echo "-- Standby redo log additions; review before execution." > "$SRL_CREATE_SQL"
sql_source <<'SQL' | tr -d '\r' | awk -F'|' 'NF>=4{
  for(i=1;i<=4;i++) gsub(/[[:space:]]/,"",$i);
  print $1"|"$2"|"$3"|"$4
}'
set pages 0 feedback off heading off verify off echo off
select thread#||'|'||count(*)||'|'||max(bytes)||'|'||
       (select count(*) from v$standby_log s where s.thread#=l.thread#)
from v$log l
group by thread#
order by thread#;
exit
SQL
