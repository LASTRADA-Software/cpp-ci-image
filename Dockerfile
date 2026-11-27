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
# to a process, jq, zip, shellcheck and the like. gcc-14 is provided by Ubuntu
# 24.04 (noble) itself and stays the default gcc/g++; gcc-15/g++-15 come from the
# ubuntu-toolchain-r PPA for projects that build with GCC 15. The libdbus,
# libegl, libfontconfig, libglib, libopengl, libpulse, libwayland, libxcb and
# libxkbcommon packages are the runtime libraries of the Qt in the `qt` stage
# below: its libraries load without them only on a full desktop.
#
# Installing GCC 15 also installs libstdc++ 15, and clang uses the newest GCC
# installation it finds. The clang config files below pin clang to GCC 14's, so
# that adding a compiler does not change what every clang build compiles against
# (nor re-key its compile cache). A project that wants another libstdc++ passes
# its own --gcc-install-dir, which overrides the config file's.
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
        libdbus-1-3 \
        libegl1 \
        libfontconfig1 \
        libgl1-mesa-dev \
        libglib2.0-0t64 \
        libopengl0 \
        libpulse0 \
        libwayland-client0 \
        libwayland-cursor0 \
        libwayland-egl1 \
        libxcb-cursor0 \
        libxcb-icccm4 \
        libxcb-image0 \
        libxcb-keysyms1 \
        libxcb-render-util0 \
        libxcb-render0 \
        libxcb-shape0 \
        libxcb-xkb1 \
        libxkbcommon-x11-0 \
        libxkbcommon0 \
        libxrandr2 \
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
    && add-apt-repository -y ppa:ubuntu-toolchain-r/test \
    && apt-get update \
    && apt-get install -y --no-install-recommends gcc-15 g++-15 \
    && test -d /usr/lib/gcc/x86_64-linux-gnu/14 \
    && for driver in clang clang++; do \
        printf -- '--gcc-install-dir=/usr/lib/gcc/x86_64-linux-gnu/14\n' \
            > "/usr/lib/llvm-${LLVM_VERSION}/bin/${driver}.cfg"; \
    done \
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

# Qt from the Qt Company's online repository (aqtinstall), not Ubuntu's: noble
# ships Qt 6.4, which is out of support and older than consumers require. The
# modules are the ones morph's CI installs.
FROM toolchain AS qt

ARG QT_VERSION=6.8.1
ARG AQTINSTALL_VERSION=3.3.0

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends python3-venv \
    && python3 -m venv /tmp/aqt \
    && /tmp/aqt/bin/pip install --quiet "aqtinstall==${AQTINSTALL_VERSION}" \
    && /tmp/aqt/bin/aqt install-qt linux desktop "${QT_VERSION}" linux_gcc_64 \
        --modules qtwebsockets qtmultimedia --outputdir /opt/Qt \
    && test -f "/opt/Qt/${QT_VERSION}/gcc_64/lib/cmake/Qt6/Qt6Config.cmake"

FROM toolchain

ARG PACE_REF
ARG LLVM_VERSION=22
ARG QT_VERSION=6.8.1

LABEL org.opencontainers.image.source="https://github.com/LASTRADA-Software/cpp-ci-image" \
      org.opencontainers.image.description="Pinned Linux C++ CI toolchain with pace compiler cache" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.lastrada.pace.ref="${PACE_REF}" \
      org.lastrada.llvm.version="${LLVM_VERSION}" \
      org.lastrada.qt.version="${QT_VERSION}"

COPY --from=builder /opt/pace/bin/pace-cc /opt/pace/bin/pace-kv /opt/pace/bin/
COPY --from=qt /opt/Qt /opt/Qt

# Compile-cache seeds, supplied as the named build context `pace-seed`. The
# publishing workflow passes seed/none, which leaves the seed directory empty,
# and its publish job layers one store per warmed group on top of this image,
# at pace/<group>.cow. See README: "Seed warmer".
COPY --from=pace-seed / /opt/pace/seed-cache/

# QT_ROOT_DIR and CMAKE_PREFIX_PATH as jurplel/install-qt-action sets them, so a
# find_package(Qt6) finds this Qt without a project-specific hint. LANG is the
# hosted runner's: Qt warns on a non-UTF-8 locale and switches to C.UTF-8 itself.
ENV PATH="/opt/pace/bin:/opt/Qt/${QT_VERSION}/gcc_64/bin:${PATH}" \
    LANG="C.UTF-8" \
    PACE_CACHE_SEED_DIR="/opt/pace/seed-cache" \
    QT_ROOT_DIR="/opt/Qt/${QT_VERSION}/gcc_64" \
    CMAKE_PREFIX_PATH="/opt/Qt/${QT_VERSION}/gcc_64"
