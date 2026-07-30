#!/usr/bin/env bash
set -Eeuo pipefail

source /opt/oracle/env.sh

if [[ "$(id -u)" -ne 0 ]]; then
  echo "ERROR: entrypoint must start as root so it can prepare the persistent mount." >&2
  exit 1
fi

mkdir -p "$ORACLE_DATA"
chown -R oracle:oinstall "$ORACLE_DATA"
chmod 0770 "$ORACLE_DATA"

# Drop privileges while keeping run-oracle.sh as PID 1, so Docker stop signals
# are handled by the Oracle lifecycle script.
# util-linux 2.23 (oraclelinux:7) has no --init-groups, so pass supplementary
# groups explicitly to get the same final identity.
ORACLE_GROUPS="$(id -G oracle | tr ' ' ',')"
exec setpriv --reuid="$(id -u oracle)" --regid="$(id -g oracle)" --groups="$ORACLE_GROUPS" /opt/oracle/run-oracle.sh
