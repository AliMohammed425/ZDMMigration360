#!/usr/bin/env bash
set -euo pipefail

operator_policy_defaults(){
  TOOLKIT_OS_USER="${TOOLKIT_OS_USER:-ops}"
  ORACLE_OS_USER="${ORACLE_OS_USER:-oracle}"
  TARGET_OS_USER="${TARGET_OS_USER:-oracle}"
  SOURCE_OS_USER="${SOURCE_OS_USER:-oracle}"
  REQUIRE_LOCAL_SUDO_ORACLE="${REQUIRE_LOCAL_SUDO_ORACLE:-YES}"
  REQUIRE_TARGET_ORACLE_SSH="${REQUIRE_TARGET_ORACLE_SSH:-YES}"
  REQUIRE_SOURCE_ORACLE_SSH="${REQUIRE_SOURCE_ORACLE_SSH:-YES}"
  export TOOLKIT_OS_USER ORACLE_OS_USER TARGET_OS_USER SOURCE_OS_USER
  export REQUIRE_LOCAL_SUDO_ORACLE REQUIRE_TARGET_ORACLE_SSH REQUIRE_SOURCE_ORACLE_SSH
}

operator_validate_local_user(){
  operator_policy_defaults
  local actual
  actual="$(id -un)"
  [[ "$actual" == "$TOOLKIT_OS_USER" ]] ||
    die "Toolkit must be executed by OS user '$TOOLKIT_OS_USER'. Current user: '$actual'."
  echo "Operator user validation: PASS ($actual)"
}

operator_validate_local_sudo_oracle(){
  operator_policy_defaults
  [[ "$REQUIRE_LOCAL_SUDO_ORACLE" == YES ]] || {
    echo "Local sudo-to-oracle validation: SKIPPED by configuration."
    return 0
  }

  command -v sudo >/dev/null 2>&1 || die "sudo is required for operator policy."
  sudo -n -u "$ORACLE_OS_USER" id -un 2>/dev/null | grep -qx "$ORACLE_OS_USER" ||
    die "User '$TOOLKIT_OS_USER' requires passwordless/non-interactive sudo access to '$ORACLE_OS_USER'. Expected: sudo -n -u $ORACLE_OS_USER id"
  echo "Local sudo-to-oracle validation: PASS"
}

operator_validate_target_oracle_ssh(){
  operator_policy_defaults
  [[ "$REQUIRE_TARGET_ORACLE_SSH" == YES ]] || {
    echo "Target oracle SSH validation: SKIPPED by configuration."
    return 0
  }
  require_var TARGET_HOST

  ssh -o BatchMode=yes -o ConnectTimeout="${SSH_CONNECT_TIMEOUT:-10}" \
      "$ORACLE_OS_USER@$TARGET_HOST" \
      "test \"\$(id -un)\" = '$ORACLE_OS_USER' && printf 'TARGET_ORACLE_SSH_PASS\n'" |
      grep -q TARGET_ORACLE_SSH_PASS ||
    die "Passwordless SSH from '$TOOLKIT_OS_USER' to '$ORACLE_OS_USER@$TARGET_HOST' is required."

  TARGET_OS_USER="$ORACLE_OS_USER"
  export TARGET_OS_USER
  echo "Target SSH validation: PASS ($ORACLE_OS_USER@$TARGET_HOST)"
}

operator_validate_source_oracle_ssh(){
  operator_policy_defaults
  [[ "$REQUIRE_SOURCE_ORACLE_SSH" == YES ]] || {
    echo "Source oracle SSH validation: SKIPPED by configuration."
    return 0
  }
  require_var SOURCE_HOST

  ssh -o BatchMode=yes -o ConnectTimeout="${SSH_CONNECT_TIMEOUT:-10}" \
      "$ORACLE_OS_USER@$SOURCE_HOST" \
      "test \"\$(id -un)\" = '$ORACLE_OS_USER' && printf 'SOURCE_ORACLE_SSH_PASS\n'" |
      grep -q SOURCE_ORACLE_SSH_PASS ||
    die "Passwordless SSH from '$TOOLKIT_OS_USER' to '$ORACLE_OS_USER@$SOURCE_HOST' is required."

  SOURCE_OS_USER="$ORACLE_OS_USER"
  export SOURCE_OS_USER
  echo "Source SSH validation: PASS ($ORACLE_OS_USER@$SOURCE_HOST)"
}

operator_validate_target_oracle_environment(){
  operator_policy_defaults
  require_var TARGET_HOST
  require_var TARGET_ORACLE_HOME

  ssh -o BatchMode=yes "$ORACLE_OS_USER@$TARGET_HOST" "
    set -e
    test -d '$TARGET_ORACLE_HOME'
    test -x '$TARGET_ORACLE_HOME/bin/sqlplus'
    test -x '$TARGET_ORACLE_HOME/bin/rman'
    test -x '$TARGET_ORACLE_HOME/bin/orapwd'
  " || die "Target Oracle home/tools are not accessible to $ORACLE_OS_USER@$TARGET_HOST: $TARGET_ORACLE_HOME"

  echo "Target Oracle software-owner access: PASS"
}

operator_validate_source_oracle_environment(){
  operator_policy_defaults
  require_var SOURCE_HOST
  require_var SOURCE_ORACLE_HOME

  ssh -o BatchMode=yes "$ORACLE_OS_USER@$SOURCE_HOST" "
    set -e
    test -d '$SOURCE_ORACLE_HOME'
    test -x '$SOURCE_ORACLE_HOME/bin/sqlplus'
    test -x '$SOURCE_ORACLE_HOME/bin/rman'
  " || die "Source Oracle home/tools are not accessible to $ORACLE_OS_USER@$SOURCE_HOST: $SOURCE_ORACLE_HOME"

  echo "Source Oracle software-owner access: PASS"
}

operator_access_preflight(){
  operator_validate_local_user
  operator_validate_local_sudo_oracle
  operator_validate_target_oracle_ssh
  operator_validate_source_oracle_ssh
  operator_validate_target_oracle_environment
  operator_validate_source_oracle_environment
  echo "Operator/Oracle access policy: PASS"
}
