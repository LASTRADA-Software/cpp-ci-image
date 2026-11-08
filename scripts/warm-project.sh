#!/usr/bin/env bash
# Warm one group of a project's presets into a single-file pace-kv store.
#
# Runs inside the cpp-ci image. The caller checks the project out at $WORKSPACE
# and passes the preset list in the environment. The script fails fast: a
# single failing preset fails the whole warm-up, so no partial seed is published.
#
# Incremental: if SEED_STORE names an existing store (the previous published seed
# for this group), the warm-up starts from a copy of it, so only translation units
# whose inputs changed are recompiled. A store the new pace-kv refuses (for
# example a storage format change) is discarded, and the warm-up starts empty.
#
# Required environment:
#   WORKSPACE     checkout of the project (also PACE_SOURCE_DIR)
#   STORE         path of the store to write, e.g. /warm/cache.cow
#   PRESETS       space-separated configure presets to build, in order
# Optional:
#   TEST_PRESETS  space-separated subset of PRESETS to run ctest on
#   SEED_STORE    previous store to start from
#   WARM_MAX_DISK on-disk cap for the store (default 4g). The cap evicts the
#                 least recently used entries, so a reused store stays bounded.
set -euo pipefail

: "${WORKSPACE:?WORKSPACE is required}"
: "${STORE:?STORE is required}"
: "${PRESETS:?PRESETS is required}"
TEST_PRESETS="${TEST_PRESETS:-}"
SEED_STORE="${SEED_STORE:-}"
WARM_MAX_DISK="${WARM_MAX_DISK:-4g}"
HERE="$(cd "$(dirname "$0")" && pwd)"
PORT="${WARM_PORT:-6674}"
LOGDIR="$(dirname "$STORE")"
mkdir -p "$LOGDIR"

KV=""

wait_for_port() {
    for _ in $(seq 100); do
        if (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; then return 0; fi
        if [ -n "$KV" ] && ! kill -0 "$KV" 2>/dev/null; then return 1; fi
        sleep 0.2
    done
    return 1
}

start_kv() {
    pace-kv --bind=127.0.0.1 --port="$PORT" \
        --storage="$STORE" --storage-shards=1 \
        --storage-max-disk="$WARM_MAX_DISK" \
        --log-level=warn > "$LOGDIR/pace-kv.log" 2>&1 &
    KV=$!
    wait_for_port
}

stop_kv() {
    # SIGTERM lets pace-kv flush its batched commit window before exiting.
    if [ -n "$KV" ]; then
        kill -TERM "$KV" 2>/dev/null || true
        wait "$KV" 2>/dev/null || true
        KV=""
    fi
}
trap stop_kv EXIT

if [ -n "$SEED_STORE" ] && [ -f "$SEED_STORE" ]; then
    cp "$SEED_STORE" "$STORE"
    echo "starting from previous seed: $(stat -c %s "$STORE") bytes"
    if ! start_kv; then
        echo "::warning::previous seed was refused by this pace-kv; starting empty"
        cat "$LOGDIR/pace-kv.log" || true
        rm -f "$STORE"
        start_kv || { echo "pace-kv did not start" >&2; exit 1; }
    fi
else
    echo "no previous seed; starting empty"
    start_kv || { echo "pace-kv did not start" >&2; cat "$LOGDIR/pace-kv.log" >&2; exit 1; }
fi

export PACE_ADDR="127.0.0.1:$PORT"
export PACE_SOURCE_DIR="$WORKSPACE"

# An open port does not mean pace-kv answers yet. Opening a large seed can make
# the first request slow, and pace's configure-time probe allows only 2s, so a
# configure started too early comes out with caching disabled. Before
# configuring, wait until a real pace-cc compile is served.
wait_for_cache() {
    local dir="$LOGDIR/ready-probe"
    mkdir -p "$dir"
    printf 'int paceWarmReady() { return 0; }\n' > "$dir/ready.cpp"
    for attempt in $(seq 24); do
        if (cd "$dir" && PACE_SOURCE_DIR="$dir" PACE_BINARY_DIR="$dir" \
                PACE_SCHEDULER= PACE_VERBOSE=1 PACE_NO_STATS=1 PACE_TIMEOUT=30s \
                timeout 60 pace-cc clang++ -c ready.cpp -o ready.o) 2> "$dir/err" \
            && grep -qE "pace-cc: (HIT|MISS) key=" "$dir/err"; then
            echo "pace-kv is serving requests (attempt $attempt)"
            return 0
        fi
        kill -0 "$KV" 2>/dev/null || break
        sleep 5
    done
    echo "::error::pace-kv never served a compile; last probe output and pace-kv log follow" >&2
    cat "$dir/err" "$LOGDIR/pace-kv.log" >&2 || true
    return 1
}
wait_for_cache || exit 1

for preset in $PRESETS; do
    binary_rel="$(python3 "$HERE/resolve-binary-dir.py" "$WORKSPACE/CMakePresets.json" "$preset")"
    export PACE_BINARY_DIR="$WORKSPACE/$binary_rel"
    echo "::group::configure $preset"
    configure_log="$LOGDIR/configure-$preset.log"
    # Configure downloads dependencies (the CPM bootstrap, CPM packages) from
    # GitHub, and a transient HTTP error there fails it. Retry before failing the
    # group, so one bad download does not cost a multi-hour warm-up.
    #
    # clang-tidy is off: it runs beside every compile, cache hit or not, and
    # writes nothing to the cache. It only changes CMAKE_CXX_CLANG_TIDY, not the
    # compile command, so the entries are the ones a tidy-enabled consumer looks up.
    #
    # CMake only warns when the cache is unusable, so a configure can succeed
    # with caching off. A warm-up must not run uncached, so that counts as a
    # failed attempt too: the probe that decided it can be a transient miss.
    configured=""
    for attempt in 1 2 3; do
        if cmake -S "$WORKSPACE" --preset "$preset" -DUSE_COMPILER_CACHE=ON -DENABLE_TIDY=OFF > "$configure_log" 2>&1; then
            if ! grep -q "caching disabled" "$configure_log"; then
                configured=1
                break
            fi
            echo "::warning::the cache came out disabled for $preset"
            grep -F "[cache]" "$configure_log" || true
        fi
        if [ "$attempt" -lt 3 ]; then
            echo "::warning::configure attempt $attempt failed for $preset; retrying"
            tail -n 20 "$configure_log"
            sleep $((attempt * 30))
        fi
    done
    if [ -z "$configured" ]; then
        cat "$configure_log" >&2
        if grep -q "caching disabled" "$configure_log"; then
            echo "::error::the cache is disabled for $preset; the warm-up would not be cached" >&2
        else
            echo "::error::configure failed for $preset; pace-kv log follows" >&2
        fi
        cat "$LOGDIR/pace-kv.log" >&2 || true
        exit 1
    fi
    cat "$configure_log"
    echo "::endgroup::"
    echo "::group::build $preset"
    if ! cmake --build "$PACE_BINARY_DIR" -j"$(nproc)"; then
        echo "::error::build failed for $preset; pace-kv log follows" >&2
        cat "$LOGDIR/pace-kv.log" >&2 || true
        exit 1
    fi
    echo "::endgroup::"
    case " $TEST_PRESETS " in
        *" $preset "*)
            # Test failures are reported, not gated. The seed depends on what
            # compiled, not on which tests passed, and the container runs as root
            # with no services, which fails a few environment-dependent tests in
            # pace. Build failures still fail the warm-up.
            echo "::group::test $preset"
            # --timeout bounds each test, so one hung test cannot hold the group until
            # the job limit cancels it.
            if ! ctest --test-dir "$PACE_BINARY_DIR" --output-on-failure --timeout 900 -j"$(nproc)"; then
                echo "::warning::ctest reported failures for $preset (not blocking the seed)"
            fi
            echo "::endgroup::"
            ;;
    esac
    pace-cc --show-stats || true
done

# A warm-up that never reached pace-cc stored nothing. Fail it rather than publish
# an empty seed that looks like a successful one.
if pace-cc --show-stats 2>&1 | grep -q "no statistics recorded"; then
    echo "::error::pace-cc recorded no statistics: the cache was not used" >&2
    exit 1
fi

stop_kv
trap - EXIT

# Reopen the finished store once. A store that does not open is never seeded.
if ! start_kv; then
    echo "store did not reopen" >&2
    exit 1
fi
stop_kv
trap - EXIT

ls -l "$STORE"
