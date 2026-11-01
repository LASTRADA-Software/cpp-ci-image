# syntax=docker/dockerfile:1.7
#
# BASE_IMAGE must be an immutable Ubuntu 24.04 digest. The publishing workflow
# resolves the digest before invoking this build.
ARG BASE_IMAGE

# Shared toolchain layer. Both the pace build stage and the final image derive
# from it, so the package list lives in exactly one place. gcc-14 is provided
# by Ubuntu 24.04 (noble) itself; no third-party PPA is needed.
FROM ${BASE_IMAGE} AS toolchain

ARG LLVM_VERSION=22

RUN printf 'Acquire::Retries "5";\n' > /etc/apt/apt.conf.d/80-retries \
    && apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        catch2 \
        ca-certificates \
        cmake \
        curl \
        g++-14 \
        gcc-14 \
        git \
        gpg \
        libgl1-mesa-dev \
        libsqlite3-dev \
        libsqliteodbc \
        libssl-dev \
        libyaml-cpp-dev \
        libzip-dev \
        lsb-release \
        ninja-build \
        openssl \
        pkg-config \
        qt6-base-dev \
        qt6-tools-dev \
        qt6-websockets-dev \
        software-properties-common \
        unixodbc-dev \
        wget \
    && wget --quiet --tries=3 --waitretry=10 https://apt.llvm.org/llvm.sh \
    && chmod +x llvm.sh \
    && ./llvm.sh ${LLVM_VERSION} \
    && apt-get install -y --no-install-recommends \
        clang-${LLVM_VERSION} \
        clang-tidy-${LLVM_VERSION} \
    && rm llvm.sh \
    && rm -rf /var/lib/apt/lists/* \
    && ln -s /usr/bin/gcc-14 /usr/local/bin/gcc \
    && ln -s /usr/bin/g++-14 /usr/local/bin/g++ \
    && ln -s /usr/bin/clang-${LLVM_VERSION} /usr/local/bin/clang \
    && ln -s /usr/bin/clang++-${LLVM_VERSION} /usr/local/bin/clang++ \
    && ln -s /usr/bin/clang-tidy-${LLVM_VERSION} /usr/local/bin/clang-tidy \
    && mkdir -p /opt/pace/seed-cache

# Build the pace compiler launcher and key-value daemon from a pinned commit.
FROM toolchain AS builder

ARG PACE_REF=53b0e5385328405147ce18bb8e0d8ac2901f5eb8

RUN git clone https://github.com/LASTRADA-Software/pace.git /src/pace \
    && git -C /src/pace checkout --detach "${PACE_REF}" \
    && test "$(git -C /src/pace rev-parse HEAD)" = "${PACE_REF}" \
    && cmake -S /src/pace -B /build/pace -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_COMPILER=gcc-14 \
        -DCMAKE_CXX_COMPILER=g++-14 \
        -DPACE_BUILD_TESTS=OFF \
        -DPACE_ENABLE_TLS=ON \
        -DUSE_COMPILER_CACHE=OFF \
    && cmake --build /build/pace --target pace-cc pace-kv \
    && install -D -m 0755 /build/pace/target/pace-cc /opt/pace/bin/pace-cc \
    && install -D -m 0755 /build/pace/target/pace-kv /opt/pace/bin/pace-kv

FROM toolchain

ARG PACE_REF
ARG LLVM_VERSION=22

LABEL org.opencontainers.image.source="https://github.com/LASTRADA-Software/cpp-ci-image" \
      org.opencontainers.image.description="Pinned Linux C++ CI toolchain with pace compiler cache" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.lastrada.pace.ref="${PACE_REF}" \
      org.lastrada.llvm.version="${LLVM_VERSION}"

COPY --from=builder /opt/pace/bin/pace-cc /opt/pace/bin/pace-kv /opt/pace/bin/

# Compile-cache seed for the project `pace`, supplied as the named build context
# `pace-seed`. Builds without a seed pass an empty directory (seed/none), which
# leaves the seed directory empty. Each project gets its own subdirectory, so a
# job copies only its own store. See README: "Seed warmer design".
COPY --from=pace-seed / /opt/pace/seed-cache/pace/

ENV PATH="/opt/pace/bin:${PATH}" \
    PACE_CACHE_SEED_DIR="/opt/pace/seed-cache"
