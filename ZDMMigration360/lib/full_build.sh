#!/usr/bin/env bash
set -euo pipefail

show_full_build_summary(){
  cat <<EOF

======================================================================
 COMPLETE STANDBY BUILD SUMMARY
======================================================================
Source DB_NAME           : $SOURCE_DB_NAME
Source DB_UNIQUE_NAME    : $SOURCE_DB_UNIQUE_NAME
Source Host              : $SOURCE_HOST
Source Service           : $SOURCE_SERVICE

Target DB_NAME           : $TARGET_DB_NAME
Target DB_UNIQUE_NAME    : $TARGET_DB_UNIQUE_NAME
Target Host              : $TARGET_HOST
Target Service           : $TARGET_SERVICE
OCI Platform             : ${OCI_TARGET_PLATFORM:-AUTO}

Standby Method           : $STANDBY_BUILD_METHOD
Target RAC               : ${TARGET_RAC_ENABLED:-NO}
Background               : ${FULL_BUILD_BACKGROUND:-YES}

Workflow:
  Production all-tasks plan: preflight, TNS/static auxiliary listener,
  OCI placeholder, password file, SYSDBA connectivity, TDE handling,
  Data Guard parameter preparation, RMAN duplicate, redo transport,
  standby redo logs, RAC processing, synchronization and final report.
======================================================================
EOF
}

complete_build_wizard(){
  collect_full_build_inputs
  write_runtime_config "$ZDM360_ROOT/conf/standby.env"
  show_full_build_summary

  local ans
  read -r -p "Start complete standby build now? Type BUILD to continue: " ans
  [[ "$ans" == "BUILD" ]] || {
    echo "Build not started. Configuration has been saved."
    return 0
  }

  # Secrets remain exported in this process and are inherited by the background
  # subshell when requested. They are never written to the job metadata/config.
  if [[ "${FULL_BUILD_BACKGROUND:-YES}" == "YES" ]]; then
    submit_all_tasks_background
  else
    local jid
    jid="$(new_job_id)"
    mkdir -p "$(job_dir "$jid")"
    echo "Job ID: $jid"
    workflow_all_tasks "$jid"
    show_job "$jid"
  fi
}

complete_build_noninteractive(){
  validate_full_build_inputs
  show_full_build_summary

  if [[ "${FULL_BUILD_BACKGROUND:-YES}" == "YES" ]]; then
    submit_all_tasks_background
  else
    local jid
    jid="$(new_job_id)"
    mkdir -p "$(job_dir "$jid")"
    echo "Job ID: $jid"
    workflow_all_tasks "$jid"
    show_job "$jid"
  fi
}
