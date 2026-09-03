#!/usr/bin/env bash
set -euo pipefail

SOURCE_HOST="${SOURCE_HOST:?SOURCE_HOST required}"
TARGET_HOST="${TARGET_HOST:?TARGET_HOST required}"
SOURCE_OS_USER="${SOURCE_OS_USER:-oracle}"
TARGET_OS_USER="${TARGET_OS_USER:-oracle}"

check() {
  local from="$1" fu="$2" fh="$3" to="$4" tu="$5" th="$6"
  echo "Checking $from -> $to ..."
  ssh -o BatchMode=yes -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no \
      -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
      "$fu@$fh" \
      "ssh -o BatchMode=yes -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no \
           -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
           '$tu@$th' 'hostname; id -un'" \
      || { echo "FAILED: $from -> $to"; exit 1; }
  echo "PASSED: $from -> $to"
}

check SOURCE "$SOURCE_OS_USER" "$SOURCE_HOST" TARGET "$TARGET_OS_USER" "$TARGET_HOST"
check TARGET "$TARGET_OS_USER" "$TARGET_HOST" SOURCE "$SOURCE_OS_USER" "$SOURCE_HOST"

echo "Bidirectional passwordless SSH key prerequisite PASSED."
