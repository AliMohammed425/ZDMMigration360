#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
source "$ROOT/dg_ops_lib.sh"
for n in SOURCE_HOST SOURCE_OS_USER SOURCE_ORACLE_HOME SOURCE_SID TARGET_HOST TARGET_OS_USER TARGET_ORACLE_HOME TARGET_SID; do require_var "$n"; done
SYNC_WAIT_SECONDS="${SYNC_WAIT_SECONDS:-900}"
SYNC_POLL_SECONDS="${SYNC_POLL_SECONDS:-15}"
FORCE_LOG_SWITCH="${FORCE_LOG_SWITCH:-YES}"

if [[ "$FORCE_LOG_SWITCH" == "YES" ]]; then
remote_sql "$SOURCE_HOST" "$SOURCE_OS_USER" "$SOURCE_ORACLE_HOME" "$SOURCE_SID" <<'SQL'
whenever sqlerror exit failure
alter system archive log current;
exit
SQL
fi

deadline=$(( $(date +%s)+SYNC_WAIT_SECONDS ))
while :; do
  OUT="$(
remote_sql "$TARGET_HOST" "$TARGET_OS_USER" "$TARGET_ORACLE_HOME" "$TARGET_SID" <<'SQL'
set pages 0 feedback off heading off verify off echo off
select 'GAPS='||count(*) from v$archive_gap;
select 'TRANSPORT='||value from v$dataguard_stats where name='transport lag';
select 'APPLY='||value from v$dataguard_stats where name='apply lag';
exit
SQL
)"
  echo "$OUT"
  GAPS="$(printf '%s\n' "$OUT" | awk -F= '/^GAPS=/{print $2}' | tail -1)"
  TRANSPORT="$(printf '%s\n' "$OUT" | sed -n 's/^TRANSPORT=//p' | tail -1)"
  APPLY="$(printf '%s\n' "$OUT" | sed -n 's/^APPLY=//p' | tail -1)"
  if [[ "${GAPS:-1}" == "0" && "$TRANSPORT" == "+00 00:00:"* && "$APPLY" == "+00 00:00:"* ]]; then
    echo "SYNC PASSED: no archive gaps and transport/apply lag are below one minute."
    exit 0
  fi
  (( $(date +%s) < deadline )) || { echo "SYNC TIMED OUT after ${SYNC_WAIT_SECONDS}s."; exit 2; }
  sleep "$SYNC_POLL_SECONDS"
done
