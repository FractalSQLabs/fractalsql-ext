# syntax=docker/dockerfile:1.7
#
# fractalsql-ext -- the pure-C DuckDB extension, built in a pinned glibc baseline.
#
# The extension is C99/C11 and calls DuckDB through the function table the engine hands it at LOAD, so no DuckDB
# source is compiled or linked and a build takes seconds. Two bands come out of one source tree:
#   fractalsql.capi.linux_<arch>.duckdb_extension        stable API (C_STRUCT, v1.5.6 header): DuckDB 1.5.6 and 2.0.0
#   fractalsql.v<1.4.N>.linux_<arch>.duckdb_extension    1.4 line (C_STRUCT_UNSTABLE): exactly that DuckDB 1.4.N
# build.sh turns those into the per-DuckDB-version release cells.
#
# Build posture
#   * rockylinux:9 (glibc 2.34): the artifact must not need a newer glibc than that, which is checked below.
#   * No libstdc++ (there is no C++ in the extension); libm/libdl/libpthread are glibc.
#   * The vendored FractalSQL core is linked statically and kept private: the extension exports exactly one
#     symbol, fractalsql_init_c_api (src/exports.map).
#
# Usage: docker buildx build --target export --output type=local,dest=<dir> -f docker/Dockerfile .

ARG BASE_IMAGE=rockylinux:9@sha256:d7be1c094cc5845ee815d4632fe377514ee6ebcf8efaed6892889657e5ddaaa6
ARG BUILD_ARCH=amd64
ARG GLIBC_CEILING=34
ARG SIZE_CEILING_BYTES=8388608

FROM ${BASE_IMAGE} AS builder
ARG GLIBC_CEILING
ARG SIZE_CEILING_BYTES
RUN dnf -y install gcc make python3 binutils && dnf clean all
WORKDIR /build
COPY Makefile                /build/
COPY src                     /build/src
COPY vendor                  /build/vendor
COPY include                 /build/include
COPY scripts/append_metadata.py /build/scripts/append_metadata.py
RUN make
# Gates inside the image: glibc ceiling, size ceiling, the one exported symbol.
RUN set -eu; \
    for f in dist/linux_*/*.duckdb_extension; do \
      need="$(objdump -T "$f" | grep -o 'GLIBC_2\.[0-9]*' | sort -V | tail -1 | sed 's/GLIBC_2\.//')"; \
      [ -z "$need" ] || [ "$need" -le "${GLIBC_CEILING}" ] || { echo "$f needs glibc 2.$need > 2.${GLIBC_CEILING}"; exit 1; }; \
      size="$(stat -c %s "$f")"; \
      [ "$size" -le "${SIZE_CEILING_BYTES}" ] || { echo "$f is $size bytes, over ${SIZE_CEILING_BYTES}"; exit 1; }; \
      syms="$(nm -D --defined-only "$f" | awk '$2 ~ /^[TDBR]$/ {print $3}' | tr '\n' ' ')"; \
      [ "$syms" = "fractalsql_init_c_api " ] || { echo "$f exports: $syms (want only fractalsql_init_c_api)"; exit 1; }; \
      echo "ok: $f (glibc 2.${need:-0}, $size bytes, one export)"; \
    done

FROM scratch AS export
ARG BUILD_ARCH
COPY --from=builder /build/dist/linux_${BUILD_ARCH}/ /
