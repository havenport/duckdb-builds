# syntax=docker/dockerfile:1

# Build one DuckDB bundle release archive for the selected Linux architecture and
# extension-loading policy.
FROM debian:13

ARG VERSION=1.5.5
ARG DISABLE_EXTENSION_LOAD=1
ARG JOBS=""

RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential cmake ninja-build curl git ca-certificates python3 \
    && rm -rf /var/lib/apt/lists/*

RUN useradd --create-home --shell /bin/bash builder
USER builder
WORKDIR /home/builder/build

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN curl --fail --location --retry 3 -o "duckdb-${VERSION}.tar.gz" \
      "https://github.com/duckdb/duckdb/archive/refs/tags/v${VERSION}.tar.gz" \
    && tar xzf "duckdb-${VERSION}.tar.gz" \
    && rm "duckdb-${VERSION}.tar.gz"

RUN <<'BASH'
set -euo pipefail

PRECOMPILED_EXTENSIONS=(
  # "autocomplete"
  # "aws"
  # "azure"
  "core_functions"
  # "ducklake"
  # "encodings"
  # "excel"
  # "fts"
  # "httpfs"
  # "icu"
  # "inet"
  "json"
  # "mysql"
  # "parquet"
  # "postgres"
  # "quack"
  # "spatial"
  # "sqlite"
  # "vss"
)

CORE_EXTENSIONS="$(IFS=';'; printf '%s' "${PRECOMPILED_EXTENSIONS[*]}")"

cd "duckdb-${VERSION}"
CORE_EXTENSIONS="${CORE_EXTENSIONS}" \
  EXTENSION_STATIC_BUILD=1 \
  DISABLE_EXTENSION_LOAD="${DISABLE_EXTENSION_LOAD}" \
  OVERRIDE_GIT_DESCRIBE="v${VERSION}" \
  GEN=ninja \
  BUILD_UNITTESTS=0 \
  make -j"${JOBS:-$(nproc)}" bundle-library
BASH

RUN set -eu; \
    BUNDLE_PATH="duckdb-${VERSION}/build/release/libduckdb_bundle.a"; \
    if [ ! -f "${BUNDLE_PATH}" ]; then \
      echo "Could not find libduckdb_bundle.a. Build failed." >&2; \
      exit 1; \
    fi; \
    mkdir -p "release/include"; \
    cp "${BUNDLE_PATH}" "release/"; \
    cp -r "duckdb-${VERSION}/src/include/." "release/include/"; \
    cp "duckdb-${VERSION}/LICENSE" "release/"; \
    tar -czf "release.tar.gz" "release"; \
    rm -rf release

# Output lives at /home/builder/build/release.tar.gz
