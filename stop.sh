#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")"
[[ -f .env ]] && source .env
CONTAINER_NAME="${CONTAINER_NAME:-oracle11204}"
docker stop -t 120 "$CONTAINER_NAME"
