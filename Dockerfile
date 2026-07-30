# syntax=docker/dockerfile:1

########################################
# Stage 1: builder — installs Oracle software; discarded after this stage.
########################################
FROM oraclelinux:7 AS builder

ARG ORACLE_UID=54321
ARG ORACLE_GID=54321

ENV ORACLE_BASE=/u01/app/oracle \
    ORACLE_HOME=/u01/app/oracle/product/11.2.0/dbhome_1 \
    ORACLE_SID=ORCL \
    ORACLE_DATA=/u01/app/oracle/oradata \
    NLS_LANG=AMERICAN_AMERICA.AL32UTF8 \
    PATH=/u01/app/oracle/product/11.2.0/dbhome_1/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Oracle 11.2.0.4 software installation and runtime dependencies.
RUN yum -y install \
      binutils \
      compat-libcap1 \
      compat-libstdc++-33 \
      gcc \
      gcc-c++ \
      glibc \
      glibc-devel \
      ksh \
      libaio \
      libaio-devel \
      libgcc \
      libstdc++ \
      libstdc++-devel \
      libX11 \
      libXau \
      libxcb \
      libXi \
      libXext \
      libXtst \
      make \
      sysstat \
      unixODBC \
      unixODBC-devel \
      unzip \
      zip \
      hostname \
      net-tools \
      procps-ng \
      util-linux \
      findutils \
      which \
      tar \
      gzip \
    && yum clean all \
    && rm -rf /var/cache/yum

RUN groupadd -g "${ORACLE_GID}" oinstall \
    && groupadd -g 54322 dba \
    && groupadd -g 54323 oper \
    && useradd -u "${ORACLE_UID}" -g oinstall -G dba,oper -m -s /bin/bash oracle \
    && mkdir -p \
         /u01/app/oracle/product/11.2.0/dbhome_1 \
         /u01/app/oracle/oradata \
         /u01/app/oraInventory \
         /opt/install \
    && chown -R oracle:oinstall /u01 /opt/install

# Oracle Database 11.2.0.4 server software is contained in parts 1 and 2.
COPY --chown=oracle:oinstall response/db_install.rsp /opt/install/db_install.rsp

USER oracle

# Bind-mount the database/ directory (containing only the two official
# install zips, per .dockerignore) instead of COPYing them into a layer.
# This stage is discarded entirely, so the only benefit is avoiding writing
# ~2.6GB into the builder's writable layer during the build. Both zips
# extract into the same database/ tree with no overlapping files, so
# extraction order does not matter.
RUN --mount=type=bind,source=database,target=/mnt/install-media \
    set -eux; \
    unzip -q /mnt/install-media/p13390677_112040_Linux-x86-64_1of7.zip -d /opt/install; \
    unzip -q /mnt/install-media/p13390677_112040_Linux-x86-64_2of7.zip -d /opt/install; \
    test -f /opt/install/database/runInstaller; \
    chmod +x /opt/install/database/runInstaller; \
    chown -R oracle:oinstall /opt/install/database

RUN set -eux; \
    /opt/install/database/runInstaller \
      -silent \
      -waitforcompletion \
      -ignorePrereq \
      -ignoreSysPrereqs \
      -responseFile /opt/install/db_install.rsp \
    || { \
      rc=$?; \
      echo "Oracle Universal Installer failed: ${rc}"; \
      find /u01/app/oraInventory/logs \
        -type f \
        -maxdepth 1 \
        -exec sh -c 'echo "===== $1 ====="; tail -n 200 "$1"' _ {} \; \
        2>/dev/null || true; \
      exit "${rc}"; \
    }

USER root

RUN /u01/app/oraInventory/orainstRoot.sh \
    && /u01/app/oracle/product/11.2.0/dbhome_1/root.sh \
    && rm -rf /opt/install

########################################
# Stage 2: runtime image — only the final installed artifacts are copied in.
########################################
FROM oraclelinux:7

ARG ORACLE_UID=54321
ARG ORACLE_GID=54321
ARG TZ_NAME=Asia/Shanghai

ENV ORACLE_BASE=/u01/app/oracle \
    ORACLE_HOME=/u01/app/oracle/product/11.2.0/dbhome_1 \
    ORACLE_SID=ORCL \
    ORACLE_DATA=/u01/app/oracle/oradata \
    NLS_LANG=AMERICAN_AMERICA.AL32UTF8 \
    TZ=${TZ_NAME} \
    PATH=/u01/app/oracle/product/11.2.0/dbhome_1/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# tzdata is already part of oraclelinux:7's base packages; just point
# /etc/localtime at it so container-local time (logs, alert log timestamps,
# SYSDATE without an explicit DBTIMEZONE) matches the host instead of UTC.
RUN ln -sf "/usr/share/zoneinfo/${TZ_NAME}" /etc/localtime \
    && echo "${TZ_NAME}" > /etc/timezone

RUN yum -y install \
      binutils \
      compat-libcap1 \
      compat-libstdc++-33 \
      gcc \
      gcc-c++ \
      glibc \
      glibc-devel \
      ksh \
      libaio \
      libaio-devel \
      libgcc \
      libstdc++ \
      libstdc++-devel \
      libX11 \
      libXau \
      libxcb \
      libXi \
      libXext \
      libXtst \
      make \
      sysstat \
      unixODBC \
      unixODBC-devel \
      unzip \
      zip \
      hostname \
      net-tools \
      procps-ng \
      util-linux \
      findutils \
      which \
      tar \
      gzip \
    && yum clean all \
    && rm -rf /var/cache/yum

RUN groupadd -g "${ORACLE_GID}" oinstall \
    && groupadd -g 54322 dba \
    && groupadd -g 54323 oper \
    && useradd -u "${ORACLE_UID}" -g oinstall -G dba,oper -m -s /bin/bash oracle \
    && mkdir -p /opt/oracle \
    && chown -R oracle:oinstall /opt/oracle

# Copy the fully installed Oracle software tree from the builder stage. No
# --chown here: root.sh sets root-owned setuid bits (e.g. oradism) that must
# survive verbatim. Matching ARG ORACLE_UID/ORACLE_GID in both stages means
# the copied numeric UID/GID resolve to the same names in this stage.
COPY --from=builder /u01 /u01
COPY --from=builder /etc/oraInst.loc /etc/oraInst.loc
COPY --from=builder /etc/oratab /etc/oratab

COPY scripts/env.sh scripts/entrypoint.sh scripts/run-oracle.sh scripts/healthcheck.sh /opt/oracle/
RUN chmod 0755 /opt/oracle/*.sh \
    && chown -R oracle:oinstall /opt/oracle \
    && printf '%s\n' \
       'export ORACLE_BASE=/u01/app/oracle' \
       'export ORACLE_HOME=/u01/app/oracle/product/11.2.0/dbhome_1' \
       'export ORACLE_SID=${ORACLE_SID:-ORCL}' \
       'export PATH=$ORACLE_HOME/bin:$PATH' \
       'export NLS_LANG=AMERICAN_AMERICA.AL32UTF8' \
       > /home/oracle/.bash_profile \
    && chown oracle:oinstall /home/oracle/.bash_profile

EXPOSE 1521

HEALTHCHECK --interval=30s --timeout=10s --start-period=10m --retries=10 \
  CMD /opt/oracle/healthcheck.sh

ENTRYPOINT ["/opt/oracle/entrypoint.sh"]
