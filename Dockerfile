# syntax=docker/dockerfile:1.7
#
# BASE_IMAGE must be an immutable Ubuntu 24.04 digest. The publishing workflow
# resolves the digest before invoking this build.
ARG BASE_IMAGE

# Shared toolchain layer. Both the pace build stage and the final image derive
# from it, so the package list lives in exactly one place. Besides the
# compilers, it carries the command-line tools a GitHub-hosted runner provides
# that projects' tests rely on: gawk (Ubuntu's default awk is mawk, which
# rejects GNU awk scripts), make, ss/lsof/fuser to attribute a listening socket
# to a process, jq, zip, shellcheck and the like. gcc-14 is provided
# by Ubuntu 24.04 (noble) itself; no third-party PPA is needed.
FROM ${BASE_IMAGE} AS toolchain

ARG LLVM_VERSION=22

RUN printf 'Acquire::Retries "5";\n' > /etc/apt/apt.conf.d/80-retries \
    && apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        bc \
        catch2 \
        ca-certificates \
        cmake \
        curl \
        file \
        gawk \
        g++-14 \
        gcc-14 \
        git \
        gpg \
        iproute2 \
        jq \
        libgl1-mesa-dev \
        libsqlite3-dev \
        libsqliteodbc \
        libssl-dev \
        libyaml-cpp-dev \
        libzip-dev \
        lsb-release \
        lsof \
        make \
        netcat-openbsd \
        ninja-build \
        openssl \
        pkg-config \
        procps \
        psmisc \
        qt6-base-dev \
        qt6-tools-dev \
        qt6-websockets-dev \
        shellcheck \
        software-properties-common \
        unixodbc-dev \
        unzip \
        wget \
        zip \
    && wget --quiet --tries=3 --waitretry=10 https://apt.llvm.org/llvm.sh \
    && chmod +x llvm.sh \
    && ./llvm.sh ${LLVM_VERSION} \
    && apt-get install -y --no-install-recommends \
        clang-${LLVM_VERSION} \
        clang-tidy-${LLVM_VERSION} \
        llvm-${LLVM_VERSION} \
    && rm llvm.sh \
    && rm -rf /var/lib/apt/lists/* \
    && ln -s /usr/bin/gcc-14 /usr/local/bin/gcc \
    && ln -s /usr/bin/g++-14 /usr/local/bin/g++ \
    && ln -s /usr/bin/clang-${LLVM_VERSION} /usr/local/bin/clang \
    && ln -s /usr/bin/clang++-${LLVM_VERSION} /usr/local/bin/clang++ \
    && ln -s /usr/bin/clang-tidy-${LLVM_VERSION} /usr/local/bin/clang-tidy \
    && ln -s /usr/bin/llvm-symbolizer-${LLVM_VERSION} /usr/local/bin/llvm-symbolizer \
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

# Compile-cache seeds, supplied as the named build context `pace-seed`. The
# publishing workflow passes seed/none, which leaves the seed directory empty,
# and its publish job layers one store per warmed group on top of this image,
# at pace/<group>.cow. See README: "Seed warmer".
COPY --from=pace-seed / /opt/pace/seed-cache/

ENV PATH="/opt/pace/bin:${PATH}" \
    PACE_CACHE_SEED_DIR="/opt/pace/seed-cache"
