#!/usr/bin/env bash
set -euo pipefail
die(){ echo "ERROR: $*" >&2; exit 1; }
require_var(){ local n="$1"; [[ -n "${!n:-}" ]] || die "$n is required"; }
remote_sql(){
  local host="$1" user="$2" oh="$3" sid="$4"
  ssh "$user@$host" "
    export ORACLE_HOME='$oh'
    export ORACLE_SID='$sid'
    export PATH=\$ORACLE_HOME/bin:\$PATH
    sqlplus -s '/ as sysdba'
  "
}
broker_enabled(){
  local host="$1" user="$2" oh="$3" sid="$4"
  remote_sql "$host" "$user" "$oh" "$sid" <<'SQL' | tr -d '\r' | awk 'NF{print toupper($1)}' | tail -1
set pages 0 feedback off heading off verify off echo off
select value from v$parameter where name='dg_broker_start';
exit
SQL
}
confirm_live(){
  local phrase="$1"
  [[ "${EXECUTE:-false}" == "true" ]] || { echo "DRY-RUN: no role-changing action executed."; return 1; }
  [[ "${AUTO_CONFIRM:-NO}" == "YES" ]] && return 0
  read -r -p "Type '$phrase' to continue: " ans
  [[ "$ans" == "$phrase" ]] || die "Confirmation failed."
}
