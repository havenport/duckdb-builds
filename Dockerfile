# syntax=docker/dockerfile:1
FROM debian:13 AS build

ARG VERSION
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

RUN test -n "${VERSION}" \
    && curl --fail --location --retry 3 -o "duckdb-${VERSION}.tar.gz" \
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
  "httpfs"
  "icu"
  "inet"
  "json"
  "parquet"
  "quack"
)

CORE_EXTENSIONS="$(IFS=';'; printf '%s' "${PRECOMPILED_EXTENSIONS[*]}")"

printf '%s\n' "${CORE_EXTENSIONS}" > /home/builder/build/extensions.txt

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

RUN <<'BASH'
set -euo pipefail

LIB_PATH="duckdb-${VERSION}/build/release/src/libduckdb.so"
if [[ ! -f "${LIB_PATH}" ]]; then
  echo "Could not find expected library at ${LIB_PATH}. Build failed." >&2
  exit 1
fi

mkdir -p "release/include"
cp "${LIB_PATH}" "release/"
strip --strip-unneeded "release/libduckdb.so"
cp -r "duckdb-${VERSION}/src/include/." "release/include/"
cp -r "duckdb-${VERSION}/third_party/fmt/include/fmt" "release/include/"
cp "duckdb-${VERSION}/LICENSE" "release/"

cat > "release/MANIFEST" <<MANIFEST
version=${VERSION}
duckdb_ref=v${VERSION}
arch=$(dpkg --print-architecture)
built=$(date -u +%Y-%m-%dT%H:%M:%SZ)
extensions=$(cat /home/builder/build/extensions.txt)
MANIFEST

tar -czf "release.tar.gz" "release"
rm -rf release
BASH

FROM scratch AS artifact
COPY --from=build /home/builder/build/release.tar.gz /release.tar.gz
