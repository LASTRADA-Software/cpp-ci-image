# Using the Shared CI Image

## Use the image

Every Linux job uses the moving `latest` tag. No pin is needed in workflows:

```yaml
jobs:
  build:
    runs-on: ubuntu-24.04
    container:
      image: ghcr.io/lastrada-software/cpp-ci:latest
```

When this repository publishes a new image from `master`, the next job that
starts uses it. There is nothing to update in consumer repositories.

Each published build also has an immutable `<sha>` tag, listed in the GHCR
package. Use it only for investigation, for example to reproduce a failure
against the exact image that produced it. Do not copy it into workflows.

A new image is pushed only after its smoke test passes, so a broken toolchain
is not published. A bad image that passes the smoke test still reaches every
job, so changes that affect the toolchain should be checked in a pull request
first.

### Rollback

If `latest` is bad, re-point it at the last good `<sha>` tag:

```sh
docker buildx imagetools create \
  --tag ghcr.io/lastrada-software/cpp-ci:latest \
  ghcr.io/lastrada-software/cpp-ci:<good-sha>
```

Then fix the problem on `master`. The next successful master build moves
`latest` forward again.

Jobs needing Docker Buildx, a Docker daemon, or nested containers remain
native Linux jobs until that combination has been tested. Windows and macOS
cannot run this Linux image.

## Configure pace-cc

For every CMake configure, configure `pace-cc` for both C and C++:

```yaml
- name: Configure
  shell: bash
  env:
    PACE_ADDR: ${{ vars.PACE_KV_ADDRESS }}
    PACE_TOKEN: ${{ secrets.PACE_KV_TOKEN }}
    PACE_SOURCE_DIR: ${{ github.workspace }}
    PACE_BINARY_DIR: ${{ github.workspace }}/out/build/gcc-release
  run: >
    cmake --preset gcc-release
    -DUSE_COMPILER_CACHE=ON
```

Enable the cache with `-DUSE_COMPILER_CACHE=ON`, not by setting the compiler
launcher variables directly. Passing `-DCMAKE_*_COMPILER_LAUNCHER=pace-cc`
skips the project's path-prefix rules, which keep objects portable across
checkouts.

`PACE_SOURCE_DIR` and `PACE_BINARY_DIR` make entries portable across checkout
paths. They must name the source and build roots actually used by that job.
Set the binary directory independently for each CMake preset.

After a build, collect the launcher statistics:

```yaml
- name: Report pace cache statistics
  if: always()
  run: pace-cc --show-stats
```

A non-zero `unavailable` count means the cache was not reached. Do not remove
the current cache implementation or its fallback path until this is monitored
on the relevant CI matrix.

## Remote cache access

Run the shared daemon with persistent storage, metrics, and an authentication
secret on a private network:

```sh
pace-kv \
  --bind=0.0.0.0 \
  --storage=/var/lib/pace/cache.cow \
  --requirepass="$PACE_KV_TOKEN" \
  --metrics
```

`PACE_TOKEN` is sent only to the `PACE_ADDR` cache endpoint. Store it as an
organization secret, never in a workflow or image layer.

`pace-kv --requirepass` authenticates clients but does not provide a
read-only cache role. Until a read-only proxy or separate access layer is
deployed, pull-request jobs must use only the image's read-only seed cache and
must not receive remote-cache credentials. Trusted default-branch and scheduled
warm-up jobs may use the authenticated read/write endpoint.

Do not expose the cache port to the public internet. `pace-cc` does not expose
a TLS client setting in its documented launcher configuration, so enable
transport encryption only after verifying an end-to-end launcher-compatible
deployment rather than assuming that a daemon-only `--tls` switch is enough.

## Seed-cache lifecycle

The image exposes `/opt/pace/seed-cache` through `PACE_CACHE_SEED_DIR`. Each
warmed project has its own read-only subdirectory, and each group of presets has
its own store file in it. For `pace` the groups are `gcc`, `clang`, `clang-extra`, and
`sanitizers`, so the stores are `$PACE_CACHE_SEED_DIR/pace/gcc.cow`,
`.../clang.cow`, `.../clang-extra.cow`, and `.../sanitizers.cow`. A job copies the store for the group
it builds to a writable location before starting a local daemon:

```sh
mkdir -p "$RUNNER_TEMP/pace-seed"
cp -a "$PACE_CACHE_SEED_DIR/pace/gcc.cow" "$RUNNER_TEMP/pace-seed/cache.cow"
pace-kv --storage="$RUNNER_TEMP/pace-seed/cache.cow" --storage-shards=1 &
export PACE_ADDR=127.0.0.1:6674
```

The store must be opened as a file (`--storage-shards=1`), not as a directory.
A store that does not open should be treated as an empty one, so the build
falls back to compiling.

Warm-ups run on every publish. Each group starts from the store published by the
previous `master` build, so the stores accumulate only what the presets have
actually compiled. The groups and presets are listed in
[`warm-targets.json`](../warm-targets.json). Seeds are keyed by toolchain ABI,
architecture, project, and CMake preset.

## Migration order

1. Migrate and measure `pace` Linux release builds. `pace` is the first warmed project.
2. Migrate `morph` Linux release builds.
3. Migrate `Lightweight` Linux release builds.
4. Migrate `formula-cpp` Linux release builds.
5. Add sanitizer, coverage, and packaging presets only when their independently
   measured cache value exceeds their storage and warm-up cost.
