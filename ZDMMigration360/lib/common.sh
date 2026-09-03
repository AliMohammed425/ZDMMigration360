#!/usr/bin/env bash
set -euo pipefail

ZDM360_ROOT="${ZDM360_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
RUN_ROOT="${RUN_ROOT:-$ZDM360_ROOT/runs}"
LOG_ROOT="${LOG_ROOT:-$ZDM360_ROOT/logs}"
REPORT_ROOT="${REPORT_ROOT:-$ZDM360_ROOT/reports}"
CONFIG_FILE="${CONFIG_FILE:-$ZDM360_ROOT/conf/standby.env}"

mkdir -p "$RUN_ROOT" "$LOG_ROOT" "$REPORT_ROOT"
umask 077

ts(){ date '+%Y-%m-%d %H:%M:%S'; }
die(){ echo "ERROR: $*" >&2; exit 1; }
log(){ echo "[$(ts)] $*"; }

load_config(){
  if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
  fi
}

require_var(){
  local n="$1"
  [[ -n "${!n:-}" ]] || die "$n is required. Set it in $CONFIG_FILE or environment."
}

safe_name(){
  printf '%s' "$1" | tr -cs 'A-Za-z0-9_.-' '_'
}

new_job_id(){
  printf '%s_%s_%s' "$(date '+%Y%m%d_%H%M%S')" "$$" "$(printf '%04d' $((RANDOM%10000)))"
}

job_dir(){ printf '%s/%s' "$RUN_ROOT" "$1"; }

job_lock_acquire(){
  local jid="$1"; local dir; dir="$(job_dir "$jid")"; mkdir -p "$dir"
  exec {JOB_LOCK_FD}>"$dir/job.lock"
  flock -n "$JOB_LOCK_FD" || die "Job $jid is already running/resuming."
}

snapshot_job_config(){
  local jid="$1" dir; dir="$(job_dir "$jid")"; mkdir -p "$dir"
  local vars=(SOURCE_DB_NAME SOURCE_DB_UNIQUE_NAME SOURCE_SID SOURCE_HOST SOURCE_OS_USER SOURCE_ORACLE_HOME SOURCE_LISTENER_PORT SOURCE_SERVICE SOURCE_IS_CDB SOURCE_TNS_ALIAS TARGET_DB_NAME TARGET_DB_UNIQUE_NAME TARGET_SID TARGET_HOST TARGET_OS_USER TARGET_PROVISION_OS_USER TARGET_ORACLE_HOME TARGET_LISTENER_PORT TARGET_AUX_PORT TARGET_AUX_LISTENER_NAME TARGET_SERVICE TARGET_TNS_ALIAS OCI_TARGET_PLATFORM TARGET_DB_CREATE_FILE_DEST TARGET_DB_RECOVERY_FILE_DEST TARGET_DB_RECOVERY_FILE_DEST_SIZE STANDBY_BUILD_METHOD SOURCE_BACKUP_STAGE TARGET_BACKUP_STAGE BACKUP_COPY_METHOD TARGET_RAC_ENABLED TARGET_RAC_INSTANCES TARGET_GRID_HOME TARGET_UNDO_PREFIX TARGET_REDO_SIZE_MB RAC_CONVERSION_MODE SYNC_WAIT_SECONDS SYNC_POLL_SECONDS SOURCE_TDE_WALLET_PATH TARGET_TDE_WALLET_PATH DG_ARCHIVE_DEST_ID)
  : > "$dir/input.env"
  local v; for v in "${vars[@]}"; do printf '%s=%q\n' "$v" "${!v:-}" >> "$dir/input.env"; done
  chmod 600 "$dir/input.env"
  if [[ -n "${ZDM360_DRIVER_FILE:-}" ]]; then printf '%s\n' "$ZDM360_DRIVER_FILE" > "$dir/driver_file"; fi
  return 0
}

load_job_config(){
  local jid="$1" dir; dir="$(job_dir "$jid")"
  [[ -f "$dir/input.env" ]] && source "$dir/input.env"
  if [[ -f "$dir/driver_file" ]]; then local d; d="$(cat "$dir/driver_file")"; [[ -f "$d" ]] && load_driver_file "$d"; fi
}


job_meta_set(){
  local jid="$1" key="$2" val="$3"
  local dir; dir="$(job_dir "$jid")"
  mkdir -p "$dir"
  printf '%s\n' "$val" > "$dir/$key"
}

job_meta_get(){
  local jid="$1" key="$2"
  local f="$(job_dir "$jid")/$key"
  [[ -f "$f" ]] && cat "$f"
}

job_state(){
  local jid="$1"
  local dir; dir="$(job_dir "$jid")"
  [[ -d "$dir" ]] || die "Unknown job: $jid"

  if [[ -f "$dir/state" ]]; then
    local st; st="$(cat "$dir/state")"
    if [[ "$st" == "RUNNING" ]]; then
      local rpid; rpid="$(job_meta_get "$jid" pid || true)"
      if [[ -n "$rpid" ]] && ! kill -0 "$rpid" 2>/dev/null; then
        if [[ -f "$dir/exit_code" ]]; then
          local erc; erc="$(cat "$dir/exit_code")"; [[ "$erc" == 0 ]] && echo COMPLETED || echo FAILED
        else
          echo STALE
        fi
        return
      fi
    fi
    echo "$st"
    return
  fi

  local pid
  pid="$(job_meta_get "$jid" pid || true)"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    echo RUNNING
  elif [[ -f "$dir/exit_code" ]]; then
    local rc; rc="$(cat "$dir/exit_code")"
    [[ "$rc" == "0" ]] && echo COMPLETED || echo FAILED
  else
    echo UNKNOWN
  fi
}

run_step(){
  # run_step <jobid> <step_number> <step_name> <command...>
  local jid="$1" step="$2" name="$3"; shift 3
  local dir; dir="$(job_dir "$jid")"
  mkdir -p "$dir/steps"

  local marker="$dir/steps/${step}_$(safe_name "$name")"
  local status_file="${marker}.status"
  local log_file="${marker}.log"

  if [[ -f "$status_file" ]] && [[ "$(cat "$status_file")" == "COMPLETED" ]]; then
    log "STEP $step [$name] already completed; skipping."
    return 0
  fi

  printf '%s\n' "$step" > "$dir/current_step"
  printf '%s\n' "$name" > "$dir/current_step_name"
  printf '%s\n' "RUNNING" > "$status_file"
  local attempt_file="${marker}.attempt" attempt=0
  [[ -f "$attempt_file" ]] && attempt="$(cat "$attempt_file")"
  attempt=$((attempt+1)); printf '%s\n' "$attempt" > "$attempt_file"
  printf '%s\n' "$(ts)" > "${marker}.started"

  log "STEP $step [$name] starting."
  set +e
  "$@" > >(tee -a "$log_file") 2> >(tee -a "$log_file" >&2)
  rc=$?
  set -e

  printf '%s\n' "$(ts)" > "${marker}.finished"
  printf '%s\n' "$rc" > "${marker}.exit_code"

  if [[ "$rc" -eq 0 ]]; then
    printf '%s\n' "COMPLETED" > "$status_file"
    log "STEP $step [$name] completed."
    return 0
  else
    printf '%s\n' "FAILED" > "$status_file"
    printf '%s\n' "FAILED" > "$dir/state"
    printf '%s\n' "$step" > "$dir/failed_step"
    printf '%s\n' "$name" > "$dir/failed_step_name"
    log "STEP $step [$name] FAILED rc=$rc."
    return "$rc"
  fi
}

reset_failed_step(){
  local jid="$1"
  local dir; dir="$(job_dir "$jid")"
  [[ -d "$dir" ]] || die "Unknown job: $jid"
  local step name
  step="$(cat "$dir/failed_step" 2>/dev/null || true)"
  name="$(cat "$dir/failed_step_name" 2>/dev/null || true)"
  [[ -n "$step" && -n "$name" ]] || return 0
  rm -f "$dir/steps/${step}_$(safe_name "$name").status" \
        "$dir/steps/${step}_$(safe_name "$name").exit_code" \
        "$dir/steps/${step}_$(safe_name "$name").finished"
  rm -f "$dir/failed_step" "$dir/failed_step_name"
  printf '%s\n' "READY" > "$dir/state"
}

show_job(){
  local jid="$1"
  local dir; dir="$(job_dir "$jid")"
  [[ -d "$dir" ]] || die "Unknown job: $jid"
  echo "Job ID        : $jid"
  echo "Task          : $(job_meta_get "$jid" task || true)"
  echo "Method        : $(job_meta_get "$jid" method || true)"
  echo "State         : $(job_state "$jid")"
  echo "PID           : $(job_meta_get "$jid" pid || true)"
  echo "Started       : $(job_meta_get "$jid" started || true)"
  echo "Finished      : $(job_meta_get "$jid" finished || true)"
  echo "Current step  : $(job_meta_get "$jid" current_step || true) $(job_meta_get "$jid" current_step_name || true)"
  echo "Failed step   : $(job_meta_get "$jid" failed_step || true) $(job_meta_get "$jid" failed_step_name || true)"
  echo "Exit code     : $(job_meta_get "$jid" exit_code || true)"
  echo "Job directory : $dir"
  echo
  if compgen -G "$dir/steps/*.status" >/dev/null; then
    echo "Steps:"
    for f in "$dir"/steps/*.status; do
      printf '  %-55s %s\n' "$(basename "$f" .status)" "$(cat "$f")"
    done
  fi
}

list_jobs(){
  printf '%-28s %-20s %-18s %-10s\n' "JOB_ID" "TASK" "METHOD" "STATE"
  printf '%-28s %-20s %-18s %-10s\n' "------" "----" "------" "-----"
  local d jid
  shopt -s nullglob
  for d in "$RUN_ROOT"/*; do
    [[ -d "$d" ]] || continue
    jid="$(basename "$d")"
    printf '%-28s %-20s %-18s %-10s\n' \
      "$jid" \
      "$(job_meta_get "$jid" task || true)" \
      "$(job_meta_get "$jid" method || true)" \
      "$(job_state "$jid" || true)"
  done
  shopt -u nullglob
}
