#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
source "$ROOT/dg_ops_lib.sh"
for n in SOURCE_HOST SOURCE_OS_USER SOURCE_ORACLE_HOME SOURCE_SID SOURCE_DB_UNIQUE_NAME TARGET_HOST TARGET_OS_USER TARGET_ORACLE_HOME TARGET_DB_UNIQUE_NAME; do require_var "$n"; done
ACTION="${1:-precheck}"
BROKER="$(broker_enabled "$SOURCE_HOST" "$SOURCE_OS_USER" "$SOURCE_ORACLE_HOME" "$SOURCE_SID" || true)"
[[ "$BROKER" == "TRUE" ]] || die "Data Guard Broker is required by this failover helper."
case "$ACTION" in
 precheck)
  ssh "$SOURCE_OS_USER@$SOURCE_HOST" "
   export ORACLE_HOME='$SOURCE_ORACLE_HOME'; export PATH=\$ORACLE_HOME/bin:\$PATH
   dgmgrl / <<DGMGRL
show configuration verbose;
validate database verbose '$TARGET_DB_UNIQUE_NAME' strict all;
exit
DGMGRL
  "
  echo "Failover is for an approved DR test or primary failure, not a planned role swap."
  ;;
 to-standby)
  confirm_live "FAILOVER $TARGET_DB_UNIQUE_NAME" || exit 0
  ssh "$TARGET_OS_USER@$TARGET_HOST" "
   export ORACLE_HOME='$TARGET_ORACLE_HOME'; export PATH=\$ORACLE_HOME/bin:\$PATH
   dgmgrl / <<DGMGRL
failover to '$TARGET_DB_UNIQUE_NAME';
show configuration verbose;
exit
DGMGRL
  "
  ;;
 reinstate-source)
  confirm_live "REINSTATE $SOURCE_DB_UNIQUE_NAME" || exit 0
  ssh "$TARGET_OS_USER@$TARGET_HOST" "
   export ORACLE_HOME='$TARGET_ORACLE_HOME'; export PATH=\$ORACLE_HOME/bin:\$PATH
   dgmgrl / <<DGMGRL
reinstate database '$SOURCE_DB_UNIQUE_NAME';
show configuration verbose;
exit
DGMGRL
  "
  ;;
 *) echo "Usage: $0 {precheck|to-standby|reinstate-source}"; exit 2;;
esac
