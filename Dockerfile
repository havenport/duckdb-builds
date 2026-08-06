# syntax=docker/dockerfile:1

# Build one DuckDB bundle release archive for the selected Linux architecture and
# extension-loading policy.
FROM debian:13

ARG VERSION=1.5.5
ARG DISABLE_EXTENSION_LOAD=1
ARG JOBS=""
ARG VCPKG_REF=2026.04.27

RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential cmake ninja-build curl git ca-certificates python3 \
      pkg-config unzip zip \
    && rm -rf /var/lib/apt/lists/*

RUN useradd --create-home --shell /bin/bash builder
USER builder
WORKDIR /home/builder/build

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN curl --fail --location --retry 3 -o "duckdb-${VERSION}.tar.gz" \
      "https://github.com/duckdb/duckdb/archive/refs/tags/v${VERSION}.tar.gz" \
    && tar xzf "duckdb-${VERSION}.tar.gz" \
    && rm "duckdb-${VERSION}.tar.gz"

RUN git clone --branch "${VCPKG_REF}" \
      https://github.com/microsoft/vcpkg.git vcpkg \
    && ./vcpkg/bootstrap-vcpkg.sh -disableMetrics

RUN <<'BASH'
set -euo pipefail

mkdir vcpkg-triplets
for arch in x64 arm64; do
  cp "vcpkg/triplets/${arch}-linux.cmake" \
    "vcpkg-triplets/${arch}-linux-release.cmake"
  printf '\nset(VCPKG_BUILD_TYPE release)\n' \
    >> "vcpkg-triplets/${arch}-linux-release.cmake"
done
BASH

RUN <<'BASH'
set -euo pipefail

PRECOMPILED_EXTENSIONS=(
  "aws"
  "core_functions"
  "ducklake"
  "excel"
  "fts"
  "httpfs"
  "icu"
  "inet"
  "json"
  "parquet"
  "quack"
  "spatial"
)

CORE_EXTENSIONS="$(IFS=';'; printf '%s' "${PRECOMPILED_EXTENSIONS[*]}")"

case "$(dpkg --print-architecture)" in
  amd64) VCPKG_TRIPLET=x64-linux-release ;;
  arm64) VCPKG_TRIPLET=arm64-linux-release ;;
  *)
    echo "Unsupported vcpkg architecture: $(dpkg --print-architecture)" >&2
    exit 1
    ;;
esac

cd "duckdb-${VERSION}"

FETCHCONTENT_CACHE="/home/builder/build/_fetchcontent_cache"
mkdir -p "${FETCHCONTENT_CACHE}"

CORE_EXTENSIONS="${CORE_EXTENSIONS}" \
  EXTENSION_STATIC_BUILD=1 \
  DISABLE_EXTENSION_LOAD="${DISABLE_EXTENSION_LOAD}" \
  USE_MERGED_VCPKG_MANIFEST=1 \
  VCPKG_DISABLE_METRICS=1 \
  VCPKG_OVERLAY_TRIPLETS="/home/builder/build/vcpkg-triplets" \
  VCPKG_TOOLCHAIN_PATH="/home/builder/build/vcpkg/scripts/buildsystems/vcpkg.cmake" \
  VCPKG_TARGET_TRIPLET="${VCPKG_TRIPLET}" \
  OVERRIDE_GIT_DESCRIBE="v${VERSION}" \
  GEN=ninja \
  BUILD_UNITTESTS=0 \
  EXTRA_CMAKE_VARIABLES="-DFETCHCONTENT_BASE_DIR=${FETCHCONTENT_CACHE}" \
  make -j"${JOBS:-$(nproc)}" release
BASH

RUN set -eu; \
    LIB_PATH="$(find "duckdb-${VERSION}/build/release" -maxdepth 3 -name 'libduckdb.so' | head -1)"; \
    if [ -z "${LIB_PATH}" ]; then \
      echo "Could not find libduckdb.so. Build failed." >&2; \
      exit 1; \
    fi; \
    mkdir -p "release/include"; \
    cp "${LIB_PATH}" "release/"; \
    cp -r "duckdb-${VERSION}/src/include/." "release/include/"; \
    cp "duckdb-${VERSION}/LICENSE" "release/"; \
    tar -czf "release.tar.gz" "release"; \
    rm -rf release

# Output lives at /home/builder/build/release.tar.gz
