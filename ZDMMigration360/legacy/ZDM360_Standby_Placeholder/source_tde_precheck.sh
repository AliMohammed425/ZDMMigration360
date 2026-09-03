#!/usr/bin/env bash
set -euo pipefail
: "${SOURCE_HOST:?SOURCE_HOST required}"
: "${SOURCE_ORACLE_HOME:?SOURCE_ORACLE_HOME required}"
: "${SOURCE_SID:?SOURCE_SID required}"
SOURCE_OS_USER="${SOURCE_OS_USER:-oracle}"

ssh "$SOURCE_OS_USER@$SOURCE_HOST" "
  export ORACLE_HOME='$SOURCE_ORACLE_HOME'
  export ORACLE_SID='$SOURCE_SID'
  export PATH=\$ORACLE_HOME/bin:\$PATH
  sqlplus -s '/ as sysdba' <<'SQL'
set pages 0 feedback off heading off verify off echo off
select case
         when exists (select 1 from v\$encrypted_tablespaces)
           then 'TDE_ENABLED'
         else 'TDE_NOT_ENABLED'
       end
from dual;
exit
SQL
"
