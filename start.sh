#!/usr/bin/env bash
set -Eeuo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR"

if [[ -f .env ]]; then
  # shellcheck disable=SC1091
  source .env
fi

: "${ORACLE_PWD:?Set ORACLE_PWD in .env before starting the container}"

IMAGE_NAME="${IMAGE_NAME:-oracle/database:11.2.0.4-ee}"
CONTAINER_NAME="${CONTAINER_NAME:-oracle11204}"
ORACLE_SID="${ORACLE_SID:-ORCL}"
ORACLE_MEMORY_MB="${ORACLE_MEMORY_MB:-2048}"
CONTAINER_MEMORY="${CONTAINER_MEMORY:-6g}"
SHM_SIZE="${SHM_SIZE:-3g}"
DATA_MODE="${DATA_MODE:-bind}"
VOLUME_NAME="${VOLUME_NAME:-oracle11204-data}"
DATA_DIR="${DATA_DIR:-$PROJECT_DIR/oracle_data}"

if docker container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
  echo "ERROR: container $CONTAINER_NAME already exists." >&2
  echo "Use: docker start $CONTAINER_NAME" >&2
  echo "Or remove only the container with: docker rm -f $CONTAINER_NAME" >&2
  exit 1
fi

case "$DATA_MODE" in
  volume)
    docker volume inspect "$VOLUME_NAME" >/dev/null 2>&1 || docker volume create "$VOLUME_NAME" >/dev/null
    MOUNT_SOURCE="$VOLUME_NAME"
    ;;
  bind)
    mkdir -p "$DATA_DIR"
    MOUNT_SOURCE="$DATA_DIR"
    ;;
  *)
    echo "ERROR: DATA_MODE must be volume or bind" >&2
    exit 1
    ;;
esac

docker run -d \
  --name "$CONTAINER_NAME" \
  --hostname oracle11g \
  --platform linux/amd64 \
  --network host \
  --restart unless-stopped \
  --stop-timeout 120 \
  --memory "$CONTAINER_MEMORY" \
  --tmpfs "/dev/shm:rw,exec,nosuid,size=${SHM_SIZE}" \
  --ulimit nofile=1024:65536 \
  --ulimit nproc=2047:16384 \
  -e ORACLE_SID="$ORACLE_SID" \
  -e ORACLE_PWD="$ORACLE_PWD" \
  -e ORACLE_MEMORY_MB="$ORACLE_MEMORY_MB" \
  -e ORACLE_CHARACTERSET="${ORACLE_CHARACTERSET:-AL32UTF8}" \
  -v "${MOUNT_SOURCE}:/u01/app/oracle/oradata" \
  "$IMAGE_NAME"

echo "Container started: $CONTAINER_NAME"
echo "Using host network mode: reachable on port 1521 from any network interface"
echo "Data mount: $DATA_MODE -> $MOUNT_SOURCE"
echo "Follow initialization with: docker logs -f $CONTAINER_NAME"
