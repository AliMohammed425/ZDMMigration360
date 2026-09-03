#!/usr/bin/env bash
set -euo pipefail

# Ordinal | production step | display name
# The ordinal is the operator-friendly task number used by:
#   tasks 1
#   tasks 1,10
#   tasks 1-10
# Step IDs can also be selected explicitly with:
#   steps 005,010,070
task_registry(){
cat <<'EOF'
1|005|production_preflight
2|010|validate_config
3|020|ssh_precheck
4|025|remote_tool_precheck
5|030|source_database_prerequisites
6|035|source_dataguard_inventory
7|040|target_precheck
8|042|configure_tns_aliases
9|043|configure_static_aux_listener
10|044|create_or_reuse_oci_placeholder_nomount
11|045|prepare_password_file
12|046|validate_tns_matrix
13|047|validate_SYSDBA_connectivity
14|048|detect_and_stage_TDE_keystore
15|049|prepare_DG_CONFIG_and_deferred_transport
16|050|validate_offline_backup
17|060|stage_and_checksum_offline_backup
18|069|validate_RMAN_duplicate_method
19|070|RMAN_standby_duplicate
20|080|restart_mount_and_start_redo_apply
21|085|enable_primary_redo_transport
22|090|ensure_standby_redo_logs
23|100|RAC_validation_and_enablement
24|101|RAC_enable_and_fix
25|110|Data_Guard_health
26|120|Data_Guard_sync
27|130|snapshot_readiness
28|140|switchover_readiness
29|150|failover_readiness
30|160|final_validation_report
31|170|final_validation_gate
EOF
}

task_list(){
  printf '%-5s %-7s %s\n' "TASK" "STEP" "NAME"
  printf '%-5s %-7s %s\n' "----" "----" "----"
  task_registry | while IFS='|' read -r idx step name; do
    local note=""
    [[ "$step" == 050 || "$step" == 060 ]] && note=" [OFFLINE_BACKUP only]"
    [[ "$step" == 100 || "$step" == 101 ]] && note=" [RAC only]"
    printf '%-5s %-7s %s%s\n' "$idx" "$step" "$name" "$note"
  done
}

task_count(){ task_registry | wc -l | tr -d ' '; }

task_row_by_index(){
  local wanted="$1"
  task_registry | awk -F'|' -v n="$wanted" '$1==n {print; exit}'
}

task_row_by_step(){
  local wanted
  wanted="$(printf '%03d' "$((10#$1))")"
  task_registry | awk -F'|' -v n="$wanted" '$2==n {print; exit}'
}

task_step_to_index(){
  local wanted
  wanted="$(printf '%03d' "$((10#$1))")"
  task_registry | awk -F'|' -v n="$wanted" '$2==n {print $1; exit}'
}

task_should_skip_condition(){
  local step="$1" method="${STANDBY_BUILD_METHOD:-ACTIVE_DUPLICATE}"
  method="${method^^}"
  if [[ "$step" == 050 || "$step" == 060 ]]; then
    [[ "$method" != "OFFLINE_BACKUP" ]] && return 0
  fi
  if [[ "$step" == 100 || "$step" == 101 ]]; then
    [[ "${TARGET_RAC_ENABLED:-NO}" != "YES" ]] && return 0
  fi
  return 1
}

task_execute_row(){
  local jid="$1" row="$2"
  local idx step name
  IFS='|' read -r idx step name <<<"$row"

  if task_should_skip_condition "$step"; then
    log "TASK $idx / STEP $step [$name] not applicable to current configuration; skipping."
    return 0
  fi

  case "$step" in
    005) run_step "$jid" "$step" "$name" production_preflight ;;
    010) run_step "$jid" "$step" "$name" precheck_validate_config ;;
    020) run_step "$jid" "$step" "$name" precheck_ssh ;;
    025) run_step "$jid" "$step" "$name" precheck_remote_tools ;;
    030) run_step "$jid" "$step" "$name" precheck_database_roles ;;
    035) run_step "$jid" "$step" "$name" dg_inventory ;;
    040) run_step "$jid" "$step" "$name" precheck_target_nonrac ;;
    042) run_step "$jid" "$step" "$name" tns_configure ;;
    043) run_step "$jid" "$step" "$name" aux_listener_configure ;;
    044) run_step "$jid" "$step" "$name" oci_placeholder_create ;;
    045) run_step "$jid" "$step" "$name" passwordfile_prepare ;;
    046) run_step "$jid" "$step" "$name" tns_validate_matrix ;;
    047) run_step "$jid" "$step" "$name" sysdba_connectivity_validate ;;
    048) run_step "$jid" "$step" "$name" tde_prepare ;;
    049) run_step "$jid" "$step" "$name" dg_config_source_prepare ;;
    050) run_step "$jid" "$step" "$name" rman_validate_backup ;;
    060) run_step "$jid" "$step" "$name" rman_stage_backup ;;
    069) run_step "$jid" "$step" "$name" rman_duplicate_method_validate ;;
    070)
      # A directly-selected duplicate must never bypass the production method gate.
      local gate_marker="$(job_dir "$jid")/steps/069_validate_RMAN_duplicate_method.status"
      if [[ ! -f "$gate_marker" || "$(cat "$gate_marker")" != "COMPLETED" ]]; then
        log "STEP 070 selected without a completed 069 gate; running 069 automatically."
        run_step "$jid" 069 validate_RMAN_duplicate_method rman_duplicate_method_validate || return $?
      fi
      if [[ "${STANDBY_BUILD_METHOD^^}" == "OFFLINE_BACKUP" ]]; then
        run_step "$jid" "$step" RMAN_offline_standby_duplicate rman_offline_duplicate
      else
        run_step "$jid" "$step" RMAN_active_standby_duplicate rman_active_duplicate
      fi
      ;;
    080) run_step "$jid" "$step" "$name" postbuild_restart_mount ;;
    085) run_step "$jid" "$step" "$name" dg_transport_enable ;;
    090) run_step "$jid" "$step" "$name" dg_srl_ensure ;;
    100) run_step "$jid" "$step" "$name" rac_validate ;;
    101) run_step "$jid" "$step" "$name" rac_enable ;;
    110) run_step "$jid" "$step" "$name" dg_health ;;
    120) run_step "$jid" "$step" "$name" dg_sync ;;
    130) run_step "$jid" "$step" "$name" snapshot_status ;;
    140) run_step "$jid" "$step" "$name" switchover_precheck ;;
    150) run_step "$jid" "$step" "$name" failover_precheck ;;
    160) run_step "$jid" "$step" "$name" final_validation_report ;;
    170) run_step "$jid" "$step" "$name" final_validation_gate ;;
    *) die "No task implementation for production step $step." ;;
  esac
}

# Normalize task ordinal selector.
# Supported:
#   all
#   7
#   1,10       -> inclusive range 1 through 10 (user-requested syntax)
#   1-10       -> inclusive range 1 through 10
#   1,4,7      -> explicit list (3+ comma-separated values)
task_indices_from_selector(){
  local sel="${1,,}" max
  max="$(task_count)"
  if [[ "$sel" == "all" ]]; then
    seq 1 "$max"
    return
  fi

  if [[ "$sel" =~ ^([0-9]+)-([0-9]+)$ ]]; then
    local a="${BASH_REMATCH[1]}" b="${BASH_REMATCH[2]}"
    (( a>=1 && b>=a && b<=max )) || die "Invalid task range $sel; valid task numbers are 1-$max."
    seq "$a" "$b"
    return
  fi

  if [[ "$sel" =~ ^([0-9]+),([0-9]+)$ ]]; then
    local a="${BASH_REMATCH[1]}" b="${BASH_REMATCH[2]}"
    (( a>=1 && b>=a && b<=max )) || die "Invalid task range $sel; valid task numbers are 1-$max."
    seq "$a" "$b"
    return
  fi

  if [[ "$sel" =~ ^[0-9]+$ ]]; then
    (( sel>=1 && sel<=max )) || die "Invalid task $sel; valid task numbers are 1-$max."
    echo "$sel"
    return
  fi

  if [[ "$sel" =~ ^[0-9]+(,[0-9]+){2,}$ ]]; then
    local x
    IFS=',' read -ra _xs <<<"$sel"
    for x in "${_xs[@]}"; do
      (( x>=1 && x<=max )) || die "Invalid task $x; valid task numbers are 1-$max."
      echo "$x"
    done
    return
  fi

  die "Invalid task selector '$sel'. Use N, N,M, N-M, N,N,N, or all."
}

# Explicit production step selector, e.g. steps 005,010,070.
task_indices_from_steps(){
  local sel="$1" token idx
  IFS=',' read -ra _steps <<<"$sel"
  for token in "${_steps[@]}"; do
    [[ "$token" =~ ^[0-9]{1,3}$ ]] || die "Invalid production step '$token'."
    idx="$(task_step_to_index "$token")"
    [[ -n "$idx" ]] || die "Unknown production step '$token'. Run task-list."
    echo "$idx"
  done
}

task_run_indices(){
  local jid="$1"; shift
  local indexes=("$@")
  [[ ${#indexes[@]} -gt 0 ]] || die "No tasks selected."

  CURRENT_JOB_ID="$jid"
  CURRENT_JOB_DIR="$(job_dir "$jid")"
  export CURRENT_JOB_ID CURRENT_JOB_DIR

  job_lock_acquire "$jid"
  job_meta_set "$jid" task "selected-tasks"
  job_meta_set "$jid" method "${STANDBY_BUILD_METHOD:-ACTIVE_DUPLICATE}"
  job_meta_set "$jid" started "$(ts)"
  job_meta_set "$jid" state RUNNING

  local idx row rc=0
  for idx in "${indexes[@]}"; do
    row="$(task_row_by_index "$idx")"
    [[ -n "$row" ]] || die "Unknown task ordinal $idx."
    task_execute_row "$jid" "$row" || { rc=$?; break; }
  done

  job_meta_set "$jid" exit_code "$rc"
  job_meta_set "$jid" finished "$(ts)"
  if [[ "$rc" -eq 0 ]]; then
    job_meta_set "$jid" state COMPLETED
  else
    job_meta_set "$jid" state FAILED
  fi
  return "$rc"
}

task_run_selector(){
  local jid="$1" selector="$2"
  local -a idxs=()
  mapfile -t idxs < <(task_indices_from_selector "$selector")
  task_run_indices "$jid" "${idxs[@]}"
}

task_run_steps(){
  local jid="$1" selector="$2"
  local -a idxs=()
  mapfile -t idxs < <(task_indices_from_steps "$selector")
  task_run_indices "$jid" "${idxs[@]}"
}

task_failed_from(){
  local jid="$1"
  local dir; dir="$(job_dir "$jid")"
  [[ -d "$dir" ]] || die "Unknown job: $jid"
  load_job_config "$jid"

  local failed_step idx max
  failed_step="$(job_meta_get "$jid" failed_step || true)"
  [[ -n "$failed_step" ]] || die "Job $jid has no recorded failed step."
  idx="$(task_step_to_index "$failed_step")"
  [[ -n "$idx" ]] || die "Failed step $failed_step is not in the production registry."
  max="$(task_count)"

  reset_failed_step "$jid"
  local -a idxs=()
  mapfile -t idxs < <(seq "$idx" "$max")
  task_run_indices "$jid" "${idxs[@]}"
}

task_submit_background(){
  local kind="$1" selector="$2" jid="${3:-$(new_job_id)}"
  mkdir -p "$(job_dir "$jid")"
  job_meta_set "$jid" task "selected-$kind:$selector"
  job_meta_set "$jid" method "${STANDBY_BUILD_METHOD:-ACTIVE_DUPLICATE}"
  job_meta_set "$jid" selection_kind "$kind"
  job_meta_set "$jid" selection "$selector"
  snapshot_job_config "$jid"

  local out="$(job_dir "$jid")/output.log"
  setsid "$ZDM360_ROOT/bin/zdm360-standby" internal-selected "$jid" "$kind" "$selector" >>"$out" 2>&1 < /dev/null &
  local pid=$! pgid
  pgid="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
  pgid="${pgid:-$pid}"
  job_meta_set "$jid" pid "$pid"
  job_meta_set "$jid" pgid "$pgid"
  job_meta_set "$jid" state RUNNING
  job_meta_set "$jid" started "$(ts)"
  echo "Submitted selected-task background job: $jid"
  echo "Selection: $kind $selector"
  echo "PID/PGID : $pid/$pgid"
  echo "Status   : $ZDM360_ROOT/bin/zdm360-standby status $jid"
  echo "Logs     : $ZDM360_ROOT/bin/zdm360-standby logs $jid"
}

task_failed_from_background(){
  local jid="$1" dir; dir="$(job_dir "$jid")"
  [[ -d "$dir" ]] || die "Unknown job: $jid"
  local out="$dir/output.log"
  setsid "$ZDM360_ROOT/bin/zdm360-standby" internal-failed-from "$jid" >>"$out" 2>&1 < /dev/null &
  local pid=$! pgid
  pgid="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
  pgid="${pgid:-$pid}"
  job_meta_set "$jid" pid "$pid"
  job_meta_set "$jid" pgid "$pgid"
  job_meta_set "$jid" state RUNNING
  echo "Resuming job $jid from its failed task in background."
  echo "PID/PGID: $pid/$pgid"
}
