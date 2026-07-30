#!/usr/bin/env bash
set -euo pipefail
source /opt/oracle/env.sh

if [[ "$(id -u)" -eq 0 ]]; then
  ORACLE_GROUPS="$(id -G oracle | tr ' ' ',')"
  exec setpriv --reuid="$(id -u oracle)" --regid="$(id -g oracle)" --groups="$ORACLE_GROUPS" /opt/oracle/healthcheck.sh
fi

result="$({
  printf '%s\n' \
    'set heading off feedback off pages 0 verify off echo off' \
    "select status from v\$instance;" \
    'exit;'
} | sqlplus -s / as sysdba 2>/dev/null || true)"

grep -q 'OPEN' <<<"$result"
