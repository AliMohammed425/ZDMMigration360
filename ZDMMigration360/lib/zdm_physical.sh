#!/usr/bin/env bash
set -euo pipefail

zdm_target_detect(){
  require_var TARGET_HOST
  local user="${TARGET_OS_USER:-${ORACLE_OS_USER:-oracle}}"
  local requested="${ZDM_TARGET_HOME:-}"
  local cmd='
set -e
if [ -n "'"$requested"'" ] && [ -x "'"$requested"'/bin/zdmcli" ]; then
  echo "'"$requested"'"
  exit 0
fi
for h in "$ZDM_HOME" /u01/app/zdmhome /opt/oracle/zdm /home/opc/zdmhome /home/zdmuser/zdmhome; do
  [ -n "$h" ] || continue
  if [ -x "$h/bin/zdmcli" ]; then echo "$h"; exit 0; fi
done
for f in /u01/app/*/bin/zdmcli /opt/oracle/*/bin/zdmcli /home/*/zdmhome/bin/zdmcli; do
  [ -x "$f" ] || continue
  dirname "$(dirname "$f")"
  exit 0
done
exit 3
'
  local home
  if home="$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$user@$TARGET_HOST" "$cmd" 2>/dev/null)"; then
    ZDM_TARGET_HOME="$(printf '%s\n' "$home" | tail -1)"
    export ZDM_TARGET_HOME
    echo "ZDM detected on target: $TARGET_HOST"
    echo "ZDM_HOME: $ZDM_TARGET_HOME"
    ssh "$user@$TARGET_HOST" "'$ZDM_TARGET_HOME/bin/zdmcli' -build" || true
    return 0
  fi
  echo "ZDM not detected on target host $TARGET_HOST for user $user."
  return 1
}

zdm_require_target(){
  zdm_target_detect || die "ZDM is not installed/detectable on target. Use native RMAN workflow or install ZDM first."
}

zdm_validate_inputs(){
  zdm_require_target
  require_var ZDM_RSP_FILE
  require_var SOURCE_HOST
  local method="${ZDM_PHYSICAL_METHOD:-${STANDBY_BUILD_METHOD:-ONLINE_PHYSICAL}}"
  method="${method^^}"
  case "$method" in
    ONLINE_PHYSICAL|OFFLINE_PHYSICAL) ;;
    ACTIVE_DUPLICATE) method=ONLINE_PHYSICAL ;;
    OFFLINE_BACKUP) method=OFFLINE_PHYSICAL ;;
    *) die "ZDM_PHYSICAL_METHOD must be ONLINE_PHYSICAL or OFFLINE_PHYSICAL." ;;
  esac
  ZDM_PHYSICAL_METHOD="$method"; export ZDM_PHYSICAL_METHOD

  local user="${TARGET_OS_USER:-${ORACLE_OS_USER:-oracle}}"
  ssh "$user@$TARGET_HOST" "test -r '$ZDM_RSP_FILE'" ||
    die "ZDM_RSP_FILE must exist and be readable on the target host: $ZDM_RSP_FILE"

  if [[ -n "${ZDM_SOURCE_SSH_KEY:-}" ]]; then
    ssh "$user@$TARGET_HOST" "test -r '$ZDM_SOURCE_SSH_KEY'" ||
      die "ZDM_SOURCE_SSH_KEY must exist on target ZDM host: $ZDM_SOURCE_SSH_KEY"
  fi
  echo "ZDM physical input validation: PASS"
  echo "Method: $ZDM_PHYSICAL_METHOD"
}

zdm_build_base_cmd(){
  local eval_mode="${1:-NO}"
  local cmd="'$ZDM_TARGET_HOME/bin/zdmcli' migrate database -rsp '$ZDM_RSP_FILE'"
  # Running ZDM from target using Instant Deploy/local target operations.
  # Source remains remote when a source node is supplied.
  cmd+=" -sourcenode '$SOURCE_HOST'"
  if [[ -n "${SOURCE_OS_USER:-}" && -n "${ZDM_SOURCE_SSH_KEY:-}" ]]; then
    cmd+=" -srcauth zdmauth -srcarg1 user:'$SOURCE_OS_USER' -srcarg2 identity_file:'$ZDM_SOURCE_SSH_KEY' -srcarg3 sudo_location:'${SOURCE_SUDO_LOCATION:-/usr/bin/sudo}'"
  fi
  [[ "$eval_mode" == YES ]] && cmd+=" -eval"
  printf '%s' "$cmd"
}

zdm_list_phases(){
  zdm_validate_inputs
  local user="${TARGET_OS_USER:-${ORACLE_OS_USER:-oracle}}" cmd
  cmd="$(zdm_build_base_cmd NO) -listphases"
  ssh "$user@$TARGET_HOST" "$cmd"
}

zdm_eval_physical(){
  zdm_validate_inputs
  local user="${TARGET_OS_USER:-${ORACLE_OS_USER:-oracle}}" cmd
  cmd="$(zdm_build_base_cmd YES)"
  echo "Submitting ZDM evaluation on target..."
  ssh "$user@$TARGET_HOST" "$cmd"
}

zdm_execute_physical(){
  zdm_validate_inputs
  local user="${TARGET_OS_USER:-${ORACLE_OS_USER:-oracle}}" cmd phase_output pause=""
  cmd="$(zdm_build_base_cmd NO)"

  if [[ "$ZDM_PHYSICAL_METHOD" == ONLINE_PHYSICAL && "${ZDM_PAUSE_AFTER_STANDBY:-YES}" == YES ]]; then
    echo "Checking ZDM phase list for standby-only pause point..."
    phase_output="$(ssh "$user@$TARGET_HOST" "$(zdm_build_base_cmd NO) -listphases" 2>&1)" || {
      printf '%s\n' "$phase_output"
      die "Unable to list ZDM phases. Run ZDM evaluation/listphases and correct prerequisites."
    }
    if grep -q 'ZDM_CONFIGURE_DG_SRC' <<<"$phase_output"; then
      pause=" -pauseafter ZDM_CONFIGURE_DG_SRC"
      echo "Standby-only mode enabled: job will pause after ZDM_CONFIGURE_DG_SRC."
      echo "This avoids automatic ZDM switchover until the operator explicitly resumes."
    else
      die "ZDM_CONFIGURE_DG_SRC is not in this job's valid phase list; refusing standby-only execution."
    fi
  elif [[ "$ZDM_PHYSICAL_METHOD" == OFFLINE_PHYSICAL ]]; then
    echo "NOTICE: OFFLINE_PHYSICAL is backup/restore migration, not a continuously applying Data Guard standby."
  fi

  echo "Submitting ZDM physical migration on target..."
  ssh "$user@$TARGET_HOST" "$cmd$pause"
}

zdm_query_jobs(){
  zdm_require_target
  local user="${TARGET_OS_USER:-${ORACLE_OS_USER:-oracle}}"
  ssh "$user@$TARGET_HOST" "'$ZDM_TARGET_HOME/bin/zdmcli' query job -latest"
}

zdm_query_job(){
  local jobid="${1:?ZDM job ID required}"
  zdm_require_target
  local user="${TARGET_OS_USER:-${ORACLE_OS_USER:-oracle}}"
  ssh "$user@$TARGET_HOST" "'$ZDM_TARGET_HOME/bin/zdmcli' query job -jobid '$jobid'"
}

zdm_resume_job(){
  local jobid="${1:?ZDM job ID required}"
  zdm_require_target
  local user="${TARGET_OS_USER:-${ORACLE_OS_USER:-oracle}}"
  ssh "$user@$TARGET_HOST" "'$ZDM_TARGET_HOME/bin/zdmcli' resume job -jobid '$jobid'"
}

zdm_suspend_job(){
  local jobid="${1:?ZDM job ID required}"
  zdm_require_target
  local user="${TARGET_OS_USER:-${ORACLE_OS_USER:-oracle}}"
  ssh "$user@$TARGET_HOST" "'$ZDM_TARGET_HOME/bin/zdmcli' suspend job -jobid '$jobid'"
}

zdm_abort_job(){
  local jobid="${1:?ZDM job ID required}"
  zdm_require_target
  local user="${TARGET_OS_USER:-${ORACLE_OS_USER:-oracle}}"
  ssh "$user@$TARGET_HOST" "'$ZDM_TARGET_HOME/bin/zdmcli' abort job -jobid '$jobid'"
}

interactive_zdm_menu(){
  interactive_load_default_driver
  echo
  if zdm_target_detect; then
    :
  else
    echo "Native RMAN workflow remains available."
    return 0
  fi

  while true; do
    cat <<'EOF'

ZDM Physical Migration / Standby Menu
-------------------------------------
1) Detect ZDM and show version
2) Validate ZDM inputs / response file
3) List ZDM physical migration phases
4) Evaluate ZDM physical migration (-eval)
5) ONLINE_PHYSICAL - build/configure standby and PAUSE before switchover
6) ONLINE_PHYSICAL - execute full ZDM migration (includes switchover)
7) OFFLINE_PHYSICAL - backup/restore migration
8) Query latest ZDM job
9) Query ZDM job ID
10) Resume ZDM job
11) Suspend ZDM job
12) Abort ZDM job
0) Back
EOF
    read -r -p "Choice: " zc
    case "$zc" in
      1) zdm_target_detect ;;
      2) zdm_validate_inputs ;;
      3) zdm_list_phases ;;
      4) zdm_eval_physical ;;
      5)
        ZDM_PHYSICAL_METHOD=ONLINE_PHYSICAL
        ZDM_PAUSE_AFTER_STANDBY=YES
        export ZDM_PHYSICAL_METHOD ZDM_PAUSE_AFTER_STANDBY
        read -r -p "Execute ZDM ONLINE_PHYSICAL and pause after standby configuration? Type ZDM: " ack
        [[ "$ack" == ZDM ]] && zdm_execute_physical
        ;;
      6)
        ZDM_PHYSICAL_METHOD=ONLINE_PHYSICAL
        ZDM_PAUSE_AFTER_STANDBY=NO
        export ZDM_PHYSICAL_METHOD ZDM_PAUSE_AFTER_STANDBY
        read -r -p "This can perform ZDM switchover. Type SWITCHOVER: " ack
        [[ "$ack" == SWITCHOVER ]] && zdm_execute_physical
        ;;
      7)
        ZDM_PHYSICAL_METHOD=OFFLINE_PHYSICAL
        ZDM_PAUSE_AFTER_STANDBY=NO
        export ZDM_PHYSICAL_METHOD ZDM_PAUSE_AFTER_STANDBY
        echo "OFFLINE_PHYSICAL performs backup/restore migration, not permanent standby creation."
        read -r -p "Execute offline physical migration? Type OFFLINE: " ack
        [[ "$ack" == OFFLINE ]] && zdm_execute_physical
        ;;
      8) zdm_query_jobs ;;
      9) read -r -p "ZDM Job ID: " j; zdm_query_job "$j" ;;
      10) read -r -p "ZDM Job ID: " j; zdm_resume_job "$j" ;;
      11) read -r -p "ZDM Job ID: " j; zdm_suspend_job "$j" ;;
      12) read -r -p "ZDM Job ID: " j; zdm_abort_job "$j" ;;
      0) return 0 ;;
      *) echo "Invalid choice." ;;
    esac
  done
}
