#!/usr/bin/env bash
export ORACLE_BASE="${ORACLE_BASE:-/u01/app/oracle}"
export ORACLE_HOME="${ORACLE_HOME:-/u01/app/oracle/product/11.2.0/dbhome_1}"
export ORACLE_SID="${ORACLE_SID:-ORCL}"
export ORACLE_DATA="${ORACLE_DATA:-/u01/app/oracle/oradata}"
export PATH="$ORACLE_HOME/bin:$PATH"
export NLS_LANG="${NLS_LANG:-AMERICAN_AMERICA.AL32UTF8}"
export LD_LIBRARY_PATH="$ORACLE_HOME/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
