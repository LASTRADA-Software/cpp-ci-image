#!/usr/bin/env bash
# Warm one project's compile cache into a single-file pace-kv store.
#
# Runs inside the cpp-ci image. The caller checks the project out at $WORKSPACE
# and passes the preset list in the environment. The script fails fast: a
# single failing preset fails the whole warm-up, so no partial seed is published.
#
# Required environment:
#   WORKSPACE   checkout of the project (also PACE_SOURCE_DIR)
#   STORE       path of the single-file store to create, e.g. /warm/cache.cow
#   PRESETS     space-separated configure presets to build, in order
#   TEST_PRESETS space-separated subset of PRESETS to run ctest on
# Optional:
#   WARM_MAX_DISK  on-disk cap for the store (default 4g)
set -euo pipefail

: "${WORKSPACE:?WORKSPACE is required}"
: "${STORE:?STORE is required}"
: "${PRESETS:?PRESETS is required}"
TEST_PRESETS="${TEST_PRESETS:-}"
WARM_MAX_DISK="${WARM_MAX_DISK:-4g}"
HERE="$(cd "$(dirname "$0")" && pwd)"

mkdir -p "$(dirname "$STORE")"
PORT=6674

pace-kv --bind=127.0.0.1 --port="$PORT" \
    --storage="$STORE" --storage-shards=1 \
    --storage-max-disk="$WARM_MAX_DISK" \
    --log-level=warn > "$(dirname "$STORE")/pace-kv.log" 2>&1 &
KV=$!

stop_kv() {
    # SIGTERM lets pace-kv flush its batched commit window before exiting.
    kill -TERM "$KV" 2>/dev/null || true
    wait "$KV" 2>/dev/null || true
}
trap stop_kv EXIT

for _ in $(seq 100); do
    if (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; then break; fi
    sleep 0.2
done

export PACE_ADDR="127.0.0.1:$PORT"
export PACE_SOURCE_DIR="$WORKSPACE"

for preset in $PRESETS; do
    binary_rel="$(python3 "$HERE/resolve-binary-dir.py" "$WORKSPACE/CMakePresets.json" "$preset")"
    export PACE_BINARY_DIR="$WORKSPACE/$binary_rel"
    echo "::group::configure $preset"
    cmake -S "$WORKSPACE" --preset "$preset" -DUSE_COMPILER_CACHE=ON
    echo "::endgroup::"
    echo "::group::build $preset"
    cmake --build "$PACE_BINARY_DIR" -j"$(nproc)"
    echo "::endgroup::"
    case " $TEST_PRESETS " in
        *" $preset "*)
            # Test failures are reported, not gated. The seed depends on what
            # compiled, not on which tests passed, and the container runs as root
            # with no services, which fails a few environment-dependent tests in
            # pace (for example a permission check and daemon start-up). Build
            # failures still fail the warm-up.
            echo "::group::test $preset"
            if ! ctest --test-dir "$PACE_BINARY_DIR" --output-on-failure -j"$(nproc)"; then
                echo "::warning::ctest reported failures for $preset (not blocking the seed)"
            fi
            echo "::endgroup::"
            ;;
    esac
    pace-cc --show-stats || true
done

stop_kv
trap - EXIT

# Verify the store can be reopened. A store that does not open is never seeded.
pace-kv --bind=127.0.0.1 --port="$PORT" --storage="$STORE" --storage-shards=1 \
    --log-level=warn > "$(dirname "$STORE")/pace-kv-verify.log" 2>&1 &
KV=$!
for _ in $(seq 100); do
    if (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; then break; fi
    sleep 0.2
done
if ! kill -0 "$KV" 2>/dev/null; then
    echo "store did not reopen" >&2
    exit 1
fi
stop_kv
trap - EXIT

ls -l "$STORE"
