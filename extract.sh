#!/bin/bash
# Copies the built artifact out of a duckdb-builder image
set -euo pipefail
IMAGE="${1:?Usage: extract.sh <image-tag>}"
CONTAINER_ID="$(docker create "${IMAGE}")"
trap 'docker rm -f "${CONTAINER_ID}" >/dev/null' EXIT
docker cp "${CONTAINER_ID}:/home/builder/build/release.tar.gz" .
echo "Extracted release artifact"
