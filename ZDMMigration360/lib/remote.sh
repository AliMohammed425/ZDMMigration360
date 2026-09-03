#!/usr/bin/env bash
set -euo pipefail

remote_sql(){
  local host="$1" user="$2" oh="$3" sid="$4"
  ssh "$user@$host" "
    export ORACLE_HOME='$oh'
    export ORACLE_SID='$sid'
    export PATH=\$ORACLE_HOME/bin:\$PATH
    sqlplus -s '/ as sysdba'
  "
}

ssh_check(){
  local user="$1" host="$2"
  ssh -o BatchMode=yes -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no \
      -o ConnectTimeout="${SSH_CONNECT_TIMEOUT:-10}" "$user@$host" "hostname; true"
}

tnsping_remote(){
  local user="$1" host="$2" oh="$3" alias="$4"
  ssh "$user@$host" "
    export ORACLE_HOME='$oh'
    export PATH=\$ORACLE_HOME/bin:\$PATH
    tnsping '$alias'
  "
}
