#!/usr/bin/env bash
set -euo pipefail

all_task_plan(){
cat <<'PLAN'
005 production_preflight
010 validate_config
020 ssh_precheck
025 remote_tool_precheck
030 source_database_prerequisites
035 source_dataguard_inventory
040 target_precheck
042 configure_tns_aliases
043 configure_static_aux_listener
044 create_or_reuse_oci_placeholder_nomount
045 prepare_password_file
046 validate_tns_matrix
047 validate_SYSDBA_connectivity
048 detect_and_stage_TDE_keystore
049 prepare_DG_CONFIG_and_deferred_transport
050 validate_offline_backup             [OFFLINE_BACKUP only]
060 stage_and_checksum_offline_backup   [OFFLINE_BACKUP only]
069 validate_RMAN_duplicate_method
070 RMAN_standby_duplicate
080 restart_mount_and_start_redo_apply
085 enable_primary_redo_transport
090 ensure_standby_redo_logs_primary_and_standby
100 RAC_validation_and_enablement       [RAC target only]
110 Data_Guard_health
120 Data_Guard_sync
130 snapshot_readiness
140 switchover_readiness
150 failover_readiness
160 final_validation_report
170 final_validation_gate
PLAN
}

workflow_all_tasks(){
  local jid="$1" method="${STANDBY_BUILD_METHOD:-ACTIVE_DUPLICATE}"; method="${method^^}"
  CURRENT_JOB_ID="$jid"; CURRENT_JOB_DIR="$(job_dir "$jid")"; export CURRENT_JOB_ID CURRENT_JOB_DIR
  job_lock_acquire "$jid"
  job_meta_set "$jid" task "all-tasks"; job_meta_set "$jid" method "$method"; job_meta_set "$jid" started "$(ts)"; job_meta_set "$jid" state RUNNING
  snapshot_job_config "$jid"
  local rc=0
  run_step "$jid" 005 production_preflight production_preflight || rc=$?; [[ $rc -eq 0 ]] || return $rc
  run_step "$jid" 010 validate_config precheck_validate_config || rc=$?; [[ $rc -eq 0 ]] || return $rc
  run_step "$jid" 020 ssh_precheck precheck_ssh || rc=$?; [[ $rc -eq 0 ]] || return $rc
  run_step "$jid" 025 remote_tool_precheck precheck_remote_tools || rc=$?; [[ $rc -eq 0 ]] || return $rc
  run_step "$jid" 030 source_database_prerequisites precheck_database_roles || rc=$?; [[ $rc -eq 0 ]] || return $rc
  run_step "$jid" 035 source_dataguard_inventory dg_inventory || rc=$?; [[ $rc -eq 0 ]] || return $rc
  run_step "$jid" 040 target_precheck precheck_target_nonrac || rc=$?; [[ $rc -eq 0 ]] || return $rc
  run_step "$jid" 042 configure_tns_aliases tns_configure || rc=$?; [[ $rc -eq 0 ]] || return $rc
  run_step "$jid" 043 configure_static_aux_listener aux_listener_configure || rc=$?; [[ $rc -eq 0 ]] || return $rc
  run_step "$jid" 044 create_or_reuse_oci_placeholder_nomount oci_placeholder_create || rc=$?; [[ $rc -eq 0 ]] || return $rc
  run_step "$jid" 045 prepare_password_file passwordfile_prepare || rc=$?; [[ $rc -eq 0 ]] || return $rc
  run_step "$jid" 046 validate_tns_matrix tns_validate_matrix || rc=$?; [[ $rc -eq 0 ]] || return $rc
  run_step "$jid" 047 validate_SYSDBA_connectivity sysdba_connectivity_validate || rc=$?; [[ $rc -eq 0 ]] || return $rc
  run_step "$jid" 048 detect_and_stage_TDE_keystore tde_prepare || rc=$?; [[ $rc -eq 0 ]] || return $rc
  run_step "$jid" 049 prepare_DG_CONFIG_and_deferred_transport dg_config_source_prepare || rc=$?; [[ $rc -eq 0 ]] || return $rc
  if [[ "$method" == OFFLINE_BACKUP ]]; then
    run_step "$jid" 050 validate_offline_backup rman_validate_backup || rc=$?; [[ $rc -eq 0 ]] || return $rc
    run_step "$jid" 060 stage_and_checksum_offline_backup rman_stage_backup || rc=$?; [[ $rc -eq 0 ]] || return $rc
  fi
  run_step "$jid" 069 validate_RMAN_duplicate_method rman_duplicate_method_validate || rc=$?; [[ $rc -eq 0 ]] || return $rc
  if [[ "$method" == OFFLINE_BACKUP ]]; then
    run_step "$jid" 070 RMAN_offline_standby_duplicate rman_offline_duplicate || rc=$?; [[ $rc -eq 0 ]] || return $rc
  else
    run_step "$jid" 070 RMAN_active_standby_duplicate rman_active_duplicate || rc=$?; [[ $rc -eq 0 ]] || return $rc
  fi
  run_step "$jid" 080 restart_mount_and_start_redo_apply postbuild_restart_mount || rc=$?; [[ $rc -eq 0 ]] || return $rc
  run_step "$jid" 085 enable_primary_redo_transport dg_transport_enable || rc=$?; [[ $rc -eq 0 ]] || return $rc
  run_step "$jid" 090 ensure_standby_redo_logs dg_srl_ensure || rc=$?; [[ $rc -eq 0 ]] || return $rc
  if [[ "${TARGET_RAC_ENABLED:-NO}" == YES ]]; then
    run_step "$jid" 100 RAC_validation_and_enablement rac_validate || rc=$?; [[ $rc -eq 0 ]] || return $rc
    run_step "$jid" 101 RAC_enable_and_fix rac_enable || rc=$?; [[ $rc -eq 0 ]] || return $rc
  fi
  run_step "$jid" 110 Data_Guard_health dg_health || rc=$?; [[ $rc -eq 0 ]] || return $rc
  run_step "$jid" 120 Data_Guard_sync dg_sync || rc=$?; [[ $rc -eq 0 ]] || return $rc
  run_step "$jid" 130 snapshot_readiness snapshot_status || rc=$?; [[ $rc -eq 0 ]] || return $rc
  run_step "$jid" 140 switchover_readiness switchover_precheck || rc=$?; [[ $rc -eq 0 ]] || return $rc
  run_step "$jid" 150 failover_readiness failover_precheck || rc=$?; [[ $rc -eq 0 ]] || return $rc
  run_step "$jid" 160 final_validation_report final_validation_report || rc=$?; [[ $rc -eq 0 ]] || return $rc
  run_step "$jid" 170 final_validation_gate final_validation_gate || rc=$?; [[ $rc -eq 0 ]] || return $rc
  job_meta_set "$jid" state COMPLETED; job_meta_set "$jid" finished "$(ts)"; job_meta_set "$jid" exit_code 0
}

workflow_all_tasks_resume(){
  local jid="$1"; load_job_config "$jid"; reset_failed_step "$jid"; workflow_all_tasks "$jid"
}

_submit_detached(){
  local jid="$1" action="$2" out="$(job_dir "$jid")/output.log"
  mkdir -p "$(job_dir "$jid")"
  setsid "$ZDM360_ROOT/bin/zdm360-standby" "internal-${action}" "$jid" >>"$out" 2>&1 < /dev/null &
  local pid=$! pgid; pgid="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ' || true)"; pgid="${pgid:-$pid}"
  job_meta_set "$jid" pid "$pid"; job_meta_set "$jid" pgid "$pgid"; job_meta_set "$jid" state RUNNING; job_meta_set "$jid" started "$(ts)"
  echo "Submitted background job: $jid"; echo "PID/PGID: $pid/$pgid"; echo "Status: $ZDM360_ROOT/bin/zdm360-standby status $jid"; echo "Logs: $ZDM360_ROOT/bin/zdm360-standby logs $jid"
}

submit_all_tasks_background(){
  local jid="${1:-$(new_job_id)}"; mkdir -p "$(job_dir "$jid")"; job_meta_set "$jid" task all-tasks; job_meta_set "$jid" method "${STANDBY_BUILD_METHOD:-ACTIVE_DUPLICATE}"; snapshot_job_config "$jid"; _submit_detached "$jid" run-all
}
resume_all_tasks_background(){ local jid="$1"; _submit_detached "$jid" resume-all; }
