# C++ CI Image

The shared Linux toolchain image for `pace`, `morph`, `Lightweight`, and
`formula-cpp`.

It includes GCC 14, Clang 22, CMake, Ninja, `pace-cc`, and `pace-kv`. It is
published to GHCR by `.github/workflows/publish.yml`. Consumers use the moving
`latest` tag, which every successful `master` build advances.

Consumers reference `ghcr.io/lastrada-software/cpp-ci:latest` and never a
pinned digest. Read [the usage guide](docs/usage.md) before migrating a workflow.
In particular, every CMake configure must enable the cache with
`-DUSE_COMPILER_CACHE=ON` and set four `pace-cc` environment variables
(`PACE_ADDR`, `PACE_TOKEN`, `PACE_SOURCE_DIR`, `PACE_BINARY_DIR`). An
authenticated `pace-kv` alone does not distinguish cache readers from writers.

## Publishing

`publish.yml` runs in four stages:

1. **resolve** pins an immutable Ubuntu base-image digest and the exact `pace`
   `master` commit, and reads the warm-up groups from `warm-targets.json`.
2. **build** builds the toolchain image with no seed, smoke-tests it, and pushes
   it as `<sha>-base`. Pull requests stop here.
3. **warm** runs one job per group in parallel, inside the base image. Each job
   starts from the previously published seed for its group, so only translation
   units whose inputs changed are recompiled. Each job pushes its result as a
   candidate seed image, `cpp-ci-seed-pace-<group>:<sha>`. A store that came
   out byte-identical to the previous seed re-tags the previous seed image, so
   its layer is not uploaded again.
4. **publish** smoke-tests the candidate seeds with the base image's `pace-kv`,
   adds them to `<sha>-base` as one layer per group, and pushes `<sha>`
   directly from buildkit, so layers the registry already holds are skipped. On
   `master` it also moves `latest` and each group's seed to the new candidates.

If any warm-up group fails, `publish` does not run, and `latest` stays on the
previous image with its previous seeds. Consumers pick up each new image
automatically, so no changes are needed in their repositories.

## Seed warmer

The warmer builds each configured project's presets with the compile cache
enabled, into single-file `pace-kv` stores. Each store is one group of presets,
and the stores are baked into the image as `/opt/pace/seed-cache/<project>/<group>.cow`.
A consumer copies the store for the group it builds.

**Status:** `pace` is the first project onboarded. The other three are not yet
onboarded. The blockers are tracked upstream:

- `Lightweight`: a test compile definition embeds an absolute build-tree path,
  so cache entries are not shared across checkouts. See
  [Lightweight#693](https://github.com/LASTRADA-Software/Lightweight/issues/693).
- `formula-cpp`: no cache integration. See
  [formula-cpp#36](https://github.com/LASTRADA-Software/formula-cpp/issues/36).
- `morph`: not yet measured.

### Manifest

[`warm-targets.json`](warm-targets.json) lists the groups. `pace` has three:

| Group | Presets |
|---|---|
| `gcc` | gcc debug, gcc release, gate-gcc-release |
| `clang` | clang debug, clang release |
| `clang-extra` | gate-clang-debug, clang tracy |
| `sanitizers` | clang asan-ubsan, clang tsan |

Each preset carries `configure_args`, which must match the flags pace's
`build.yml` configures that preset with: `gcc-release` and `clang-release` as
the `linux` job does, `clang-debug` as `clang-asan-ubsan` does, and `clang-tsan`
as `clang-tsan` does. A flag that changes a compile definition changes the cache
key of every translation unit it reaches (`PACE_ENABLE_TLS` adds a PUBLIC define
to the `Pace` library, so it reaches all of them), and a seed warmed without it
never hits.

Coverage presets are excluded, because `pace-cc` binds coverage objects to the
checkout root and they never hit from another checkout. Windows presets are out
of scope.

### What a group job does

[`scripts/warm-project.sh`](scripts/warm-project.sh) runs inside the base image:

- starts a local `pace-kv` on a single-file store, with an on-disk cap of
  `WARM_MAX_DISK` (default `4g`), which evicts least-recently-used entries;
- if the previous seed exists, starts from a copy of it. A store the new
  `pace-kv` refuses (for example after a storage format change) is discarded,
  and the group starts empty;
- for each preset, configures with `-DUSE_COMPILER_CACHE=ON -DENABLE_TIDY=OFF`
  plus the preset's `configure_args`, and builds it. clang-tidy is off because
  it re-runs on every file, even on a cache hit, and adds nothing to the store.
  It doesn't change the compile command, so the seeded entries still hit for
  consumers that build with tidy on;
- fails fast: a failing configure or build stops the group, and a configure that
  disables the cache fails it too;
- fails if `pace-cc` records no statistics, so an uncached warm-up is never
  published;
- stops `pace-kv` with SIGTERM, so batched writes are flushed, and reopens the
  store once.

The project checkout sits at the same path inside the container as on the host,
and that path is pace CI's own checkout path (`PACE_CI_WORKSPACE`,
`/home/runner/work/pace/pace`), with CPM's source cache inside it at
`.cache/CPM` as pace CI keeps it. Some compiles depend on these paths in ways
`pace-cc` cannot map away: pace's generated `tests/CheckoutPaths.hpp` spells the
checkout path, and CMake names the object files of zstd, lz4 and catch2's main by
an absolute path when CPM's cache is outside the source tree. Warmed at any other
path, those 43 gcc-release units miss on every CI run.

### Decisions

- **Parallel groups, one store each.** `pace-kv` cannot merge stores, so each
  group job writes its own store. Groups run in parallel to cut wall-clock time.
- **Incremental reuse.** Each group starts from the previously published seed,
  so only changed translation units are recompiled. The disk cap bounds the
  reused store.
- **Promotion on `master` only.** The candidate seeds become the starting point
  for the next warm-up only when the image that contains them is published.
  Branch runs never move `latest`, so their seeds cannot become a starting point.
- **Build only, no tests.** The seed depends on what compiled, not on which
  tests passed, and `ctest` adds no cache entries. It used to run for the gcc
  and clang release presets, as warnings only, and took about 7.5 minutes per
  group even when every compile hit (run 42597225082), which made it the
  critical path of a warm run. A build failure still fails the warm-up.
- **Groups stay under the job limit.** The clang group ran for 5 h 30 min in
  run 42095583072 and was cancelled by the 330-minute `timeout-minutes`, which
  skipped `publish`. Its gate and tracy presets moved to `clang-extra`.
- **Warm-up runs inside `publish.yml`,** not on a separate schedule. The seed is
  produced by the same `pace-cc`, `pace-kv`, and compilers it is baked beside.
  Cache keys include the compiler banner, and `pace-kv` refuses stores written
  with a different storage format.
- **Credentials.** The warm-up uses a local `pace-kv`, so it needs no
  `PACE_TOKEN`. `pace` is a public repository, so no checkout token is needed.
- **Runner.** The warm-up runs on `ubuntu-24.04` unless the `WARM_RUNNER`
  repository or organization variable selects another runner. A hosted runner
  may not have the time or disk for a full warm-up, so a larger runner may be
  needed.

### Measurements

These come from building on the same machine, against a local `pace-kv` store.

| Build | Compiles | Hits | Notes |
|---|---|---|---|
| `pace` `gcc-release`, cold, checkout A | 1,173 | 0 | 541 s build |
| `pace` `gcc-release`, checkout B, same store | 1,173 | 1,149 (98.0%) | 52 s build; 23 misses not investigated |
| `pace` `gcc-release`, starting from the previous seed | 1,173 | 1,172 (100%) | incremental reuse |
| `Lightweight` `gcc-release`, checkout B, same store | 243 | 104 (43%) | cause: test compile definition with absolute path |
| `Lightweight` after that define is made relative | 228 | 226 (99.1%) | counterfactual |
| `formula-cpp` `gcc-release`, checkout B, launchers set by hand | 415 | 339 (81.7%) | no cache integration; prefix-map rules not applied |

The store size for `pace` has not been measured yet, so the `4g` cap is a
placeholder. It should be set from the first real run.

### Open risks

- **The 23 `pace` misses are unexplained.** A verbose run would show which
  translation units miss.
- **Warm-up time on hosted runners is unknown.** Nine presets, two of them
  sanitizer builds, may exceed the time or disk of a standard runner. The groups
  shorten the wall-clock time, not the total work.
- **A configure can fail intermittently on the cache exchange.** Once, a configure
  reported `fetch exchange failed` and disabled the cache. It did not recur in
  the verbose re-run. The script now fails the group when the cache is disabled,
  so this cannot publish an uncached seed.
- **Compiler banner drift.** If the `apt.llvm.org` clang 22 point release changes
  between daily builds, the cache is re-keyed every day. The base build pins the
  compiler version, so the banner should be compared between runs.
- **Seed size in every pull.** The seeds are part of the image, so every job that
  pulls the image also pulls them. Reuse keeps the stores bounded by the disk cap,
  not by the number of runs.
