#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export ZDM360_ROOT="$ROOT"
export RUN_ROOT="$(mktemp -d /tmp/zdm360_selftest_runs.XXXXXX)"
trap 'rm -rf "$RUN_ROOT" /tmp/zdm360_bad.drv' EXIT
source "$ROOT/lib/common.sh"
source "$ROOT/lib/driver_file.sh"
source "$ROOT/lib/batch.sh"
source "$ROOT/lib/task_select.sh"

# Driver parser must reject arbitrary shell input.
cat >/tmp/zdm360_bad.drv <<'DRV'
SOURCE_DB_NAME=ORCL
EVIL_COMMAND=$(touch /tmp/ZDM360_SHOULD_NOT_EXIST)
DRV
if (load_driver_file /tmp/zdm360_bad.drv) >/dev/null 2>&1; then echo "FAIL: unsafe driver key accepted"; exit 1; fi
[[ ! -e /tmp/ZDM360_SHOULD_NOT_EXIST ]] || { echo "FAIL: driver executed shell"; exit 1; }

# Mock every workflow function to validate step engine, status and ordering.
for fn in operator_access_preflight production_preflight precheck_validate_config precheck_ssh precheck_remote_tools precheck_database_roles dg_inventory precheck_target_nonrac tns_configure aux_listener_configure oci_placeholder_create passwordfile_prepare tns_validate_matrix sysdba_connectivity_validate tde_prepare dg_config_source_prepare rman_duplicate_method_validate rman_validate_backup rman_stage_backup rman_offline_duplicate rman_active_duplicate postbuild_restart_mount dg_transport_enable dg_srl_ensure rac_validate rac_enable dg_health dg_sync snapshot_status switchover_precheck failover_precheck final_validation_report final_validation_gate; do
  eval "$fn(){ echo MOCK:$fn; return 0; }"
done
SOURCE_DB_NAME=ORCL; SOURCE_DB_UNIQUE_NAME=ORCLPRD; SOURCE_SID=ORCL1; SOURCE_HOST=src; SOURCE_OS_USER=oracle; SOURCE_ORACLE_HOME=/oh; SOURCE_SERVICE=srcsvc; SOURCE_TNS_ALIAS=SRC
TARGET_DB_NAME=ORCL; TARGET_DB_UNIQUE_NAME=ORCLSTBY; TARGET_SID=ORCL1; TARGET_HOST=tgt; TARGET_OS_USER=oracle; TARGET_ORACLE_HOME=/oh; TARGET_SERVICE=tgtsvc; TARGET_TNS_ALIAS=TGT
STANDBY_BUILD_METHOD=ACTIVE_DUPLICATE; TARGET_RAC_ENABLED=NO
export SOURCE_DB_NAME SOURCE_DB_UNIQUE_NAME SOURCE_SID SOURCE_HOST SOURCE_OS_USER SOURCE_ORACLE_HOME SOURCE_SERVICE SOURCE_TNS_ALIAS TARGET_DB_NAME TARGET_DB_UNIQUE_NAME TARGET_SID TARGET_HOST TARGET_OS_USER TARGET_ORACLE_HOME TARGET_SERVICE TARGET_TNS_ALIAS STANDBY_BUILD_METHOD TARGET_RAC_ENABLED
jid=test_$$; mkdir -p "$(job_dir "$jid")"; workflow_all_tasks "$jid"
[[ "$(job_state "$jid")" == COMPLETED ]] || { echo "FAIL: workflow state"; exit 1; }
[[ "$(cat "$(job_dir "$jid")/steps/170_final_validation_gate.status")" == COMPLETED ]] || { echo "FAIL: final gate missing"; exit 1; }

# Task selector parser checks.
mapfile -t _range < <(task_indices_from_selector "1,10")
[[ "${#_range[@]}" -eq 10 && "${_range[0]}" == 1 && "${_range[9]}" == 10 ]] || { echo "FAIL: task range parser"; exit 1; }
mapfile -t _list < <(task_indices_from_selector "1,4,7")
[[ "${#_list[@]}" -eq 3 && "${_list[1]}" == 4 ]] || { echo "FAIL: task list parser"; exit 1; }
[[ "$(task_step_to_index 070)" == 19 ]] || { echo "FAIL: production step mapping"; exit 1; }
echo "SELFTEST PASS"

