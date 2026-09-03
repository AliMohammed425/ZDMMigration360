#!/usr/bin/env bash
set -euo pipefail

: "${SOURCE_HOST:?SOURCE_HOST required}"
: "${SOURCE_OS_USER:=oracle}"
: "${SOURCE_ORACLE_HOME:?SOURCE_ORACLE_HOME required}"
: "${SOURCE_SID:?SOURCE_SID required}"
: "${SOURCE_BACKUP_STAGE:?SOURCE_BACKUP_STAGE required}"

REPORT="${OFFLINE_BACKUP_REPORT:-./offline_backup_validation_report.txt}"

{
  echo "Offline RMAN Backup Precheck"
  echo "============================"
  echo "Host : $SOURCE_HOST"
  echo "SID  : $SOURCE_SID"
  echo "Stage: $SOURCE_BACKUP_STAGE"
  echo
} > "$REPORT"

count="$(ssh "$SOURCE_OS_USER@$SOURCE_HOST" "
  test -d '$SOURCE_BACKUP_STAGE' || exit 3
  find '$SOURCE_BACKUP_STAGE' -maxdepth 1 -type f | wc -l
" 2>/dev/null | awk 'NF{print $1}' | tail -1 || true)"
count="${count:-0}"

if [[ "$count" -eq 0 ]]; then
  echo "BACKUP NOT FOUND in $SOURCE_BACKUP_STAGE" | tee -a "$REPORT"
  echo "Choose ACTIVE_DUPLICATE or create/stage an offline RMAN backup first." | tee -a "$REPORT"
  exit 2
fi

echo "Files found: $count" | tee -a "$REPORT"

ssh "$SOURCE_OS_USER@$SOURCE_HOST" "
  export ORACLE_HOME='$SOURCE_ORACLE_HOME'
  export ORACLE_SID='$SOURCE_SID'
  export PATH=\$ORACLE_HOME/bin:\$PATH
  rman target / <<RMAN
LIST BACKUP SUMMARY;
CROSSCHECK BACKUP;
exit
RMAN
" >> "$REPORT" 2>&1

echo "Backup inventory validation completed. Review $REPORT"
