#!/usr/bin/env bash
set -Eeuo pipefail

source /opt/oracle/env.sh
umask 027

ORACLE_PWD="${ORACLE_PWD:-Oracle_123}"
ORACLE_CHARACTERSET="${ORACLE_CHARACTERSET:-AL32UTF8}"
ORACLE_NCHARACTERSET="${ORACLE_NCHARACTERSET:-AL16UTF16}"
ORACLE_MEMORY_MB="${ORACLE_MEMORY_MB:-2048}"

NETWORK_ADMIN="$ORACLE_HOME/network/admin"
DBS_DIR="$ORACLE_HOME/dbs"
PERSIST_CONFIG="$ORACLE_DATA/dbconfig/$ORACLE_SID"
INIT_MARKER="$ORACLE_DATA/.db_initialized_${ORACLE_SID}"

mkdir -p "$NETWORK_ADMIN" "$DBS_DIR" "$PERSIST_CONFIG"

configure_network() {
  cat > "$NETWORK_ADMIN/listener.ora" <<NETEOF
LISTENER =
  (DESCRIPTION_LIST =
    (DESCRIPTION =
      (ADDRESS = (PROTOCOL = TCP)(HOST = 0.0.0.0)(PORT = 1521))
    )
  )

SID_LIST_LISTENER =
  (SID_LIST =
    (SID_DESC =
      (GLOBAL_DBNAME = ${ORACLE_SID})
      (ORACLE_HOME = ${ORACLE_HOME})
      (SID_NAME = ${ORACLE_SID})
    )
  )
NETEOF

  cat > "$NETWORK_ADMIN/tnsnames.ora" <<NETEOF
${ORACLE_SID} =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = 127.0.0.1)(PORT = 1521))
    (CONNECT_DATA =
      (SERVER = DEDICATED)
      (SERVICE_NAME = ${ORACLE_SID})
    )
  )
NETEOF

  cat > "$NETWORK_ADMIN/sqlnet.ora" <<'NETEOF'
NAMES.DIRECTORY_PATH = (TNSNAMES, EZCONNECT)
SQLNET.AUTHENTICATION_SERVICES = (BEQ)
NETEOF
}

persist_instance_files() {
  local name source target
  for name in "spfile${ORACLE_SID}.ora" "orapw${ORACLE_SID}"; do
    source="$DBS_DIR/$name"
    target="$PERSIST_CONFIG/$name"
    if [[ -f "$source" && ! -L "$source" ]]; then
      cp -p "$source" "$target"
      rm -f "$source"
    fi
    if [[ -f "$target" ]]; then
      ln -sfn "$target" "$source"
    fi
  done

  cat > "$PERSIST_CONFIG/init${ORACLE_SID}.ora" <<INITEOF
SPFILE='${PERSIST_CONFIG}/spfile${ORACLE_SID}.ora'
INITEOF
  ln -sfn "$PERSIST_CONFIG/init${ORACLE_SID}.ora" "$DBS_DIR/init${ORACLE_SID}.ora"
}

restore_instance_links() {
  local required="$PERSIST_CONFIG/spfile${ORACLE_SID}.ora"
  if [[ ! -f "$required" ]]; then
    echo "ERROR: initialized data directory is missing $required" >&2
    exit 1
  fi
  persist_instance_files
}

sqlplus_sysdba() {
  sqlplus -s / as sysdba
}

shutdown_database() {
  set +e
  echo "Stopping Oracle Database ${ORACLE_SID}..."
  sqlplus_sysdba <<'SQLEOF'
whenever sqlerror continue
shutdown immediate;
exit;
SQLEOF
  lsnrctl stop >/dev/null 2>&1
  [[ -n "${TAIL_PID:-}" ]] && kill "$TAIL_PID" >/dev/null 2>&1
  echo "Oracle Database stopped."
}

trap 'shutdown_database; exit 0' TERM INT

configure_network

# Start the listener before DBCA; static registration also makes the SID visible.
lsnrctl start

if [[ ! -f "$INIT_MARKER" ]]; then
  echo "No initialized database found in $ORACLE_DATA. Creating ${ORACLE_SID}..."

  dbca -silent -createDatabase \
    -templateName General_Purpose.dbc \
    -gdbName "$ORACLE_SID" \
    -sid "$ORACLE_SID" \
    -sysPassword "$ORACLE_PWD" \
    -systemPassword "$ORACLE_PWD" \
    -emConfiguration NONE \
    -storageType FS \
    -datafileDestination "$ORACLE_DATA" \
    -recoveryAreaDestination "$ORACLE_DATA/fast_recovery_area" \
    -characterSet "$ORACLE_CHARACTERSET" \
    -nationalCharacterSet "$ORACLE_NCHARACTERSET" \
    -totalMemory "$ORACLE_MEMORY_MB" \
    -redoLogFileSize 100 \
    -sampleSchema false

  # dbca writes local_listener='LISTENER_<SID>', but configure_network above
  # registers the listener under the default name LISTENER. The mismatch
  # only surfaces on the next startup (ORA-00119/ORA-00132), so strip it now
  # while the freshly created instance is still up.
  sqlplus_sysdba <<'SQLEOF'
whenever sqlerror continue
alter system reset local_listener scope=spfile sid='*';
exit;
SQLEOF

  persist_instance_files
  touch "$INIT_MARKER"
  echo "Database ${ORACLE_SID} creation completed."
else
  echo "Existing database found. Starting ${ORACLE_SID}..."
  restore_instance_links
  sqlplus_sysdba <<'SQLEOF'
whenever sqlerror exit failure
startup;
exit;
SQLEOF
fi

# Ask PMON to register the service with the listener now.
sqlplus_sysdba <<'SQLEOF'
whenever sqlerror continue
alter system register;
exit;
SQLEOF

ALERT_LOG="$(find "$ORACLE_BASE/diag/rdbms" -type f -name "alert_${ORACLE_SID}.log" 2>/dev/null | head -n 1 || true)"
if [[ -n "$ALERT_LOG" ]]; then
  echo "Following alert log: $ALERT_LOG"
  tail -n 100 -F "$ALERT_LOG" &
  TAIL_PID=$!
fi

while pgrep -u oracle -f "ora_pmon_${ORACLE_SID}" >/dev/null 2>&1; do
  sleep 5
done

echo "ERROR: Oracle PMON process exited unexpectedly." >&2
[[ -n "${TAIL_PID:-}" ]] && kill "$TAIL_PID" >/dev/null 2>&1 || true
exit 1
