#!/usr/bin/env bash
set -euo pipefail

dg_inventory(){
  remote_sql "$SOURCE_HOST" "$SOURCE_OS_USER" "$SOURCE_ORACLE_HOME" "$SOURCE_SID" <<'SQL'
set pages 300 lines 260
select name,db_unique_name,database_role,open_mode,log_mode,force_logging from v$database;
select name,value from v$parameter where name in ('log_archive_config','standby_file_management','remote_login_passwordfile','fal_server') or name like 'log_archive_dest_%' order by name;
select group#,thread#,bytes/1024/1024 mb,status from v$log order by thread#,group#;
select group#,thread#,bytes/1024/1024 mb,status from v$standby_log order by thread#,group#;
exit
SQL
}

dg_config_source_prepare(){
  local current members final
  current="$(remote_sql "$SOURCE_HOST" "$SOURCE_OS_USER" "$SOURCE_ORACLE_HOME" "$SOURCE_SID" <<'SQL' | tr -d '\r' | sed '/^[[:space:]]*$/d' | tail -1
set pages 0 feedback off heading off verify off echo off
select value from v$parameter where name='log_archive_config';
exit
SQL
)"
  if [[ "$current" =~ DG_CONFIG=\((.*)\) ]]; then members="${BASH_REMATCH[1]}"; else members="$SOURCE_DB_UNIQUE_NAME"; fi
  final="$(printf '%s,%s,%s\n' "$members" "$SOURCE_DB_UNIQUE_NAME" "$TARGET_DB_UNIQUE_NAME" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | awk 'NF{u=toupper($0);if(!seen[u]++) a[++n]=$0} END{for(i=1;i<=n;i++)printf "%s%s",(i>1?",":""),a[i]}')"

  local used id
  used="$(remote_sql "$SOURCE_HOST" "$SOURCE_OS_USER" "$SOURCE_ORACLE_HOME" "$SOURCE_SID" <<'SQL' | awk 'NF{gsub(/[[:space:]]/,"",$1);print $1}'
set pages 0 feedback off heading off verify off echo off
select regexp_substr(name,'[0-9]+$') from v$parameter where regexp_like(name,'^log_archive_dest_[0-9]+$') and value is not null;
exit
SQL
)"
  id="${DG_ARCHIVE_DEST_ID:-}"
  if [[ -z "$id" ]]; then
    for n in $(seq 2 31); do if ! grep -qx "$n" <<<"$used"; then id="$n"; break; fi; done
  fi
  [[ -n "$id" ]] || die "No free LOG_ARCHIVE_DEST_n found."
  DG_ARCHIVE_DEST_ID="$id"; export DG_ARCHIVE_DEST_ID
  local dest="SERVICE=${TARGET_TNS_ALIAS} ASYNC VALID_FOR=(ONLINE_LOGFILES,PRIMARY_ROLE) DB_UNIQUE_NAME=${TARGET_DB_UNIQUE_NAME}"
  remote_sql "$SOURCE_HOST" "$SOURCE_OS_USER" "$SOURCE_ORACLE_HOME" "$SOURCE_SID" <<SQL
whenever sqlerror exit failure
alter system set log_archive_config='DG_CONFIG=($final)' scope=both;
alter system set standby_file_management='AUTO' scope=both;
alter system set log_archive_dest_${id}='$dest' scope=both;
alter system set log_archive_dest_state_${id}='DEFER' scope=both;
exit
SQL
  echo "$id" > "${CURRENT_JOB_DIR:-$REPORT_ROOT}/dg_archive_dest_id" 2>/dev/null || true
}

dg_transport_enable(){
  local id="${DG_ARCHIVE_DEST_ID:-}"
  if [[ -z "$id" && -n "${CURRENT_JOB_DIR:-}" && -f "$CURRENT_JOB_DIR/dg_archive_dest_id" ]]; then id="$(cat "$CURRENT_JOB_DIR/dg_archive_dest_id")"; fi
  [[ -n "$id" ]] || die "DG_ARCHIVE_DEST_ID is unknown."
  remote_sql "$SOURCE_HOST" "$SOURCE_OS_USER" "$SOURCE_ORACLE_HOME" "$SOURCE_SID" <<SQL
whenever sqlerror exit failure
alter system set log_archive_dest_state_${id}='ENABLE' scope=both;
alter system archive log current;
exit
SQL

  # Prepare reverse transport on the standby for a future switchover without
  # overwriting an existing destination.
  local used rid
  used="$(remote_sql "$TARGET_HOST" "$TARGET_OS_USER" "$TARGET_ORACLE_HOME" "$TARGET_SID" <<'SQL' | awk 'NF{gsub(/[[:space:]]/,"",$1);print $1}'
set pages 0 feedback off heading off verify off echo off
select regexp_substr(name,'[0-9]+$') from v$parameter where regexp_like(name,'^log_archive_dest_[0-9]+$') and value is not null;
exit
SQL
)"
  for n in $(seq 2 31); do if ! grep -qx "$n" <<<"$used"; then rid="$n"; break; fi; done
  [[ -n "${rid:-}" ]] || die "No free LOG_ARCHIVE_DEST_n on standby for reverse transport."
  remote_sql "$TARGET_HOST" "$TARGET_OS_USER" "$TARGET_ORACLE_HOME" "$TARGET_SID" <<SQL
whenever sqlerror exit failure
alter system set fal_server='${SOURCE_TNS_ALIAS}' scope=both;
alter system set log_archive_dest_${rid}='SERVICE=${SOURCE_TNS_ALIAS} ASYNC VALID_FOR=(ONLINE_LOGFILES,PRIMARY_ROLE) DB_UNIQUE_NAME=${SOURCE_DB_UNIQUE_NAME}' scope=both;
alter system set log_archive_dest_state_${rid}='ENABLE' scope=both;
exit
SQL
}

ensure_srl_on_db(){
  local host="$1" user="$2" oh="$3" sid="$4" label="$5"
  local data
  data="$(remote_sql "$host" "$user" "$oh" "$sid" <<'SQL'
set pages 0 feedback off heading off verify off echo off
select thread#||'|'||count(*)||'|'||max(bytes) from v$log group by thread# order by thread#;
select 'OMF|'||nvl(value,'') from v$parameter where name='db_create_file_dest';
select 'MAXGROUP|'||greatest(nvl((select max(group#) from v$log),0),nvl((select max(group#) from v$standby_log),0)) from dual;
exit
SQL
)"
  local omf maxg
  omf="$(sed -n 's/^OMF|//p' <<<"$data" | tail -1)"
  maxg="$(sed -n 's/^MAXGROUP|//p' <<<"$data" | tail -1)"; maxg="${maxg// /}"; maxg="${maxg:-0}"
  while IFS='|' read -r thr online bytes; do
    [[ "$thr" =~ ^[0-9]+$ ]] || continue
    local current need size
    current="$(remote_sql "$host" "$user" "$oh" "$sid" <<SQL | awk 'NF{print \$1}' | tail -1
set pages 0 feedback off heading off
select count(*) from v\$standby_log where thread#=$thr;
exit
SQL
)"; current="${current:-0}"
    need=$((online+1-current)); ((need>0)) || continue
    size=$(( (bytes + 1048575) / 1048576 ))
    [[ -n "$omf" ]] || die "$label needs $need SRL group(s) for thread $thr but DB_CREATE_FILE_DEST is empty. Configure OMF or create SRLs manually."
    for ((i=0;i<need;i++)); do
      maxg=$((maxg+1))
      remote_sql "$host" "$user" "$oh" "$sid" <<SQL
whenever sqlerror exit failure
alter database add standby logfile thread $thr group $maxg size ${size}M;
exit
SQL
    done
  done <<<"$data"
}

dg_srl_ensure(){
  ensure_srl_on_db "$SOURCE_HOST" "$SOURCE_OS_USER" "$SOURCE_ORACLE_HOME" "$SOURCE_SID" PRIMARY
  ensure_srl_on_db "$TARGET_HOST" "$TARGET_OS_USER" "$TARGET_ORACLE_HOME" "$TARGET_SID" STANDBY
}
