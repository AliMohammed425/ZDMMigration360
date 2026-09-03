#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
source "$ROOT/dg_ops_lib.sh"
for n in SOURCE_HOST SOURCE_OS_USER SOURCE_ORACLE_HOME SOURCE_SID SOURCE_DB_UNIQUE_NAME TARGET_HOST TARGET_OS_USER TARGET_ORACLE_HOME TARGET_DB_UNIQUE_NAME; do require_var "$n"; done
ACTION="${1:-precheck}"
BROKER="$(broker_enabled "$SOURCE_HOST" "$SOURCE_OS_USER" "$SOURCE_ORACLE_HOME" "$SOURCE_SID")"
[[ "$BROKER" == "TRUE" ]] || die "Data Guard Broker is required by this switchover helper."
case "$ACTION" in
 precheck)
  ssh "$SOURCE_OS_USER@$SOURCE_HOST" "
   export ORACLE_HOME='$SOURCE_ORACLE_HOME'; export PATH=\$ORACLE_HOME/bin:\$PATH
   dgmgrl / <<DGMGRL
show configuration verbose;
validate database verbose '$TARGET_DB_UNIQUE_NAME';
validate network configuration for all;
exit
DGMGRL
  "
  ;;
 to-standby)
  confirm_live "SWITCHOVER $TARGET_DB_UNIQUE_NAME" || exit 0
  ssh "$SOURCE_OS_USER@$SOURCE_HOST" "
   export ORACLE_HOME='$SOURCE_ORACLE_HOME'; export PATH=\$ORACLE_HOME/bin:\$PATH
   dgmgrl / <<DGMGRL
validate database verbose '$TARGET_DB_UNIQUE_NAME';
switchover to '$TARGET_DB_UNIQUE_NAME';
show configuration verbose;
exit
DGMGRL
  "
  ;;
 back-to-source)
  confirm_live "SWITCHBACK $SOURCE_DB_UNIQUE_NAME" || exit 0
  ssh "$TARGET_OS_USER@$TARGET_HOST" "
   export ORACLE_HOME='$TARGET_ORACLE_HOME'; export PATH=\$ORACLE_HOME/bin:\$PATH
   dgmgrl / <<DGMGRL
validate database verbose '$SOURCE_DB_UNIQUE_NAME';
switchover to '$SOURCE_DB_UNIQUE_NAME';
show configuration verbose;
exit
DGMGRL
  "
  ;;
 *) echo "Usage: $0 {precheck|to-standby|back-to-source}"; exit 2;;
esac
